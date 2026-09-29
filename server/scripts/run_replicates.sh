#!/usr/bin/env bash
#
# run_replicates.sh — n independent cycles of the three-way comparison.
#
# Characterization and the ML refinery are NOT re-run: the routing table is
# already compiled for this workload, and recompiling between replicates would
# make each one a different allocator. Only the benchmark repeats.
#
# Usage:
#   K=1.0 N=15 ./server/scripts/run_replicates.sh     # main table, all healthy
#   K=2.0 N=10 ./server/scripts/run_replicates.sh     # survival rate under stress
#   K=1.0 N=15 SUMMARY_ONLY=1 ./server/scripts/run_replicates.sh   # re-print results
#
# RESUMABLE. Each condition writes one JSON per replicate and an existing file is
# skipped, so an interrupted campaign continues where it stopped rather than
# starting over. At ~12 minutes per run a full n=15 is roughly nine hours, which
# is long enough that a laptop sleeping through it is a real possibility -- and
# that already happened once in this project.
#
# WHY TEN MINUTES AND NOT THREE
#
# Three-minute runs mislead, measured twice. At the 2MB write cap they put SAMM
# ahead of jemalloc on RSS (290.7 vs 300.3) while ten minutes reversed it
# (302.8 vs 267.9) -- jemalloc's decay had not settled. At k=2.0 they showed
# glibc surviving at 916.6 MB while ten minutes took it to the ceiling and killed
# it. A third of a three-minute run is warmup: bumpResetBlocked was 31,655 at
# three minutes and 131 at ten, for the same configuration.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

K="${K:-1.0}"
N="${N:-15}"

# Load point. Arrival rate scales by k, every hold by 1/k, so peak live bytes --
# and every quota derived from them -- stay put while CPU pressure rises.
case "$K" in
  1.0) MAX_RPS=500;  PROCESS_HOLD_MS=600; HOLD_SCALE=4     ;;
  1.5) MAX_RPS=750;  PROCESS_HOLD_MS=400; HOLD_SCALE=2.667 ;;
  2.0) MAX_RPS=1000; PROCESS_HOLD_MS=300; HOLD_SCALE=2     ;;
  2.5) MAX_RPS=1250; PROCESS_HOLD_MS=240; HOLD_SCALE=1.6   ;;
  3.0) MAX_RPS=1500; PROCESS_HOLD_MS=200; HOLD_SCALE=1.333 ;;
  *) echo "ERROR: K must be one of 1.0 1.5 2.0 2.5 3.0 (got '$K')"; exit 1 ;;
esac

export SIMULATION_MINUTES="${SIMULATION_MINUTES:-10}"
export MIN_RPS=5 PRE_ALLOCATED_VUS=400 MAX_VUS=1400
export MEM_LIMIT=1024m MEMSWAP_LIMIT=1024m CPUS=1.0
export SHADOW_PROFILER_ENABLED=false SAMM_TELEMETRY=false
export PROCESS_MAX_BYTES=$((16*1024*1024))
export SAMM_RECLAIM_POLICY=none SAMM_WARMUP=false
export MAX_RPS PROCESS_HOLD_MS HOLD_SCALE

# PAIRED DESIGN. Each replicate gets its own seed, and every condition within
# that replicate gets the SAME one -- so the allocators serve a byte-identical
# request stream and workload variance cancels out of the difference rather than
# inflating it. Across replicates the seed varies, so the campaign still samples
# the payload and hold distributions instead of one fixed draw.
#
# This only became possible once the request stream itself was seeded. The seed
# used to drive the Markov schedule alone -- the per-minute RPS target and
# nothing else -- while endpoint choice, payload size, hold time and the
# server's own draws all came from unseeded Math.random. Measured consequence:
# two runs of the same k=2.0 point put jemalloc at 96.5% and 98.5% of the memory
# ceiling, one surviving and one not.
#
# Set VARY_SEED=0 to hold one seed across every replicate instead, which
# measures pure machine noise on a single fixed workload.
BASE_SEED="${SCHEDULE_SEED:-20250911}"
VARY_SEED="${VARY_SEED:-1}"

# k != 1.0 runs against a table characterized at k=1.0. That is sound because
# lambda*W is invariant, so P_j and the segment requirement are unchanged -- but
# the fingerprint hashes lambda and W separately and cannot see that, so it has
# to be told.
SAMM_EXTRA=()
[ "$K" != "1.0" ] && SAMM_EXTRA=(-e SAMM_ALLOW_WORKLOAD_MISMATCH=true)

export RESULTS_DIR="${RESULTS_DIR:-$REPO_ROOT/benchmark-results/replicates-k$K}"
mkdir -p "$RESULTS_DIR"

# shellcheck source=./_bench-lib.sh
source "$SCRIPT_DIR/_bench-lib.sh"

JEMALLOC_SO="${JEMALLOC_SO:-/usr/lib/x86_64-linux-gnu/libjemalloc.so.2}"

if [ "${SUMMARY_ONLY:-0}" != "1" ]; then
  echo "======================================================================"
  echo " Replicates: n=$N at k=$K"
  echo " Per run  : ${SIMULATION_MINUTES}m, MAX_RPS=$MAX_RPS, process hold ${PROCESS_HOLD_MS}ms, fetch hold x${HOLD_SCALE}"
  echo " Container: ${MEM_LIMIT}, swap off, ${CPUS} vCPU"
  echo " Seed     : $BASE_SEED $([ "$VARY_SEED" = "1" ] && echo '+ replicate index (paired: same seed for all conditions in a replicate)' || echo '(fixed across all replicates)')"
  echo " Results  : $RESULTS_DIR"
  echo " Estimate : ~$(( N * 3 * 12 / 60 ))h$(( N * 3 * 12 % 60 ))m  (resumable; existing results are skipped)"
  echo "======================================================================"

  for i in $(seq 1 "$N"); do
    export SCHEDULE_SEED=$([ "$VARY_SEED" = "1" ] && echo $((BASE_SEED + i)) || echo "$BASE_SEED")
    echo; echo "########## replicate $i/$N (seed $SCHEDULE_SEED) ##########"
    for cond in glibc jemalloc samm; do
      label="r$(printf '%02d' "$i")-$cond"
      if [ -f "$RESULTS_DIR/$label.json" ]; then echo "  [$label] already done, skipping"; continue; fi
      case "$cond" in
        glibc)    run_condition "$label" "docker/baseline-environment/Dockerfile" "samm-baseline:bench" "rep-glibc" || echo "[[ $label FAILED ]]" ;;
        jemalloc) run_condition "$label" "docker/baseline-environment/Dockerfile" "samm-baseline:bench" "rep-jem" \
                    -e LD_PRELOAD="$JEMALLOC_SO" || echo "[[ $label FAILED ]]" ;;
        samm)     run_condition "$label" "docker/samm-environment/Dockerfile" "samm-enabled:bench" "rep-samm" \
                    -e SAMM_ALLOCATOR_ENABLED=true -e LD_PRELOAD="$JEMALLOC_SO" \
                    -e SAMM_RECLAIM_POLICY=none -e SAMM_WARMUP=false \
                    "${SAMM_EXTRA[@]}" || echo "[[ $label FAILED ]]" ;;
      esac
    done
  done
fi

"$PYTHON_BIN" - "$RESULTS_DIR" "$K" <<'PYEOF'
import json, os, sys, glob, statistics as st

results_dir, K = sys.argv[1], sys.argv[2]
CONDS = [("glibc", "glibc"), ("jemalloc", "jemalloc"), ("samm", "SAMM")]

def load(cond):
    out = []
    for p in sorted(glob.glob(os.path.join(results_dir, f"r*-{cond}.json"))):
        r = json.load(open(p))
        # A run whose container vanished has zeroed CPU/fault counters; its
        # memory and drop figures survive via the poller but its performance
        # numbers describe a dying process and must not enter a mean.
        r["_died"] = (r["cpu_utilisation_pct"] == 0.0) or r["oom_kills"] > 0 or r["failed_rate"] > 0.05
        r["_suspect"] = r.get("timing_suspect", False)
        out.append(r)
    return out

def ms(vals):
    if not vals: return "—"
    if len(vals) == 1: return f"{vals[0]:.1f}"
    m, s = st.mean(vals), st.stdev(vals)
    ci = 1.96 * s / (len(vals) ** 0.5)
    return f"{m:.1f} ±{ci:.1f}"

print()
print("=" * 96)
print(f" REPLICATES AT k={K}")
print("=" * 96)
print(f"{'condition':11}{'n':>4}{'survived':>10}{'suspect':>9}   "
      f"{'Peak RSS MB':>16}{'proc p99 ms':>16}{'thruput rps':>16}")
print("-" * 96)
any_rows = False
for cond, name in CONDS:
    rows = load(cond)
    if not rows: continue
    any_rows = True
    ok = [r for r in rows if not r["_died"] and not r["_suspect"]]
    survived = len(rows) - sum(r["_died"] for r in rows)
    print(f"{name:11}{len(rows):>4}{str(survived) + '/' + str(len(rows)):>10}"
          f"{sum(r['_suspect'] for r in rows):>9}   "
          f"{ms([r['peak_rss_mb'] for r in ok]):>16}"
          f"{ms([r['processing_p99_ms'] for r in ok]):>16}"
          f"{ms([r['throughput_rps'] for r in ok]):>16}")
if not any_rows:
    sys.exit("No results yet in " + results_dir)
print("-" * 96)
print("  Mean ±95% CI, over runs that survived and were not timing-suspect.")
print("  'survived' counts runs with no OOM, live counters at teardown, and <5% failed requests.")

# Pairwise memory comparison only where both conditions have healthy runs.
def healthy(cond):
    return [r['peak_rss_mb'] for r in load(cond) if not r['_died'] and not r['_suspect']]
g, j, s = healthy("glibc"), healthy("jemalloc"), healthy("samm")
if len(s) > 1 and len(j) > 1:
    ds, dj = st.mean(s), st.mean(j)
    pooled = ((st.stdev(s)**2)/len(s) + (st.stdev(j)**2)/len(j)) ** 0.5
    print(f"\n  SAMM vs jemalloc peak RSS: {ds:.1f} vs {dj:.1f} MB "
          f"({100*(ds-dj)/dj:+.1f}%), difference {abs(ds-dj):.1f} ± {1.96*pooled:.1f} MB")
    print("  " + ("Separated at 95% confidence." if abs(ds-dj) > 1.96*pooled
                  else "NOT separated at 95% confidence — inside run-to-run noise."))
PYEOF
