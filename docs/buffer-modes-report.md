# Buffer modes: test report and recommendation

Branch `feat/buffer-views`, 2026-11-12. All timings come from the development
laptop, which failed its last health probe (2026-11-03), so treat them as
indicative. Counts (fallbacks, garbage collections, allocations) are
reproducible.

## Recommendation

**Merge the branch with `detach` (today's behaviour) left as the default, and
decide the default on the VM.**

- `chunk` mode is a considerable upgrade and keeps today's safety guarantee:
  about 12 % less CPU per request and about 13 % more throughput in the Docker
  comparison, and allocation cost on the mixed trace roughly halved.
- It passed every safety test on Node 22 and Node 24.
- Two things are not settled, and both need the VM's trustworthy timing: the
  size of the gain, and whether `chunk` raises the fallback share (it was
  higher in both Docker pairs, lower or equal in the deterministic replay).
- `view` mode should not be used for the study. It is kept only as a measured
  upper bound.

Because the mode is a switch (`SAMM_BUFFER_MODE`) and does not depend on the
routing table, merging it changes nothing until the switch is set.

## What the problem was

The microbenchmark showed the engine costs 10-18 ns per allocation while the
path through Node costs 780-3,000 ns. Timing each step on Node 22:

| Step | ns per allocation |
|---|---|
| Bridge call with three arguments, no work | 26 |
| + engine allocate and release | 31 |
| Today's full path (region, 200 allocations, close) | ~1,000 |
| A view into an existing ArrayBuffer (`Buffer.from(ab, offset, len)`) | 34 |

Nearly all of the cost is V8 creating one external Buffer per object. A typed
array view into an ArrayBuffer that already exists costs about 3 % of that.

## The three modes

| Mode | What an object is | When references are cut off | What `.buffer` exposes |
|---|---|---|---|
| `detach` (default, today) | its own external Buffer | when its request ends | only itself |
| `chunk` (the safety solution) | a view into a chunk owned by its request | when its request ends | only that request's own chunk |
| `view` (upper bound only) | a view into its segment's ArrayBuffer, shared by every request using the segment | when the segment is recycled, later | other requests' bytes |

Only region-scoped allocations from bump arenas take the new paths. Slab
call-sites, allocations outside a request, and the System heap are unchanged in
every mode.

## The safety solution: per-request chunks

The concern with shared views was twofold: an escaped reference stays readable
after its request ends, and one object's `.buffer` reaches other requests'
data. `chunk` mode removes both by never sharing an ArrayBuffer between
requests:

1. A request's **first** allocation in an arena is an ordinary Buffer, as
   today. Most requests allocate once, and a chunk for one object would be
   waste.
2. From the second allocation on, the request gets a private **chunk** carved
   from the arena: 64 KiB first, doubling up to a quarter of the arena's
   segment. Its objects are views into its own chunks.
3. There is **one ArrayBuffer per chunk**. When the request ends, each chunk is
   detached, which empties every view into it at once.
4. An object larger than a quarter of a chunk takes the ordinary path.

So the guarantee is the one `detach` gives today: an escaped reference reads as
empty from the moment its request ends, and nothing a request can reach through
`.buffer` belongs to another request. A 200-object batch request needs about 19
ArrayBuffers instead of 200.

**A second fix, found while tracing a crash:** region ids were slot numbers,
and a slot is reused as soon as its region closes. A handler still running
after its client disconnected could allocate into whichever request held the
slot by then. Region ids now carry a generation; a stale id names no region.
This applies to every mode and is covered by a test.

### What `chunk` still does not protect against

- **Objects of the same request share a chunk.** One object's `.buffer` shows
  its sibling objects in the same request. They are in the same trust domain.
- **`byteOffset` is not zero** for chunked objects. Code that builds a typed
  array from `buf.buffer` without `buf.byteOffset` reads the wrong bytes. Node's
  own pooled Buffers (under 4 KiB) behave the same way; the routes in this
  repository never touch `.buffer` or `byteOffset`.
- **Transferring `buf.buffer`** to a worker detaches the whole chunk, emptying
  the request's other objects in it.
- **Reachable is still not the same as used**, as with `detach`: a misrouted
  escaping call-site loses its data silently at request end.

## Results

### Gate 1: safety (passed)

`zig-allocator/tests/buffer_mode_test.js`, run in all three modes on Node
22.16 and Node 24.18: 7 of 7 checks pass in every combination.

| Check | detach | chunk | view |
|---|---|---|---|
| No two live objects share a byte (6,000 randomised steps, up to 24 interleaved requests, every managed call-site, over 20,000 allocations) | pass | pass | pass |
| An escaped reference never shows another request's data, across several arena recycles | pass | pass | pass |
| An escaped reference reads as empty the moment its request ends | pass | pass | not provided by design: readable until the segment is recycled |
| Two interleaved requests never share an ArrayBuffer | pass | pass | not provided by design: they share |
| Objects counted once, zero detach failures, no region left open | pass | pass | pass |
| A region id that outlived its region cannot join the request holding the slot | pass | pass | pass |
| An allocation outside a request is still an ordinary Buffer | pass | pass | pass |

The 32 Zig unit tests, the region test and the zero-copy test also pass.

### Gate 2: is the gain real

**Replay through the server path, Node 22** (3 trials each):

| Trace | Measure | detach | chunk | view |
|---|---|---|---|---|
| batch | ns per allocation | 935 | 230 | 160 |
| mix | ns per allocation | 1,901 | 940 | 1,112 |
| mix | major GCs | 461 | 343 | 397 |
| mix | total GC time | 2,539 ms | 2,098 ms | 2,430 ms |
| mix | fallbacks (3 trials) | 13,010 | 14,284 | 13,010 |
| mix, held-out slice | fallbacks (3 trials) | 3,891 | 3,815 | not run |
| ingest, cache | ns per allocation | 1,178 / 1,235 | 1,201 / 1,193 | 1,218 / 1,234 |
| process | ns per allocation | 6,578 | 6,795 | 4,428 |

`chunk` gains where a request makes many small allocations (batch) and is
neutral for call-sites that allocate once per request, as designed. On the
mixed trace it beats `view`.

**Docker, the real server at k = 2.5, same seed, alternating runs, 2 minutes
each:**

| Run | Throughput | CPU per request | Processing p95 | Dropped | Fallback share |
|---|---|---|---|---|---|
| detach 1 | 657 req/s | 1.349 ms | 745 ms | 24,234 | 0.63 % |
| chunk 1 | 756 req/s | 1.184 ms | 397 ms | 11,716 | 0.99 % |
| detach 2 | 667 req/s | 1.348 ms | 601 ms | 23,852 | 0.15 % |
| chunk 2 | 745 req/s | 1.194 ms | 367 ms | 12,385 | 0.53 % |

CPU per request is the steadiest number here (1.349 and 1.348 against 1.184
and 1.194): about 12 % lower. That is more than the allocation path alone
explains (about 42 allocations per request at roughly 1 µs each is about 3 %),
so most of the rest is likely garbage-collection work on external Buffers.
That part is an inference; the VM's GC-instrumented pass can confirm it.

**The open question is fallbacks.** The share was higher under `chunk` in both
pairs. It also differed fourfold between the two identical `detach` runs
(0.63 % and 0.15 %), so two pairs cannot settle it, and `chunk` was serving
14 % more requests at the time. The deterministic replay, where the request
stream is identical, shows +10 % on one slice and -2 % on the other.

### Gate 3: stability

**Passed at the training load.** `chunk` mode, k = 1.0, 10 minutes, seed
2025, with allocator counters sampled every second:

| Measure | Result |
|---|---|
| Requests | 227,996 served, 0 failed |
| Memory, median per minute | 781-790 MB in every minute: flat, no growth |
| Memory, peak | 824 MiB of 1,024; no OOM kill |
| Detach failures | 0 |
| Regions | 228,065 opened, 228,065 closed, 0 exhausted |
| Objects served as views | 9,547,637, over 850,493 chunk ArrayBuffers (about 11 objects per chunk) |
| Fallback share | 0.144 % of 9,765,367 allocations |
| Processing time | p95 2.24 ms, p99 6.33 ms |

(Data: `benchmark-results/buffer-modes/stability-k1.0-chunk/`, not in git.)

**The crash that was not a crash.** The first 10-minute run (k = 2.5, seed
2026, `chunk`) lost its container about four minutes in. Reproduced with the
logs kept, on the same seed:

| Mode | Outcome over 7 minutes |
|---|---|
| chunk | survived: 390,091 requests, 0 failed, 841 req/s |
| detach (today) | killed about 3 minutes in: exit 137, `OOMKilled=true`, after 140,542 requests |

So the death is memory pressure at k = 2.5 on that seed, and today's code dies
of it too. It is not a defect in the new mode. One run each cannot show that
`chunk` survives better. What it does show matters for the study: **at k = 2.5
SAMM itself can be killed on some seeds**, at least on this laptop. That bears
on the choice of stress point and on how killed runs are treated, both still
undecided.

## Tried and dropped along the way

| Idea | Result |
|---|---|
| Unwinding the bump cursor when a request ends (reuse its bytes at once) | No effect on fallbacks, GC or timing on two trace slices; removed |
| External ArrayBuffer wrapped in JS, one per object | Slower than today (about 1,270 against 1,060 ns) |
| Returning empty segments when another arena is refused | Fallbacks rose 4,336 → 10,388 and 1,297 → 16,115: the arenas thrash |
| Tuning segments per floor | Best value on one slice was the worst on the other: overfitting |
| Reserving floors at startup | Same fallbacks on mixed traces, slightly worse for a single site |
| Hiding arena Buffers from V8's external-memory count | Aborts the process on Node 24 |

## Other findings

- **`finalizer_test.js` is timing-sensitive.** It failed once inside the suite
  and once in three reruns while a Docker run was loading the machine, then
  passed 12 of 12 on both `main` and the branch. Like the steady-state test, it
  depends on when V8 collects.
- **The fallback share is noisy between identical runs** (0.15 % to 0.63 %),
  so any comparison of it needs replicates.
- **A harness bug, fixed on this branch:** a relative `RESULTS_DIR` made k6
  write its summary nowhere, because k6 starts in its scenario directory, and
  the run was lost at the end. The runbook's main-study command used a relative
  path. `_bench-lib.sh` now makes it absolute.

## What to do on the VM

1. Run `K=<locked> N=10 CONDITIONS=samm SAMM_BUFFER_MODE=detach` and the same
   with `chunk` (same seeds), before the main study: CPU per request,
   throughput, processing p99, fallback share, survival.
2. Include one GC-instrumented run of each, to see whether the CPU saving is
   garbage collection.
3. Choose the default from those numbers and freeze it with the table. If
   `chunk` is chosen, the thesis's design section gains a paragraph on
   per-request chunks; the safety claim does not change.

## Files

- `zig-allocator/src/node-api-interface/addon.zig`: the modes, region
  generations (see "BUFFER MODES").
- `zig-allocator/index.js`: the JS side that turns an offset into a view.
- `zig-allocator/src/arenas/bump-allocator/bump.zig`: per-segment epochs
  (`view` mode only).
- `zig-allocator/tests/buffer_mode_test.js`: the safety test, run per mode by
  `run_tests.sh` step 8.
- `server/scripts/run_replicates.sh`: passes `SAMM_BUFFER_MODE` through.
