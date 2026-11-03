#!/usr/bin/env python3
"""
Derive Layer 3's beta from a SAMM run instead of fixing it at 0.75.

beta sizes the pool: M_available = POOL_HARD_LIMIT x beta, where POOL_HARD_LIMIT
is the container minus the Node/V8 baseline (80 MB) minus the System
reservation (01_calculate_spatial_quotas.py). The rest of the container has to
hold everything the pool does not account for: V8's heap, the System heap,
refused managed allocations that fell back to malloc, and the page cache the
cgroup charges. Characterization runs without SAMM, so the trace cannot show
that amount; this measures it on a run WITH SAMM, at the load the table must
serve:

    outside(t) = memory.current(t) - committedBytes(t)
    C          = container - max_t outside(t) - margin
    beta       = C / POOL_HARD_LIMIT

Then recompile with SAMM_BETA_UTILIZATION=beta, rebuild, run the same load
again and re-derive: a different ceiling changes how much falls back, and so
the memory outside the pool (runbook Phase 6: iterate once).

memory.current includes page cache the cgroup is charged for, which the kernel
can reclaim under pressure, so this errs towards a smaller pool.

Reads any of:
  <label>-samm-stats.jsonl   _bench-lib.sh with POLL_SAMM_STATS=1 (realistic runs)
  <run dir>                  internal-validation/run.sh with POLL_SAMM_STATS=1
                             (allocator.jsonl joined with container.tsv)
  <recording>.jsonl          a demo recording of a SAMM run

Usage: derive_beta.py RUN [--margin-mb 32] [--quotas spatial_quotas.json]
"""

import argparse
import csv
import json
import statistics as st
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_QUOTAS = (REPO_ROOT / "datasets/shadow-telemetry/intermediate/step7-ml-refinery"
                  / "spatial_quotas.json")
MB = 1024 * 1024


def read_lines(path):
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def samples(run):
    """[(seconds, memory bytes, SAMM stats or None)], and a description."""
    run = Path(run)
    if run.is_dir():
        # internal-validation: counters and cgroup polled by separate loops,
        # both stamped with the host's uptime; pair each counter sample with the
        # nearest cgroup sample.
        with open(run / "container.tsv") as f:
            cg = [(float(r["uptime_s"]), int(r["memory_current"]))
                  for r in csv.DictReader(f, delimiter="\t") if r["memory_current"]]
        out = []
        for r in read_lines(run / "allocator.jsonl"):
            t = float(r["uptime_s"])
            nearest = min(cg, key=lambda c: abs(c[0] - t))
            if abs(nearest[0] - t) <= 1.0:
                out.append((t, nearest[1], r.get("stats")))
        return out, "internal-validation run (allocator.jsonl + container.tsv)"
    rows = read_lines(run)
    if rows and "event" in rows[0]:
        out = [(r["data"]["t"] / 1000, int(r["data"]["rss_mb"] * MB), r["data"].get("allocator"))
               for r in rows if r.get("event") == "metrics" and r["data"].get("rss_mb") is not None]
        return out, "demo recording"
    out = [(r["uptime_s"], int(r["memory_current"]), r.get("stats"))
           for r in rows if r.get("memory_current") is not None]
    return out, "_bench-lib.sh POLL_SAMM_STATS=1"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("run")
    ap.add_argument("--margin-mb", type=float, default=32.0)
    ap.add_argument("--quotas", type=Path, default=DEFAULT_QUOTAS)
    args = ap.parse_args()

    rows, kind = samples(args.run)
    # Only samples where SAMM answered: a saturated server may not have.
    live = [(t, mem, s) for t, mem, s in rows if s and "committedBytes" in s]
    if not live:
        sys.exit(f"ERROR: no samples with SAMM counters in {args.run} ({kind}). "
                 "Was it a SAMM run with POLL_SAMM_STATS=1?")
    q = json.loads(args.quotas.read_text())
    container = int(q["container_ceiling_bytes"])
    pool_limit = int(q["pool_hard_limit_bytes"])
    t0 = rows[0][0]

    outside = [(t, mem - s["committedBytes"], mem, s["committedBytes"]) for t, mem, s in live]
    peak = max(outside, key=lambda o: o[1])
    vals = sorted(o[1] for o in outside)
    p99 = vals[min(len(vals) - 1, int(0.99 * len(vals)))]
    # Before the first managed allocation: Node, V8 and the addon at rest, the
    # part the quota script fixes at 80 MB.
    idle = [mem for _, mem, s in live if s["committedBytes"] == 0]
    last = live[-1][2]

    c = container - peak[1] - args.margin_mb * MB
    beta = c / pool_limit
    print("=" * 78)
    print(f" beta from {args.run}")
    print(f" ({kind}; {len(live)} of {len(rows)} samples with SAMM counters, "
          f"{rows[-1][0] - t0:,.0f} s)")
    print("=" * 78)
    if idle:
        print(f"  memory before the pool is touched : {idle[0] / MB:7.1f} MB "
              f"(quota script assumes {q['node_v8_baseline_bytes'] / MB:.0f} MB for Node/V8)")
    print(f"  outside the pool, median          : {st.median(vals) / MB:7.1f} MB")
    print(f"  outside the pool, p99             : {p99 / MB:7.1f} MB")
    print(f"  outside the pool, peak            : {peak[1] / MB:7.1f} MB at +{peak[0] - t0:,.0f} s "
          f"(memory {peak[2] / MB:.1f} MB, pool committed {peak[3] / MB:.1f} MB)")
    print(f"  fallbacks at the end              : capacity {last.get('capacityFallbacks', 0):,}, "
          f"budget refusals {last.get('budgetRefusals', 0):,}, "
          f"bumpResetBlocked {last.get('bumpResetBlocked', 0):,}")
    print()
    print(f"  container                         : {container / MB:7.1f} MB")
    print(f"  - peak outside the pool           : {peak[1] / MB:7.1f} MB")
    print(f"  - margin                          : {args.margin_mb:7.1f} MB")
    print(f"  = ceiling C                       : {c / MB:7.1f} MB")
    print(f"  POOL_HARD_LIMIT (current table)   : {pool_limit / MB:7.1f} MB")
    print(f"  beta = C / POOL_HARD_LIMIT        : {beta:7.3f}   "
          f"(current {q['beta_utilization_fraction']}, M_available {q['m_available_bytes'] / MB:.1f} MB)")
    if rows[-1][2] is None or len(live) < len(rows):
        print(f"\n  NOTE: {len(rows) - len(live)} samples had no SAMM counters (server not up yet, "
              "unresponsive, or gone).\n  If the run died, it is not a sound basis.")
    if not 0 < beta <= 1:
        print("\n  WARNING: beta outside (0, 1]: the pool cannot be sized from this run as it stands.")
    else:
        print(f"\n  Next: SAMM_BETA_UTILIZATION={int(beta * 1000) / 1000} for the quota calculation and the "
              "table compiler,\n  rebuild, run the same load again with POLL_SAMM_STATS=1, and re-derive once.")


if __name__ == "__main__":
    main()
