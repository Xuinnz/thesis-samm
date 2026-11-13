#!/usr/bin/env python3
"""
Puts Phase 1 batches side by side: what the load generator will actually do
differently when it is driven from one batch instead of another.

    venv/bin/python preprocessing/phase1-azure-simulation/batch_summary.py d01-d07 d08-d14
    venv/bin/python preprocessing/phase1-azure-simulation/batch_summary.py all d01-d07 d08-d14 --max-rps 1000

"all" names the default models (all published days). MIN_RPS / MAX_RPS and the
largest process payload only set the scale of the rate and size rows; they
default to the main study's values at k = 2.0 and change nothing in the batches.

The request rate per state is worked out the way the load generator does it
(load-generator/traffic-models/markov-chain.js): each state's mean invocations
divided by the busiest state's mean, mapped onto MIN_RPS..MAX_RPS.
"""

import argparse
import json
import os

import numpy as np
import pandas as pd

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                     "datasets", "azure-trace-2019", "processed"))
STATES = ["Idle", "Ramp", "Burst", "Cooldown"]


def load(batch, min_rps, max_rps, cap_mb):
    base = ROOT if batch == "all" else os.path.join(ROOT, batch)
    traffic, memory = os.path.join(base, "traffic-models"), os.path.join(base, "memory-models")
    if not os.path.isdir(traffic):
        raise SystemExit(f"No batch '{batch}' under {ROOT}. Build it with AZURE_DAYS=... run_phase1.sh")

    series = pd.read_csv(os.path.join(traffic, "traffic_state_series.csv"))
    matrix = pd.read_csv(os.path.join(traffic, "markov_transition_matrix.csv"), index_col=0).loc[STATES, STATES]
    jitter = json.load(open(os.path.join(traffic, "jitter_parameters.json")))
    meta = json.load(open(os.path.join(memory, "normalization_metadata.json")))
    payload = pd.read_csv(os.path.join(memory, "memory_payload_allocations.csv"))
    thresholds_path = os.path.join(traffic, "traffic_thresholds.json")
    thresholds = json.load(open(thresholds_path)) if os.path.exists(thresholds_path) else {}

    share = series["State"].value_counts(normalize=True).reindex(STATES, fill_value=0.0)
    means = series.groupby("State")["Total_Invocations"].mean().reindex(STATES, fill_value=0.0)
    rps = min_rps + (means / means.max()) * (max_rps - min_rps)

    # Long-run share of minutes the generated walk spends in each state: the
    # left eigenvector of the transition matrix for eigenvalue 1.
    values, vectors = np.linalg.eig(matrix.values.T)
    stationary = np.real(vectors[:, np.argmin(np.abs(values - 1))])
    stationary = stationary / stationary.sum()

    weights = payload["SampleCount"] if "SampleCount" in payload.columns else pd.Series(1.0, index=payload.index)
    median_col = "payload_AverageAllocatedMb_pct50_mb"
    order = payload[median_col].argsort()
    cumulative = weights.iloc[order].cumsum() / weights.sum()
    weighted_median = float(payload[median_col].iloc[order][cumulative >= 0.5].iloc[0])

    rows = {"days": ", ".join(f"d{d:02d}" for d in thresholds["days"]) if thresholds.get("days") else "all published",
            "states classified on": thresholds.get("thresholds_from", "own percentiles"),
            "minutes": f"{len(series):,}",
            "mean invocations / min": f"{series['Total_Invocations'].mean():,.0f}",
            "peak invocations / min": f"{series['Total_Invocations'].max():,.0f}"}
    for s in STATES:
        rows[f"share of minutes: {s}"] = f"{100 * share[s]:.1f} %"
    for i, s in enumerate(STATES):
        rows[f"long-run share of the walk: {s}"] = f"{100 * stationary[i]:.1f} %"
    for s in STATES:
        rows[f"mean stay in {s}"] = f"{1 / (1 - matrix.loc[s, s]):.1f} min" if matrix.loc[s, s] < 1 else "never leaves"
    for s in STATES:
        rows[f"request rate in {s}"] = f"{rps[s]:,.0f} req/s"
    rows["mean request rate over the walk"] = f"{float(np.dot(stationary, rps.values)):,.0f} req/s"
    rows["hold time, median"] = f"{jitter['back_calc_p50_ms']:.0f} ms"
    rows["hold time, 99th percentile"] = f"{jitter['back_calc_p99_ms']:.0f} ms"
    rows["memory files (apps)"] = f"{meta['apps_processed']:,}"
    rows["memory anchor (Azure, P99 app)"] = f"{meta['global_p99_azure_anchor_mb']:.1f} MB" + (
        f" (from {meta['anchor_from']}; own {meta['own_p99_azure_anchor_mb']:.1f})"
        if meta.get("anchor_from") not in (None, batch, "all days") else "")
    rows["payload model, invocation-weighted median"] = f"{weighted_median:.1f} MB"
    # server/routes/process.js rescales the model's 0..effective-ceiling range
    # onto 0..PROCESS_MAX_BYTES, so this is the size the server allocates.
    rows[f"  as allocated (largest = {cap_mb:g} MB)"] = f"{weighted_median * cap_mb / meta['effective_ceiling_mb']:.2f} MB"
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("batches", nargs="+", help="batch names under processed/, or 'all' for the default models")
    ap.add_argument("--min-rps", type=float, default=5)
    ap.add_argument("--max-rps", type=float, default=1000)
    ap.add_argument("--process-max-mb", type=float, default=16, help="the server's PROCESS_MAX_BYTES, in MB")
    ap.add_argument("--markdown", action="store_true", help="print a Markdown table")
    args = ap.parse_args()

    columns = {b: load(b, args.min_rps, args.max_rps, args.process_max_mb) for b in args.batches}
    labels = list(next(iter(columns.values())))
    if args.markdown:
        print("| | " + " | ".join(args.batches) + " |")
        print("| :--- |" + " ---: |" * len(args.batches))
        for label in labels:
            print(f"| {label} | " + " | ".join(columns[b][label] for b in args.batches) + " |")
        return
    width = max(len(l) for l in labels) + 2
    col = max(22, *(len(columns[b][l]) + 2 for b in args.batches for l in labels))
    print(f"{'':{width}}" + "".join(f"{b:>{col}}" for b in args.batches))
    for label in labels:
        print(f"{label:{width}}" + "".join(f"{columns[b][label]:>{col}}" for b in args.batches))
    print(f"\nRequest rates assume MIN_RPS={args.min_rps:g}, MAX_RPS={args.max_rps:g}.")


if __name__ == "__main__":
    main()
