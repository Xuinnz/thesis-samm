#!/usr/bin/env bash
#
# run_oracle.sh
#
# One reachability-oracle run: the ground truth Layer 1's labels are checked
# against (server/routes/_oracle.js). The baseline image serves the normal
# workload with the profiler OFF while the oracle forces a full GC every
# SAMM_ORACLE_GC_MS and records, for every Buffer, the last GC that found it
# alive and the first that found it dead. Then the matrix analysis runs.
#
#   1. Rebuild the baseline image (so it carries the current routes)
#   2. Start it with the oracle on, wait for /health, record /workload
#   3. Run k6 at a LOW rate: forced GCs every few ms take much of the CPU,
#      and reachability does not depend on the rate
#   4. Stop it with SIGTERM, so the oracle's exit hook writes the Buffers
#      still alive (censored) and meta.json
#   5. stats-eval/matrix-validation/oracle_matrix.py against the current table
#
# Nothing from this run is a performance measurement.
#
# Usage:
#   ./run_oracle.sh
#   SCHEDULE_SEED=2025 ORACLE_LABEL=seed2025 ./run_oracle.sh
#   SAMM_ORACLE_GC_MS=5 MAX_RPS=50 ./run_oracle.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

COMPOSE_FILE="$REPO_ROOT/docker/baseline-environment/docker-compose.yml"
IMAGE="samm-baseline:latest"
CONTAINER="samm-oracle"
K6_SCENARIO_DIR="$REPO_ROOT/load-generator/k6-scenarios"
K6_SCENARIO_FILE="samm-load-test.js"

BASE_URL="${BASE_URL:-http://localhost:3000}"

# Allocation shape: the k = 1.0 workload the table is trained on, so the
# fingerprint matches the characterization. Only the RATE is lower.
LOAD_K="${LOAD_K:-1.0}"
read -r LOAD_HOLD_SCALE LOAD_PROCESS_HOLD_MS < <(node -e '
  const { LOAD } = require(process.argv[1]);
  const L = LOAD[process.argv[2]];
  if (!L) { console.error("LOAD_K must be one of " + Object.keys(LOAD).join(", ")); process.exit(1); }
  console.log(L.HOLD_SCALE, L.PROCESS_HOLD_MS);
' "$REPO_ROOT/demo/loads.js" "$LOAD_K") || exit 2
HOLD_SCALE="${HOLD_SCALE:-$LOAD_HOLD_SCALE}"
PROCESS_HOLD_MS="${PROCESS_HOLD_MS:-$LOAD_PROCESS_HOLD_MS}"
PROCESS_MAX_BYTES="${PROCESS_MAX_BYTES:-16777216}"

MIN_RPS="${MIN_RPS:-5}"
MAX_RPS="${MAX_RPS:-100}"
SIMULATION_MINUTES="${SIMULATION_MINUTES:-5}"
PRE_ALLOCATED_VUS="${PRE_ALLOCATED_VUS:-400}"
MAX_VUS="${MAX_VUS:-1400}"
# The characterization's seed by default: same traffic walk, so this checks the
# table on the input it was trained from. Another seed is the held-out check.
SCHEDULE_SEED="${SCHEDULE_SEED-19870601}"
SAMM_ORACLE_GC_MS="${SAMM_ORACLE_GC_MS:-10}"

ORACLE_LABEL="${ORACLE_LABEL:-seed${SCHEDULE_SEED:-random}-gc${SAMM_ORACLE_GC_MS}ms}"
OUT_DIR="$REPO_ROOT/datasets/oracle/$ORACLE_LABEL"

MARKOV_MATRIX_PATH="${MARKOV_MATRIX_PATH:-../../datasets/azure-trace-2019/processed/traffic-models/markov_transition_matrix.csv}"
TRAFFIC_SERIES_PATH="${TRAFFIC_SERIES_PATH:-../../datasets/azure-trace-2019/processed/traffic-models/traffic_state_series.csv}"
JITTER_PARAMS_PATH="${JITTER_PARAMS_PATH:-../../datasets/azure-trace-2019/processed/traffic-models/jitter_parameters.json}"
PAYLOAD_CSV_PATH="${PAYLOAD_CSV_PATH:-../../datasets/azure-trace-2019/processed/memory-models/memory_payload_allocations.csv}"

HEALTH_CHECK_TIMEOUT_S="${HEALTH_CHECK_TIMEOUT_S:-30}"
# The exit hook runs one last forced GC and writes every censored row before
# the process ends; docker must not SIGKILL it first.
STOP_TIMEOUT_S="${STOP_TIMEOUT_S:-60}"

if [ -n "${PYTHON_BIN:-}" ]; then
    :
elif [ -x "$REPO_ROOT/venv/bin/python3" ]; then
    PYTHON_BIN="$REPO_ROOT/venv/bin/python3"
else
    PYTHON_BIN="python3"
fi

log() { echo "[run_oracle] $*"; }

CONTAINER_STARTED=0
cleanup() {
    if [ "$CONTAINER_STARTED" -eq 1 ]; then
        log "Cleanup: stopping oracle container..."
        docker stop -t "$STOP_TIMEOUT_S" "$CONTAINER" > /dev/null 2>&1 || true
        docker rm "$CONTAINER" > /dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

# The output directory is created here, as this user, so the analysis can
# write beside the container's (root-owned) files.
docker rm -f "$CONTAINER" > /dev/null 2>&1 || true
mkdir -p "$OUT_DIR"
rm -f "$OUT_DIR/objects.csv" "$OUT_DIR/gcs.csv" "$OUT_DIR/meta.json" "$OUT_DIR/workload_manifest.json"

log "Step 1/5: Building the baseline image..."
docker compose -f "$COMPOSE_FILE" build characterization

log "Step 2/5: Starting the oracle container (forced GC every ${SAMM_ORACLE_GC_MS} ms)..."
# Same limits as every other run; jemalloc as in the characterization.
docker run -d --name "$CONTAINER" \
    -p 3000:3000 \
    --memory 1024m --memory-swap 1024m --memory-swappiness 0 --cpus 1.0 \
    -e SHADOW_PROFILER_ENABLED=false \
    -e SAMM_ORACLE=true \
    -e SAMM_ORACLE_GC_MS="$SAMM_ORACLE_GC_MS" \
    -e SAMM_ORACLE_DIR=/app/datasets/oracle-out \
    -e PROCESS_MAX_BYTES="$PROCESS_MAX_BYTES" \
    -e HOLD_SCALE="$HOLD_SCALE" \
    -e PROCESS_HOLD_MS="$PROCESS_HOLD_MS" \
    -e LD_PRELOAD="${ORACLE_LD_PRELOAD-/usr/lib/x86_64-linux-gnu/libjemalloc.so.2}" \
    -v "$OUT_DIR:/app/datasets/oracle-out" \
    "$IMAGE" > /dev/null
CONTAINER_STARTED=1

elapsed=0
until curl -sf "$BASE_URL/health" > /dev/null 2>&1; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge "$HEALTH_CHECK_TIMEOUT_S" ]; then
        log "ERROR: server did not become healthy within ${HEALTH_CHECK_TIMEOUT_S}s. Logs: docker logs $CONTAINER"
        exit 1
    fi
done
curl -sf "$BASE_URL/workload" -o "$OUT_DIR/workload_manifest.json"
log "Healthy after ${elapsed}s; workload fingerprint $("$PYTHON_BIN" -c "import json,sys; print(json.load(open(sys.argv[1]))['fingerprint'])" "$OUT_DIR/workload_manifest.json")"

log "Step 3/5: Running k6 (${SIMULATION_MINUTES} min, MIN_RPS=${MIN_RPS}, MAX_RPS=${MAX_RPS}, HOLD_SCALE=${HOLD_SCALE}, PROCESS_HOLD_MS=${PROCESS_HOLD_MS}, seed ${SCHEDULE_SEED:-random})..."
(
    cd "$K6_SCENARIO_DIR"
    k6 run --quiet \
        -e BASE_URL="$BASE_URL" \
        -e HOLD_SCALE="$HOLD_SCALE" \
        -e PROCESS_HOLD_MS="$PROCESS_HOLD_MS" \
        -e MARKOV_MATRIX_PATH="$MARKOV_MATRIX_PATH" \
        -e TRAFFIC_SERIES_PATH="$TRAFFIC_SERIES_PATH" \
        -e JITTER_PARAMS_PATH="$JITTER_PARAMS_PATH" \
        -e PAYLOAD_CSV_PATH="$PAYLOAD_CSV_PATH" \
        -e MIN_RPS="$MIN_RPS" \
        -e MAX_RPS="$MAX_RPS" \
        -e SIMULATION_MINUTES="$SIMULATION_MINUTES" \
        -e PRE_ALLOCATED_VUS="$PRE_ALLOCATED_VUS" \
        -e MAX_VUS="$MAX_VUS" \
        ${SCHEDULE_SEED:+-e SCHEDULE_SEED="$SCHEDULE_SEED"} \
        "$K6_SCENARIO_FILE"
) || log "k6 exited non-zero (thresholds are performance checks and mean nothing here); continuing"

log "Step 4/5: Stopping (SIGTERM, up to ${STOP_TIMEOUT_S}s for the exit hook)..."
docker stop -t "$STOP_TIMEOUT_S" "$CONTAINER" > /dev/null
docker logs "$CONTAINER" 2>&1 | grep '^\[oracle\]' || true
docker rm "$CONTAINER" > /dev/null
CONTAINER_STARTED=0

if [ ! -f "$OUT_DIR/meta.json" ]; then
    log "ERROR: no meta.json -- the exit hook did not run, so Buffers alive at shutdown are missing."
    exit 1
fi

log "Step 5/5: Matrix against the current routing table..."
"$PYTHON_BIN" "$REPO_ROOT/stats-eval/matrix-validation/oracle_matrix.py" "$OUT_DIR"

log "Done: $OUT_DIR"
