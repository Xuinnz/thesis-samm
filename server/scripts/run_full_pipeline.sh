#!/usr/bin/env bash
#
# run_full_pipeline.sh — retrain SAMM and benchmark it, end to end, in one go.
#
#   1. Characterization pass  (profiler ON)  -> training_trace.csv
#   2. Preprocessing phase 2                 -> cleaned per-call-site features
#   3. ML refinery                           -> policies, quotas, model_weights.zig
#   4. Allocator test suite                  -> guard: does the new table even build
#   5. Comparison, n=1                       -> baseline vs SAMM
#
# WHY THE TRAFFIC CONFIG IS SHARED
# --------------------------------
# Characterization and benchmark run at the SAME MAX_RPS and VU pool. The ML
# refinery sizes every arena from the peak concurrent demand it observed, so
# training at 50 RPS and benchmarking at 500 would under-provision every
# stratum by roughly an order of magnitude and the run would be dominated by
# capacity fallbacks. The load the model is trained on has to be the load it is
# asked to serve.
#
# WHY THE SEEDS DIFFER
# --------------------
# Same traffic PARAMETERS, different Markov walk. Training and testing on the
# identical schedule would let the quotas fit that one traffic sequence exactly
# — the arenas would be tuned to the very bursts they are later scored on.
# Different seeds keep the benchmark a test of generalization rather than of
# recall. Both are pinned, so the whole pipeline is reproducible.
#
# Usage:
#   ./run_full_pipeline.sh
#   CHARACTERIZATION_MINUTES=5 BENCHMARK_MINUTES=5 ./run_full_pipeline.sh
#   SKIP_CHARACTERIZATION=1 ./run_full_pipeline.sh    # reuse the existing trace

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# =====================================================================
# SHARED CONFIGURATION — one definition, used by every stage below
# =====================================================================
export MIN_RPS="${MIN_RPS:-5}"
export MAX_RPS="${MAX_RPS:-500}"
export PRE_ALLOCATED_VUS="${PRE_ALLOCATED_VUS:-250}"
export MAX_VUS="${MAX_VUS:-600}"

CHARACTERIZATION_MINUTES="${CHARACTERIZATION_MINUTES:-10}"
BENCHMARK_MINUTES="${BENCHMARK_MINUTES:-10}"

CHARACTERIZATION_SEED="${CHARACTERIZATION_SEED:-19870601}"
BENCHMARK_SEED="${BENCHMARK_SEED:-20250911}"

# batch.js issues ~200 allocations per request, so concurrent tracked objects
# run into the thousands at this RPS. Undersized capacity drops records
# silently (one stderr warning, then nothing), which would quietly bias the
# training data toward whatever survived.
export SHADOW_PROFILER_CAPACITY="${SHADOW_PROFILER_CAPACITY:-100000}"

# Container environment for the benchmark stage: 1GB, swap off, 1 vCPU.
export MEM_LIMIT="${MEM_LIMIT:-1024m}"
export MEMSWAP_LIMIT="${MEMSWAP_LIMIT:-1024m}"
export CPUS="${CPUS:-1.0}"

export SAMM_RECLAIM_POLICY="${SAMM_RECLAIM_POLICY:-none}"
export SAMM_WARMUP="${SAMM_WARMUP:-false}"

TRACE_FILE="$REPO_ROOT/datasets/shadow-telemetry/raw/training_trace.csv"

if [ -n "${PYTHON_BIN:-}" ]; then
    :
elif [ -x "$REPO_ROOT/venv/bin/python3" ]; then
    export PYTHON_BIN="$REPO_ROOT/venv/bin/python3"
else
    export PYTHON_BIN="python3"
fi

STARTED_AT=$(date +%s)
step_banner() {
    echo
    echo "######################################################################"
    echo "# $1"
    echo "######################################################################"
    echo
}
elapsed() { echo "elapsed: $(( ($(date +%s) - STARTED_AT) / 60 ))m"; }

echo "======================================================================"
echo " SAMM full pipeline — retrain and benchmark"
echo "======================================================================"
echo " Traffic (both stages) : MAX_RPS=${MAX_RPS}, MIN_RPS=${MIN_RPS}, VUs ${PRE_ALLOCATED_VUS}-${MAX_VUS}"
echo " Characterization      : ${CHARACTERIZATION_MINUTES}m, seed ${CHARACTERIZATION_SEED}, profiler ON"
echo " Benchmark             : ${BENCHMARK_MINUTES}m per condition, seed ${BENCHMARK_SEED}, profiler OFF"
echo " Container             : ${MEM_LIMIT} RAM, swap off, ${CPUS} vCPU"
echo " Profiler capacity     : ${SHADOW_PROFILER_CAPACITY} concurrent objects"
echo "======================================================================"

# =====================================================================
# 1. Characterization
# =====================================================================
if [ "${SKIP_CHARACTERIZATION:-0}" = "1" ]; then
    step_banner "STEP 1/5: Characterization — SKIPPED (reusing existing trace)"
    [ -f "$TRACE_FILE" ] || { echo "ERROR: no trace at $TRACE_FILE to reuse."; exit 1; }
else
    step_banner "STEP 1/5: Characterization (${CHARACTERIZATION_MINUTES}m, profiler ON)"
    SIMULATION_MINUTES="$CHARACTERIZATION_MINUTES" \
    SCHEDULE_SEED="$CHARACTERIZATION_SEED" \
        "$SCRIPT_DIR/run_characterization.sh"
fi
elapsed

# =====================================================================
# 2. Preprocessing phase 2
# =====================================================================
step_banner "STEP 2/5: Preprocessing phase 2 (telemetry -> call-site features)"
bash "$REPO_ROOT/preprocessing/phase2-ml-telemetry/run_phase2.sh"
elapsed

# =====================================================================
# 3. ML refinery (clustering -> policy -> quotas -> table compiler)
# =====================================================================
step_banner "STEP 3/5: ML refinery (also regenerates model_weights.zig)"
bash "$REPO_ROOT/ml-refinery/run_ml_refinery.sh"
elapsed

# =====================================================================
# 4. Allocator guard
#
# The table compiler fails loudly if the new quotas do not fit the pool, and
# the Zig comptime assertions fail if the emitted layout is inconsistent. Run
# them BEFORE spending ~25 minutes on a benchmark that would only then discover
# the table is unusable.
# =====================================================================
step_banner "STEP 4/5: Allocator test suite against the regenerated table"
(cd "$REPO_ROOT/zig-allocator" && zig build test --summary all)
elapsed

# =====================================================================
# 5. Comparison, n=1
# =====================================================================
if [ "${SKIP_BENCHMARK:-0}" = "1" ]; then
    step_banner "STEP 5/5: Benchmark comparison — SKIPPED (SKIP_BENCHMARK=1)"
    echo "The model is retrained and the routing table regenerated. Run a"
    echo "comparison separately, e.g. server/scripts/run_allocator_attribution.sh"
else
    step_banner "STEP 5/5: Benchmark comparison (n=1 per condition, ${BENCHMARK_MINUTES}m each)"
    SIMULATION_MINUTES="$BENCHMARK_MINUTES" \
    SCHEDULE_SEED="$BENCHMARK_SEED" \
        "$SCRIPT_DIR/run_comparison.sh"
fi

echo
echo "======================================================================"
echo " Pipeline complete. Total $(( ($(date +%s) - STARTED_AT) / 60 ))m"
echo "======================================================================"
