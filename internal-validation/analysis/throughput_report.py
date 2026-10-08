#!/usr/bin/env python3
"""
Throughput report for Experiment 1 (throughput-saturation.js).

Reads a `run.sh throughput` results directory. Per config:
  steady throughput   completed requests in the MEASURE window / MEASURE_SECONDS
                      (warmup and cooldown discarded; counted by completion time)
  dropped_iterations  reported as k6 recorded it; a closed loop cannot drop, so
                      anything but 0 is a fault
  per-second series   from the raw samples: mean, coefficient of variation and
                      drift across the window -- a steady state should be flat
  container           CPU used during the window (user and kernel separately),
                      throttling, page faults per request, peak memory

Validity checks, any of which makes a config's number unusable:
  failed requests in the window, dropped iterations, an OOM-killed container,
  CPU below --min-cpu (the server was not saturated: the client was the limit,
  so raise SATURATION_VUS). Unsteady series (CV or drift above the limits) is
  flagged as a warning.

Usage: throughput_report.py RESULTS_DIR [--reference glibc] [--min-cpu 0.90]
                            [--max-cv 0.15] [--max-drift 0.10] [--no-plot]
"""

import argparse
from pathlib import Path

import numpy as np

from common import (INK_2, color, configs, container_fate, container_load, die, direct_label, label,
                    load_samples, print_table, pyplot, read_json, save_csv, save_figure)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('results_dir', type=Path)
    ap.add_argument('--reference', default='glibc', help='config the others are compared to (default glibc)')
    ap.add_argument('--min-cpu', type=float, default=0.90, help='CPU (of 1 vCPU) below which the server was not saturated')
    ap.add_argument('--max-cv', type=float, default=0.15, help='largest acceptable CV of per-second throughput')
    ap.add_argument('--max-drift', type=float, default=0.10, help='largest acceptable drift across the window (fraction)')
    ap.add_argument('--no-plot', action='store_true')
    args = ap.parse_args()

    results, series = {}, {}
    for cfg, d in configs(args.results_dir):
        s = read_json(d / 'summary.json')
        if not s or s.get('experiment') != 'throughput-saturation':
            die(f'{d}/summary.json is not a throughput-saturation summary')
        warm, meas = s['phases_s']['warmup'], s['phases_s']['measure']
        r = {'summary': s, 'fate': container_fate(read_json(d / 'run.json')), 'flags': [], 'warnings': []}

        done = load_samples(d / 'raw.csv.gz', 'completed_iterations', ('phase', 'ok', 't_s'))
        win = None
        if done is not None and len(done):
            m = done[(done['phase'] == 'measure') & (done['ok'] == 'true')].copy()
            m['t_s'] = m['t_s'].astype(int)
            # Whole seconds strictly inside the window: the first and last may be partial.
            secs = np.arange(warm + 1, warm + meas - 1)
            per_sec = m.groupby('t_s').size().reindex(secs, fill_value=0).astype(float)
            series[cfg] = per_sec
            if len(per_sec) > 2 and per_sec.mean() > 0:
                slope = np.polyfit(per_sec.index.values, per_sec.values, 1)[0]
                r['cv'] = per_sec.std() / per_sec.mean()
                r['drift'] = slope * len(per_sec) / per_sec.mean()
            if len(m):
                win = (m['ts_ms'].min(), m['ts_ms'].max())
        else:
            r['warnings'].append('no raw.csv.gz: per-second series and CPU window unavailable')

        c = container_load(d / 'container.tsv', win)
        r['container'] = c

        if s['failed_in_measure'] > 0:
            r['flags'].append(f"{s['failed_in_measure']} failed requests in the window")
        if s['dropped_iterations'] > 0:
            r['flags'].append(f"{s['dropped_iterations']} dropped iterations")
        if r['fate']:
            r['flags'].append(r['fate'])
        if c and c['cpu_frac'] < args.min_cpu:
            r['flags'].append(f"CPU {c['cpu_frac']:.0%} < {args.min_cpu:.0%}: not saturated, raise SATURATION_VUS")
        if r.get('cv', 0) > args.max_cv:
            r['warnings'].append(f"per-second CV {r['cv']:.0%} > {args.max_cv:.0%}")
        if abs(r.get('drift', 0)) > args.max_drift:
            r['warnings'].append(f"drift {r['drift']:+.0%} across the window > {args.max_drift:.0%}")
        results[cfg] = r

    ref = results.get(args.reference)
    ref_tp = ref['summary']['steady_throughput_rps'] if ref else None
    rows = []
    for cfg, r in results.items():
        s, c = r['summary'], r['container'] or {}
        tp = s['steady_throughput_rps']
        done_m = s['completed_by_phase']['measure']['ok']
        rows.append([
            label(cfg), s['vus'], tp,
            f'{(tp / ref_tp - 1):+.1%}' if ref_tp and cfg != args.reference else '-',
            s['dropped_iterations'], s['failed_in_measure'],
            r.get('cv', float('nan')), r.get('drift', float('nan')),
            c.get('cpu_frac', float('nan')), c.get('user_frac', float('nan')), c.get('system_frac', float('nan')),
            c.get('faults', float('nan')) / done_m if c and done_m else float('nan'),
            c.get('peak_memory_mb', float('nan')),
            'VALID' if not r['flags'] else 'INVALID',
        ])
    cols = ['config', 'VUs', 'throughput/s', f'vs {args.reference}', 'dropped', 'failed', 'CV/s', 'drift',
            'CPU', 'user', 'kernel', 'faults/req', 'peak MB', 'verdict']
    print_table('Steady-state throughput (MEASURE window only)', cols, rows)
    save_csv(args.results_dir / 'throughput.csv', cols, rows)
    for cfg, r in results.items():
        for f in r['flags']:
            print(f'  {label(cfg)}: INVALID -- {f}')
        for w in r['warnings']:
            print(f'  {label(cfg)}: warning -- {w}')

    if args.no_plot:
        return
    plt = pyplot()
    if plt is None:
        return
    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(11, 4), gridspec_kw={'width_ratios': [1, 1.6]})
    names = list(results)
    tps = [results[c]['summary']['steady_throughput_rps'] for c in names]
    y = np.arange(len(names))[::-1]
    ax1.barh(y, tps, height=0.4, color=[color(c) for c in names], edgecolor='#fcfcfb', linewidth=2)
    for yi, tp, c in zip(y, tps, names):
        mark = '' if not results[c]['flags'] else '  (invalid)'
        ax1.annotate(f'{tp:,.0f}/s{mark}', (tp, yi), xytext=(4, 0), textcoords='offset points', va='center', fontsize=8)
    ax1.set_yticks(y, [label(c) for c in names])
    ax1.set_xlim(0, max(tps) * 1.25 if tps else 1)
    ax1.set_title('Steady-state throughput')
    ax1.set_xlabel('completed requests / s (MEASURE window)')
    ax1.grid(axis='y', visible=False)
    for c in names:
        if c in series:
            sr = series[c]
            ax2.plot(sr.index - sr.index[0], sr.values, color=color(c), label=label(c), linewidth=1.2)
            direct_label(ax2, sr.index[-1] - sr.index[0], sr.values[-20:].mean(), label(c), color(c))
    ax2.set_title('Completed requests per second, across the window')
    ax2.set_xlabel('seconds into the MEASURE window')
    ax2.set_ylabel('completed / s')
    ax2.set_ylim(bottom=0)
    ax2.margins(x=0.1)
    if series:
        ax2.legend(loc='lower left')
    fig.text(0.01, -0.03, 'Closed loop (constant-vus): a flat line means a steady state; warmup and cooldown are not shown.',
             color=INK_2, fontsize=8)
    fig.tight_layout()
    save_figure(fig, args.results_dir / 'plots' / 'throughput.png')


if __name__ == '__main__':
    main()
