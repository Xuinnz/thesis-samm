#!/usr/bin/env bash
#
# run_characterization_jsd.sh
#
# Same overall flow as run_characterization.sh, but termination is
# driven by the Convergence-Based Termination Criterion (Jensen-Shannon
# Divergence between successive lifespan-distribution windows) instead
# of a fixed wall-clock duration:
#
#   1-4. Identical to run_characterization.sh (teardown, clean trace,
#        rebuild, start container, health check)
#   5.   Start k6 in the BACKGROUND with a generous wall-clock backstop
#        duration — NOT the intended stop condition, just a safety net
#        in case the JSD monitor itself hangs or crashes
#   6.   Run jsd_convergence_monitor.py in the FOREGROUND. This is the
#        actual stop condition: it tails training_trace.csv, computes
#        D_JS between successive 100,000-row windows, and calls
#        `docker compose down` itself the moment convergence is reached
#        or the 10-cycle hard ceiling is hit.
#   7.   Once the monitor returns, explicitly kill the backgrounded k6
#        process — it has no reason to keep running once the container
#        it's targeting is already down, and any of its remaining
#        requests would just be harmless connection-error noise.
#   8.   Same summary step as run_characterization.sh.
#
# No second terminal is used or needed — k6 runs as a background job
# within this single script via `&`, tracked by PID.
#
# Usage:
#   ./run_characterization_jsd.sh
#
# Override any parameter via environment variable, e.g.:
#   MAX_RPS=80 WINDOW_SIZE=150000 ./run_characterization_jsd.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

COMPOSE_FILE="$REPO_ROOT/docker/baseline-environment/docker-compose.yml"
TRACE_FILE="$REPO_ROOT/datasets/shadow-telemetry/raw/training_trace.csv"
K6_SCENARIO_DIR="$REPO_ROOT/load-generator/k6-scenarios"
K6_SCENARIO_FILE="samm-load-test.js"
JSD_MONITOR_SCRIPT="$SCRIPT_DIR/jsd_convergence_monitor.py"

BASE_URL="${BASE_URL:-http://localhost:3000}"
HEALTH_URL="$BASE_URL/health"

MIN_RPS="${MIN_RPS:-5}"
MAX_RPS="${MAX_RPS:-50}"
PRE_ALLOCATED_VUS="${PRE_ALLOCATED_VUS:-50}"
MAX_VUS="${MAX_VUS:-200}"

# k6's own duration here is a BACKSTOP, not the intended stop
# condition — the JSD monitor is expected to trigger shutdown well
# before this elapses under normal operation. Generous by design.
BACKSTOP_MINUTES="${BACKSTOP_MINUTES:-60}"

MARKOV_MATRIX_PATH="${MARKOV_MATRIX_PATH:-../../datasets/azure-trace-2019/processed/traffic-models/markov_transition_matrix.csv}"
TRAFFIC_SERIES_PATH="${TRAFFIC_SERIES_PATH:-../../datasets/azure-trace-2019/processed/traffic-models/traffic_state_series.csv}"
JITTER_PARAMS_PATH="${JITTER_PARAMS_PATH:-../../datasets/azure-trace-2019/processed/traffic-models/jitter_parameters.json}"
PAYLOAD_CSV_PATH="${PAYLOAD_CSV_PATH:-../../datasets/azure-trace-2019/processed/memory-models/memory_payload_allocations.csv}"

HEALTH_CHECK_TIMEOUT_S="${HEALTH_CHECK_TIMEOUT_S:-30}"

# JSD monitor tunables — see jsd_convergence_monitor.py for the full
# derivation of these defaults.
WINDOW_SIZE="${WINDOW_SIZE:-100000}"
EPSILON_JSD="${EPSILON_JSD:-0.01}"
MAX_CYCLES="${MAX_CYCLES:-10}"
POLL_INTERVAL="${POLL_INTERVAL:-5}"

if [ -n "${PYTHON_BIN:-}" ]; then
    :
elif [ -x "$REPO_ROOT/venv/bin/python3" ]; then
    PYTHON_BIN="$REPO_ROOT/venv/bin/python3"
else
    PYTHON_BIN="python3"
fi

log() { echo "[run_characterization_jsd] $*"; }

if ! "$PYTHON_BIN" -c "import pandas, numpy" > /dev/null 2>&1; then
    log "ERROR: '$PYTHON_BIN' cannot import pandas and/or numpy."
    log "Fix by either activating your venv first, or:"
    log "  PYTHON_BIN=/path/to/venv/bin/python3 $0"
    exit 1
fi

# ---------------------------------------------------------------------
# Cleanup trap — covers both the container and the backgrounded k6
# process, so an interrupted or failed run never leaves either running
# silently.
# ---------------------------------------------------------------------
CONTAINER_STARTED=0
K6_PID=""
cleanup() {
    if [ -n "$K6_PID" ] && kill -0 "$K6_PID" 2>/dev/null; then
        log "Cleanup: stopping backgrounded k6 process (PID $K6_PID)..."
        kill "$K6_PID" 2>/dev/null || true
    fi
    if [ "$CONTAINER_STARTED" -eq 1 ]; then
        log "Cleanup: stopping characterization container..."
        docker compose -f "$COMPOSE_FILE" down || true
    fi
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------
# 1-4. Identical to run_characterization.sh
# ---------------------------------------------------------------------
log "Step 1/8: Tearing down any existing characterization container..."
docker compose -f "$COMPOSE_FILE" down || true

log "Step 2/8: Removing stale training_trace.csv (if present)..."
rm -f "$TRACE_FILE"

log "Step 3/8: Building the characterization image..."
docker compose -f "$COMPOSE_FILE" build characterization

log "Step 4/8: Starting characterization container..."
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
# 5. Start k6 in the BACKGROUND. Its duration is a wall-clock backstop
#    only — the JSD monitor is expected to stop things well before
#    this elapses. `timeout` guarantees k6 itself exits even if
#    something downstream never sends a signal.
# ---------------------------------------------------------------------
log "Step 5/8: Starting k6 in the background (backstop duration: ${BACKSTOP_MINUTES}m, MAX_RPS=${MAX_RPS})..."
(
    cd "$K6_SCENARIO_DIR"
    exec timeout "${BACKSTOP_MINUTES}m" k6 run \
        -e BASE_URL="$BASE_URL" \
        -e MARKOV_MATRIX_PATH="$MARKOV_MATRIX_PATH" \
        -e TRAFFIC_SERIES_PATH="$TRAFFIC_SERIES_PATH" \
        -e JITTER_PARAMS_PATH="$JITTER_PARAMS_PATH" \
        -e PAYLOAD_CSV_PATH="$PAYLOAD_CSV_PATH" \
        -e MIN_RPS="$MIN_RPS" \
        -e MAX_RPS="$MAX_RPS" \
        -e SIMULATION_MINUTES="$BACKSTOP_MINUTES" \
        -e PRE_ALLOCATED_VUS="$PRE_ALLOCATED_VUS" \
        -e MAX_VUS="$MAX_VUS" \
        "$K6_SCENARIO_FILE"
) &
K6_PID=$!
log "k6 running in background as PID $K6_PID."

# ---------------------------------------------------------------------
# 6. Run the JSD monitor in the FOREGROUND. This is the real stop
#    condition — it calls `docker compose down` itself internally the
#    moment it converges or hits the hard cycle ceiling, which is what
#    lets the profiler's stop() flush right-censored data cleanly.
# ---------------------------------------------------------------------
log "Step 6/8: Running JSD convergence monitor (WINDOW_SIZE=${WINDOW_SIZE}, epsilon=${EPSILON_JSD})..."
"$PYTHON_BIN" "$JSD_MONITOR_SCRIPT" \
    --trace-path "$TRACE_FILE" \
    --compose-file "$COMPOSE_FILE" \
    --window-size "$WINDOW_SIZE" \
    --epsilon "$EPSILON_JSD" \
    --max-cycles "$MAX_CYCLES" \
    --poll-interval "$POLL_INTERVAL"

# The monitor already called `docker compose down` on its way out.
CONTAINER_STARTED=0

# ---------------------------------------------------------------------
# 7. Explicitly stop k6 — no reason for it to keep running once the
#    container it targets is already down.
# ---------------------------------------------------------------------
log "Step 7/8: Stopping backgrounded k6 process..."
if kill -0 "$K6_PID" 2>/dev/null; then
    kill "$K6_PID" 2>/dev/null || true
    sleep 1
    if kill -0 "$K6_PID" 2>/dev/null; then
        log "k6 did not exit cleanly, forcing..."
        kill -9 "$K6_PID" 2>/dev/null || true
    fi
fi
wait "$K6_PID" 2>/dev/null || true
K6_PID=""
log "k6 stopped."

# ---------------------------------------------------------------------
# 8. Summary
# ---------------------------------------------------------------------
log "Step 8/8: Summarizing training_trace.csv..."
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