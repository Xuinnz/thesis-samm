#!/usr/bin/env python3
"""
Calibration report: how many VUs saturate each config, and what to set.

Reads a `run.sh calibrate` results directory. For each config and VU step it
measures throughput, processing time, and -- from the container's cgroup --
CPU used and peak memory during the step's measured part.

Saturation is judged by CPU, not by the throughput curve. The server has one
vCPU: once it uses all of it, adding VUs cannot add throughput, only queueing.
Throughput at saturation wobbles by a few percent from step to step, so a
"97 % of the best step" rule can mistake that noise for still-rising.
  knee      = fewest VUs at which the container used >= --sat-cpu of its vCPU
              (falls back to the throughput plateau if container.tsv is missing)
  capacity  = highest throughput any valid step reached
A step is valid if it had no failed requests; a container that died fails
every later step, so those drop out.

Recommends:
  SATURATION_VUS     = the next tested VU count above the highest knee (one step
                       of margin), provided EVERY config ran that step validly
                       with peak memory <= --mem-frac of its limit. Higher VU
                       counts add only queueing and memory, and the configs run
                       out of memory at different points.
  LATENCY_RPS_SWEEP  = doubling rates up to 80 % of the LOWEST capacity, then
                       80 % and 95 % points, so the flatness check can see where
                       the slowest config starts to queue

Usage: calibration_report.py RESULTS_DIR [--sat-cpu 0.98] [--mem-frac 0.90]
                             [--plateau 0.97] [--no-plot]
"""

import argparse
import math
import re
from pathlib import Path

from common import (INK_2, color, configs, container_fate, container_window, die, direct_label, label,
                    load_container, load_samples, print_table, pyplot, read_json, save_csv, save_figure)

NAN = float('nan')


def nice_floor(x: float) -> float:
    """Largest 1/2/5 x 10^n not above x."""
    if x <= 0:
        return 0
    p = 10 ** math.floor(math.log10(x))
    return max(m * p for m in (1, 2, 5) if m * p <= x)


def memory_limit_mb(run: dict | None) -> float:
    raw = str(((run or {}).get('container_limits') or {}).get('memory', '1024m'))
    m = re.match(r'^(\d+)([mg]?)$', raw.lower())
    if not m:
        return 1024.0
    return float(m.group(1)) * (1024 if m.group(2) == 'g' else 1)


def step_resources(d: Path, steps: list) -> None:
    """Adds cpu and peak_mb to each step from container.tsv, windowed by the step's measured completions."""
    raw = load_samples(d / 'raw.csv.gz', 'completed_iterations', ('step', 'phase', 'ok'))
    tsv = load_container(d / 'container.tsv')
    for s in steps:
        s['cpu'] = s['peak_mb'] = NAN
        if raw is None or tsv is None:
            continue
        m = raw[(raw['step'] == str(s['vus'])) & (raw['phase'] == 'measure') & (raw['ok'] == 'true')]
        if len(m) < 10:
            continue
        w = container_window(tsv, m['ts_ms'].min(), m['ts_ms'].max())
        if w:
            s['cpu'], s['peak_mb'] = w['cpu_frac'], w['peak_memory_mb']


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('results_dir', type=Path)
    ap.add_argument('--sat-cpu', type=float, default=0.98, help='CPU (of 1 vCPU) that counts as saturated (default 0.98)')
    ap.add_argument('--mem-frac', type=float, default=0.90, help='largest safe peak memory, as a fraction of the limit (default 0.90)')
    ap.add_argument('--plateau', type=float, default=0.97, help='throughput fraction for the fallback knee (default 0.97)')
    ap.add_argument('--no-plot', action='store_true')
    args = ap.parse_args()

    rows, per_config = [], {}
    for cfg, d in configs(args.results_dir):
        summary = read_json(d / 'summary.json')
        if not summary or summary.get('experiment') != 'calibrate-saturation':
            die(f'{d}/summary.json is not a calibrate-saturation summary')
        run = read_json(d / 'run.json')
        limit = memory_limit_mb(run)
        steps = summary['steps']
        step_resources(d, steps)
        broken = False
        for s in steps:
            broken = broken or s['failed'] > 0
            s['valid'] = not broken
            s['safe'] = s['valid'] and not (s['peak_mb'] > args.mem_frac * limit)   # NaN (unknown) counts as safe
        valid = [s for s in steps if s['valid']]
        r = {'steps': steps, 'fate': container_fate(run), 'limit_mb': limit, 'capacity': NAN, 'knee': None,
             'knee_by': '-', 'saturated': False}
        if valid:
            r['capacity'] = max(s['throughput_rps'] for s in valid)
            has_cpu = any(not math.isnan(s['cpu']) for s in valid)
            cpu_knees = [s['vus'] for s in valid if s['cpu'] >= args.sat_cpu]
            if has_cpu and cpu_knees:
                r['knee'], r['knee_by'], r['saturated'] = min(cpu_knees), 'CPU', True
            elif has_cpu:
                r['knee'], r['knee_by'] = max(s['vus'] for s in valid), 'none'   # never reached --sat-cpu
            else:
                r['knee'] = min(s['vus'] for s in valid if s['throughput_rps'] >= args.plateau * r['capacity'])
                r['knee_by'] = 'throughput'
                r['saturated'] = any(s['vus'] > r['knee'] for s in valid)
        per_config[cfg] = r
        for s in steps:
            p = s['processing_ms']
            rows.append([label(cfg), s['vus'], s['throughput_rps'], s['failed'], s['cpu'], s['peak_mb'],
                         p.get('med'), p.get('p95'), 'yes' if s['valid'] else 'no'])

    cols = ['config', 'VUs', 'throughput/s', 'failed', 'CPU', 'peak MB', 'proc p50 ms', 'proc p95 ms', 'valid']
    print_table('Calibration steps (measured part of each step only; CPU = share of the 1 vCPU)', cols, rows)
    save_csv(args.results_dir / 'calibration_steps.csv', cols, rows)

    krows = [[label(c), r['capacity'], r['knee'], r['knee_by'],
              'yes' if r['saturated'] else f'NO -- never reached {args.sat_cpu:.0%} CPU', r['fate'] or 'survived']
             for c, r in per_config.items()]
    kcols = ['config', 'capacity req/s', 'knee VUs', 'knee from', 'saturated', 'container']
    print_table(f'Knee per config (fewest VUs using >= {args.sat_cpu:.0%} of the vCPU)', kcols, krows)
    save_csv(args.results_dir / 'calibration_knees.csv', kcols, krows)

    print('\nRecommendation')
    knees = {c: r['knee'] for c, r in per_config.items()}
    if any(k is None for k in knees.values()) or not all(r['saturated'] for r in per_config.values()):
        print('  Not every config saturated (or some had no valid step): extend CAL_VUS or fix the failure first.')
    else:
        top = max(knees.values())
        tested = sorted({s['vus'] for r in per_config.values() for s in r['steps']})
        above = [v for v in tested if v > top]

        def safe_for_all(v):
            return all(any(s['vus'] == v and s['safe'] for s in r['steps']) for r in per_config.values())

        choice = next((v for v in above[:1] if safe_for_all(v)), None)
        if choice is not None:
            print(f'  highest knee {top} VUs ({label(max(knees, key=knees.get))}); one tested step above it, run safely by every')
            print(f'  config (peak memory <= {args.mem_frac:.0%} of the limit) -> SATURATION_VUS={choice}')
        elif safe_for_all(top):
            print(f'  the step above the highest knee was not safe for every config -> SATURATION_VUS={top}')
            print('  (the highest knee itself, with no margin: check the throughput report\'s CPU column)')
        else:
            print(f'  NOT FEASIBLE as measured: no VU count at or above the highest knee ({top}) was run safely by every')
            print('  config. The slowest config runs out of memory before the fastest saturates.')
        for c, r in per_config.items():
            unsafe = [s['vus'] for s in r['steps'] if not s['safe']]
            if unsafe:
                print(f'  {label(c)}: unsafe from {min(unsafe)} VUs ({r["fate"] or "peak memory over the limit fraction"})')

    caps = [r['capacity'] for r in per_config.values() if not math.isnan(r['capacity'])]
    if caps:
        low = min(caps)
        lowest = min((c for c in per_config if not math.isnan(per_config[c]['capacity'])), key=lambda c: per_config[c]['capacity'])
        sweep, r = [], nice_floor(low / 32) or 1
        while r <= 0.8 * low:
            sweep.append(int(r))
            r *= 2
        for frac in (0.8, 0.95):
            point = int(round(frac * low / 10) * 10)
            if not sweep or point > sweep[-1] * 1.15:
                sweep.append(point)
        print(f'  lowest capacity {low:.0f} req/s ({label(lowest)}) -> LATENCY_RPS_SWEEP={",".join(map(str, sweep))}')
        print('  (doubling up to 80 % of the lowest capacity, then 95 %: the last step sits just under the slowest')
        print("   config's limit, so the flatness check can see where its queueing begins)")

    if args.no_plot:
        return
    plt = pyplot()
    if plt is None:
        return
    fig, axes = plt.subplots(1, 3, figsize=(15, 4.2))
    panels = [('throughput_rps', 'Throughput vs VUs (dotted: knee)', 'completed requests / s', False),
              ('cpu', 'Container CPU vs VUs', 'share of the 1 vCPU', False),
              ('p95', 'Processing time p95 vs VUs', 'ms (log scale)', True)]
    for ax, (key, title, ylabel, logy) in zip(axes, panels):
        for cfg, r in per_config.items():
            v = [s for s in r['steps'] if s['valid']]
            if not v:
                continue
            x = [s['vus'] for s in v]
            y = [s['processing_ms'].get('p95') if key == 'p95' else s[key] for s in v]
            ax.plot(x, y, '-o', color=color(cfg), label=label(cfg))
            direct_label(ax, x[-1], y[-1], label(cfg), color(cfg))
            if key == 'throughput_rps' and r['knee'] is not None:
                ax.axvline(r['knee'], color=color(cfg), linewidth=0.8, linestyle=':', zorder=1)
        ax.set_title(title)
        ax.set_xlabel('VUs (closed loop)')
        ax.set_ylabel(ylabel)
        if logy:
            ax.set_yscale('log')
        else:
            ax.set_ylim(bottom=0)
        ax.legend(loc='upper left')
        ax.margins(x=0.14)
    axes[1].axhline(args.sat_cpu, color=INK_2, linewidth=0.8, linestyle='--', zorder=1)
    fig.text(0.01, -0.02, 'Once a config uses its whole vCPU, extra VUs only queue: throughput flattens while processing time '
             'climbs. Steps after a failure (e.g. an OOM kill) are not drawn.', color=INK_2, fontsize=8)
    fig.tight_layout()
    save_figure(fig, args.results_dir / 'plots' / 'calibration.png')


if __name__ == '__main__':
    main()
