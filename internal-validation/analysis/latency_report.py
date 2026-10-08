#!/usr/bin/env python3
"""
Latency report for Experiment 2 (latency-baseline.js).

Reads a `run.sh latency` results directory. Uses the RAW per-request
processing_time values (k6 --out csv) when present, and falls back to the
quantile table in summary.json (every 0.5 % plus the far tail) when not.
Only samples sent in each step's measure window are used.

Per config and rate step it reports p50 / p90 / p95 / p99 / p99.9, and runs
the flat-until-saturation check against that config's LOWEST rate:
  ks          two-sample Kolmogorov-Smirnov distance between the two ECDFs
              (0 = identical distributions, 1 = disjoint); shown, not gated
  p95 ratio   p95 of this step / p95 of the lowest step       gate: <= --p95-ratio
  drift       how much the median rose from the start of the step to its end
              (least-squares over per-second medians)       gate: <= --drift-frac
                                                                x lowest-step p95
                                                                (and at least 5 ms)
  drops/fail  any dropped iteration or failed request          gate: none
A step passing every gate is FLAT; the first step that fails one is where
queueing starts for that config.

A second table splits each step by endpoint type:
  non-held  cache, batch, aggregate: processing_time is the full duration, exact
  held      fetch, ingest, process: duration minus the hold the server waited,
            which carries about +-1 ms of timer error that cannot be removed from
            the client (see k6-scenarios/lib/workload.js); its share at 0 is shown
Quote medians and other sub-millisecond figures from the non-held columns.

Plots (in <results-dir>/plots/):
  latency_ecdf_by_step.png       one panel per rate, the configs overlaid
  latency_ecdf_by_config.png     one panel per config, its rates overlaid (flatness)
  latency_histogram_by_step.png  log-binned histograms, configs overlaid
  latency_percentiles_vs_rate.png  p50 / p95 / p99 against offered rate

Usage: latency_report.py RESULTS_DIR [--p95-ratio 1.5] [--drift-frac 0.5] [--no-plot]
"""

import argparse
from pathlib import Path

import numpy as np

from common import (INK_2, color, configs, container_fate, die, direct_label, ecdf, ks_distance, label,
                    load_samples, panel_grid, pick_steps, print_table, pyplot, ramp, read_json, save_csv,
                    save_figure)

PCTS = [50, 90, 95, 99, 99.9]
HELD = {'fetch', 'ingest', 'process'}   # endpoints whose server-side hold is subtracted


def from_quantiles(table: dict | None) -> tuple[np.ndarray, np.ndarray] | None:
    """(values, cumulative probability) from a summary quantile table."""
    if not table or not table.get('quantiles'):
        return None
    q = sorted((float(p), v) for p, v in table['quantiles'].items() if v is not None)
    x = np.array([v for _, v in q])
    y = np.array([p / 100 for p, _ in q])
    return x, y


def drift_ms(samples) -> float:
    """Rise of the per-second median across the step, from a least-squares line."""
    per = samples.groupby(samples['t_s'].astype(int))['value'].median()
    if len(per) < 5:
        return float('nan')
    slope = np.polyfit(per.index.values, per.values, 1)[0]
    return float(slope * (per.index.max() - per.index.min()))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('results_dir', type=Path)
    ap.add_argument('--p95-ratio', type=float, default=1.5, help='largest p95 vs the lowest rate still called flat')
    ap.add_argument('--drift-frac', type=float, default=0.5, help='largest within-step drift, as a fraction of lowest-rate p95')
    ap.add_argument('--no-plot', action='store_true')
    args = ap.parse_args()

    data = {}   # cfg -> {rate: {'values': array|None, 'curve': (x, y), 'step': summary row, 'raw': df}}
    for cfg, d in configs(args.results_dir):
        s = read_json(d / 'summary.json')
        if not s or s.get('experiment') != 'latency-baseline':
            die(f'{d}/summary.json is not a latency-baseline summary')
        raw = load_samples(d / 'raw.csv.gz', 'processing_time', ('step', 'phase', 'endpoint', 't_s'))
        fate = container_fate(read_json(d / 'run.json'))
        steps = {}
        for row in s['steps']:
            rate = row['offered_rps']
            entry = {'step': row, 'fate': fate, 'values': None, 'raw': None}
            if raw is not None and len(raw):
                m = raw[(raw['phase'] == 'measure') & (raw['step'].astype(float) == float(rate))]
                if len(m):
                    entry['raw'] = m
                    entry['values'] = m['value'].to_numpy()
            entry['curve'] = ecdf(entry['values']) if entry['values'] is not None else from_quantiles(row['processing_ms'])
            steps[rate] = entry
        data[cfg] = {'steps': steps, 'raw': raw is not None, 'fate': fate}

    rows, onset = [], {}
    for cfg, c in data.items():
        rates = sorted(c['steps'])
        base = c['steps'][rates[0]]
        base_p95 = pct(base, 95)
        drift_limit = max(5.0, args.drift_frac * base_p95) if not np.isnan(base_p95) else float('nan')
        onset[cfg] = None
        for rate in rates:
            e = c['steps'][rate]
            st = e['step']
            p = {q: pct(e, q) for q in PCTS}
            ks = ks_distance(base['values'], e['values']) if e['values'] is not None and base['values'] is not None else float('nan')
            ratio = p[95] / base_p95 if base_p95 else float('nan')
            drift = drift_ms(e['raw']) if e['raw'] is not None else float('nan')
            reasons = []
            if st['dropped_iterations']:
                reasons.append('dropped')
            if st['failed']:
                reasons.append('failed')
            if ratio > args.p95_ratio:
                reasons.append(f'p95 x{ratio:.1f}')
            if not np.isnan(drift) and drift > drift_limit:
                reasons.append(f'drift +{drift:.0f} ms')
            if e['fate']:
                reasons.append(e['fate'])
            verdict = 'flat' if not reasons else 'NOT FLAT: ' + ', '.join(reasons)
            if reasons and onset[cfg] is None:
                onset[cfg] = rate
            n = len(e['values']) if e['values'] is not None else (st['processing_ms'] or {}).get('count', 0)
            rows.append([label(cfg), rate, st['achieved_rps'], st['dropped_iterations'], st['failed'], n,
                         *[p[q] for q in PCTS], ks, ratio, drift, verdict])

    cols = ['config', 'offered/s', 'achieved/s', 'dropped', 'failed', 'n', 'p50 ms', 'p90 ms', 'p95 ms', 'p99 ms',
            'p99.9 ms', 'KS vs lowest', 'p95 ratio', 'drift ms', 'verdict']
    print_table('Processing time per rate step (measure window only; KS / ratio / drift vs the lowest rate)', cols, rows)
    save_csv(args.results_dir / 'latency_steps.csv', cols, rows)
    srows = []
    for cfg, c in data.items():
        for rate in sorted(c['steps']):
            e = c['steps'][rate]
            if e['raw'] is None:
                continue
            is_held = e['raw']['endpoint'].isin(HELD)
            free, held = e['raw'][~is_held]['value'].to_numpy(), e['raw'][is_held]['value'].to_numpy()
            q = lambda v: [float(np.percentile(v, x)) if len(v) else float('nan') for x in (50, 95, 99)]
            srows.append([label(cfg), rate, len(free), *q(free), len(held), *q(held),
                          f'{(held <= 0).mean():.1%}' if len(held) else '-'])
    if srows:
        scols = ['config', 'offered/s', 'non-held n', 'p50 ms', 'p95 ms', 'p99 ms', 'held n', 'p50 ms', 'p95 ms',
                 'p99 ms', 'held at 0']
        print_table('By endpoint type: non-held (cache/batch/aggregate, exact) vs held (fetch/ingest/process, '
                    'minus the hold; +-1 ms timer error)', scols, srows)
        save_csv(args.results_dir / 'latency_by_endpoint_type.csv', scols, srows)
    print('\nWhere queueing starts')
    for cfg, rate in onset.items():
        src = 'raw samples' if data[cfg]['raw'] else 'summary quantiles (no raw.csv.gz: KS and drift unavailable)'
        print(f'  {label(cfg):14} ' + (f'first non-flat step at {rate} req/s' if rate is not None
                                         else 'flat across every step tested') + f'   [{src}]')

    if args.no_plot:
        return
    plt = pyplot()
    if plt is None:
        return
    out = args.results_dir / 'plots'
    all_rates = sorted({r for c in data.values() for r in c['steps']})

    # 1. configs overlaid, one panel per rate
    fig, axes = panel_grid(plt, len(all_rates), 3.6, 3.3, sharey=True)
    for ax, rate in zip(axes, all_rates):
        for cfg, c in data.items():
            e = c['steps'].get(rate)
            if e and e['curve'] is not None:
                ax.plot(*e['curve'], color=color(cfg), label=label(cfg), drawstyle='steps-post')
        ax.set_xscale('log')
        ax.set_title(f'{rate:g} req/s offered')
        ax.set_xlabel('processing time, ms (log)')
        ax.set_ylabel('fraction at or below')
    axes[0].legend(loc='lower right')
    fig.suptitle('Processing-time ECDF per rate, allocator configs overlaid', x=0.01, ha='left', fontsize=11, fontweight='bold')
    fig.tight_layout()
    save_figure(fig, out / 'latency_ecdf_by_step.png')
    plt.close(fig)

    # 2. one panel per config, its rates overlaid: the flatness picture
    fig, axes = panel_grid(plt, len(data), 3.9, 3.5, sharey=True)
    for ax, (cfg, c) in zip(axes, data.items()):
        shown = pick_steps(sorted(c['steps']))
        for rate, col in zip(shown, ramp(len(shown))):
            e = c['steps'][rate]
            if e['curve'] is None:
                continue
            x, y = e['curve']
            ax.plot(x, y, color=col, label=f'{rate:g}/s', drawstyle='steps-post')
        ax.set_xscale('log')
        title = label(cfg) + (f'  ({len(shown)} of {len(c["steps"])} rates)' if len(shown) < len(c['steps']) else '')
        ax.set_title(title)
        ax.set_xlabel('processing time, ms (log)')
        ax.legend(loc='lower right', title='offered', title_fontsize=8)
        ax.set_ylabel('fraction at or below')
    fig.suptitle('Does the distribution stay put as the rate rises? (light = low rate, dark = high)',
                 x=0.01, ha='left', fontsize=11, fontweight='bold')
    fig.tight_layout()
    save_figure(fig, out / 'latency_ecdf_by_config.png')
    plt.close(fig)

    # 3. log-binned histograms (raw samples only)
    if any(c['raw'] for c in data.values()):
        allv = np.concatenate([e['values'] for c in data.values() for e in c['steps'].values() if e['values'] is not None])
        pos = allv[allv > 0]
        if len(pos):
            bins = np.logspace(np.log10(max(pos.min(), 1e-3)), np.log10(pos.max()), 60)
            fig, axes = panel_grid(plt, len(all_rates), 3.6, 3.2, sharey=True)
            for ax, rate in zip(axes, all_rates):
                for cfg, c in data.items():
                    e = c['steps'].get(rate)
                    if e and e['values'] is not None:
                        v = e['values'][e['values'] > 0]
                        ax.hist(v, bins=bins, density=False, weights=np.full(len(v), 1 / max(len(v), 1)),
                                histtype='step', linewidth=1.5, color=color(cfg), label=label(cfg))
                ax.set_xscale('log')
                ax.set_title(f'{rate:g} req/s offered')
                ax.set_xlabel('processing time, ms (log bins)')
                ax.set_ylabel('share per bin')
            axes[0].legend(loc='upper right')
            fig.suptitle('Processing-time histogram per rate, configs overlaid', x=0.01, ha='left', fontsize=11, fontweight='bold')
            fig.tight_layout()
            save_figure(fig, out / 'latency_histogram_by_step.png')
            plt.close(fig)

    # 4. percentiles against offered rate: one panel per percentile (same scale within a panel)
    fig, axes = plt.subplots(1, 3, figsize=(12, 3.8), squeeze=False)
    for ax, q in zip(axes[0], (50, 95, 99)):
        for cfg, c in data.items():
            rates = sorted(c['steps'])
            vals = [pct(c['steps'][r], q) for r in rates]
            ax.plot(rates, vals, '-o', color=color(cfg), label=label(cfg))
            if rates:
                direct_label(ax, rates[-1], vals[-1], label(cfg), color(cfg))
            if onset.get(cfg) is not None:
                ax.axvline(onset[cfg], color=color(cfg), linewidth=0.8, linestyle=':', zorder=1)
        ax.set_xscale('log')
        ax.set_yscale('log')
        ax.set_title(f'p{q:g}')
        ax.set_xlabel('offered rate, req/s (log)')
        ax.margins(x=0.15)
    axes[0][0].set_ylabel('processing time, ms (log)')
    axes[0][0].legend(loc='upper left')
    fig.text(0.01, -0.03, 'Flat lines = no queueing. Dotted: first rate where the flatness check failed for that config.',
             color=INK_2, fontsize=8)
    fig.tight_layout()
    save_figure(fig, out / 'latency_percentiles_vs_rate.png')


def pct(entry: dict, q: float) -> float:
    """Percentile q of a step: exact from raw samples, else read off the quantile table."""
    if entry['values'] is not None and len(entry['values']):
        return float(np.percentile(entry['values'], q))
    table = (entry['step'].get('processing_ms') or {}).get('quantiles') or {}
    for key in (f'{q:g}', str(q)):
        if key in table and table[key] is not None:
            return float(table[key])
    return float('nan')


if __name__ == '__main__':
    main()
