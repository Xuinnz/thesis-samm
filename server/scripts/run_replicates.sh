#!/usr/bin/env bash
#
# run_replicates.sh — n independent cycles of the comparison (three-way by
# default; CONDITIONS picks a subset, e.g. the main study's two-way).
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
#   # main study on the VM: two-way, server on core 1, k6 on cores 2-3
#   K=<locked k> N=100 CONDITIONS="jemalloc samm" CPUSET_CPUS=1 K6_TASKSET=2,3 \
#     RESULTS_DIR=benchmark-results/main-study ./server/scripts/run_replicates.sh
#   ... DRY_RUN=1 ...   # print each replicate's seed and order, run nothing
#
# ORDER. ROTATE=1 (default) rotates the condition order every replicate
# (two conditions: AB, BA, AB, ...; three: ABC, BCA, CAB, ...), so slow drift
# in the host or a position effect (first run after a pause, a warm page cache)
# lands on every condition equally instead of always on the first. The order is
# fixed by the replicate index, so a resumed campaign keeps it, and each result
# records its run_order and order_position. ROTATE=0 keeps CONDITIONS' order.
#
# RESUMABLE. Each condition writes one JSON per replicate and an existing file is
# skipped, so an interrupted campaign continues where it stopped rather than
# starting over. At ~12 minutes per run a full n=15 is roughly nine hours, which
# is long enough that a laptop sleeping through it is a real possibility -- and
# that already happened once in this project.
#
# CAMPAIGN LOCK. The first start writes RESULTS_DIR/campaign.json: the load
# point, seeds, pinning, buffer mode, the routing table's hash and a hash of
# every file the measured system is built from. A later start (a resume)
# refuses to add runs if any of those changed, so one folder never mixes two
# configurations. REQUIRE_CLEAN=1 also refuses uncommitted changes to those
# files. CAMPAIGN_ALLOW_CHANGE=1 overrides, and the change is written into
# campaign.json where the statistics will report it.
#
# HOST HEALTH. PROBE_EVERY=n runs the host probe (internal-validation/
# host-probe.sh, full) before the first replicate of every start, then before
# every n-th, and once at the end. A failed probe waits PROBE_RETRY_WAIT_S
# (600) and tries again, up to PROBE_RETRIES (6) times, then stops the campaign
# (exit 3; resume later). Every attempt is logged in RESULTS_DIR/
# host-health.tsv; the replicates between a passed probe and the next failed
# one are the ones the statistics' sensitivity check leaves out. Added
# 2026-11-15 after the VM slowed by up to 18 % within one boot (runbook,
# Phase 8, launch 1). PROBE_EVERY=0 (default) is off.
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
read -r -a CONDS <<< "${CONDITIONS:-glibc jemalloc samm}"
for c in "${CONDS[@]}"; do
  case "$c" in glibc|jemalloc|samm) ;; *) echo "ERROR: unknown condition '$c' (use glibc, jemalloc, samm)"; exit 1 ;; esac
done
ROTATE="${ROTATE:-1}"

# Condition order for replicate $1: rotated left by (replicate - 1).
replicate_order() {
  local i="$1" n=${#CONDS[@]} shift_by=0 j
  [ "$ROTATE" = "1" ] && shift_by=$(( (i - 1) % n ))
  for ((j = 0; j < n; j++)); do printf '%s ' "${CONDS[$(( (j + shift_by) % n ))]}"; done
}

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
# PEAK_RPS: the panel's higher-load extras (decided 2026-11-18). The holds stay
# K's and only the peak rate changes, so live memory grows with the rate. Unset
# (every other run), the load is exactly the table above.
if [ -n "${PEAK_RPS:-}" ]; then
  [[ "$PEAK_RPS" =~ ^[0-9]+$ ]] || { echo "ERROR: PEAK_RPS must be a whole number of requests per second (got '$PEAK_RPS')"; exit 1; }
  MAX_RPS="$PEAK_RPS"
fi

export SIMULATION_MINUTES="${SIMULATION_MINUTES:-10}"
export MIN_RPS=5 PRE_ALLOCATED_VUS=400 MAX_VUS=1400
# 1 GiB unless told otherwise (the panel's 2 GB / 4 GB runs: MEM_LIMIT=2048m).
# Swap is always off: memory-swap equals memory.
export MEM_LIMIT="${MEM_LIMIT:-1024m}" CPUS=1.0
export MEMSWAP_LIMIT="$MEM_LIMIT"
MEM_LIMIT_BYTES=$(numfmt --from=iec "${MEM_LIMIT^^}") || { echo "ERROR: MEM_LIMIT='$MEM_LIMIT' is not a size like 1024m or 2g"; exit 1; }

# SAMM's table is sized for one container limit. At k != 1.0 the server is told
# to accept a workload mismatch (below), which also silences its check of the
# limit, so check it here: a 1 GiB table in a 2 GiB container would run, and
# measure a pool half the size it should be.
TABLE_FINGERPRINT="$REPO_ROOT/zig-allocator/workload_fingerprint.json"
if [[ " ${CONDS[*]} " == *" samm "* ]] && [ "${SUMMARY_ONLY:-0}" != "1" ] && [ -f "$TABLE_FINGERPRINT" ]; then
  TABLE_LIMIT_BYTES=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['parameters'].get('container_limit_bytes',''))" "$TABLE_FINGERPRINT")
  if [ -n "$TABLE_LIMIT_BYTES" ] && [ "$TABLE_LIMIT_BYTES" != "$MEM_LIMIT_BYTES" ]; then
    echo "ERROR: the routing table was trained for a $((TABLE_LIMIT_BYTES / 1048576)) MiB container, and MEM_LIMIT=$MEM_LIMIT is $((MEM_LIMIT_BYTES / 1048576)) MiB."
    echo "       Retrain for this limit first (MEM_LIMIT=$MEM_LIMIT SKIP_BENCHMARK=1 server/scripts/run_full_pipeline.sh),"
    echo "       on a branch of its own so the main study's table stays as it is. See docs/vm-test-plan.md, Phase 10."
    exit 1
  fi
fi
# SAMM_TELEMETRY=true is for the GC pass only (study.sh gc): the GC observer
# perturbs the run, and the statistics refuse runs that had it on.
export SHADOW_PROFILER_ENABLED=false SAMM_TELEMETRY="${SAMM_TELEMETRY:-false}"
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

# A non-default limit or traffic batch gets a folder of its own, so its results
# are never mixed with (or skipped as "already done" by) the main configuration.
VARIANT=""
[ -n "${PEAK_RPS:-}" ] && VARIANT="$VARIANT-r$PEAK_RPS"
[ "$MEM_LIMIT" != "1024m" ] && VARIANT="$VARIANT-mem$MEM_LIMIT"
[ -n "${TRAFFIC_BATCH:-}" ] && VARIANT="$VARIANT-$TRAFFIC_BATCH"
export RESULTS_DIR="${RESULTS_DIR:-$REPO_ROOT/benchmark-results/replicates-k$K$VARIANT}"
mkdir -p "$RESULTS_DIR"

# shellcheck source=./_bench-lib.sh
source "$SCRIPT_DIR/_bench-lib.sh"

JEMALLOC_SO="${JEMALLOC_SO:-/usr/lib/x86_64-linux-gnu/libjemalloc.so.2}"

# --- campaign lock -----------------------------------------------------------
# Files the measured system is built from. A change to any of them makes a
# different system; documentation and analysis scripts are not in the list.
MEASURED_PATHS=(server/routes server/baseline-v8 server/samm-enabled profiler zig-allocator/src
  zig-allocator/build.zig zig-allocator/index.js zig-allocator/workload_check.js
  zig-allocator/workload_fingerprint.json docker load-generator
  server/scripts/_bench-lib.sh server/scripts/run_replicates.sh
  "datasets/azure-trace-2019/processed${TRAFFIC_BATCH:+/$TRAFFIC_BATCH}")
campaign_lock() {
  local dirty
  dirty=$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no -- "${MEASURED_PATHS[@]}" 2>/dev/null | wc -l) || true
  if [ "${REQUIRE_CLEAN:-0}" = "1" ] && [ "$dirty" -gt 0 ]; then
    echo "ERROR: REQUIRE_CLEAN=1 and $dirty measured file(s) have uncommitted changes:"
    git -C "$REPO_ROOT" status --porcelain --untracked-files=no -- "${MEASURED_PATHS[@]}" | sed 's/^/         /'
    exit 1
  fi
  CAMPAIGN_K="$K" CAMPAIGN_N="$N" CAMPAIGN_CONDS="${CONDS[*]}" CAMPAIGN_ROTATE="$ROTATE" \
  CAMPAIGN_BASE_SEED="$BASE_SEED" CAMPAIGN_VARY_SEED="$VARY_SEED" CAMPAIGN_DIRTY="$dirty" \
  CAMPAIGN_SYSTEM_SHA="$( { git -C "$REPO_ROOT" ls-files -s -- "${MEASURED_PATHS[@]}"; git -C "$REPO_ROOT" diff HEAD -- "${MEASURED_PATHS[@]}"; } 2>/dev/null | sha256sum | cut -d' ' -f1)" \
  CAMPAIGN_TABLE_SHA="$(sha256sum "$REPO_ROOT/zig-allocator/src/routing-table/model_weights.zig" | cut -d' ' -f1)" \
  CAMPAIGN_GIT="$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)" \
  CAMPAIGN_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)" \
  CAMPAIGN_THP="$(cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true)" \
  CAMPAIGN_DOCKER="$(docker version -f '{{.Server.Version}}' 2>/dev/null || true)" \
  CAMPAIGN_K6="$(k6 version 2>/dev/null | head -1 || true)" \
  CAMPAIGN_MACHINE="$(curl -s -m 2 -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/machine-type 2>/dev/null | sed 's|.*/||' || true)" \
  "$PYTHON_BIN" - "$RESULTS_DIR/campaign.json" "$TABLE_FINGERPRINT" <<'PYEOF' || exit 1
import datetime, json, os, platform, sys
path, fingerprint_path = sys.argv[1:3]
e = os.environ
try:
    fingerprint = json.load(open(fingerprint_path)).get("fingerprint")
except (OSError, ValueError):
    fingerprint = None
def cpu_model():
    try:
        return next(l.split(":", 1)[1].strip() for l in open("/proc/cpuinfo") if l.startswith("model name"))
    except (OSError, StopIteration):
        return None
locked = {   # a resume must match every one of these
    "k": e["CAMPAIGN_K"], "conditions": e["CAMPAIGN_CONDS"], "rotate": e["CAMPAIGN_ROTATE"],
    "base_seed": e["CAMPAIGN_BASE_SEED"], "vary_seed": e["CAMPAIGN_VARY_SEED"],
    "simulation_minutes": e.get("SIMULATION_MINUTES"), "mem_limit": e.get("MEM_LIMIT"),
    "max_rps": e.get("MAX_RPS"), "hold_scale": e.get("HOLD_SCALE"), "process_hold_ms": e.get("PROCESS_HOLD_MS"),
    "traffic_batch": e.get("TRAFFIC_BATCH") or "all days",
    "cpuset_cpus": e.get("CPUSET_CPUS") or None, "k6_taskset": e.get("K6_TASKSET") or None,
    "samm_buffer_mode": e.get("SAMM_BUFFER_MODE") or None, "samm_segment_reuse": e.get("SAMM_SEGMENT_REUSE") or None,
    "telemetry": e.get("SAMM_TELEMETRY") == "true",
    "routing_table_sha256": e["CAMPAIGN_TABLE_SHA"], "workload_fingerprint": fingerprint,
    "measured_system_sha256": e["CAMPAIGN_SYSTEM_SHA"],
}
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
start = {"at": now, "n_planned": int(e["CAMPAIGN_N"]), "git_commit": e.get("CAMPAIGN_GIT") or None,
         "git_branch": e.get("CAMPAIGN_BRANCH") or None, "dirty_measured_files": int(e["CAMPAIGN_DIRTY"]),
         "probe_every": int(e.get("PROBE_EVERY") or 0),
         "host": {"cpu_model": cpu_model(), "nproc": os.cpu_count(), "kernel": platform.release(),
                  "docker": e.get("CAMPAIGN_DOCKER") or None, "k6": e.get("CAMPAIGN_K6") or None,
                  "thp": e.get("CAMPAIGN_THP") or None, "machine_type": e.get("CAMPAIGN_MACHINE") or None}}
if os.path.exists(path):
    campaign = json.load(open(path))
    diff = {k: (campaign["locked"].get(k), v) for k, v in locked.items() if campaign["locked"].get(k) != v}
    if diff:
        print("ERROR: this folder's campaign was started with different settings:")
        for k, (was, now_) in diff.items():
            print(f"         {k}: was {was!r}, now {now_!r}")
        if e.get("CAMPAIGN_ALLOW_CHANGE") != "1":
            print("       Runs under different settings do not belong in one sample. Use another RESULTS_DIR,")
            print("       or put the settings back. (CAMPAIGN_ALLOW_CHANGE=1 overrides and records the change.)")
            sys.exit(1)
        print("       CAMPAIGN_ALLOW_CHANGE=1: continuing; the change is recorded in campaign.json.")
        campaign.setdefault("changes", []).append({"at": now, "changed": {k: {"was": a, "now": b} for k, (a, b) in diff.items()}})
        campaign["locked"] = locked
    campaign["starts"].append(start)
else:
    campaign = {"locked": locked, "starts": [start]}
with open(path, "w") as f:
    json.dump(campaign, f, indent=2)
print(f" Campaign : {path} (start {len(campaign['starts'])}; system {locked['measured_system_sha256'][:12]}, "
      f"table {locked['routing_table_sha256'][:12]})")
PYEOF
}

# --- host health -------------------------------------------------------------
PROBE_EVERY="${PROBE_EVERY:-0}"
HOST_PROBE_CMD="${HOST_PROBE_CMD:-$REPO_ROOT/internal-validation/host-probe.sh}"
HEALTH_LOG="$RESULTS_DIR/host-health.tsv"
# host_gate <replicate about to run, or "end">: probe until clean, or stop the campaign.
host_gate() {
  local before="$1" attempt=0 rc dir verdict
  [ -f "$HEALTH_LOG" ] || printf 'time_utc\tbefore_replicate\tattempt\tverdict\tprobe_dir\n' > "$HEALTH_LOG"
  while :; do
    attempt=$((attempt + 1))
    dir="$RESULTS_DIR/host-health/before-$before-$(date -u +%Y%m%dT%H%M%S)"
    echo; echo "---------- host probe before replicate $before (attempt $attempt) ----------"
    rc=0; "$HOST_PROBE_CMD" "$dir" full || rc=$?
    verdict=$([ "$rc" -eq 0 ] && echo pass || echo fail)
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$before" "$attempt" "$verdict" "${dir#"$RESULTS_DIR"/}" >> "$HEALTH_LOG"
    [ "$rc" -eq 0 ] && return 0
    if [ "$before" = "end" ]; then echo "Host probe failed after the last replicate (logged)."; return 0; fi
    if [ "$attempt" -gt "${PROBE_RETRIES:-6}" ]; then
      echo "ERROR: the host probe failed $attempt times in a row. Stopping; the campaign is resumable."
      exit 3
    fi
    echo "Host not clean. Waiting ${PROBE_RETRY_WAIT_S:-600} s before probing again."
    sleep "${PROBE_RETRY_WAIT_S:-600}"
  done
}

if [ "${SUMMARY_ONLY:-0}" != "1" ]; then
  echo "======================================================================"
  echo " Replicates: n=$N at k=$K, conditions: ${CONDS[*]} ($([ "$ROTATE" = "1" ] && echo 'order rotated each replicate' || echo 'fixed order'))"
  echo " Per run  : ${SIMULATION_MINUTES}m, MAX_RPS=$MAX_RPS, process hold ${PROCESS_HOLD_MS}ms, fetch hold x${HOLD_SCALE}"
  echo " Container: ${MEM_LIMIT}, swap off, ${CPUS} vCPU"
  echo " Traffic  : ${TRAFFIC_BATCH:-all published days (default models)}"
  echo " Seed     : $BASE_SEED $([ "$VARY_SEED" = "1" ] && echo '+ replicate index (paired: same seed for all conditions in a replicate)' || echo '(fixed across all replicates)')"
  echo " Results  : $RESULTS_DIR"
  echo " Pinning  : server ${CPUSET_CPUS:-not pinned}, k6 ${K6_TASKSET:-not pinned}"
  echo " Estimate : ~$(( N * ${#CONDS[@]} * 12 / 60 ))h$(( N * ${#CONDS[@]} * 12 % 60 ))m  (resumable; existing results are skipped)"
  [ "${DRY_RUN:-0}" = "1" ] || campaign_lock
  echo "======================================================================"

  since_probe=$PROBE_EVERY      # so the first replicate of every start is probed
  if [ "$PROBE_EVERY" -gt 0 ] && [ "${DRY_RUN:-0}" != "1" ]; then
    # A start marker: a failed probe says nothing about replicates run before this start.
    [ -f "$HEALTH_LOG" ] || printf 'time_utc\tbefore_replicate\tattempt\tverdict\tprobe_dir\n' > "$HEALTH_LOG"
    printf '%s\t-\t0\tstart\t-\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$HEALTH_LOG"
  fi
  ran_any=0
  failures_in_a_row=0
  for i in $(seq 1 "$N"); do
    export SCHEDULE_SEED=$([ "$VARY_SEED" = "1" ] && echo $((BASE_SEED + i)) || echo "$BASE_SEED")
    read -r -a order <<< "$(replicate_order "$i")"
    export RUN_ORDER="${order[*]}"
    pending=0
    for cond in "${order[@]}"; do [ -f "$RESULTS_DIR/r$(printf '%02d' "$i")-$cond.json" ] || pending=1; done
    if [ "$pending" = "1" ] && [ "${DRY_RUN:-0}" != "1" ] && [ "$PROBE_EVERY" -gt 0 ]; then
      if [ "$since_probe" -ge "$PROBE_EVERY" ]; then host_gate "$i"; since_probe=0; fi
      since_probe=$((since_probe + 1))
    fi
    echo; echo "########## replicate $i/$N (seed $SCHEDULE_SEED, order: $RUN_ORDER) ##########"
    pos=0
    for cond in "${order[@]}"; do
      pos=$((pos + 1)); export RUN_ORDER_POSITION=$pos
      label="r$(printf '%02d' "$i")-$cond"
      if [ -f "$RESULTS_DIR/$label.json" ]; then echo "  [$label] already done, skipping"; continue; fi
      if [ "${DRY_RUN:-0}" = "1" ]; then echo "  [$label] would run (position $pos)"; continue; fi
      ran_any=1
      case "$cond" in
        glibc)    run_condition "$label" "docker/baseline-environment/Dockerfile" "samm-baseline:bench" "rep-glibc" || echo "[[ $label FAILED ]]" ;;
        jemalloc) run_condition "$label" "docker/baseline-environment/Dockerfile" "samm-baseline:bench" "rep-jem" \
                    -e LD_PRELOAD="$JEMALLOC_SO" || echo "[[ $label FAILED ]]" ;;
        samm)     run_condition "$label" "docker/samm-environment/Dockerfile" "samm-enabled:bench" "rep-samm" \
                    -e SAMM_ALLOCATOR_ENABLED=true -e LD_PRELOAD="$JEMALLOC_SO" \
                    -e SAMM_RECLAIM_POLICY=none -e SAMM_WARMUP=false \
                    -e SAMM_SEGMENT_REUSE="${SAMM_SEGMENT_REUSE:-}" \
                    -e SAMM_BUFFER_MODE="${SAMM_BUFFER_MODE:-}" \
                    "${SAMM_EXTRA[@]}" || echo "[[ $label FAILED ]]" ;;
      esac
      # A run that leaves no result file is a harness failure (a build error,
      # no k6, a port in use), not a measurement: an OOM-killed container still
      # writes its file. Three in a row means it will not fix itself.
      if [ -f "$RESULTS_DIR/$label.json" ]; then failures_in_a_row=0; else failures_in_a_row=$((failures_in_a_row + 1)); fi
      if [ "$failures_in_a_row" -ge 3 ]; then
        echo "ERROR: three runs in a row produced no result file. Stopping; fix the cause and start again (resumable)."
        exit 4
      fi
    done
  done
  if [ "$ran_any" = "1" ] && [ "$PROBE_EVERY" -gt 0 ]; then host_gate end; fi
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
        ended = (r.get("container_end_state") or {}).get("status")
        r["_died"] = ((r["cpu_utilisation_pct"] == 0.0) or r["oom_kills"] > 0 or r["failed_rate"] > 0.05
                      or ended not in (None, "running", "unknown"))
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
deaths = [(c, os.path.basename(p)[:3], r) for c, _ in CONDS for p in sorted(glob.glob(os.path.join(results_dir, f"r*-{c}.json")))
          for r in [json.load(open(p))] if (r.get("container_end_state") or {}).get("status") not in (None, "running", "unknown")]
for cond, rep_id, r in deaths:
    e = r["container_end_state"]
    print(f"  {rep_id} {cond}: container {e['status']} (OOM-killed: {e['oom_killed']}, exit {e['exit_code']}) "
          f"{r.get('died_after_s')} s after k6 was launched (start-up included); peak {r['peak_rss_mb']} MB")

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
