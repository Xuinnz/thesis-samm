#!/usr/bin/env bash
#
# run_characterization.sh
#
# Runs one full characterization pass end-to-end:
#   1. Tear down any leftover container from a previous run
#   2. Delete stale training_trace.csv (never trust append-mode leftovers)
#   3. Rebuild the baseline image so it reflects current source, not a stale cache
#   4. Start the characterization container (profiler ON) and wait until healthy
#   5. Run k6 against it
#   6. Explicitly stop the container (SIGTERM) so persistent/System-heap
#      objects still referenced at shutdown get flushed as right-censored
#      records rather than being silently lost when the container is torn down
#   7. Print an immediate sanity summary (row count, per-call-site
#      breakdown, censoring rate) so problems are visible immediately
#      rather than discovered several steps later
#
# Usage (from anywhere — paths are resolved relative to this script):
#   ./run_characterization.sh
#
# Override any parameter via environment variable, e.g.:
#   MAX_RPS=80 SIMULATION_MINUTES=30 ./run_characterization.sh

set -euo pipefail

# ---------------------------------------------------------------------
# Path resolution — anchor everything to the repo root regardless of
# where this script is invoked from, since it lives under server/ but
# needs to reach docker/, load-generator/, and datasets/.
# ---------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

COMPOSE_FILE="$REPO_ROOT/docker/baseline-environment/docker-compose.yml"
TRACE_FILE="$REPO_ROOT/datasets/shadow-telemetry/raw/training_trace.csv"
K6_SCENARIO_DIR="$REPO_ROOT/load-generator/k6-scenarios"
K6_SCENARIO_FILE="samm-load-test.js"

BASE_URL="${BASE_URL:-http://localhost:3000}"
HEALTH_URL="$BASE_URL/health"

# k6 traffic parameters — override via env var. Defaults reflect the
# values validated through pilot testing (0% http_req_failed, low
# dropped_iterations) documented in the methodology.
MIN_RPS="${MIN_RPS:-5}"
MAX_RPS="${MAX_RPS:-50}"
SIMULATION_MINUTES="${SIMULATION_MINUTES:-20}"
PRE_ALLOCATED_VUS="${PRE_ALLOCATED_VUS:-50}"
MAX_VUS="${MAX_VUS:-200}"

# Data paths fed to the k6 scenario's __ENV overrides.
MARKOV_MATRIX_PATH="${MARKOV_MATRIX_PATH:-../../datasets/azure-trace-2019/processed/traffic-models/markov_transition_matrix.csv}"
TRAFFIC_SERIES_PATH="${TRAFFIC_SERIES_PATH:-../../datasets/azure-trace-2019/processed/traffic-models/traffic_state_series.csv}"
JITTER_PARAMS_PATH="${JITTER_PARAMS_PATH:-../../datasets/azure-trace-2019/processed/traffic-models/jitter_parameters.json}"
PAYLOAD_CSV_PATH="${PAYLOAD_CSV_PATH:-../../datasets/azure-trace-2019/processed/memory-models/memory_payload_allocations.csv}"

HEALTH_CHECK_TIMEOUT_S="${HEALTH_CHECK_TIMEOUT_S:-30}"
POST_K6_SETTLE_S="${POST_K6_SETTLE_S:-5}"  # brief pause before shutdown, lets any final GC cycle land

# Python interpreter used for the final summary. Explicit override via
# PYTHON_BIN takes priority; otherwise, prefer a venv at the repo root
# if one exists (common layout: `python3 -m venv venv` at REPO_ROOT),
# and only fall back to whatever `python3` resolves to on PATH as a
# last resort. This avoids silently using a system Python that lacks
# pandas just because the invoking shell didn't have a venv active.
if [ -n "${PYTHON_BIN:-}" ]; then
    : # explicit override wins, use as-is
elif [ -x "$REPO_ROOT/venv/bin/python3" ]; then
    PYTHON_BIN="$REPO_ROOT/venv/bin/python3"
else
    PYTHON_BIN="python3"
fi

log() { echo "[run_characterization] $*"; }

# Fail fast with a clear, actionable message rather than letting step 7
# fail deep into a 20+ minute run with a cryptic traceback.
if ! "$PYTHON_BIN" -c "import pandas" > /dev/null 2>&1; then
    log "ERROR: '$PYTHON_BIN' cannot import pandas."
    log "Fix by either:"
    log "  - activating your venv before running this script, or"
    log "  - passing an explicit interpreter: PYTHON_BIN=/path/to/venv/bin/python3 $0"
    exit 1
fi

# ---------------------------------------------------------------------
# Cleanup trap — guarantees the container is torn down even if this
# script is interrupted (Ctrl+C) or fails partway through, so a failed
# run never leaves a container silently running in the background.
# ---------------------------------------------------------------------
CONTAINER_STARTED=0
cleanup() {
    if [ "$CONTAINER_STARTED" -eq 1 ]; then
        log "Cleanup: stopping characterization container..."
        docker compose -f "$COMPOSE_FILE" down || true
    fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------
# 1. Tear down any leftover container from a previous run
# ---------------------------------------------------------------------
log "Step 1/7: Tearing down any existing characterization container..."
docker compose -f "$COMPOSE_FILE" down || true

# ---------------------------------------------------------------------
# 2. Delete stale training_trace.csv
#
# The profiler writes in append mode — if this file survives from a
# prior manual test or an earlier interrupted run, new data silently
# mixes with old data with no warning. Always start from a clean file.
# ---------------------------------------------------------------------
log "Step 2/7: Removing stale training_trace.csv (if present)..."
rm -f "$TRACE_FILE"

# ---------------------------------------------------------------------
# 3. Rebuild the image
#
# `docker compose up` alone does NOT rebuild if an image already
# exists under the same tag — an easy way to silently run stale code
# after editing a route file. Building explicitly every run closes
# that gap. Docker's own layer caching still applies (this is fast
# when only a COPY'd source file changed), so this is not a full
# --no-cache rebuild by default.
# ---------------------------------------------------------------------
log "Step 3/7: Building the characterization image..."
docker compose -f "$COMPOSE_FILE" build characterization

# ---------------------------------------------------------------------
# 4. Start the container and wait until it reports healthy
# ---------------------------------------------------------------------
log "Step 4/7: Starting characterization container..."
docker compose -f "$COMPOSE_FILE" up -d characterization
CONTAINER_STARTED=1

log "Waiting for the server to become healthy (timeout: ${HEALTH_CHECK_TIMEOUT_S}s)..."
elapsed=0
until curl -sf "$HEALTH_URL" > /dev/null 2>&1; do
    sleep 1
    elapsed=$((elapsed + 1))
    if [ "$elapsed" -ge "$HEALTH_CHECK_TIMEOUT_S" ]; then
        log "ERROR: server did not become healthy within ${HEALTH_CHECK_TIMEOUT_S}s."
        log "Check container logs: docker compose -f $COMPOSE_FILE logs characterization"
        exit 1
    fi
done
log "Server is healthy after ${elapsed}s."

# ---------------------------------------------------------------------
# 5. Run k6
# ---------------------------------------------------------------------
log "Step 5/7: Running k6 (${SIMULATION_MINUTES} minutes, MAX_RPS=${MAX_RPS})..."
(
    cd "$K6_SCENARIO_DIR"
    k6 run \
        -e BASE_URL="$BASE_URL" \
        -e MARKOV_MATRIX_PATH="$MARKOV_MATRIX_PATH" \
        -e TRAFFIC_SERIES_PATH="$TRAFFIC_SERIES_PATH" \
        -e JITTER_PARAMS_PATH="$JITTER_PARAMS_PATH" \
        -e PAYLOAD_CSV_PATH="$PAYLOAD_CSV_PATH" \
        -e MIN_RPS="$MIN_RPS" \
        -e MAX_RPS="$MAX_RPS" \
        -e SIMULATION_MINUTES="$SIMULATION_MINUTES" \
        -e PRE_ALLOCATED_VUS="$PRE_ALLOCATED_VUS" \
        -e MAX_VUS="$MAX_VUS" \
        "$K6_SCENARIO_FILE"
)
log "k6 run complete."

# ---------------------------------------------------------------------
# 6. Explicit graceful shutdown
#
# This is what makes right-censoring correct: SIGTERM lets the
# profiler's stop() walk every still-occupied slot (e.g. objects still
# sitting in aggregate.js's persistentStore) and flush them as
# right-censored records before the process exits. Killing the
# container abruptly (docker kill, or just letting `down` time out)
# skips this and silently loses that data.
# ---------------------------------------------------------------------
log "Step 6/7: Settling ${POST_K6_SETTLE_S}s before shutdown..."
sleep "$POST_K6_SETTLE_S"

log "Sending graceful shutdown (docker compose down / SIGTERM)..."
docker compose -f "$COMPOSE_FILE" down
CONTAINER_STARTED=0  # already torn down cleanly, trap does not need to repeat this

# ---------------------------------------------------------------------
# 7. Immediate sanity summary
# ---------------------------------------------------------------------
log "Step 7/7: Summarizing training_trace.csv..."
if [ ! -f "$TRACE_FILE" ]; then
    log "ERROR: training_trace.csv was not produced. Check container logs from this run."
    exit 1
fi

"$PYTHON_BIN" - "$TRACE_FILE" << 'PYEOF'
import sys
import pandas as pd

path = sys.argv[1]
df = pd.read_csv(path)

total = len(df)
censored = df['finalization_time_ms'].isnull().sum()
censored_pct = (censored / total * 100) if total > 0 else 0.0

print(f"\n=== training_trace.csv summary ===")
print(f"Total records     : {total:,}")
print(f"Right-censored     : {censored:,} ({censored_pct:.4f}%)")
print(f"\nRecords per call-site hash:")
print(df['call_site_hash'].value_counts().to_string())
print("===================================\n")
PYEOF

log "Done. training_trace.csv is at: $TRACE_FILE"