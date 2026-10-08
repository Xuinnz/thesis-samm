#!/usr/bin/env bash
#
# run.sh -- run one internal-validation experiment against each allocator
# config, ONE CONTAINER AT A TIME (configs never share the CPU).
#
# Usage (from anywhere):
#   internal-validation/run.sh calibrate  [config ...]
#   internal-validation/run.sh throughput [config ...]
#   internal-validation/run.sh latency    [config ...]
#
#   configs: glibc  jemalloc  samm  glibc-tuned
#   default: glibc jemalloc samm, in that order (the validated three-way)
#
# Experiment inputs, passed through to k6 (see each scenario's header):
#   calibrate   CAL_VUS (required)  CAL_STEP_SECONDS  CAL_STEP_WARMUP_SECONDS  CAL_GAP_SECONDS
#   throughput  SATURATION_VUS (required)  WARMUP_SECONDS  MEASURE_SECONDS  COOLDOWN_SECONDS
#   latency     LATENCY_RPS_SWEEP or LATENCY_RPS (required)  LATENCY_STEP_SECONDS
#               LATENCY_STEP_WARMUP_SECONDS  LATENCY_GAP_SECONDS  LATENCY_VU_HEADROOM  LATENCY_MAX_VUS
#
# Shared settings:
#   LOAD_K       load point in demo/loads.js whose hold scaling to use (default 2.5; see README)
#   SEED         request-stream seed, same for every config (default 20250911)
#   RESULTS_DIR  default internal-validation/results/<experiment>-<timestamp>
#   HOST_PORT    default 3000
#   SKIP_BUILD   1 = reuse the existing images instead of rebuilding them
#   POLL_SAMM_STATS  1 = for the samm config, also record /samm/stats once a second
#                (allocator.jsonl: fallbacks, budget refusals, bumpResetBlocked, detach
#                failures...). Off by default: it adds one request per second to the
#                server, so runs compared against unpolled runs should leave it off.
#
# Output: $RESULTS_DIR/<config>/
#   summary.json   k6 handleSummary output        raw.csv.gz   every k6 sample (k6 --out csv)
#   container.tsv  cgroup CPU / memory / faults, 1 s     run.json  settings, host, container fate
#   allocator.jsonl  SAMM's own counters, 1 s (samm config with POLL_SAMM_STATS=1 only)
#   k6.log         k6 stdout (the summary)       k6-stderr.log  k6 warnings and errors
#
# Container settings mirror server/scripts/_bench-lib.sh run_condition, so these
# are the same containers the realistic benchmark measures. Nothing outside
# internal-validation/ is modified.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SCEN="$HERE/k6-scenarios"

EXPERIMENT="${1:-}"
shift || true
case "$EXPERIMENT" in
  calibrate)  SCRIPT=calibrate-saturation.js ;;
  throughput) SCRIPT=throughput-saturation.js ;;
  latency)    SCRIPT=latency-baseline.js ;;
  *) sed -n '3,20p' "$0"; exit 2 ;;
esac
CONFIGS=("$@")
[ ${#CONFIGS[@]} -eq 0 ] && CONFIGS=(glibc jemalloc samm)
for c in "${CONFIGS[@]}"; do
  case "$c" in glibc|jemalloc|samm|glibc-tuned) ;; *) echo "unknown config: $c"; exit 2 ;; esac
done

# Fail before starting anything if the experiment's required input is missing.
case "$EXPERIMENT" in
  calibrate)  [ -n "${CAL_VUS:-}" ] || { echo "CAL_VUS is required, e.g. CAL_VUS=50,100,150,200,300,400,500"; exit 2; } ;;
  throughput) [ -n "${SATURATION_VUS:-}" ] || { echo "SATURATION_VUS is required: run 'run.sh calibrate' and analysis/calibration_report.py first"; exit 2; } ;;
  latency)    [ -n "${LATENCY_RPS_SWEEP:-}${LATENCY_RPS:-}" ] || { echo "LATENCY_RPS_SWEEP (e.g. 10,20,40,80) or LATENCY_RPS is required"; exit 2; } ;;
esac

LOAD_K="${LOAD_K:-2.5}"
SEED="${SEED:-20250911}"
HOST_PORT="${HOST_PORT:-3000}"
RESULTS_DIR="${RESULTS_DIR:-$HERE/results/$EXPERIMENT-$(date +%Y%m%d-%H%M%S)}"
JEMALLOC_SO=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
# Same values server/scripts/run_allocator_attribution.sh uses for its tuned glibc.
GLIBC_MMAP_THRESHOLD="${GLIBC_MMAP_THRESHOLD:-131072}"
GLIBC_TRIM_THRESHOLD="${GLIBC_TRIM_THRESHOLD:-131072}"

log() { echo "[$(date +%T)] $*"; }

# --- workload parameters, read from the repo rather than typed in ------------
# Hold scaling for the chosen load point comes from demo/loads.js, the same
# table the demo and run_comparison.sh use: rate scales by k, every hold by 1/k,
# so rate x hold -- live memory -- stays at the level the table was trained on.
read -r HOLD_SCALE PROCESS_HOLD_MS < <(node -e '
  const { LOAD } = require(process.argv[1]);
  const L = LOAD[process.argv[2]];
  if (!L) { console.error("LOAD_K must be one of " + Object.keys(LOAD).join(", ")); process.exit(1); }
  console.log(L.HOLD_SCALE, L.PROCESS_HOLD_MS);
' "$REPO/demo/loads.js" "$LOAD_K") || exit 2

# The table's own workload: process payload cap, and the holds it was fit at.
read -r PROCESS_MAX_BYTES FP_HOLD_SCALE FP_PROCESS_HOLD_MS < <(python3 -c '
import json, sys
p = json.load(open(sys.argv[1]))["parameters"]
print(p["process_max_bytes"], p["hold_scale"], p["process_hold_ms"])
' "$REPO/zig-allocator/workload_fingerprint.json") || { echo "cannot read zig-allocator/workload_fingerprint.json"; exit 2; }

# SAMM refuses to boot when the workload differs from the one its table was fit
# to. Other load points keep rate x hold -- and so every quota -- unchanged, but
# the fingerprint hashes hold and rate separately and cannot see that, so it is
# told, exactly as the demo collector does for k != 1.0.
SAMM_MISMATCH=()
if ! python3 -c "import sys; sys.exit(0 if abs($HOLD_SCALE-$FP_HOLD_SCALE)<1e-6 and abs($PROCESS_HOLD_MS-$FP_PROCESS_HOLD_MS)<1e-6 else 1)"; then
  SAMM_MISMATCH=(-e SAMM_ALLOW_WORKLOAD_MISMATCH=true)
fi

# --- images --------------------------------------------------------------------
BASE_IMAGE=samm-baseline:bench
SAMM_IMAGE=samm-enabled:bench
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  log "building $BASE_IMAGE and $SAMM_IMAGE (SKIP_BUILD=1 to reuse)"
  docker build -q -f "$REPO/docker/baseline-environment/Dockerfile" -t "$BASE_IMAGE" "$REPO" >/dev/null || exit 1
  docker build -q -f "$REPO/docker/samm-environment/Dockerfile" -t "$SAMM_IMAGE" "$REPO" >/dev/null || exit 1
fi

if ss -ltn 2>/dev/null | grep -q ":$HOST_PORT "; then
  echo "port $HOST_PORT is in use (a demo container?). Stop it or set HOST_PORT."; exit 2
fi

mkdir -p "$RESULTS_DIR"
CURRENT=""
POLLER=""
STATS_POLLER=""
cleanup() {
  [ -n "$POLLER" ] && kill "$POLLER" 2>/dev/null
  [ -n "$STATS_POLLER" ] && kill "$STATS_POLLER" 2>/dev/null
  [ -n "$CURRENT" ] && docker rm -f "$CURRENT" >/dev/null 2>&1
}
trap cleanup EXIT INT TERM

poll_samm_stats() {   # poll_samm_stats <cgroup dir> <out.jsonl>: /samm/stats once a second until the cgroup vanishes
  local cg="$1" out="$2" body
  : > "$out"
  while [ -r "$cg/cpu.stat" ]; do
    # A saturated server may answer late or not at all: record null rather than stall.
    body=$(curl -s -m 2 "http://127.0.0.1:$HOST_PORT/samm/stats" 2>/dev/null)
    [ -n "$body" ] || body=null
    printf '{"uptime_s":%s,"wall_ms":%s,"stats":%s}\n' "$(cut -d' ' -f1 /proc/uptime)" "$(date +%s%3N)" "$body" >> "$out"
    sleep 1
  done
}

poll_cgroup() {   # poll_cgroup <cgroup dir> <out.tsv>: one line per second until the cgroup vanishes
  local cg="$1" out="$2"
  printf 'uptime_s\twall_ms\tusage_usec\tuser_usec\tsystem_usec\tnr_throttled\tthrottled_usec\tmemory_current\tpgfault\n' > "$out"
  while [ -r "$cg/cpu.stat" ]; do
    {
      printf '%s\t%s\t' "$(cut -d' ' -f1 /proc/uptime)" "$(date +%s%3N)"
      awk '{v[$1]=$2} END {printf "%s\t%s\t%s\t%s\t%s\t", v["usage_usec"], v["user_usec"], v["system_usec"], v["nr_throttled"], v["throttled_usec"]}' "$cg/cpu.stat"
      printf '%s\t%s\n' "$(cat "$cg/memory.current")" "$(awk '$1=="pgfault"{print $2}' "$cg/memory.stat")"
    } >> "$out" 2>/dev/null || break
    sleep 1
  done
}

log "experiment=$EXPERIMENT configs=${CONFIGS[*]} LOAD_K=$LOAD_K (HOLD_SCALE=$HOLD_SCALE PROCESS_HOLD_MS=$PROCESS_HOLD_MS) SEED=$SEED"
log "results -> $RESULTS_DIR"

for CONFIG in "${CONFIGS[@]}"; do
  OUT="$RESULTS_DIR/$CONFIG"
  mkdir -p "$OUT"
  CURRENT="iv-$CONFIG"
  IMAGE=$BASE_IMAGE
  EXTRA=()
  case "$CONFIG" in
    glibc)       ;;
    glibc-tuned) EXTRA=(-e MALLOC_MMAP_THRESHOLD_="$GLIBC_MMAP_THRESHOLD" -e MALLOC_TRIM_THRESHOLD_="$GLIBC_TRIM_THRESHOLD") ;;
    jemalloc)    EXTRA=(-e LD_PRELOAD="$JEMALLOC_SO") ;;
    samm)        IMAGE=$SAMM_IMAGE
                 EXTRA=(-e SAMM_ALLOCATOR_ENABLED=true -e LD_PRELOAD="$JEMALLOC_SO" -e SAMM_RECLAIM_POLICY=none
                        -e SAMM_WARMUP=false "${SAMM_MISMATCH[@]}") ;;
  esac

  log "=== $CONFIG: starting $CURRENT ($IMAGE)"
  docker rm -f "$CURRENT" >/dev/null 2>&1
  docker run -d --name "$CURRENT" \
    --memory=1024m --memory-swap=1024m --memory-swappiness=0 --cpus=1.0 \
    -p "$HOST_PORT:3000" \
    -e SHADOW_PROFILER_ENABLED=false -e SAMM_TELEMETRY=false \
    -e PROCESS_MAX_BYTES="$PROCESS_MAX_BYTES" -e HOLD_SCALE="$HOLD_SCALE" -e PROCESS_HOLD_MS="$PROCESS_HOLD_MS" \
    "${EXTRA[@]}" "$IMAGE" >/dev/null 2>"$OUT/docker-run.err" || { log "docker run failed:"; cat "$OUT/docker-run.err"; continue; }

  healthy=0
  for _ in $(seq 1 60); do
    curl -sf "http://127.0.0.1:$HOST_PORT/health" >/dev/null 2>&1 && { healthy=1; break; }
    sleep 1
  done
  if [ $healthy -ne 1 ]; then
    log "$CONFIG did not become healthy; last log lines:"; docker logs --tail 20 "$CURRENT" 2>&1 | tee "$OUT/container.log"
    docker rm -f "$CURRENT" >/dev/null 2>&1; CURRENT=""; continue
  fi

  CID=$(docker inspect -f '{{.Id}}' "$CURRENT")
  CG=""
  for cand in "/sys/fs/cgroup/system.slice/docker-$CID.scope" "/sys/fs/cgroup/docker/$CID" "/sys/fs/cgroup/$CID"; do
    [ -r "$cand/cpu.stat" ] && CG="$cand" && break
  done
  if [ -n "$CG" ]; then
    poll_cgroup "$CG" "$OUT/container.tsv" &
    POLLER=$!
    if [ "$CONFIG" = samm ] && [ "${POLL_SAMM_STATS:-0}" = 1 ]; then
      poll_samm_stats "$CG" "$OUT/allocator.jsonl" &
      STATS_POLLER=$!
    fi
  else
    log "WARNING: cgroup not found; container.tsv will be missing (no CPU/memory record)"
  fi

  log "$CONFIG: running $SCRIPT"
  START_WALL=$(date +%s%3N)
  (
    cd "$SCEN" && \
    BASE_URL="http://127.0.0.1:$HOST_PORT" SEED="$SEED" HOLD_SCALE="$HOLD_SCALE" PROCESS_HOLD_MS="$PROCESS_HOLD_MS" \
    CONFIG_LABEL="$CONFIG" SUMMARY_PATH="$OUT/summary.json" K6_CSV_TIME_FORMAT=unix_milli \
    k6 run --quiet --out "csv=$OUT/raw.csv.gz" "$SCRIPT"
  ) > "$OUT/k6.log" 2> "$OUT/k6-stderr.log"
  K6_RC=$?
  END_WALL=$(date +%s%3N)
  cat "$OUT/k6.log"

  [ -n "$POLLER" ] && { kill "$POLLER" 2>/dev/null; wait "$POLLER" 2>/dev/null; POLLER=""; }
  [ -n "$STATS_POLLER" ] && { kill "$STATS_POLLER" 2>/dev/null; wait "$STATS_POLLER" 2>/dev/null; STATS_POLLER=""; }
  STATE=$(docker inspect -f '{{.State.Status}} {{.State.OOMKilled}} {{.State.ExitCode}}' "$CURRENT" 2>/dev/null || echo "gone false -1")
  read -r C_STATUS C_OOM C_EXIT <<< "$STATE"
  docker logs "$CURRENT" > "$OUT/container.log" 2>&1
  IMAGE_ID=$(docker inspect -f '{{.Image}}' "$CURRENT" 2>/dev/null)
  docker rm -f "$CURRENT" >/dev/null 2>&1; CURRENT=""

  python3 - "$OUT/run.json" <<PY
import json, os, platform, subprocess, sys
def sh(cmd):
    try: return subprocess.run(cmd, shell=True, capture_output=True, text=True).stdout.strip()
    except Exception: return None
cpu = next((l.split(':', 1)[1].strip() for l in open('/proc/cpuinfo') if l.startswith('model name')), None)
json.dump({
    'experiment': '$EXPERIMENT', 'config': '$CONFIG', 'script': '$SCRIPT',
    'image': '$IMAGE', 'image_id': '$IMAGE_ID',
    'load_k': '$LOAD_K', 'hold_scale': $HOLD_SCALE, 'process_hold_ms': $PROCESS_HOLD_MS,
    'process_max_bytes': $PROCESS_MAX_BYTES, 'seed': $SEED,
    'samm_workload_mismatch_override': ${#SAMM_MISMATCH[@]} > 0 and '$CONFIG' == 'samm',
    'container_limits': {'memory': '1024m', 'swap': 'off', 'cpus': 1.0},
    'k6_exit_code': $K6_RC, 'start_wall_ms': $START_WALL, 'end_wall_ms': $END_WALL,
    'container_end_state': {'status': '$C_STATUS', 'oom_killed': '$C_OOM' == 'true', 'exit_code': int('$C_EXIT')},
    'host': {'cpu_model': cpu, 'nproc': os.cpu_count(), 'kernel': platform.release(),
             'k6': sh('k6 version'), 'docker': sh("docker version -f '{{.Server.Version}}'")},
}, open(sys.argv[1], 'w'), indent=2)
PY
  if [ "$C_OOM" = "true" ]; then
    log "$CONFIG: container was OOM-KILLED during the run (exit $C_EXIT) -- its results are not valid"
  else
    log "$CONFIG: done (k6 exit $K6_RC, container $C_STATUS)"
  fi
  sleep 10   # let the host settle between configs
done

case "$EXPERIMENT" in
  calibrate)  NEXT="calibration_report.py" ;;
  throughput) NEXT="throughput_report.py" ;;
  latency)    NEXT="latency_report.py" ;;
esac
log "all configs done. Next:"
echo "  $REPO/venv/bin/python3 $HERE/analysis/$NEXT $RESULTS_DIR"
