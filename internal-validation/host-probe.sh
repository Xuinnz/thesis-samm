#!/usr/bin/env bash
#
# host-probe.sh -- is this host healthy enough to benchmark on?
#
# Four checks: the clock against an outside reference, plus the three that caught
# the 2026-09-24 slowdown (the same ones and limits as zig-allocator/microbench/gated_run.sh):
#   0. Monotonic clock vs an outside clock over 60 s (CLOCK_CHECK_SECONDS)   99-101 %
#      Under WSL the outside clock is Windows'; elsewhere (the cloud VM) an NTP
#      server, plus chrony's own state when chronyd is running.
#      (WSL ran at 92.7 % on 2026-10-04 with clocksource tsc: every in-VM timing ~7 % short)
#   1. k6 startup to its first VU, on a closed port (no server)   <= 80 s
#      (healthy 60-77 s on the Ryzen 5 6600H, degraded 103-139 s)
#   2. V8 allocation microbench vs the reference                   0.90-1.10x
#   3. GC time per collection, same comparison                     <= 1.10x
# The limits for 1-3 were calibrated on the laptop against its Sept 19 run
# (zig-allocator/microbench/results/). Another machine needs its own reference
# run before checks 1-3 mean anything: record one with `reference` mode, set
# K6_STARTUP_LIMIT_S from it, and write both down BEFORE any benchmark.
#
# Usage: internal-validation/host-probe.sh <out-dir> [full|k6-only|reference]
#   k6-only    checks 0 and 1 (about two minutes), for re-checks between stages.
#   reference  runs everything, applies only check 0, and records the timings
#              as a reference: later runs point PROBE_REFERENCE at <out-dir>.
# Settings (environment):
#   PROBE_REFERENCE      a previous `reference` run's <out-dir> (default: the laptop's
#                        Sept 19 files in zig-allocator/microbench/results/)
#   K6_STARTUP_LIMIT_S   check 1's limit (default 80, the laptop's)
#   PROBE_CPU            core the microbench is pinned to (default 2)
#   CLOCK_REFERENCE      windows | ntp (default: windows if powershell.exe exists)
#   CLOCK_NTP_SERVER     NTP server for check 0 (default: metadata.google.internal
#                        if it resolves, else time.google.com)
# Exit 0 = HOST CLEAN (or REFERENCE RECORDED). The verdict is also written to
# <out-dir>/verdict.txt.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
OUT="${1:?usage: host-probe.sh <out-dir> [full|k6-only|reference]}"
MODE="${2:-full}"
case "$MODE" in full|k6-only|reference) ;; *) echo "unknown mode: $MODE" >&2; exit 2 ;; esac
mkdir -p "$OUT"
MB=$REPO/zig-allocator/microbench
JEMALLOC=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
TM=$REPO/datasets/azure-trace-2019/processed/traffic-models
K6_LIMIT="${K6_STARTUP_LIMIT_S:-80}"
PROBE_CPU="${PROBE_CPU:-2}"

# 0. Clock rate: the monotonic clock (what Node, k6 and the microbench time
#    with) against an outside clock read at the start and end of the interval.
#    On 2026-10-04 the WSL clock (clocksource tsc) ran at 92.7 % of real time:
#    every duration measured inside WSL -- probe timings, k6 latencies, req/s,
#    microbench ns -- read ~7 % short, while WSL stepped the wall clock forward
#    ~2.6 s every 31 s. Limit: within +-1 % of real time.
#    windows: one PowerShell process prints Windows' time at both ends; the VM's
#      clock is read the moment each line arrives, so the PowerShell startup
#      delay cancels out.
#    ntp: an SNTP query at both ends (best of five by round trip), each paired
#      with the local clock at the midpoint of its round trip, so network delay
#      cancels to within half the round-trip asymmetry -- milliseconds against
#      a 60 s interval. If chronyd runs, an unsynchronised clock also fails:
#      that is when the wall clock gets stepped, which is what put latency
#      spikes into the WSL runs.
CLOCK_SECONDS="${CLOCK_CHECK_SECONDS:-60}"
CLOCK_LINE=$(python3 - "$CLOCK_SECONDS" "$OUT" <<'PY'
import os, shutil, socket, struct, subprocess, sys, time
secs, out = int(sys.argv[1]), sys.argv[2]
src = open('/sys/devices/system/clocksource/clocksource0/current_clocksource').read().strip()
ref = os.environ.get('CLOCK_REFERENCE') or ('windows' if shutil.which('powershell.exe') else 'ntp')

def windows():
    cmd = ('[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); [Console]::Out.Flush(); '
           f'Start-Sleep -Seconds {secs}; [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()')
    p = subprocess.Popen(['powershell.exe', '-NoProfile', '-Command', cmd], stdout=subprocess.PIPE, text=True)
    marks = []
    for line in p.stdout:
        line = line.strip()
        if line.isdigit():
            marks.append((time.monotonic(), int(line) / 1000))
    p.wait(timeout=30)
    return marks[0], marks[-1], 'Windows', ''

def ntp_server():
    if os.environ.get('CLOCK_NTP_SERVER'):
        return os.environ['CLOCK_NTP_SERVER']
    try:
        socket.getaddrinfo('metadata.google.internal', 123, socket.AF_INET)
        return 'metadata.google.internal'
    except OSError:
        return 'time.google.com'

def sntp(server):
    addr = socket.getaddrinfo(server, 123, socket.AF_INET, socket.SOCK_DGRAM)[0][4]
    best = None
    for _ in range(5):
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(2)
            a = time.monotonic()
            s.sendto(b'\x23' + bytes(47), addr)   # LI 0, version 4, mode 3 (client)
            data = s.recv(48)
            b = time.monotonic()
        if data[0] >> 6 == 3 or data[1] == 0:
            raise RuntimeError(f'{server} says it is not synchronised')
        stamp = lambda o: struct.unpack('!I', data[o:o + 4])[0] + struct.unpack('!I', data[o + 4:o + 8])[0] / 2**32
        # midpoint of the server's receive and transmit times, against the
        # midpoint of our round trip
        mark = ((a + b) / 2, (stamp(32) + stamp(40)) / 2, b - a)
        if best is None or mark[2] < best[2]:
            best = mark
        time.sleep(0.2)
    return best

def chrony():
    if not shutil.which('chronyc'):
        return True, ''
    text = subprocess.run(['chronyc', 'tracking'], capture_output=True, text=True, timeout=10).stdout
    open(os.path.join(out, 'chrony.txt'), 'w').write(text)
    field = dict(l.split(':', 1) for l in text.splitlines() if ':' in l)
    get = lambda k: field.get(k, '?').strip()
    synced = get('Leap status') == 'Normal'
    return synced, (f"; chrony {'synchronised' if synced else 'NOT SYNCHRONISED'}, "
                    f"offset {get('System time')}, freq {get('Frequency')}")

try:
    if ref == 'windows':
        (v0, w0), (v1, w1), name, note = windows()
        rtt = ''
    else:
        server = ntp_server()
        v0, w0, r0 = sntp(server)
        time.sleep(secs)
        v1, w1, r1 = sntp(server)
        name, rtt = f'NTP {server}', f', rtt {1000 * r0:.1f}/{1000 * r1:.1f} ms'
    rate = (v1 - v0) / (w1 - w0)
    synced, note = chrony()
    ok = abs(rate - 1) <= 0.01 and synced
    print(f"0. clock vs {name:16} {100 * rate:7.2f} % of real time   limit 99-101 %     {'PASS' if ok else 'FAIL'}   "
          f"[clocksource {src}, {secs} s{rtt}{note}]")
except Exception as e:  # cannot verify the clock = not clean
    print(f"0. clock vs {ref:16} not measurable ({type(e).__name__}: {e})        FAIL   [clocksource {src}]")
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
    python3 -c "k=$K6S; l=$K6_LIMIT; print(f'1. k6 startup to first VU   {k:6.1f} s            limit <= {l:g} s      ' + ('PASS' if k<=l else 'FAIL'))"
  } | tee "$OUT/verdict.txt"
  if [ $CLOCK_OK -eq 1 ] && python3 -c "import sys; sys.exit(0 if $K6S <= $K6_LIMIT else 1)"; then echo 'HOST CLEAN' | tee -a "$OUT/verdict.txt"; exit 0; fi
  echo 'HOST NOT CLEAN' | tee -a "$OUT/verdict.txt"; exit 1
fi

# 2-3. V8 microbench and GC timing, pinned to one core, against the reference.
#      The workload is a fixed trace kept in git (microbench/probe-trace, the
#      2026-09-19 mix), not the current characterization's, so the probe measures
#      the same thing on every machine and after every retrain. The native
#      replayer is built here if this checkout has never built it.
if [ ! -x "$MB/.out/engine_bench" ]; then
  mkdir -p "$MB/.out"
  ( cd "$MB" && zig build-exe -O ReleaseFast -target x86_64-linux-gnu.2.36 -lc \
      --dep samm -Mroot=engine_bench.zig \
      -O ReleaseFast -target x86_64-linux-gnu.2.36 -Msamm=../src/root.zig \
      -femit-bin=.out/engine_bench ) > "$OUT/engine_bench-build.log" 2>&1 \
    || { echo "could not build engine_bench (see $OUT/engine_bench-build.log)" | tee "$OUT/verdict.txt"; exit 1; }
fi
bench() {
  local out="$1"; shift; local envs=()
  while [[ "$1" != "--" ]]; do envs+=(-e "$1"); shift; done; shift
  docker run --rm --cpuset-cpus="$PROBE_CPU" --memory=3g --memory-swap=3g -v "$MB":/bench -w /bench \
    -e SAMM_APP_ROOT=/app -e SAMM_RECLAIM_POLICY=none "${envs[@]}" --entrypoint sh samm-enabled:bench -c "$*" > "$out"
}
bench "$OUT/native.jsonl" LD_PRELOAD=$JEMALLOC -- \
  "./.out/engine_bench probe-trace/mix engine 3 0 1 && ./.out/engine_bench probe-trace/mix malloc 3 1 1"
bench "$OUT/v8.jsonl" LD_PRELOAD=$JEMALLOC SAMM_ALLOCATOR_ENABLED=false BENCH_MALLOC=jemalloc -- \
  "node --expose-gc js_bench.js probe-trace/mix v8 3 0 1 && node --expose-gc js_bench.js probe-trace/mix v8 3 1 1"
echo "k6_startup_s $K6S" > "$OUT/k6_startup.txt"

K6S=$K6S K6_LIMIT=$K6_LIMIT MODE=$MODE CLOCK_OK=$CLOCK_OK CLOCK_LINE="$CLOCK_LINE" python3 - "$MB/results" "$OUT" "${PROBE_REFERENCE:-}" <<'PY' | tee "$OUT/verdict.txt"
import json, os, statistics as st, sys
ref_dir, p, probe_ref = sys.argv[1], sys.argv[2], sys.argv[3]
load = lambda f: [json.loads(l) for l in open(f) if l.strip().startswith('{')]
if probe_ref:
    # a previous `reference` run of this script
    ref = load(f'{probe_ref}/native.jsonl') + load(f'{probe_ref}/v8.jsonl')
    ref_name = 'reference'
else:
    ref = load(f'{ref_dir}/engine-jemalloc.jsonl') + load(f'{ref_dir}/malloc-jemalloc.jsonl') + load(f'{ref_dir}/v8-jemalloc.jsonl')
    ref_name = 'Sep 19'
now = load(f'{p}/native.jsonl') + load(f'{p}/v8.jsonl')
def cell(rows, layer, touch, f=lambda r: r['ns_per_alloc']):
    return st.median(f(r) for r in rows if r['layer'] == layer and r['trace'] == 'mix' and bool(r['touch']) == touch)
per_gc = lambda r: r['gc_ms'] / r['gc_count']
ok = os.environ['CLOCK_OK'] == '1'
print(os.environ['CLOCK_LINE'])
k6, limit = float(os.environ['K6S']), float(os.environ['K6_LIMIT'])
if os.environ['MODE'] == 'reference':
    # Timings only: no limits until they are set from this run.
    print(f"1. k6 startup to first VU   {k6:6.1f} s")
    for touch, name in ((False, 'no touch'), (True, 'page writes')):
        print(f"2. V8 microbench, {name:11} {cell(now, 'v8', touch):7.0f} ns per allocation")
    print(f"3. GC time per collection   {cell(now, 'v8', False, per_gc):.2f} ms")
    print(f"REFERENCE RECORDED: set PROBE_REFERENCE={p} and K6_STARTUP_LIMIT_S before any benchmark"
          if ok else 'NO REFERENCE: the clock check failed')
    sys.exit(0 if ok else 1)
good = k6 <= limit; ok &= good
print(f"1. k6 startup to first VU   {k6:6.1f} s            limit <= {limit:g} s      {'PASS' if good else 'FAIL'}")
for touch, name in ((False, 'no touch'), (True, 'page writes')):
    r = cell(now, 'v8', touch) / cell(ref, 'v8', touch); good = 0.90 <= r <= 1.10; ok &= good
    print(f"2. V8 microbench, {name:11} {r:4.2f}x of {ref_name:9} limit 0.90-1.10x   {'PASS' if good else 'FAIL'}")
r = cell(now, 'v8', False, per_gc) / cell(ref, 'v8', False, per_gc); good = r <= 1.10; ok &= good
print(f"3. GC time per collection   {cell(now, 'v8', False, per_gc):.2f} ms = {r:4.2f}x   limit <= 1.10x     {'PASS' if good else 'FAIL'}")
print('HOST CLEAN' if ok else 'HOST NOT CLEAN')
sys.exit(0 if ok else 1)
PY
exit "${PIPESTATUS[0]}"
