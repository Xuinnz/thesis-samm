#!/usr/bin/env bash
#
# _bench-lib.sh — shared benchmark driver for both conditions.
#
# Not meant to be run directly. run_baseline.sh and run_samm.sh each source
# this and call run_condition().
#
# The point of a shared library rather than two parallel scripts is that the
# container limits, the traffic parameters, the health gate, the k6 invocation
# and the metric capture are then LITERALLY the same code for both conditions.
# Two scripts maintained side by side drift, and a drifted resource limit or
# traffic seed would silently become an uncontrolled variable in the comparison.
#
# Every tunable is read from the environment with a default, so a condition
# script can run standalone, while run_comparison.sh exports one shared set for
# both.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

K6_SCENARIO_DIR="$REPO_ROOT/load-generator/k6-scenarios"
K6_SCENARIO_FILE="samm-load-test.js"
RESULTS_DIR="${RESULTS_DIR:-$REPO_ROOT/benchmark-results/comparison}"

# --- Container environment (identical across conditions) -------------------
MEM_LIMIT="${MEM_LIMIT:-1024m}"
# memory-swap equal to memory means zero swap headroom: a true swap-off
# guarantee, stronger than mem_swappiness alone.
MEMSWAP_LIMIT="${MEMSWAP_LIMIT:-1024m}"
CPUS="${CPUS:-1.0}"
HOST_PORT="${HOST_PORT:-3000}"

# --- k6 traffic parameters (identical across conditions) -------------------
# Defaults match server/run_characterization.sh, so the benchmark drives the
# same traffic shape the training telemetry was collected under.
MIN_RPS="${MIN_RPS:-5}"
MAX_RPS="${MAX_RPS:-50}"
SIMULATION_MINUTES="${SIMULATION_MINUTES:-5}"
PRE_ALLOCATED_VUS="${PRE_ALLOCATED_VUS:-50}"
MAX_VUS="${MAX_VUS:-200}"
# A fixed seed is what makes an n=1 comparison meaningful at all: both
# conditions then walk the IDENTICAL Markov traffic schedule rather than two
# independent random ones.
SCHEDULE_SEED="${SCHEDULE_SEED:-20250911}"

MARKOV_MATRIX_PATH="${MARKOV_MATRIX_PATH:-../../datasets/azure-trace-2019/processed/traffic-models/markov_transition_matrix.csv}"
TRAFFIC_SERIES_PATH="${TRAFFIC_SERIES_PATH:-../../datasets/azure-trace-2019/processed/traffic-models/traffic_state_series.csv}"
JITTER_PARAMS_PATH="${JITTER_PARAMS_PATH:-../../datasets/azure-trace-2019/processed/traffic-models/jitter_parameters.json}"
PAYLOAD_CSV_PATH="${PAYLOAD_CSV_PATH:-../../datasets/azure-trace-2019/processed/memory-models/memory_payload_allocations.csv}"

HEALTH_CHECK_TIMEOUT_S="${HEALTH_CHECK_TIMEOUT_S:-60}"
POST_K6_SETTLE_S="${POST_K6_SETTLE_S:-5}"

# The profiler must be OFF during benchmarking — the methodology requires it be
# active only during training data collection, to avoid observer-effect
# contamination of the very metrics being compared.
SHADOW_PROFILER_ENABLED="${SHADOW_PROFILER_ENABLED:-false}"

# GC-pause and heap-fragmentation telemetry. OFF by default because the GC
# observer runs a callback on every collection and therefore perturbs the run
# it measures; turn it on for a separate instrumented run rather than for the
# headline numbers.
SAMM_TELEMETRY="${SAMM_TELEMETRY:-false}"

log() { echo "[$BENCH_LABEL] $*"; }

# Host-side cgroup directory for the container under measurement, set by
# run_condition. Empty means the host path could not be resolved and reads fall
# back to `docker exec` (which costs the container ~950 faults per call).
CG_DIR=""

# cg_read <file> <container> [awk-key]
# Reads one cgroup file host-side when possible, else via docker exec. With a
# third argument, returns the value of that key from a "key value" style file.
cg_read() {
    local file="$1" container="$2" key="${3:-}" out=""
    if [ -n "$CG_DIR" ] && [ -r "$CG_DIR/$file" ]; then
        out=$(cat "$CG_DIR/$file" 2>/dev/null || echo "")
    else
        out=$(docker exec "$container" cat "/sys/fs/cgroup/$file" 2>/dev/null || echo "")
    fi
    if [ -n "$key" ]; then
        out=$(echo "$out" | awk -v k="$key" '$1 == k {print $2}')
    fi
    [ -z "$out" ] && out=0
    echo "$out"
}

# ---------------------------------------------------------------------
# run_condition <label> <dockerfile> <image-tag> <container-name> [extra docker env flags...]
# ---------------------------------------------------------------------
run_condition() {
    BENCH_LABEL="$1"; shift
    local dockerfile="$1"; shift
    local image="$1"; shift
    local container="$1"; shift
    local extra_env=("$@")

    mkdir -p "$RESULTS_DIR"
    local summary_json="$RESULTS_DIR/${BENCH_LABEL}-k6.json"
    local result_json="$RESULTS_DIR/${BENCH_LABEL}.json"
    local alloc_json="$RESULTS_DIR/${BENCH_LABEL}-allocator.json"
    local telemetry_json="$RESULTS_DIR/${BENCH_LABEL}-telemetry.json"
    rm -f "$summary_json" "$result_json" "$alloc_json" "$telemetry_json"

    # Teardown trap so an interrupted run never leaves a container holding the
    # port (which would silently make the NEXT condition measure the wrong one).
    cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; }
    trap cleanup EXIT INT TERM

    log "Removing any leftover container..."
    docker rm -f "$container" >/dev/null 2>&1 || true

    # Build every run: `docker run` does not rebuild on its own, and silently
    # benchmarking stale code after editing a route file is an easy mistake.
    log "Building image ($dockerfile)..."
    docker build -q -f "$REPO_ROOT/$dockerfile" -t "$image" "$REPO_ROOT" >/dev/null

    log "Starting container (mem=$MEM_LIMIT swap=$MEMSWAP_LIMIT cpus=$CPUS)..."
    docker run -d \
        --name "$container" \
        --memory="$MEM_LIMIT" \
        --memory-swap="$MEMSWAP_LIMIT" \
        --memory-swappiness=0 \
        --cpus="$CPUS" \
        -p "${HOST_PORT}:3000" \
        -e SHADOW_PROFILER_ENABLED="$SHADOW_PROFILER_ENABLED" \
        -e SAMM_TELEMETRY="$SAMM_TELEMETRY" \
        -e SAMM_MAX_TOUCH_BYTES="${SAMM_MAX_TOUCH_BYTES:-}" \
        -e SAMM_TOUCH_FRACTION="${SAMM_TOUCH_FRACTION:-}" \
        -e SAMM_RETAINED_BYTES="${SAMM_RETAINED_BYTES:-}" \
        -e PROCESS_MAX_BYTES="${PROCESS_MAX_BYTES:-}" \
        -e HOLD_SCALE="${HOLD_SCALE:-1}" \
        -e PROCESS_HOLD_MS="${PROCESS_HOLD_MS:-}" \
        -e ENDPOINT_WEIGHTS="${ENDPOINT_WEIGHTS:-}" \
        -e FETCH_BYTES="${FETCH_BYTES:-}" \
        "${extra_env[@]}" \
        "$image" >/dev/null

    log "Waiting for health (timeout ${HEALTH_CHECK_TIMEOUT_S}s)..."
    local elapsed=0
    until curl -sf "http://localhost:${HOST_PORT}/health" >/dev/null 2>&1; do
        sleep 1
        elapsed=$((elapsed + 1))
        if [ "$elapsed" -ge "$HEALTH_CHECK_TIMEOUT_S" ]; then
            log "ERROR: server did not become healthy in ${HEALTH_CHECK_TIMEOUT_S}s"
            docker logs "$container" 2>&1 | tail -30
            exit 1
        fi
    done
    log "Healthy after ${elapsed}s."

    # Resolve the container's cgroup on the HOST filesystem so every counter can
    # be read without entering the container.
    #
    # WHY THIS MATTERS BEYOND TIDINESS
    #
    # `docker exec` spawns a process INSIDE the measured cgroup, and that
    # process's own page faults are counted in pgfault. Measured: 4,791 faults
    # for the five execs the harness used to do inside the window. That is a
    # constant, so it inflated whichever condition faulted least -- SAMM -- by
    # the largest relative amount. Reading host-side costs the container nothing.
    #
    # It also survives the container dying. Under a retained store large enough
    # to reach the ceiling, an OOM kill is an expected OUTCOME, not a harness
    # failure -- and once the container is gone every `docker exec` returns
    # nothing, which would silently turn the most interesting result into zeros.
    CG_DIR=""
    local cid
    cid=$(docker inspect -f '{{.Id}}' "$container" 2>/dev/null || echo "")
    if [ -n "$cid" ]; then
        for cand in \
            "/sys/fs/cgroup/system.slice/docker-${cid}.scope" \
            "/sys/fs/cgroup/docker/${cid}" \
            "/sys/fs/cgroup/${cid}"; do
            [ -r "$cand/memory.peak" ] && CG_DIR="$cand" && break
        done
    fi
    if [ -n "$CG_DIR" ]; then
        log "cgroup (host): $CG_DIR"
    else
        log "WARNING: host cgroup not found; falling back to docker exec reads."
        log "         Fault counts will include ~4,800 of the harness's own faults."
    fi

    # Reset the kernel's peak counter so startup cost (image load, warmup,
    # health probes) is not folded into the measured peak.
    if [ -n "$CG_DIR" ]; then
        echo 0 > "$CG_DIR/memory.peak" 2>/dev/null || true
    else
        docker exec "$container" sh -c 'echo 0 > /sys/fs/cgroup/memory.peak' 2>/dev/null || true
    fi
    local rss_before
    rss_before=$(cg_read memory.current "$container")
    log "RSS at start of measurement: $((rss_before / 1024 / 1024)) MB"

    # Poll peak/current/oom from the host while the run proceeds. Free, because
    # nothing enters the container. If the container is OOM-killed mid-run the
    # last sample is still on disk, so the peak that killed it is recoverable.
    local poll_file="$RESULTS_DIR/${BENCH_LABEL}-poll.tsv"
    : > "$poll_file"
    local poller_pid=""
    if [ -n "$CG_DIR" ]; then
        (
            while [ -r "$CG_DIR/memory.peak" ]; do
                printf '%s\t%s\t%s\t%s\n' \
                    "$(date +%s)" \
                    "$(cat "$CG_DIR/memory.peak" 2>/dev/null || echo 0)" \
                    "$(cat "$CG_DIR/memory.current" 2>/dev/null || echo 0)" \
                    "$(awk '/^oom_kill /{print $2}' "$CG_DIR/memory.events" 2>/dev/null || echo 0)" \
                    >> "$poll_file"
                sleep 5
            done
        ) &
        poller_pid=$!
    fi

    # CFS throttling counters, read before and after. nr_throttled rising is
    # the definitive statement that the container wanted more CPU than its
    # quota allowed -- far more reliable than inferring saturation from sampled
    # `docker stats` percentages, and it is what separates "this run measured
    # memory behaviour" from "this run measured queueing delay".
    # Page faults. The whole fault-cost argument -- that an allocator which
    # recycles resident pages pays less than one which returns them to the OS
    # and must re-fault -- is unfalsifiable without this counter.
    local flt_before
    flt_before=$(cg_read memory.stat "$container" pgfault)

    local cpu_before
    cpu_before=$(cg_read cpu.stat "$container")
    local usage_before throttled_before nr_throttled_before
    usage_before=$(echo "$cpu_before" | awk '/^usage_usec/{print $2}'); : "${usage_before:=0}"
    throttled_before=$(echo "$cpu_before" | awk '/^throttled_usec/{print $2}'); : "${throttled_before:=0}"
    nr_throttled_before=$(echo "$cpu_before" | awk '/^nr_throttled/{print $2}'); : "${nr_throttled_before:=0}"

    log "Running k6: ${SIMULATION_MINUTES}m, RPS ${MIN_RPS}-${MAX_RPS}, VUs ${PRE_ALLOCATED_VUS}-${MAX_VUS}, seed ${SCHEDULE_SEED}"
    local window_start
    window_start=$(date +%s)
    (
        cd "$K6_SCENARIO_DIR"
        k6 run \
            --summary-export="$summary_json" \
            --summary-trend-stats="avg,min,med,p(90),p(95),p(99),max" \
            -e BASE_URL="http://localhost:${HOST_PORT}" \
            -e MARKOV_MATRIX_PATH="$MARKOV_MATRIX_PATH" \
            -e TRAFFIC_SERIES_PATH="$TRAFFIC_SERIES_PATH" \
            -e JITTER_PARAMS_PATH="$JITTER_PARAMS_PATH" \
            -e PAYLOAD_CSV_PATH="$PAYLOAD_CSV_PATH" \
            -e MIN_RPS="$MIN_RPS" \
            -e MAX_RPS="$MAX_RPS" \
            -e SIMULATION_MINUTES="$SIMULATION_MINUTES" \
            -e PRE_ALLOCATED_VUS="$PRE_ALLOCATED_VUS" \
            -e MAX_VUS="$MAX_VUS" \
            -e SCHEDULE_SEED="$SCHEDULE_SEED" \
            -e HOLD_SCALE="${HOLD_SCALE:-1}" \
            -e PROCESS_HOLD_MS="${PROCESS_HOLD_MS:-}" \
            -e ENDPOINT_WEIGHTS="${ENDPOINT_WEIGHTS:-}" \
            "$K6_SCENARIO_FILE"
    ) 2>&1 | tail -40

    log "Settling ${POST_K6_SETTLE_S}s..."
    sleep "$POST_K6_SETTLE_S"

    # Capture metrics BEFORE teardown. memory.peak is the kernel's own
    # high-water mark for the container's cgroup, which is exactly Peak RSS —
    # no sampling, so no chance of missing a transient spike between polls.
    local window_secs=$(( $(date +%s) - window_start ))
    [ "$window_secs" -le 0 ] && window_secs=1

    # Stop the poller before the final reads so it cannot race them.
    if [ -n "$poller_pid" ]; then kill "$poller_pid" 2>/dev/null || true; wait "$poller_pid" 2>/dev/null || true; fi

    local peak_bytes mem_limit_bytes oom_kills
    peak_bytes=$(cg_read memory.peak "$container")
    mem_limit_bytes=$(cg_read memory.max "$container")
    oom_kills=$(cg_read memory.events "$container" oom_kill)

    # If the container died mid-run its cgroup is gone and the live reads are
    # zero. Recover the last polled sample rather than reporting a peak of 0 for
    # the one condition that actually hit the ceiling.
    if [ "${peak_bytes:-0}" -eq 0 ] && [ -s "$poll_file" ]; then
        local last
        last=$(tail -1 "$poll_file")
        peak_bytes=$(echo "$last" | cut -f2); : "${peak_bytes:=0}"
        oom_kills=$(echo "$last" | cut -f4); : "${oom_kills:=0}"
        log "Container gone at teardown; recovered peak from poller: $((peak_bytes / 1024 / 1024)) MB, oom_kill=$oom_kills"
    fi
    if [ "${mem_limit_bytes:-0}" -eq 0 ]; then
        mem_limit_bytes=$(( $(echo "$MEM_LIMIT" | tr -dc '0-9') * 1024 * 1024 ))
    fi

    local flt_after
    flt_after=$(cg_read memory.stat "$container" pgfault)
    local page_faults=$((flt_after - flt_before))
    [ "$page_faults" -lt 0 ] && page_faults=0

    local cpu_after
    cpu_after=$(cg_read cpu.stat "$container")
    local usage_after throttled_after nr_throttled_after
    usage_after=$(echo "$cpu_after" | awk '/^usage_usec/{print $2}'); : "${usage_after:=0}"
    throttled_after=$(echo "$cpu_after" | awk '/^throttled_usec/{print $2}'); : "${throttled_after:=0}"
    nr_throttled_after=$(echo "$cpu_after" | awk '/^nr_throttled/{print $2}'); : "${nr_throttled_after:=0}"

    local cpu_usage_usec=$((usage_after - usage_before))
    local cpu_throttled_usec=$((throttled_after - throttled_before))
    local cpu_nr_throttled=$((nr_throttled_after - nr_throttled_before))
    [ "$cpu_usage_usec" -lt 0 ] && cpu_usage_usec=0
    [ "$cpu_throttled_usec" -lt 0 ] && cpu_throttled_usec=0
    [ "$cpu_nr_throttled" -lt 0 ] && cpu_nr_throttled=0

    # Allocator telemetry, if this condition exposes it.
    curl -sf "http://localhost:${HOST_PORT}/samm/stats" -o "$alloc_json" 2>/dev/null || true
    # GC / heap telemetry, if it was enabled for this run. Both conditions
    # expose it, so the comparison is like for like.
    curl -sf "http://localhost:${HOST_PORT}/telemetry" -o "$telemetry_json" 2>/dev/null || true

    log "Graceful shutdown (SIGTERM)..."
    docker stop -t 20 "$container" >/dev/null 2>&1 || true
    docker logs "$container" 2>&1 | tail -12
    docker rm -f "$container" >/dev/null 2>&1 || true
    trap - EXIT INT TERM

    # Fold k6's metrics and the container metrics into one result file.
    "$PYTHON_BIN" - "$summary_json" "$result_json" "$BENCH_LABEL" "$peak_bytes" "$oom_kills" \
        "$mem_limit_bytes" "$cpu_usage_usec" "$cpu_throttled_usec" "$cpu_nr_throttled" \
        "$window_secs" "$MAX_RPS" "$CPUS" "$SIMULATION_MINUTES" "$page_faults" <<'PYEOF'
import json, os, sys
(summary_path, out_path, label, peak_bytes, oom_kills, mem_limit_bytes,
 cpu_usage_usec, cpu_throttled_usec, cpu_nr_throttled,
 window_secs, max_rps, cpus, sim_minutes_expected, page_faults) = sys.argv[1:15]

with open(summary_path) as f:
    s = json.load(f)
m = s.get("metrics", {})

def g(metric, key, default=0.0):
    return float(m.get(metric, {}).get(key, default) or 0.0)

# P99 is one of the study's three headline metrics, and k6's DEFAULT summary
# emits only p(90)/p(95). Without --summary-trend-stats it would silently
# report 0.00 here and look like a real measurement, so fail loudly instead.
if "p(99)" not in m.get("http_req_duration", {}):
    sys.exit("ERROR: k6 summary has no p(99) for http_req_duration. "
             "The --summary-trend-stats flag is missing or was ignored.")

# Share of the CPU quota actually consumed. cpu.max was set to `cpus` cores, so
# the budget is cpus * the measured wall window (timed in the shell rather than
# assumed from SIMULATION_MINUTES, which excludes the post-k6 settle).
wall_usec = float(window_secs) * 1e6
cpu_budget_usec = wall_usec * float(cpus)
cpu_utilisation = (int(cpu_usage_usec) / cpu_budget_usec * 100) if cpu_budget_usec else 0.0

limit = int(mem_limit_bytes)
mem_utilisation = (int(peak_bytes) / limit * 100) if limit > 0 else 0.0

# A host suspend (laptop lid, sleep) freezes the container mid-run. The clock
# keeps moving, k6's schedule is disrupted, and in-flight requests resume with
# absurd latencies -- but the run still "completes", so nothing else would catch
# it. Compare the measured wall window against what the traffic schedule asked
# for and flag a large overshoot rather than reporting the numbers as clean.
#
# The wall window is NOT just the stage duration. It also contains fixed
# harness overhead that k6 incurs regardless of how long the scenario runs:
# preallocating PRE_ALLOCATED_VUS VUs and loading the traffic model before t=0,
# k6's 30s default gracefulStop draining in-flight requests at the end (this
# workload's median hold_ms is ~466ms, so the drain is real), and the
# post-k6 settle. Measured here at ~65-70s.
#
# Comparing against the bare stage duration made that overhead a fixed tax, so
# the flag fired on EVERY short run: at 10 minutes 67s is 11% and passes, at 3
# minutes it is 37% and trips the 1.25 threshold. Nine identical false
# positives is worse than no guard at all, because the one real suspend then
# reads as more of the same. Budget the overhead explicitly instead. The real
# case still trips it comfortably -- the observed suspend was 979s against a
# 530s scenario, which is 1.58x even with the allowance.
K6_FIXED_OVERHEAD_S = float(os.environ.get("K6_FIXED_OVERHEAD_S", 90))
expected_secs = float(sim_minutes_expected) * 60 + K6_FIXED_OVERHEAD_S
overshoot = (float(window_secs) / expected_secs) if expected_secs > 0 else 1.0
timing_suspect = overshoot > 1.25

result = {
    "condition": label,
    "max_rps": float(max_rps),
    "wall_overshoot_ratio": round(overshoot, 3),
    "page_faults": int(page_faults),
    "page_faults_per_sec": round(int(page_faults) / float(window_secs), 1),
    # Faults per request is the cleanest cross-condition comparison: an
    # allocator that recycles resident pages should need far fewer than one
    # that hands them back and re-faults.
    "page_faults_per_request": 0.0,
    "timing_suspect": timing_suspect,
    "window_secs": int(window_secs),
    "peak_rss_bytes": int(peak_bytes),
    "peak_rss_mb": round(int(peak_bytes) / 1048576, 1),
    "mem_limit_mb": round(limit / 1048576, 1),
    "mem_utilisation_pct": round(mem_utilisation, 1),
    # >0 nr_throttled means the container hit its CPU ceiling: any memory
    # number from that run is entangled with queueing delay.
    "cpu_utilisation_pct": round(cpu_utilisation, 1),
    "cpu_throttled_periods": int(cpu_nr_throttled),
    "cpu_throttled_ms": round(int(cpu_throttled_usec) / 1000, 1),
    "oom_kills": int(oom_kills),
    "requests": int(g("http_reqs", "count")),
    "throughput_rps": round(g("http_reqs", "rate"), 2),
    "latency_avg_ms": round(g("http_req_duration", "avg"), 2),
    "latency_p95_ms": round(g("http_req_duration", "p(95)"), 2),
    "latency_p99_ms": round(g("http_req_duration", "p(99)"), 2),
    "latency_max_ms": round(g("http_req_duration", "max"), 2),
    "failed_rate": round(g("http_req_failed", "value"), 6),
    # Latency with the request's own deliberate hold_ms removed -- the part the
    # allocator can actually influence. Absent on older summaries.
    "processing_avg_ms": round(g("processing_time", "avg"), 2),
    "processing_p95_ms": round(g("processing_time", "p(95)"), 2),
    "processing_p99_ms": round(g("processing_time", "p(99)"), 2),
    "processing_max_ms": round(g("processing_time", "max"), 2),
    "dropped_iterations": int(g("dropped_iterations", "count")),
}
if result["requests"]:
    result["page_faults_per_request"] = round(int(page_faults) / result["requests"], 1)

with open(out_path, "w") as f:
    json.dump(result, f, indent=2)
print(json.dumps(result, indent=2))

if timing_suspect:
    print()
    print("!" * 70)
    print(f"WARNING: wall window was {overshoot:.2f}x the scheduled duration "
          f"({float(window_secs):.0f}s vs {expected_secs:.0f}s).")
    print("The host was probably suspended or heavily descheduled mid-run.")
    print("Latency and throughput from this condition are NOT trustworthy.")
    print("!" * 70)
PYEOF

    log "Results written to $result_json"
}

# Python interpreter: prefer an explicit override, then a repo venv, then PATH.
if [ -n "${PYTHON_BIN:-}" ]; then
    :
elif [ -x "$REPO_ROOT/venv/bin/python3" ]; then
    PYTHON_BIN="$REPO_ROOT/venv/bin/python3"
else
    PYTHON_BIN="python3"
fi
