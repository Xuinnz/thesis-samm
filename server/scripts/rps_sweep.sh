#!/usr/bin/env bash
#
# rps_sweep.sh
#
# Runs a SHORT pilot at each candidate MAX_RPS and records, per point, the
# exact same metrics the real benchmark records — because it calls the same
# run_condition() from _bench-lib.sh. Calibrating with different instrumentation
# than you measure with is how you pick an operating point that turns out not to
# hold when the real run starts.
#
# What changed from the original version, and why:
#   - It used to run the `characterization` compose service, which has
#     SHADOW_PROFILER_ENABLED=true. The profiler adds N-API tracking and a
#     finalizer queue to EVERY allocation, so its CPU cost is nothing like the
#     benchmark's. An operating point calibrated with the profiler on does not
#     transfer to a profiler-off benchmark. Condition is now selectable and
#     defaults to the benchmark condition (profiler OFF).
#   - Peak RSS came from `docker stats` sampled every 2s, which can miss a
#     transient spike entirely. It now comes from the kernel's own
#     memory.peak, which cannot.
#   - CPU saturation was inferred from sampled CPU%. It now also reads
#     cpu.stat's CFS throttling counters, which state definitively whether the
#     container wanted more CPU than its quota allowed.
#
# Output: one JSON per candidate in datasets/rps-sweep-results/, then run
#   python3 server/analyze_rps_sweep.py datasets/rps-sweep-results
#
# Usage:
#   ./rps_sweep.sh
#   RPS_CANDIDATES="10,20,30,40,60,80" SWEEP_MINUTES=2 ./rps_sweep.sh
#   SWEEP_CONDITION=samm ./rps_sweep.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

OUTPUT_ROOT="${OUTPUT_ROOT:-$REPO_ROOT/datasets/rps-sweep-results}"

# Which server to calibrate against. The operating point should be chosen for
# the condition you intend to measure.
SWEEP_CONDITION="${SWEEP_CONDITION:-baseline}"

# Candidate MAX_RPS values. MIN_RPS stays fixed low: it represents genuine
# Idle-level traffic per the Markov chain's own intensity mapping, and should
# not be swept alongside MAX_RPS.
RPS_CANDIDATES_RAW="${RPS_CANDIDATES:-10,20,30,40,60,80}"

# Exported so run_condition picks them up. Short pilots — this is calibration,
# not final data collection.
export SIMULATION_MINUTES="${SWEEP_MINUTES:-2}"
export MIN_RPS="${MIN_RPS_FIXED:-10}"
export PRE_ALLOCATED_VUS="${PRE_ALLOCATED_VUS:-50}"
export MAX_VUS="${MAX_VUS:-300}"
export MEM_LIMIT="${MEM_LIMIT:-1024m}"
export MEMSWAP_LIMIT="${MEMSWAP_LIMIT:-1024m}"
export CPUS="${CPUS:-1.0}"
# Fixed seed so every candidate walks the same traffic shape and the only
# variable between points is the RPS ceiling.
export SCHEDULE_SEED="${SCHEDULE_SEED:-20250911}"
export SHADOW_PROFILER_ENABLED="${SHADOW_PROFILER_ENABLED:-false}"
export RESULTS_DIR="$OUTPUT_ROOT"

# shellcheck source=./_bench-lib.sh
source "$SCRIPT_DIR/_bench-lib.sh"

case "$SWEEP_CONDITION" in
    baseline)
        DOCKERFILE="docker/baseline-environment/Dockerfile"
        IMAGE="samm-baseline:bench"
        EXTRA_ENV=()
        ;;
    samm)
        DOCKERFILE="docker/samm-environment/Dockerfile"
        IMAGE="samm-enabled:bench"
        EXTRA_ENV=(-e SAMM_ALLOCATOR_ENABLED=true
                   -e SAMM_RECLAIM_POLICY="${SAMM_RECLAIM_POLICY:-none}"
                   -e SAMM_WARMUP="${SAMM_WARMUP:-false}")
        ;;
    *)
        echo "ERROR: SWEEP_CONDITION must be 'baseline' or 'samm', got '$SWEEP_CONDITION'"
        exit 1
        ;;
esac

mkdir -p "$OUTPUT_ROOT"

IFS=',' read -ra RPS_LIST <<< "$RPS_CANDIDATES_RAW"

echo "======================================================================"
echo " RPS sweep — condition: $SWEEP_CONDITION (profiler OFF)"
echo " Candidates : ${RPS_CANDIDATES_RAW}"
echo " Per point  : ${SIMULATION_MINUTES}m, MIN_RPS=${MIN_RPS}, VUs ${PRE_ALLOCATED_VUS}-${MAX_VUS}"
echo " Container  : ${MEM_LIMIT} RAM, swap disabled, ${CPUS} vCPU"
echo " Output     : ${OUTPUT_ROOT}"
echo "======================================================================"
echo

for RPS in "${RPS_LIST[@]}"; do
    RPS=$(echo "$RPS" | xargs)
    [ -z "$RPS" ] && continue

    echo ">>> Sweep point: MAX_RPS=${RPS}"
    export MAX_RPS="$RPS"

    run_condition \
        "rps_${RPS}" \
        "$DOCKERFILE" \
        "$IMAGE" \
        "samm-sweep-${SWEEP_CONDITION}" \
        "${EXTRA_ENV[@]}"

    echo
done

echo "Sweep complete. Analyze with:"
echo "  python3 $SCRIPT_DIR/analyze_rps_sweep.py $OUTPUT_ROOT"
