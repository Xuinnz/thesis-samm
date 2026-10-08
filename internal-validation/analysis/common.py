"""
Shared helpers for the internal-validation analysis scripts.

Layout they read (written by internal-validation/run.sh):
    <results-dir>/<config>/summary.json    k6 handleSummary output
    <results-dir>/<config>/raw.csv.gz      every k6 sample (k6 --out csv, timestamps in ms)
    <results-dir>/<config>/container.tsv   cgroup CPU / memory / faults, one row per second
    <results-dir>/<config>/run.json        settings, host, and whether the container survived

Needs pandas and numpy; plots need matplotlib (pip install -r requirements.txt).
Without matplotlib the reports still print and save their tables.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import numpy as np
import pandas as pd

CONFIG_ORDER = ['glibc', 'jemalloc', 'samm', 'glibc-tuned']
LABEL = {'glibc': 'glibc (stock)', 'jemalloc': 'jemalloc', 'samm': 'SAMM', 'glibc-tuned': 'glibc (tuned)'}

# Each config keeps one colour in every chart, whichever configs are present
# (categorical slots 1-4 of the dataviz reference palette; validated CVD-safe
# for adjacent pairs). Aqua and yellow sit below 3:1 contrast on the surface,
# so every chart also carries a legend and direct labels, and every number is
# printed and saved as a table.
COLOR = {'glibc': '#2a78d6', 'jemalloc': '#eb6834', 'samm': '#1baf7a', 'glibc-tuned': '#eda100'}
# Ordered steps (rates, VU counts): one hue, light to dark, validated for 5 steps.
RAMP = ['#86b6ef', '#5598e7', '#2a78d6', '#1c5cab', '#0d366b']
SURFACE, INK, INK_2, GRID = '#fcfcfb', '#0b0b0b', '#52514e', '#e4e3de'


def die(msg: str) -> None:
    print(f'error: {msg}', file=sys.stderr)
    sys.exit(1)


def read_json(path: Path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def configs(results_dir: Path) -> list[tuple[str, Path]]:
    """(config, directory) for every config that has a summary.json, in a fixed order."""
    found = {p.name: p for p in sorted(results_dir.iterdir()) if p.is_dir() and (p / 'summary.json').exists()}
    if not found:
        die(f'no <config>/summary.json under {results_dir} -- is this a run.sh results directory?')
    ordered = [c for c in CONFIG_ORDER if c in found] + [c for c in found if c not in CONFIG_ORDER]
    return [(c, found[c]) for c in ordered]


def label(config: str) -> str:
    return LABEL.get(config, config)


def color(config: str) -> str:
    return COLOR.get(config, INK_2)


def container_fate(run: dict | None) -> str:
    """'' if the container survived the run, otherwise why it did not."""
    if not run:
        return ''
    end = run.get('container_end_state') or {}
    if end.get('oom_killed'):
        return f"OOM-killed (exit {end.get('exit_code')})"
    if end.get('status') not in (None, 'running'):
        return f"container {end.get('status')} (exit {end.get('exit_code')})"
    return ''


_TAG_CACHE: dict[str, re.Pattern] = {}


def _tag(series: pd.Series, key: str) -> pd.Series:
    pat = _TAG_CACHE.setdefault(key, re.compile(rf'(?:^|&){re.escape(key)}=([^&]*)'))
    return series.str.extract(pat, expand=False)


def load_samples(csv_path: Path, metric: str, tags: tuple[str, ...]) -> pd.DataFrame | None:
    """
    One k6 metric from a k6 --out csv file, as columns ts_ms, value, scenario,
    status and one column per requested tag. Read in chunks: a throughput run's
    raw file holds millions of rows for other metrics.
    """
    if not csv_path.exists():
        return None
    parts = []
    for chunk in pd.read_csv(csv_path, usecols=['metric_name', 'timestamp', 'metric_value', 'scenario', 'status', 'extra_tags'],
                             dtype={'extra_tags': str, 'scenario': str, 'status': str}, chunksize=500_000):
        chunk = chunk[chunk['metric_name'] == metric]
        if len(chunk):
            parts.append(chunk)
    if not parts:
        return pd.DataFrame(columns=['ts_ms', 'value', 'scenario', 'status', *tags])
    df = pd.concat(parts, ignore_index=True)
    out = pd.DataFrame({'ts_ms': df['timestamp'].astype('int64'), 'value': df['metric_value'].astype(float),
                        'scenario': df['scenario'], 'status': df['status']})
    extra = df['extra_tags'].fillna('')
    for key in tags:
        out[key] = _tag(extra, key).values
    return out


def load_container(path: Path) -> pd.DataFrame | None:
    if not path.exists():
        return None
    df = pd.read_csv(path, sep='\t')
    return df.dropna() if len(df) else None


def container_window(tsv: pd.DataFrame | None, start_ms: float, end_ms: float) -> dict | None:
    """
    CPU, memory and faults of the container between two wall-clock moments.
    Durations use /proc/uptime deltas (monotonic); wall_ms only locates the rows.
    """
    if tsv is None:
        return None
    inside = tsv[(tsv['wall_ms'] >= start_ms) & (tsv['wall_ms'] <= end_ms)]
    if len(inside) < 3:
        return None
    a, b = inside.iloc[0], inside.iloc[-1]
    secs = b['uptime_s'] - a['uptime_s']
    if secs <= 0:
        return None
    return {
        'seconds': secs,
        'cpu_frac': (b['usage_usec'] - a['usage_usec']) / 1e6 / secs,
        'user_frac': (b['user_usec'] - a['user_usec']) / 1e6 / secs,
        'system_frac': (b['system_usec'] - a['system_usec']) / 1e6 / secs,
        'throttled_periods': b['nr_throttled'] - a['nr_throttled'],
        'faults': b['pgfault'] - a['pgfault'],
        'peak_memory_mb': inside['memory_current'].max() / 1048576,
    }


def container_load(tsv_path: Path, window_ms: tuple[float, float] | None) -> dict | None:
    """container_window() for a container.tsv file and a (start, end) wall-clock window."""
    if window_ms is None:
        return None
    return container_window(load_container(tsv_path), *window_ms)


def ecdf(values) -> tuple[np.ndarray, np.ndarray]:
    x = np.sort(np.asarray(values, dtype=float))
    return x, np.arange(1, len(x) + 1) / len(x)


def ks_distance(a, b) -> float:
    """Two-sample Kolmogorov-Smirnov statistic: the largest vertical gap between two ECDFs."""
    a, b = np.sort(np.asarray(a, dtype=float)), np.sort(np.asarray(b, dtype=float))
    if len(a) == 0 or len(b) == 0:
        return float('nan')
    grid = np.concatenate([a, b])
    fa = np.searchsorted(a, grid, side='right') / len(a)
    fb = np.searchsorted(b, grid, side='right') / len(b)
    return float(np.max(np.abs(fa - fb)))


def ramp(n: int) -> list[str]:
    """n ordered colours (n <= 5) spread over the validated ramp."""
    if n <= 0:
        return []
    if n == 1:
        return [RAMP[2]]
    idx = np.round(np.linspace(0, len(RAMP) - 1, n)).astype(int)
    return [RAMP[i] for i in idx]


def pick_steps(values: list, limit: int = 5) -> list:
    """
    At most `limit` of the ordered values: always the lowest and the top two
    (where queueing begins, the part the flatness check is about), the rest
    spread evenly between them.
    """
    n = len(values)
    if n <= limit:
        return list(values)
    keep = {0, n - 2, n - 1}
    middle = np.round(np.linspace(1, n - 3, limit - len(keep))).astype(int)
    keep.update(int(i) for i in middle)
    return [values[i] for i in sorted(keep)][:limit]


def panel_grid(plt, n: int, width: float, height: float, max_cols: int = 4, **kw):
    """Figure with n panels wrapped into rows of at most max_cols; unused panels hidden."""
    cols = min(max_cols, n)
    rows = int(np.ceil(n / cols))
    fig, axes = plt.subplots(rows, cols, figsize=(width * cols, height * rows), squeeze=False, **kw)
    flat = list(axes.flat)
    for ax in flat[n:]:
        ax.set_visible(False)
    return fig, flat[:n]


def print_table(title: str, columns: list[str], rows: list[list]) -> None:
    def cell(v):
        if isinstance(v, float):
            return '-' if np.isnan(v) else (f'{v:,.0f}' if abs(v) >= 1000 else f'{v:,.2f}' if abs(v) < 10 else f'{v:,.1f}')
        return '-' if v is None else str(v)
    text = [[cell(v) for v in r] for r in rows]
    widths = [max(len(c), *(len(r[i]) for r in text)) for i, c in enumerate(columns)] if text else [len(c) for c in columns]
    print(f'\n{title}')
    print('  ' + '  '.join(c.rjust(w) for c, w in zip(columns, widths)))
    for r in text:
        print('  ' + '  '.join(v.rjust(w) for v, w in zip(r, widths)))


def save_csv(path: Path, columns: list[str], rows: list[list]) -> None:
    pd.DataFrame(rows, columns=columns).to_csv(path, index=False)


# --------------------------------------------------------------------- plots

def pyplot():
    """matplotlib.pyplot configured for these charts, or None if it is not installed."""
    try:
        import matplotlib
        matplotlib.use('Agg')
        import matplotlib.pyplot as plt
    except ImportError:
        print('\n(matplotlib not installed: tables only. pip install -r internal-validation/analysis/requirements.txt)')
        return None
    plt.rcParams.update({
        'figure.facecolor': SURFACE, 'axes.facecolor': SURFACE, 'savefig.facecolor': SURFACE,
        'axes.edgecolor': GRID, 'axes.labelcolor': INK_2, 'axes.titlecolor': INK, 'axes.titlesize': 11,
        'axes.titleweight': 'bold', 'axes.titlelocation': 'left', 'axes.labelsize': 9,
        'xtick.color': INK_2, 'ytick.color': INK_2, 'xtick.labelsize': 8, 'ytick.labelsize': 8,
        'axes.grid': True, 'grid.color': GRID, 'grid.linewidth': 0.6, 'axes.axisbelow': True,
        'axes.spines.top': False, 'axes.spines.right': False,
        'legend.frameon': False, 'legend.fontsize': 8, 'legend.labelcolor': INK,
        'lines.linewidth': 1.5, 'lines.markersize': 6, 'font.size': 9, 'text.color': INK,
    })
    return plt


def direct_label(ax, x, y, text, color_hex, dx=4):
    """Text label at the end of a line, in ink; a small swatch-coloured dot carries identity."""
    ax.plot([x], [y], 'o', color=color_hex, markersize=4, zorder=5)
    ax.annotate(text, (x, y), xytext=(dx, 0), textcoords='offset points', va='center', fontsize=8, color=INK)


def save_figure(fig, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fig.savefig(path, dpi=150, bbox_inches='tight')
    print(f'  plot: {path}')
