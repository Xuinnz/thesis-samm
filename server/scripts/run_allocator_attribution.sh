#!/usr/bin/env bash
#
# run_allocator_attribution.sh
#
# Answers the question a reviewer will ask first: how much of SAMM's memory win
# is actually SAMM, and how much is just glibc malloc failing to return freed
# memory to the OS?
#
# The baseline's footprint is external memory -- Buffer backing stores, not the
# V8 heap -- so its size is decided jointly by when V8 collects the wrapper
# (triggering free()) and whether the C allocator hands the pages back. glibc's
# M_MMAP_THRESHOLD starts at 128KB but is DYNAMIC: freeing an mmap'd block
# raises the threshold toward 32MB, after which large buffers come from the
# sbrk heap and are retained rather than returned. This workload allocates up
# to 32MB buffers, so that adaptation is very likely engaged.
#
# Four conditions, one identical image per condition, run back to back so host
# state is as close to constant as it can be:
#
#   baseline-glibc-default  stock glibc, dynamic mmap threshold  (the status quo)
#   baseline-jemalloc       a different C allocator entirely, via LD_PRELOAD
#   samm-jemalloc           the allocator under test, on the SAME C allocator
#
# SAMM runs on jemalloc too, deliberately. It still uses malloc for
# System-classified call-sites, capacity fallbacks and Node's own internals, so
# comparing SAMM-on-glibc against baseline-on-jemalloc would vary two things at
# once. Holding the C allocator constant leaves the arena as the only
# difference. (The earlier attribution run had SAMM on glibc, which means its
# 45% margin there was measured with the WORSE C allocator underneath it.)
#
# Set ATTRIBUTION_INCLUDE_TUNED=1 to add the glibc-tuned variant back.
#
# Re-running the plain baseline is deliberate rather than reusing an earlier
# number: the baseline image now carries the jemalloc package, and measured
# run-to-run variance on this host has reached 20% on Peak RSS. Every number
# below comes from one session.
#
# Usage:
#   ./run_allocator_attribution.sh
#   SIMULATION_MINUTES=5 ./run_allocator_attribution.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Identical experiment configuration for every condition.
export MIN_RPS="${MIN_RPS:-5}"
export MAX_RPS="${MAX_RPS:-500}"
export SIMULATION_MINUTES="${SIMULATION_MINUTES:-10}"
export PRE_ALLOCATED_VUS="${PRE_ALLOCATED_VUS:-250}"
export MAX_VUS="${MAX_VUS:-600}"
export SCHEDULE_SEED="${SCHEDULE_SEED:-20250911}"
export MEM_LIMIT="${MEM_LIMIT:-1024m}"
export MEMSWAP_LIMIT="${MEMSWAP_LIMIT:-1024m}"
export CPUS="${CPUS:-1.0}"
export SHADOW_PROFILER_ENABLED="false"
export SAMM_RECLAIM_POLICY="${SAMM_RECLAIM_POLICY:-none}"
export SAMM_WARMUP="${SAMM_WARMUP:-false}"
# OFF by default. Measured: with telemetry ON this run reported
# bumpResetBlocked=15,719 and 17,669 capacity fallbacks; the identical run with
# it OFF reported 2,706 and 4,629. The GC PerformanceObserver fires a JS
# callback on every collection, which delays the event-loop turns that run
# region closes and N-API finalizers -- so regions stay open longer, bump
# segments get recycled while still live, and the allocator is pushed to
# malloc. That perturbation lands on the SAMM condition specifically, because
# only SAMM has regions, which makes it an ASYMMETRIC confound rather than a
# constant tax across conditions. Run telemetry as its own instrumented pass
# (SAMM_TELEMETRY=1 ./run_allocator_attribution.sh) and compare it against a
# clean one, exactly as routes/_telemetry.js documents.
export SAMM_TELEMETRY="${SAMM_TELEMETRY:-false}"
export RESULTS_DIR="${RESULTS_DIR:-$REPO_ROOT/benchmark-results/attribution}"

JEMALLOC_SO="${JEMALLOC_SO:-/usr/lib/x86_64-linux-gnu/libjemalloc.so.2}"

# Pinning M_MMAP_THRESHOLD is the load-bearing setting: glibc documents that
# setting it explicitly disables the dynamic adjustment that otherwise lets the
# threshold drift up to 32MB.
GLIBC_MMAP_THRESHOLD="${GLIBC_MMAP_THRESHOLD:-131072}"
GLIBC_TRIM_THRESHOLD="${GLIBC_TRIM_THRESHOLD:-131072}"

# shellcheck source=./_bench-lib.sh
source "$SCRIPT_DIR/_bench-lib.sh"

BASE_DOCKERFILE="docker/baseline-environment/Dockerfile"
BASE_IMAGE="samm-baseline:bench"

echo "======================================================================"
echo " Allocator attribution — where does the memory win come from?"
echo "======================================================================"
echo " Traffic  : ${SIMULATION_MINUTES}m, RPS ${MIN_RPS}-${MAX_RPS}, VUs ${PRE_ALLOCATED_VUS}-${MAX_VUS}, seed ${SCHEDULE_SEED}"
echo " Container: ${MEM_LIMIT} RAM, swap off, ${CPUS} vCPU"
if [ "${ATTRIBUTION_INCLUDE_TUNED:-0}" = "1" ]; then
    echo " glibc    : stock, PLUS a tuned variant (MALLOC_MMAP_THRESHOLD_=${GLIBC_MMAP_THRESHOLD} MALLOC_TRIM_THRESHOLD_=${GLIBC_TRIM_THRESHOLD})"
else
    # Printing the tuning values unconditionally read as though the glibc
    # condition were tuned, when ATTRIBUTION_INCLUDE_TUNED defaults to 0 and it
    # is stock. Say which one actually ran.
    echo " glibc    : stock (no MALLOC_* tuning; set ATTRIBUTION_INCLUDE_TUNED=1 to add the tuned variant)"
fi
echo " jemalloc : ${JEMALLOC_SO}"
echo " Results  : ${RESULTS_DIR}"
echo "======================================================================"
echo

# Clear prior results. Conditions are optional, so a file left behind by an
# earlier invocation would silently join this run's report -- mixing two
# different workloads or code versions into one table, which is exactly what
# happened when the touch change landed beside a stale pre-change result.
mkdir -p "$RESULTS_DIR"
rm -f "$RESULTS_DIR"/*.json

echo ">>> baseline, stock glibc"
run_condition "baseline-glibc-default" "$BASE_DOCKERFILE" "$BASE_IMAGE" "samm-attr-base"
echo

if [ "${ATTRIBUTION_INCLUDE_TUNED:-0}" = "1" ]; then
    echo ">>> baseline, glibc with mmap/trim thresholds pinned"
    run_condition "baseline-glibc-tuned" "$BASE_DOCKERFILE" "$BASE_IMAGE" "samm-attr-base" \
        -e MALLOC_MMAP_THRESHOLD_="$GLIBC_MMAP_THRESHOLD" \
        -e MALLOC_TRIM_THRESHOLD_="$GLIBC_TRIM_THRESHOLD"
    echo
fi

echo ">>> baseline, jemalloc"
run_condition "baseline-jemalloc" "$BASE_DOCKERFILE" "$BASE_IMAGE" "samm-attr-base" \
    -e LD_PRELOAD="$JEMALLOC_SO"
echo

echo ">>> SAMM, jemalloc (same C allocator as the baseline above)"
run_condition "samm-jemalloc" "docker/samm-environment/Dockerfile" "samm-enabled:bench" "samm-attr-samm" \
    -e SAMM_ALLOCATOR_ENABLED=true \
    -e LD_PRELOAD="$JEMALLOC_SO" \
    -e SAMM_RECLAIM_POLICY="$SAMM_RECLAIM_POLICY" \
    -e SAMM_WARMUP="$SAMM_WARMUP"
echo

"$PYTHON_BIN" - "$RESULTS_DIR" <<'PYEOF'
import json, os, sys

results_dir = sys.argv[1]
ORDER = [
    ("baseline-glibc-default", "Baseline (stock glibc)"),
    ("baseline-glibc-tuned",   "Baseline (glibc tuned)"),
    ("baseline-jemalloc",      "Baseline (jemalloc)"),
    ("samm-jemalloc",          "SAMM (jemalloc)"),
    ("samm",                   "SAMM (glibc)"),
]

rows = []
for key, label in ORDER:
    path = os.path.join(results_dir, f"{key}.json")
    if not os.path.exists(path):
        continue  # optional conditions are simply absent
    with open(path) as f:
        rows.append((label, json.load(f)))
if len(rows) < 2:
    sys.exit("ERROR: fewer than two conditions produced results")

print()
print("=" * 92)
print(" ALLOCATOR ATTRIBUTION — n=1 per condition")
print("=" * 92)
print(f"{'Condition':<26}{'PeakRSS MB':>12}{'p99 ms':>10}{'proc p99':>10}{'thruput':>10}{'fail%':>8}{'oom':>6}")
print("-" * 92)
for label, r in rows:
    print(f"{label:<26}{r['peak_rss_mb']:>12,.1f}{r['latency_p99_ms']:>10,.1f}"
          f"{r.get('processing_p99_ms', 0):>10,.2f}{r['throughput_rps']:>10,.1f}"
          f"{r['failed_rate']*100:>8.2f}{r['oom_kills']:>6}")
print("-" * 92)

by = {label: r for label, r in rows}
def rss(label):
    return by[label]["peak_rss_mb"] if label in by else None

stock = rss("Baseline (stock glibc)")
jem = rss("Baseline (jemalloc)")
samm = rss("SAMM (jemalloc)") or rss("SAMM (glibc)")
c_only = [v for v in (rss("Baseline (glibc tuned)"), jem) if v is not None]

print("\nPeak RSS against the stock-glibc baseline:")
for label, r in rows[1:]:
    print(f"  {label:<24} {r['peak_rss_mb']:8.1f} MB   "
          f"{100*(r['peak_rss_mb']-stock)/stock:+7.1f}%")

if c_only and samm:
    best = min(c_only)
    print(f"\nBest C-allocator-only result : {best:.1f} MB")
    print(f"SAMM                         : {samm:.1f} MB")
    print(f"SAMM's margin over it        : {100*(samm-best)/best:+.1f}%")
    if stock != samm:
        print(f"\nShare of the stock-vs-SAMM gap closed by swapping the C allocator alone: "
              f"{(stock - best) / (stock - samm) * 100:.1f}%")
        print("The remainder is what the arena contributes beyond a better malloc.")

# Memory pressure actually achieved -- the point of the touch change.
limit = rows[0][1].get("mem_limit_mb") or 0
if limit:
    print(f"\nMemory pressure reached (ceiling {limit:.0f} MB):")
    for label, r in rows:
        print(f"  {label:<24} {r['peak_rss_mb']:8.1f} MB  "
              f"({100*r['peak_rss_mb']/limit:5.1f}% of ceiling)"
              + ("   OOM-KILLED" if r.get("oom_kills") else ""))
PYEOF

echo
echo "[attribution] Done. Raw results in $RESULTS_DIR"
