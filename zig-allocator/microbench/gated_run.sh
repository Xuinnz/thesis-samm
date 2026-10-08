#!/usr/bin/env bash
#
# gated_run.sh -- re-run the microbenchmark only on a host that passes the
# health probe that caught the 2026-09-24 slowdown.
#
#   1. Checksums results/ (the 2026-09-19 run) so any change to it is caught.
#   2. Probe, three checks, limits fixed here before anything runs:
#        k6 startup to first VU       <= 80 s     (normal 60-77 s, degraded 103-139 s)
#        V8 microbench, mix, jemalloc 0.90-1.10x  of results/ (degraded 1.21-1.30x)
#        GC time per collection       <= 1.10x    of results/ (degraded 1.62 ms vs 1.22)
#      Any failure stops here; nothing is benchmarked.
#   3. Full run (all layers x all traces x touch/no-touch, 5 trials + 1 warmup),
#      then the aggregate touch-mode cell again with 30 trials.
#   4. k6 startup again, to show the host stayed healthy through the run.
#
# Every probe attempt is kept in its own host-probe-<time>/ directory, and
# run.sh refuses to write over existing results, so nothing earlier is lost.
#
# Usage: ./gated_run.sh [results-dir]      (default: results-<today>)
# Last line printed is always "DONE ...".

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
cd "$HERE"
NEW="$(realpath -m "${1:-results-$(date +%F)}")"
AGG="$NEW/aggregate-touch-30"
JEMALLOC=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
IMAGE="${IMAGE:-samm-enabled:bench}"
CPU="${CPU:-2}"

mkdir -p "$NEW"
sha256sum results/* > "$NEW/results-2026-09-19.sha256"
echo "$(date +%T) results/ (2026-09-19) checksummed: $(wc -l < "$NEW/results-2026-09-19.sha256") files"

k6_init() {   # $1 = log file. Seconds from k6 spawn to its first VU, on a closed port (no server).
  local TM="$REPO/datasets/azure-trace-2019/processed/traffic-models"
  ( cd "$REPO/load-generator/k6-scenarios"
    BASE_URL=http://127.0.0.1:9 MARKOV_MATRIX_PATH=$TM/markov_transition_matrix.csv \
    TRAFFIC_SERIES_PATH=$TM/traffic_state_series.csv JITTER_PARAMS_PATH=$TM/jitter_parameters.json \
    PAYLOAD_CSV_PATH=$REPO/datasets/azure-trace-2019/processed/memory-models/memory_payload_allocations.csv \
    MIN_RPS=5 MAX_RPS=1250 SIMULATION_MINUTES=3 PRE_ALLOCATED_VUS=400 MAX_VUS=1400 SCHEDULE_SEED=2025 \
    HOLD_SCALE=1.6 PROCESS_HOLD_MS=240 \
    exec k6 run --address 127.0.0.1:6599 --quiet samm-load-test.js ) > "$1" 2>&1 &
  local kpid=$! s e v
  s=$(awk '{print $1}' /proc/uptime)   # monotonic: the WSL wall clock steps
  for _ in $(seq 1 480); do
    v=$(curl -s -m 1 http://127.0.0.1:6599/v1/metrics/vus 2>/dev/null |
      python3 -c "import json,sys;print(int(json.load(sys.stdin)['data']['attributes']['sample']['value']))" 2>/dev/null)
    [ -n "$v" ] && [ "$v" -gt 0 ] && break
    kill -0 $kpid 2>/dev/null || break
    sleep 0.5
  done
  e=$(awk '{print $1}' /proc/uptime)
  kill -INT $kpid 2>/dev/null; sleep 1; kill -9 $kpid 2>/dev/null; wait $kpid 2>/dev/null
  python3 -c "print(round($e-$s,1))"
}

bench() {   # bench <out.jsonl> <env...> -- <command>: one pinned container, as run.sh does
  local out="$1"; shift; local envs=()
  while [[ "$1" != "--" ]]; do envs+=(-e "$1"); shift; done; shift
  docker run --rm --cpuset-cpus="$CPU" --memory=3g --memory-swap=3g -v "$HERE":/bench -w /bench \
    -e SAMM_APP_ROOT=/app -e SAMM_RECLAIM_POLICY=none "${envs[@]}" --entrypoint sh "$IMAGE" -c "$*" > "$out"
}

P="$NEW/host-probe-$(date +%H%M%S)"
mkdir -p "$P"
echo "$(date +%T) PROBE 1/3: k6 startup"
K6S=$(k6_init "$P/k6.log")
echo "$(date +%T) PROBE 2-3/3: V8 microbench + GC timing (native layers for reference)"
bench "$P/native.jsonl" LD_PRELOAD=$JEMALLOC -- \
  "./.out/engine_bench .out/traces/mix engine 3 0 1 && ./.out/engine_bench .out/traces/mix malloc 3 1 1"
bench "$P/v8.jsonl" LD_PRELOAD=$JEMALLOC SAMM_ALLOCATOR_ENABLED=false BENCH_MALLOC=jemalloc -- \
  "node --expose-gc js_bench.js .out/traces/mix v8 3 0 1 && node --expose-gc js_bench.js .out/traces/mix v8 3 1 1"

K6S=$K6S python3 - "$HERE/results" "$P" > "$P/verdict.txt" <<'PY'
import datetime, json, os, statistics as st, sys
ref_dir, p = sys.argv[1], sys.argv[2]
def load(f): return [json.loads(l) for l in open(f) if l.strip().startswith('{')]
ref = load(f'{ref_dir}/engine-jemalloc.jsonl') + load(f'{ref_dir}/malloc-jemalloc.jsonl') + load(f'{ref_dir}/v8-jemalloc.jsonl')
now = load(f'{p}/native.jsonl') + load(f'{p}/v8.jsonl')
def cell(rows, layer, touch, f=lambda r: r['ns_per_alloc']):
    return st.median(f(r) for r in rows if r['layer'] == layer and r['trace'] == 'mix' and bool(r['touch']) == touch)
ok = True
print(f'host probe, {datetime.datetime.now():%Y-%m-%d %H:%M:%S}')
k6 = float(os.environ['K6S']); good = k6 <= 80; ok &= good
print(f"1. k6 startup to first VU      {k6:6.1f} s              limit <= 80 s          {'PASS' if good else 'FAIL'}   (normal 60-77, degraded 103-139)")
for touch, name in ((False, 'no touch'), (True, 'page writes')):
    a, b = cell(ref, 'v8', touch), cell(now, 'v8', touch); r = b / a; good = 0.90 <= r <= 1.10; ok &= good
    print(f"2. V8 microbench, {name:11}   {b:7.0f} ns = {r:4.2f}x   limit 0.90-1.10x       {'PASS' if good else 'FAIL'}   (Sep 19 {a:.0f} ns; degraded 1.21-1.30x)")
per_gc = lambda r: r['gc_ms'] / r['gc_count']
a, b = cell(ref, 'v8', False, per_gc), cell(now, 'v8', False, per_gc); r = b / a; good = r <= 1.10; ok &= good
print(f"3. GC time per collection       {b:5.2f} ms = {r:4.2f}x   limit <= 1.10x          {'PASS' if good else 'FAIL'}   (Sep 19 {a:.2f} ms; degraded 1.62 ms)")
for layer, touch, name in (('engine', False, 'SAMM engine (native)'), ('malloc', True, 'jemalloc + page faults (native)')):
    print(f'   reference: {name:32} {cell(now, layer, touch) / cell(ref, layer, touch):4.2f}x of Sep 19')
print('HOST CLEAN' if ok else 'HOST NOT CLEAN')
sys.exit(0 if ok else 1)
PY
PROBE_RC=$?
cat "$P/verdict.txt"
if [ $PROBE_RC -ne 0 ]; then
  mv "$P" "$P-failed"
  echo "$(date +%T) probe failed: benchmark NOT run"
  echo "DONE rc_probe=$PROBE_RC"; exit 0
fi

echo "$(date +%T) MAIN RUN: all layers x all traces x touch/no-touch, 5 trials + 1 warmup -> $NEW"
RESULTS="$NEW" TRIALS=5 WARMUP=1 bash ./run.sh; RC_MAIN=$?
echo "$(date +%T) MAIN RUN done rc=$RC_MAIN"
echo "$(date +%T) AGGREGATE TOUCH: 30 trials + 1 warmup -> $AGG"
RESULTS="$AGG" TRACES=aggregate TOUCH_MODES=1 TRIALS=30 WARMUP=1 bash ./run.sh; RC_AGG=$?
echo "$(date +%T) AGGREGATE TOUCH done rc=$RC_AGG"

echo "$(date +%T) POST-CHECK: k6 startup"
K6E=$(k6_init "$NEW/k6-after.log")
echo "k6 startup to first VU after the run: $K6E s (limit <= 80 s)" | tee "$NEW/host_probe_after.txt"
if sha256sum --quiet -c "$NEW/results-2026-09-19.sha256"; then
  echo "results/ (2026-09-19): unchanged, checksums match"
else
  echo "results/ (2026-09-19): CHANGED"
fi
echo "DONE rc_probe=0 rc_main=$RC_MAIN rc_agg=$RC_AGG"
