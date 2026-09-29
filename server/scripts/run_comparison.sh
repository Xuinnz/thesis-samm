#!/usr/bin/env bash
#
# run_comparison.sh — DEMO: jemalloc vs SAMM, side by side, in about ten minutes.
#
# Built for a live presentation rather than for the record. It runs the two
# allocators that matter for the comparison -- jemalloc is the strongest
# baseline, and SAMM runs ON jemalloc, so the arena is the only difference
# between them -- at the load level where they visibly diverge.
#
# WHY k = 2.5 AND THREE MINUTES
#
# Three minutes keeps the whole thing inside a demo slot.
#
# k = 2.5 rather than 2.0. At k = 2.0 jemalloc lands at 91-98% of the memory
# ceiling depending on the draw -- measured across five seeds -- so whether its
# container survives is close to a coin flip, and a demo should not promise an
# outcome it delivers half the time. Its DROP rate at that load is reliable
# (8-13% of offered requests against SAMM's 0.5%), but the failure is not.
# At k = 2.5 the failure is decisive: jemalloc errors on roughly 28% of requests
# and does not finish, while SAMM completes with none.
#
# K=2.0 remains available and is the better choice if you would rather show a
# large, certain gap than a failure that is dramatic but occasionally absent.
#
# NOT A MEASUREMENT. Read the caveats the script prints at the end:
# n = 1, three-minute runs are roughly a third warmup, and the same k = 2.0 point
# behaves differently over ten minutes -- glibc flips from surviving to dying,
# and blocked bump resets fall from 31,655 to 131. The study's numbers come from
# run_replicates.sh at ten minutes. This shows the effect; it does not size it.
#
# Usage:
#   ./run_comparison.sh
#   K=1.0 ./run_comparison.sh          # gentler: both survive, differences are numeric
#   SIMULATION_MINUTES=5 ./run_comparison.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

K="${K:-2.5}"
case "$K" in
  1.0) MAX_RPS=500;  PROCESS_HOLD_MS=600; HOLD_SCALE=4 ;;
  1.5) MAX_RPS=750;  PROCESS_HOLD_MS=400; HOLD_SCALE=2.667 ;;
  2.0) MAX_RPS=1000; PROCESS_HOLD_MS=300; HOLD_SCALE=2 ;;
  2.5) MAX_RPS=1250; PROCESS_HOLD_MS=240; HOLD_SCALE=1.6 ;;
  *) echo "ERROR: K must be 1.0, 1.5, 2.0 or 2.5 for the demo (got '$K')"; exit 1 ;;
esac

export SIMULATION_MINUTES="${SIMULATION_MINUTES:-3}"
export MIN_RPS=5 PRE_ALLOCATED_VUS=400 MAX_VUS=1400
export SCHEDULE_SEED="${SCHEDULE_SEED:-20250911}"
export MEM_LIMIT="${MEM_LIMIT:-1024m}" MEMSWAP_LIMIT="${MEMSWAP_LIMIT:-1024m}" CPUS="${CPUS:-1.0}"
export SHADOW_PROFILER_ENABLED=false SAMM_TELEMETRY=false
export PROCESS_MAX_BYTES=$((16*1024*1024))
export SAMM_RECLAIM_POLICY=none SAMM_WARMUP=false
export MAX_RPS PROCESS_HOLD_MS HOLD_SCALE

export RESULTS_DIR="${RESULTS_DIR:-$REPO_ROOT/benchmark-results/demo}"

JEMALLOC_SO="${JEMALLOC_SO:-/usr/lib/x86_64-linux-gnu/libjemalloc.so.2}"

# k != 1.0 runs against a table characterized at k = 1.0. Sound, because
# lambda*W is invariant so peak demand and the segment requirement do not move,
# but the fingerprint hashes lambda and W separately and cannot see that.
SAMM_EXTRA=()
[ "$K" != "1.0" ] && SAMM_EXTRA=(-e SAMM_ALLOW_WORKLOAD_MISMATCH=true)

# shellcheck source=./_bench-lib.sh
source "$SCRIPT_DIR/_bench-lib.sh"
mkdir -p "$RESULTS_DIR"; rm -f "$RESULTS_DIR"/*.json

echo "======================================================================"
echo " DEMO — jemalloc vs SAMM"
echo "======================================================================"
echo " Load      : k=${K}  (MAX_RPS=${MAX_RPS}, process hold ${PROCESS_HOLD_MS}ms, fetch hold x${HOLD_SCALE})"
echo " Duration  : ${SIMULATION_MINUTES} min per condition"
echo " Container : ${MEM_LIMIT} RAM, swap off, ${CPUS} vCPU"
echo " Same C allocator underneath both — the arena is the only difference."
echo " Results   : ${RESULTS_DIR}"
echo "======================================================================"
echo

echo ">>> 1/2  jemalloc (baseline)"
run_condition "jemalloc" "docker/baseline-environment/Dockerfile" "samm-baseline:bench" "demo-jem" \
  -e LD_PRELOAD="$JEMALLOC_SO" || echo "[[ jemalloc did not complete ]]"
echo
echo ">>> 2/2  SAMM (arena on jemalloc)"
run_condition "samm" "docker/samm-environment/Dockerfile" "samm-enabled:bench" "demo-samm" \
  -e SAMM_ALLOCATOR_ENABLED=true -e LD_PRELOAD="$JEMALLOC_SO" \
  -e SAMM_RECLAIM_POLICY=none -e SAMM_WARMUP=false \
  "${SAMM_EXTRA[@]}" || echo "[[ SAMM did not complete ]]"
echo

"$PYTHON_BIN" - "$RESULTS_DIR" "$K" "$SIMULATION_MINUTES" <<'PYEOF'
import json, os, sys
d, K, mins = sys.argv[1], sys.argv[2], sys.argv[3]

def load(n):
    p = os.path.join(d, f"{n}.json")
    return json.load(open(p)) if os.path.exists(p) else None

jem, samm = load("jemalloc"), load("samm")
if not jem or not samm:
    sys.exit("ERROR: a condition produced no result — see the log above.")

def survived(r):
    # Zeroed CPU counters mean the cgroup was gone at teardown: the container
    # died and its performance numbers describe a process on its way out.
    return not (r["cpu_utilisation_pct"] == 0.0 or r["oom_kills"] or r["failed_rate"] > 0.05)

def dropped_pct(r):
    t = r["dropped_iterations"] + r["requests"]
    return 100 * r["dropped_iterations"] / t if t else 0.0

W = 74
print("=" * W)
print(f" jemalloc  vs  SAMM      k={K}, {mins} min, 1 GB / 1 vCPU, n=1")
print("=" * W)
print(f"{'':26}{'jemalloc':>14}{'SAMM':>14}{'':>4}")
print("-" * W)

def row(label, a, b, fmt="{:,.1f}", lower_better=True, suffix=""):
    if a is None or b is None:
        return
    better = (b < a) if lower_better else (b > a)
    mark = "  <-- SAMM" if better else ""
    print(f"{label:26}{fmt.format(a)+suffix:>14}{fmt.format(b)+suffix:>14}{mark}")

row("Requests served",        jem["requests"],               samm["requests"],               "{:,.0f}", False)
row("Dropped (% of offered)", dropped_pct(jem),              dropped_pct(samm),              "{:,.2f}", True, " %")
row("Failed requests (%)",    jem["failed_rate"]*100,        samm["failed_rate"]*100,        "{:,.2f}", True, " %")
print("-" * W)
row("Peak RSS (MB)",          jem["peak_rss_mb"],            samm["peak_rss_mb"])
row("Page faults / request",  jem["page_faults_per_request"],samm["page_faults_per_request"])
row("CPU (% of 1 vCPU)",      jem["cpu_utilisation_pct"],    samm["cpu_utilisation_pct"])
row("CPU throttled (periods)",jem["cpu_throttled_periods"],  samm["cpu_throttled_periods"],  "{:,.0f}")
print("-" * W)
row("Allocation p99 (ms)",    jem["processing_p99_ms"],      samm["processing_p99_ms"],      "{:,.2f}")
row("End-to-end p99 (ms)",    jem["latency_p99_ms"],         samm["latency_p99_ms"])
row("Throughput (req/s)",     jem["throughput_rps"],         samm["throughput_rps"],         "{:,.1f}", False)
print("-" * W)
for name, r in (("jemalloc", jem), ("SAMM", samm)):
    print(f"  {name:10} {'COMPLETED' if survived(r) else 'DID NOT SURVIVE THE RUN'}"
          f"   peak {r['peak_rss_mb']:.0f} MB of {r['mem_limit_mb']:.0f}"
          f" ({100*r['peak_rss_mb']/r['mem_limit_mb']:.0f}%)")

a = os.path.join(d, "samm-allocator.json")
if os.path.exists(a):
    s = json.load(open(a))
    allocs = s["regionReclaimed"] + s["unmanaged"] + s["capacityFallbacks"]
    print(f"\n  SAMM arena: {s['regionsOpened']:,} regions opened, "
          f"{s['regionReclaimed']:,} objects reclaimed deterministically at request scope,")
    print(f"              {s['detachFailures']} use-after-free detach failures, "
          f"{100*s['capacityFallbacks']/allocs:.2f}% of allocations fell back to malloc.")

print("\n" + "!" * W)
print("  DEMO, not a measurement. n=1; a three-minute run is about a third")
print("  warmup; and this same load point behaves differently over ten minutes.")
print("  The study's numbers come from run_replicates.sh at ten minutes.")
print("!" * W)
PYEOF
