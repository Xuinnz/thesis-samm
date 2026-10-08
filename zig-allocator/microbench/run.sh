#!/usr/bin/env bash
#
# run.sh -- how fast is SAMM with and without the Node-API bridge?
#
# Replays the characterization's own request stream (extract_trace.js) through
# every layer between a route and physical memory, one container per layer, all
# inside the production SAMM image (same Node, same ReleaseFast addon, same
# routing table, jemalloc available):
#
#   engine    SAMM engine, no bridge            (engine_bench.zig)
#   malloc    C allocator, no bridge, no V8     (engine_bench.zig)
#   bridge    one samm.allocate() round trip that does no memory work
#   samm      allocateBuffer() -> SAMM through the bridge   (js_bench.js)
#   v8        allocateBuffer() -> Buffer.allocUnsafe()      (js_bench.js)
#
# Nothing under zig-allocator/src is built or modified here: the Zig bench
# imports the engine read-only, and the Node layers load the addon already in
# the image. All output stays under microbench/.out and the results directory.
#
# Usage:
#   ./run.sh                     # full run
#   TRIALS=3 ./run.sh            # fewer trials
#   RESULTS=results-2026-09-25 ./run.sh   # results go to a NEW directory; an existing
#                                         # run is never overwritten (see the guard below)
#   TRACES=aggregate TOUCH_MODES=1 TRIALS=30 RESULTS=... ./run.sh   # one cell, more trials
#   IMAGE=samm-enabled:bench CPU=2 ./run.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

IMAGE="${IMAGE:-samm-enabled:bench}"
CPU="${CPU:-2}"                 # one pinned core: the study's 1 vCPU, minus CFS throttling noise
TRIALS="${TRIALS:-5}"
WARMUP="${WARMUP:-1}"
SCOPES="${SCOPES:-30000}"
TRACES="${TRACES:-mix batch cache ingest fetch process aggregate}"
JEMALLOC=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2
RESULTS="${RESULTS:-$HERE/results}"
TOUCH_MODES="${TOUCH_MODES:-0 1}"   # 0 = no memory touched, 1 = one write per 4 KB page

command -v zig >/dev/null || { echo "zig not found"; exit 1; }
docker image inspect "$IMAGE" >/dev/null 2>&1 || {
  echo "image $IMAGE not found -- run a SAMM benchmark first so it is built from the current table"; exit 1; }

# The image's addon must be built from the table this bench's engine is built
# from, or the two sides would be timing different routing decisions.
host_fp="$(sha256sum ../src/routing-table/model_weights.zig | cut -c1-16)"
echo "routing table (host) : $host_fp"
echo "image                : $IMAGE ($(docker image inspect -f '{{.Created}}' "$IMAGE" | cut -c1-19))"
table_mtime="$(date -r ../src/routing-table/model_weights.zig +%s)"
image_ctime="$(date -d "$(docker image inspect -f '{{.Created}}' "$IMAGE")" +%s)"
if (( image_ctime < table_mtime )); then
  echo "ERROR: $IMAGE predates the current routing table -- rebuild it first."; exit 1
fi

# A finished run is evidence: never write over one. Each run gets its own directory.
if compgen -G "$RESULTS/*.jsonl" >/dev/null; then
  echo "ERROR: $RESULTS already holds results. Pass RESULTS=<new directory>; the existing run is left as is."; exit 1
fi

mkdir -p .out "$RESULTS"

echo "== building engine_bench (ReleaseFast, glibc 2.36 to match the image)"
zig build-exe -O ReleaseFast -target x86_64-linux-gnu.2.36 -lc \
  --dep samm -Mroot=engine_bench.zig \
  -O ReleaseFast -target x86_64-linux-gnu.2.36 -Msamm=../src/root.zig \
  -femit-bin=.out/engine_bench

if [[ ! -f .out/traces/mix/meta.json || "${REEXTRACT:-0}" == 1 ]]; then
  echo "== extracting traces from the characterization"
  node extract_trace.js .out/traces "$SCOPES"
fi

run() {   # run <label> <env...> -- <command>
  local label="$1"; shift
  local envs=()
  while [[ "$1" != "--" ]]; do envs+=(-e "$1"); shift; done
  shift
  echo "== $label"
  # A layer that dies (OOM, crash) is reported and skipped, not allowed to take
  # the remaining layers down with it.
  local rc=0
  docker run --rm --cpuset-cpus="$CPU" --memory=3g --memory-swap=3g \
    -v "$HERE":/bench -w /bench -e SAMM_APP_ROOT=/app -e SAMM_RECLAIM_POLICY=none \
    "${envs[@]}" --entrypoint sh "$IMAGE" -c "$*" > "$RESULTS/$label.jsonl" || rc=$?
  wc -l < "$RESULTS/$label.jsonl" | xargs printf '   %s trials recorded\n'
  if (( rc != 0 )); then
    echo "   FAILED: $label exited $rc$( ((rc == 137)) && echo ' (killed -- out of memory?)')"
    FAILED+=("$label")
  fi
}
FAILED=()

loop() {  # loop <command-template>, {T}=trace {X}=touch
  local tpl="$1" out=""
  for touch in $TOUCH_MODES; do
    for t in $TRACES; do
      local c="${tpl//\{T\}/.out/traces/$t}"
      out+="${c//\{X\}/$touch} && "
    done
  done
  echo "${out% && }"
}

run engine-jemalloc   LD_PRELOAD=$JEMALLOC --                 "$(loop "./.out/engine_bench {T} engine $TRIALS {X} $WARMUP")"
run malloc-glibc                           --                 "$(loop "./.out/engine_bench {T} malloc $TRIALS {X} $WARMUP")"
run malloc-jemalloc   LD_PRELOAD=$JEMALLOC --                 "$(loop "./.out/engine_bench {T} malloc $TRIALS {X} $WARMUP")"
run bridge-jemalloc   LD_PRELOAD=$JEMALLOC SAMM_ALLOCATOR_ENABLED=true BENCH_MALLOC=jemalloc -- \
  "node --expose-gc js_bench.js - bridge $TRIALS 0 $WARMUP"
run samm-jemalloc     LD_PRELOAD=$JEMALLOC SAMM_ALLOCATOR_ENABLED=true BENCH_MALLOC=jemalloc -- \
  "$(loop "node --expose-gc js_bench.js {T} samm $TRIALS {X} $WARMUP")"
run v8-jemalloc       LD_PRELOAD=$JEMALLOC SAMM_ALLOCATOR_ENABLED=false BENCH_MALLOC=jemalloc -- \
  "$(loop "node --expose-gc js_bench.js {T} v8 $TRIALS {X} $WARMUP")"
run v8-glibc          SAMM_ALLOCATOR_ENABLED=false BENCH_MALLOC=glibc -- \
  "$(loop "node --expose-gc js_bench.js {T} v8 $TRIALS {X} $WARMUP")"

node report.js "$RESULTS" | tee "$RESULTS/summary.txt"
if (( ${#FAILED[@]} )); then echo "LAYERS THAT FAILED: ${FAILED[*]}"; exit 1; fi
echo "ALL LAYERS COMPLETED"
