#!/usr/bin/env bash
#
# run_touch_sweep.sh
#
# Sweeps how much of each buffer is actually WRITTEN, and measures what that
# costs and what it buys, for three allocators at once.
#
# WHY A SWEEP RATHER THAN A CHOSEN VALUE
#
# Residency is page faults: a page becomes resident only when written, and the
# kernel must allocate and zero it. Writing one byte per page is already the
# cheapest way to obtain residency, so the only remaining dial is how many
# pages. Every previous attempt to pick that number by argument has been wrong
# in one direction or the other -- 32 fixed samples gave 0.4% residency, every
# page unbounded gave 99% CPU -- so this measures the exchange rate instead.
#
# WHAT IT ALSO SETTLES
#
# 1. Whether recycling is happening. A fault is paid only on a FRESH page;
#    writing to a page the allocator already holds costs a single store. So
#    faults-per-request should separate the three conditions: glibc retains and
#    recycles, jemalloc returns pages and must re-fault, SAMM reuses its arena.
#    Without the fault counter this is an untested story.
#
# 2. Whether SAMM's budget exhaustion clears. At a 512KB cap, `process`
#    allocates ~13.7MB and writes 512KB -- a 27x gap. SAMM must reserve the full
#    allocation, so that gap consumed its entire budget and pushed 15,719
#    requests to the fallback path. Raising the cap closes the gap from the
#    other side, so bumpResetBlocked should fall as the cap rises. That makes
#    the sweep a direct test of the problem rather than a measurement
#    contaminated by it.
#
# Usage:
#   ./run_touch_sweep.sh
#   TOUCH_CAPS="524288,2097152,0" SWEEP_MINUTES=3 ./run_touch_sweep.sh
#     (0 = unbounded: write every page of every buffer)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TOUCH_CAPS_RAW="${TOUCH_CAPS:-524288,2097152,0}"
export SIMULATION_MINUTES="${SWEEP_MINUTES:-3}"

# Identical for every point; only the write cap varies.
export MIN_RPS="${MIN_RPS:-5}"
export MAX_RPS="${MAX_RPS:-500}"
export PRE_ALLOCATED_VUS="${PRE_ALLOCATED_VUS:-250}"
export MAX_VUS="${MAX_VUS:-600}"
export SCHEDULE_SEED="${SCHEDULE_SEED:-20250911}"
export MEM_LIMIT="${MEM_LIMIT:-1024m}"
export MEMSWAP_LIMIT="${MEMSWAP_LIMIT:-1024m}"
export CPUS="${CPUS:-1.0}"
export SHADOW_PROFILER_ENABLED="false"
export SAMM_TELEMETRY="false"
export SAMM_RECLAIM_POLICY="${SAMM_RECLAIM_POLICY:-none}"
export SAMM_WARMUP="${SAMM_WARMUP:-false}"
export RESULTS_DIR="${RESULTS_DIR:-$REPO_ROOT/benchmark-results/touch}"

JEMALLOC_SO="${JEMALLOC_SO:-/usr/lib/x86_64-linux-gnu/libjemalloc.so.2}"

# shellcheck source=./_bench-lib.sh
source "$SCRIPT_DIR/_bench-lib.sh"

mkdir -p "$RESULTS_DIR"
rm -f "$RESULTS_DIR"/*.json

IFS=',' read -ra CAPS <<< "$TOUCH_CAPS_RAW"

echo "======================================================================"
echo " Touch sweep — CPU/residency exchange rate, three allocators"
echo "======================================================================"
echo " Caps      : ${TOUCH_CAPS_RAW}  (0 = unbounded)"
echo " Per point : ${SIMULATION_MINUTES}m x 3 conditions"
echo " Container : ${MEM_LIMIT} RAM, swap off, ${CPUS} vCPU"
echo " Results   : ${RESULTS_DIR}"
echo "======================================================================"
echo

for CAP in "${CAPS[@]}"; do
    CAP=$(echo "$CAP" | xargs)
    [ -z "$CAP" ] && continue
    export SAMM_MAX_TOUCH_BYTES="$CAP"
    TAG="cap${CAP}"

    echo "########## write cap = ${CAP} bytes ##########"

    run_condition "${TAG}-glibc"   "docker/baseline-environment/Dockerfile" \
        "samm-baseline:bench" "samm-touch-base"
    run_condition "${TAG}-jemalloc" "docker/baseline-environment/Dockerfile" \
        "samm-baseline:bench" "samm-touch-base" \
        -e LD_PRELOAD="$JEMALLOC_SO"
    run_condition "${TAG}-samm"    "docker/samm-environment/Dockerfile" \
        "samm-enabled:bench" "samm-touch-samm" \
        -e SAMM_ALLOCATOR_ENABLED=true \
        -e LD_PRELOAD="$JEMALLOC_SO" \
        -e SAMM_RECLAIM_POLICY="$SAMM_RECLAIM_POLICY" \
        -e SAMM_WARMUP="$SAMM_WARMUP"
    echo
done

"$PYTHON_BIN" - "$RESULTS_DIR" "$TOUCH_CAPS_RAW" <<'PYEOF'
import json, os, sys

results_dir, caps_raw = sys.argv[1], sys.argv[2]
caps = [c.strip() for c in caps_raw.split(",") if c.strip()]
KIND = [("glibc", "glibc"), ("jemalloc", "jemalloc"), ("samm", "SAMM")]

def load(cap, kind):
    p = os.path.join(results_dir, f"cap{cap}-{kind}.json")
    return json.load(open(p)) if os.path.exists(p) else None

def label(cap):
    return "unbounded" if cap == "0" else f"{int(cap)//1024}KB"

print()
print("=" * 104)
print(" TOUCH SWEEP — what residency costs, and who pays less for it")
print("=" * 104)
print(f"{'cap':>10}{'allocator':>11}{'PeakRSS MB':>12}{'%ceil':>8}{'cpu%':>7}{'thr':>6}"
      f"{'faults/req':>12}{'proc p99':>10}{'thruput':>9}{'fallbacks':>11}")
print("-" * 104)
for cap in caps:
    for kind, name in KIND:
        r = load(cap, kind)
        if not r:
            continue
        a_path = os.path.join(results_dir, f"cap{cap}-{kind}-allocator.json")
        fb = ""
        if os.path.exists(a_path):
            a = json.load(open(a_path))
            fb = f"{a.get('capacityFallbacks', 0):,}"
        flag = " SUSPECT" if r.get("timing_suspect") else ""
        print(f"{label(cap):>10}{name:>11}{r['peak_rss_mb']:>12,.1f}"
              f"{100*r['peak_rss_mb']/r['mem_limit_mb']:>7.1f}%{r['cpu_utilisation_pct']:>7.1f}"
              f"{r['cpu_throttled_periods']:>6,}{r.get('page_faults_per_request', 0):>12,.1f}"
              f"{r['processing_p99_ms']:>10,.2f}{r['throughput_rps']:>9,.1f}{fb:>11}{flag}")
    print("-" * 104)

print("\nRECYCLING CHECK — faults per request, lower means more page reuse")
for cap in caps:
    vals = [(n, load(cap, k)) for k, n in KIND]
    vals = [(n, r["page_faults_per_request"]) for n, r in vals if r]
    if len(vals) < 2:
        continue
    best = min(v for _, v in vals)
    line = "  ".join(f"{n}={v:,.1f}" + ("*" if v == best else "") for n, v in vals)
    print(f"  cap {label(cap):>10}:  {line}")
print("  (* = fewest faults. If the three differ materially, recycling is real")
print("   and the allocators are paying measurably different fault costs.)")

print("\nSAMM BUDGET — does raising the cap clear the exhaustion?")
for cap in caps:
    p = os.path.join(results_dir, f"cap{cap}-samm-allocator.json")
    if not os.path.exists(p):
        continue
    a = json.load(open(p))
    print(f"  cap {label(cap):>10}:  bumpResetBlocked={a['bumpResetBlocked']:>8,}  "
          f"fallbacks={a['capacityFallbacks']:>8,}  "
          f"committed={a['committedBytes']/2**20:>7.1f} of {a['ceilingBytes']/2**20:.0f} MB")
PYEOF

echo
echo "[touch-sweep] Done. Raw results in $RESULTS_DIR"
