"""
analyze_rps_sweep.py

Turns the per-candidate JSON files written by rps_sweep.sh into a single
comparison table and a recommended operating point.

Usage:
    python3 analyze_rps_sweep.py /path/to/datasets/rps-sweep-results

Recommendation logic, stated explicitly rather than hidden in a heuristic:

  1. A candidate is DISQUALIFIED if the container was CFS-throttled, or if CPU
     utilisation exceeded CPU_SAFE_THRESHOLD_PCT of its quota. At that point the
     server is CPU-bound, and any RSS measured there reflects queue depth as
     much as allocator behaviour — which is exactly the confound this study
     needs to avoid.
  2. Among the survivors, the highest memory utilisation wins: that is the most
     real memory pressure obtainable without crossing into CPU saturation.
  3. If the winner still sits below MEM_PRESSURE_TARGET_PCT of the container
     ceiling, the sweep is reported as INCONCLUSIVE rather than dressed up as a
     recommendation. RPS moves CPU and memory in the same direction, so when a
     workload is CPU-bound per request no RPS value can produce memory pressure
     — and quietly returning the least-bad point would hide that.

Fixed from the previous version:
  - http_req_failed was read as `.rate`; k6 emits `.value`, so the failure-rate
    column was silently N/A for every candidate.
  - Peak RSS and CPU now come from cgroup counters captured by _bench-lib.sh
    rather than 2-second `docker stats` samples that can miss a spike.
"""

import argparse
import json
import os
import re
import sys


# Below 100% because a container sitting at its quota is already queueing; the
# margin keeps the chosen point clear of the cliff rather than balanced on it.
CPU_SAFE_THRESHOLD_PCT = 85.0

# CFS throttling is reported per 100ms period, so a couple of throttled periods
# across a multi-minute run is a transient burst, not saturation. Disqualify on
# the SHARE of periods throttled rather than on any throttling at all — a
# zero-tolerance rule rejects the highest-memory points for measurement noise.
CPU_THROTTLE_TOLERANCE_PCT = 1.0
CFS_PERIODS_PER_SEC = 10  # default 100ms period

# What counts as "genuine memory pressure". Under this, the 1GB ceiling is not
# the binding constraint and the run cannot say much about memory management.
MEM_PRESSURE_TARGET_PCT = 60.0


def load_points(sweep_dir):
    points = []
    for entry in sorted(os.listdir(sweep_dir)):
        match = re.fullmatch(r"rps_(\d+)\.json", entry)
        if not match:
            continue
        with open(os.path.join(sweep_dir, entry)) as f:
            data = json.load(f)
        data["rps"] = int(match.group(1))
        points.append(data)
    points.sort(key=lambda p: p["rps"])
    return points


def fmt(val, suffix="", decimals=1):
    if val is None:
        return "N/A"
    return f"{val:.{decimals}f}{suffix}"


def print_table(points):
    header = (
        f"{'RPS':>5}{'cpu%':>8}{'thr%':>7}{'peakRSS':>10}{'mem%':>7}"
        f"{'thruput':>9}{'p95ms':>9}{'p99ms':>9}{'fail%':>8}{'drop':>6}{'oom':>5}"
    )
    print(header)
    print("-" * len(header))
    for p in points:
        print(
            f"{p['rps']:>5}"
            f"{fmt(p.get('cpu_utilisation_pct')):>8}"
            f"{fmt(throttle_share_pct(p), '', 2):>7}"
            f"{fmt(p.get('peak_rss_mb')):>10}"
            f"{fmt(p.get('mem_utilisation_pct')):>7}"
            f"{fmt(p.get('throughput_rps'), '', 1):>9}"
            f"{fmt(p.get('latency_p95_ms')):>9}"
            f"{fmt(p.get('latency_p99_ms')):>9}"
            f"{fmt((p.get('failed_rate') or 0) * 100, '', 2):>8}"
            f"{p.get('dropped_iterations', 0):>6,}"
            f"{p.get('oom_kills', 0):>5}"
        )


def throttle_share_pct(p):
    """Share of CFS periods in which the container was throttled."""
    window = p.get("window_secs") or 0
    total_periods = window * CFS_PERIODS_PER_SEC
    if total_periods <= 0:
        return 0.0
    return p.get("cpu_throttled_periods", 0) / total_periods * 100


def is_cpu_safe(p):
    if throttle_share_pct(p) > CPU_THROTTLE_TOLERANCE_PCT:
        return False
    cpu = p.get("cpu_utilisation_pct")
    return cpu is not None and cpu < CPU_SAFE_THRESHOLD_PCT


def recommend(points):
    healthy = [p for p in points if p.get("oom_kills", 0) == 0 and (p.get("failed_rate") or 0) <= 0.01]
    safe = [p for p in healthy if is_cpu_safe(p)]

    print()
    if not safe:
        print("=" * 78)
        print(" NO CPU-SAFE OPERATING POINT")
        print("=" * 78)
        print("Every candidate was CPU-throttled or above "
              f"{CPU_SAFE_THRESHOLD_PCT:.0f}% of its CPU quota.")
        print()
        print("Raising or lowering RPS cannot fix this. RPS scales arrival rate,")
        print("which drives CPU and memory in the SAME direction, so there is no")
        print("value of it that produces memory pressure while leaving CPU idle.")
        print("The levers that actually decouple the two are per-request:")
        print("  - hold_ms (object lifespan): concurrent live bytes scale as")
        print("    lambda x lifespan (Little's Law) at ZERO extra CPU, since the")
        print("    request is just awaiting a timer.")
        print("  - payload size: more bytes per request at the same request rate.")
        print("  - FIXED_TOUCH_COUNT in routes/_alloc-utils.js: the CPU cost per")
        print("    request, independent of how many bytes it holds.")
        return None

    best = max(safe, key=lambda p: (p.get("mem_utilisation_pct") or 0))
    excluded = [p["rps"] for p in points if p not in safe]

    print("=" * 78)
    print(f" RECOMMENDED MAX_RPS: {best['rps']}")
    print("=" * 78)
    print(f"  Highest memory utilisation ({fmt(best.get('mem_utilisation_pct'), '%')} of "
          f"{fmt(best.get('mem_limit_mb'))} MB) among candidates that stayed")
    print(f"  under {CPU_SAFE_THRESHOLD_PCT:.0f}% CPU with zero throttling.")
    print(f"  At this point: cpu={fmt(best.get('cpu_utilisation_pct'), '%')}, "
          f"peakRSS={fmt(best.get('peak_rss_mb'))} MB, "
          f"p99={fmt(best.get('latency_p99_ms'))} ms, "
          f"throughput={fmt(best.get('throughput_rps'))} rps")
    if excluded:
        print(f"  Excluded (CPU-saturated / unhealthy): {excluded}")

    mem_pct = best.get("mem_utilisation_pct") or 0
    if mem_pct < MEM_PRESSURE_TARGET_PCT:
        print()
        print("-" * 78)
        print(" WARNING: INCONCLUSIVE — this point has no real memory pressure")
        print("-" * 78)
        print(f"  Peak RSS reached only {mem_pct:.1f}% of the {fmt(best.get('mem_limit_mb'))} MB")
        print(f"  ceiling, against a {MEM_PRESSURE_TARGET_PCT:.0f}% target. The container is")
        print("  nowhere near memory-bound, so a benchmark run here measures CPU")
        print("  scheduling, not memory management, and cannot support a claim")
        print("  about allocator behaviour under a 1GB constraint.")
        print()
        print("  Increase memory demand per request WITHOUT adding CPU cost —")
        print("  hold_ms (lifespan) is the cleanest lever, since live bytes scale")
        print("  as lambda x lifespan while an awaiting request burns no CPU.")

    return best


def main():
    parser = argparse.ArgumentParser(
        description="Analyze an RPS sweep and recommend an operating point")
    parser.add_argument("sweep_dir", help="Path to the rps-sweep-results directory")
    parser.add_argument("--json-out", default=None, help="Optional path to save parsed results")
    args = parser.parse_args()

    if not os.path.isdir(args.sweep_dir):
        sys.exit(f"Error: {args.sweep_dir} is not a directory")

    points = load_points(args.sweep_dir)
    if not points:
        sys.exit(f"No rps_*.json files found in {args.sweep_dir}. Run rps_sweep.sh first.")

    print(f"Parsed {len(points)} sweep points from {args.sweep_dir}\n")
    print_table(points)
    recommend(points)

    if args.json_out:
        with open(args.json_out, "w") as f:
            json.dump(points, f, indent=2)
        print(f"\nFull parsed results saved to {args.json_out}")


if __name__ == "__main__":
    main()
