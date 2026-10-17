#!/usr/bin/env bash
#
# host-probe.sh -- is this host healthy enough to benchmark on?
#
# Four checks: the VM clock against Windows' clock, plus the three that caught the
# 2026-09-24 slowdown (the same ones and limits as zig-allocator/microbench/gated_run.sh):
#   0. VM monotonic clock vs Windows clock over 60 s (CLOCK_CHECK_SECONDS)    99-101 %
#      (it ran at 92.7 % on 2026-10-04 with clocksource tsc: every in-VM timing ~7 % short)
#   1. k6 startup to its first VU, on a closed port (no server)   <= 80 s
#      (healthy 60-77 s on the Ryzen 5 6600H, degraded 103-139 s)
#   2. V8 allocation microbench vs zig-allocator/microbench/results/   0.90-1.10x
#   3. GC time per collection, same comparison                         <= 1.10x
# The limits were calibrated on this laptop; another machine needs its own
# reference run before checks 2 and 3 mean anything.
#
# Usage: internal-validation/host-probe.sh <out-dir> [k6-only]
#   k6-only runs checks 0 and 1 (about two minutes), for re-checks between stages.
# Exit 0 = HOST CLEAN. The verdict is also written to <out-dir>/verdict.txt.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${1:?usage: host-probe.sh <out-dir> [k6-only]}"
MODE="${2:-full}"
mkdir -p "$OUT"
MB=$REPO/zig-allocator/microbench
JEMALLOC=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
TM=$REPO/datasets/azure-trace-2019/processed/traffic-models

# 0. Clock drift: the VM's monotonic clock against Windows' clock. On 2026-10-04
#    the VM clock (clocksource tsc) ran at 92.7 % of real time: every duration
#    measured inside WSL -- probe timings, k6 latencies, req/s, microbench ns --
#    read ~7 % short, while WSL stepped the wall clock forward ~2.6 s every 31 s.
#    One PowerShell process prints Windows' time at the start and end of the
#    interval; the VM's clock is read the moment each line arrives, so the
#    PowerShell startup delay cancels out. Limit: within +-1 % of real time.
CLOCK_SECONDS="${CLOCK_CHECK_SECONDS:-60}"
CLOCK_LINE=$(python3 - "$CLOCK_SECONDS" <<'PY'
import subprocess, sys, time
secs = int(sys.argv[1])
src = open('/sys/devices/system/clocksource/clocksource0/current_clocksource').read().strip()
cmd = ('[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); [Console]::Out.Flush(); '
       f'Start-Sleep -Seconds {secs}; [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()')
try:
    p = subprocess.Popen(['powershell.exe', '-NoProfile', '-Command', cmd], stdout=subprocess.PIPE, text=True)
    marks = []
    for line in p.stdout:
        line = line.strip()
        if line.isdigit():
            marks.append((time.monotonic(), int(line)))
    p.wait(timeout=30)
    (v0, w0), (v1, w1) = marks[0], marks[-1]
    rate = (v1 - v0) / ((w1 - w0) / 1000)
    ok = abs(rate - 1) <= 0.01
    print(f"0. VM clock vs Windows      {100 * rate:6.1f} % of real time   limit 99-101 %     {'PASS' if ok else 'FAIL'}   [clocksource {src}, {secs} s]")
except Exception as e:  # cannot verify the clock = not clean
    print(f"0. VM clock vs Windows      not measurable ({type(e).__name__}: {e})                  FAIL   [clocksource {src}]")
PY
)
echo "$CLOCK_LINE" > "$OUT/clock.txt"
CLOCK_OK=1; [[ "$CLOCK_LINE" == *PASS* ]] || CLOCK_OK=0

# 1. k6 startup: k6 builds 400 VUs from the realistic scenario's inputs, host-side.
( cd "$REPO/load-generator/k6-scenarios"
  BASE_URL=http://127.0.0.1:9 MARKOV_MATRIX_PATH=$TM/markov_transition_matrix.csv TRAFFIC_SERIES_PATH=$TM/traffic_state_series.csv \
  JITTER_PARAMS_PATH=$TM/jitter_parameters.json PAYLOAD_CSV_PATH=$REPO/datasets/azure-trace-2019/processed/memory-models/memory_payload_allocations.csv \
  MIN_RPS=5 MAX_RPS=1250 SIMULATION_MINUTES=3 PRE_ALLOCATED_VUS=400 MAX_VUS=1400 SCHEDULE_SEED=2025 HOLD_SCALE=1.6 PROCESS_HOLD_MS=240 \
  exec k6 run --address 127.0.0.1:6599 --quiet samm-load-test.js ) > "$OUT/k6.log" 2>&1 &
kpid=$!
s=$(awk '{print $1}' /proc/uptime)   # monotonic: the WSL wall clock steps
for _ in $(seq 1 480); do
  v=$(curl -s -m 1 http://127.0.0.1:6599/v1/metrics/vus 2>/dev/null | python3 -c "import json,sys;print(int(json.load(sys.stdin)['data']['attributes']['sample']['value']))" 2>/dev/null)
  [ -n "$v" ] && [ "$v" -gt 0 ] && break
  kill -0 $kpid 2>/dev/null || break
  sleep 0.5
done
e=$(awk '{print $1}' /proc/uptime)
kill -INT $kpid 2>/dev/null; sleep 1; kill -9 $kpid 2>/dev/null; wait $kpid 2>/dev/null
K6S=$(python3 -c "print(round($e-$s,1))")

if [ "$MODE" = "k6-only" ]; then
  { echo "$CLOCK_LINE"
    python3 -c "k=$K6S; print(f'1. k6 startup to first VU   {k:6.1f} s            limit <= 80 s      ' + ('PASS' if k<=80 else 'FAIL'))"
  } | tee "$OUT/verdict.txt"
  if [ $CLOCK_OK -eq 1 ] && python3 -c "import sys; sys.exit(0 if $K6S <= 80 else 1)"; then echo 'HOST CLEAN' | tee -a "$OUT/verdict.txt"; exit 0; fi
  echo 'HOST NOT CLEAN' | tee -a "$OUT/verdict.txt"; exit 1
fi

# 2-3. V8 microbench and GC timing, pinned to one core, against the 2026-09-19 reference.
bench() {
  local out="$1"; shift; local envs=()
  while [[ "$1" != "--" ]]; do envs+=(-e "$1"); shift; done; shift
  docker run --rm --cpuset-cpus=2 --memory=3g --memory-swap=3g -v "$MB":/bench -w /bench \
    -e SAMM_APP_ROOT=/app -e SAMM_RECLAIM_POLICY=none "${envs[@]}" --entrypoint sh samm-enabled:bench -c "$*" > "$out"
}
bench "$OUT/native.jsonl" LD_PRELOAD=$JEMALLOC -- \
  "./.out/engine_bench .out/traces/mix engine 3 0 1 && ./.out/engine_bench .out/traces/mix malloc 3 1 1"
bench "$OUT/v8.jsonl" LD_PRELOAD=$JEMALLOC SAMM_ALLOCATOR_ENABLED=false BENCH_MALLOC=jemalloc -- \
  "node --expose-gc js_bench.js .out/traces/mix v8 3 0 1 && node --expose-gc js_bench.js .out/traces/mix v8 3 1 1"

K6S=$K6S CLOCK_OK=$CLOCK_OK CLOCK_LINE="$CLOCK_LINE" python3 - "$MB/results" "$OUT" <<'PY' | tee "$OUT/verdict.txt"
import json, os, statistics as st, sys
ref_dir, p = sys.argv[1], sys.argv[2]
load = lambda f: [json.loads(l) for l in open(f) if l.strip().startswith('{')]
ref = load(f'{ref_dir}/engine-jemalloc.jsonl') + load(f'{ref_dir}/malloc-jemalloc.jsonl') + load(f'{ref_dir}/v8-jemalloc.jsonl')
now = load(f'{p}/native.jsonl') + load(f'{p}/v8.jsonl')
def cell(rows, layer, touch, f=lambda r: r['ns_per_alloc']):
    return st.median(f(r) for r in rows if r['layer'] == layer and r['trace'] == 'mix' and bool(r['touch']) == touch)
ok = os.environ['CLOCK_OK'] == '1'
print(os.environ['CLOCK_LINE'])
k6 = float(os.environ['K6S']); good = k6 <= 80; ok &= good
print(f"1. k6 startup to first VU   {k6:6.1f} s            limit <= 80 s      {'PASS' if good else 'FAIL'}")
for touch, name in ((False, 'no touch'), (True, 'page writes')):
    r = cell(now, 'v8', touch) / cell(ref, 'v8', touch); good = 0.90 <= r <= 1.10; ok &= good
    print(f"2. V8 microbench, {name:11} {r:4.2f}x of Sep 19   limit 0.90-1.10x   {'PASS' if good else 'FAIL'}")
per_gc = lambda r: r['gc_ms'] / r['gc_count']
r = cell(now, 'v8', False, per_gc) / cell(ref, 'v8', False, per_gc); good = r <= 1.10; ok &= good
print(f"3. GC time per collection   {cell(now, 'v8', False, per_gc):.2f} ms = {r:4.2f}x   limit <= 1.10x     {'PASS' if good else 'FAIL'}")
print('HOST CLEAN' if ok else 'HOST NOT CLEAN')
sys.exit(0 if ok else 1)
PY
exit "${PIPESTATUS[0]}"
