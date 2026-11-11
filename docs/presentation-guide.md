# Presentation guide: SAMM in 10 minutes (expert audience)

Built from your outline: **problem → gap → idea → architecture (offline,
online) → evaluation → questions.** The online half follows the classic
memory-management split: **allocation** (where a new object goes),
**identification** (what is dead), **reclamation** (how it is freed). This
audience will recognise that split immediately.

Mention limitations where they occur (in each layer); the closing slide
collects them in one line.

## Timing

| # | Slide | Time |
|---|---|---|
| 1 | Title | 0:10 |
| 2 | Problem | 0:30 |
| 3 | Gap | 0:30 |
| 4 | Idea | 0:25 |
| 5 | Architecture: two phases | 0:25 |
| 6 | Offline 1: Azure → k6 | 0:35 |
| 7 | Offline 2: the server | 1:00 |
| 8 | Offline 3: the profiler | 0:50 |
| 9 | Layer 1: request-scoped vs escaping | 0:35 |
| 10 | Layer 2: bump vs slab | 0:35 |
| 11 | Layer 3: quotas + compiled table | 0:40 |
| 12 | Online 1: allocation | 0:40 |
| 13 | Online 2: identification | 0:25 |
| 14 | Online 3: reclamation | 0:40 |
| 15 | Evaluation design + external | 0:40 |
| 16 | Internal validation | 0:40 |
| 17 | Microbenchmark | 0:20 |
| 18 | Limitations, next steps, questions | 0:20 |
| | **Total** | **10:00** |

18 slides in 10 minutes is tight. Rehearse with a timer. If you run over,
merge 10 + 11 and fold 13 into 14.

## Build rules for every slide

- **Headline = the point, as a sentence.** Not "Problem", but "Buffers are freed by the GC, not when they die".
- **One visual per slide**, at most 3 short lines of text. Everything else goes in the speaker notes.
- **One architecture diagram, reused.** Slide 5 introduces it; slides 6–14 show a small copy in a corner with the current box highlighted.
- **One running example.** Follow `process.js` through slides 7, 8, 9, 10, 11 and 12.
- **Same colour per allocator everywhere** (as in the internal-validation plots): glibc blue, jemalloc orange, SAMM aqua.
- **Your own numbers only**, at most one or two per line. Full tables go in backup slides.
- **Skip definitions** she knows (bump, slab, k-means, THP, Little's Law). Spend the time on the server, the profiler and reclamation.

---

## Slide-by-slide

### 1. Title (0:10)
- Title, names, adviser.
- Say: one line of what SAMM is, nothing more.

### 2. Problem (0:30)
**Headline:** "In Node, large Buffers are freed by the GC, not when they die,
so memory comes back late and unpredictably."

**Visual:** a timeline of one Buffer: *allocated → used → no longer needed →
still resident (overhang) → GC finalizer frees it.* Mark the overhang.

**On slide (3 lines):**
- Buffers live outside the V8 heap, in malloc; they are freed only when the GC collects their JavaScript wrapper.
- In a 1 GB container: late release, fresh page faults (86 per request on jemalloc), extra GC work → wasted CPU, latency spikes, OOM kills.
- GC is the right default when lifetimes are unknown (no manual freeing), but buffer-heavy servers pay for it.

**Say:** the setting in one sentence (microservices in small containers;
memory is expensive). Don't mention requests yet.

**Avoid:** "V8 fragments memory like Swiss cheese" (V8 compacts its old
generation), "huge stop-the-world pauses" (your GC pause p99 is ~1.3–1.5 ms),
and claiming fragmentation (not measured).

### 3. Gap (0:30)
**Headline:** "Lifetime-aware allocation exists, but not for off-heap memory in
a garbage-collected runtime."

**Visual:** three boxes side by side.

| Learned, at runtime | Manual, deterministic | Garbage-collected runtime |
|---|---|---|
| **LLAMA** (C++): predicts lifetime classes from calling context, adapts while running | **Per-request pools** (nginx, Apache): free everything at request end, but the developer decides what belongs there | **V8**: lifetime is blurred, because objects die long before the GC frees them; tuning heap size doesn't reach external memory |

**On slide (1 line):** "No approach learns which off-heap objects are
request-scoped and frees them deterministically."

**Say:** "LLAMA showed lifetimes are predictable from allocation context in C++
servers. We asked how far a fully ahead-of-time approach gets in a
garbage-collected runtime." Cite Maas et al., ASPLOS 2020. Don't call LLAMA slow.

**Backup evidence:** in your gc-control probe, raising `--max-old-space-size`
to 1.5 or 2 GB left GC counts unchanged (about 287 minor / 80 major), because
external Buffer memory drives GC, not heap size.

### 4. Idea (0:25)
**Headline:** "Use the request as the lifetime boundary, learn which call
sites respect it, and compile the decisions into a fixed table."

**Visual:** four challenges, each answered by one design piece.

| Challenge | Answer |
|---|---|
| GC blurs lifetime | **Layer 1**: compare each object's finalizer lifespan with its request's lifespan (the overhang) to find request-scoped call sites |
| No structure fits every site (bump pins on mixed lifetimes; slab wastes on mixed sizes) | **Layer 2**: compute each structure's waste from the trace, pick the lower |
| Static arenas starve or OOM | **Layer 3**: budget each arena from its concurrent demand, under one global ceiling, with shared headroom |
| Runtime inference costs time | **Compile** every decision into an O(1) lookup table used by a small Zig allocator |

**Say:** "Do the learning offline, compile it into a fixed O(1) routing table,
and run it through a small Zig allocator, so there's no inference at runtime."

### 5. Architecture: two phases (0:25)
**Visual:** the diagram you will reuse.
- **Offline:** Azure trace → k6 traffic → server with profiler → traces → ML refinery (L1, L2, L3) → table compiler → `model_weights.zig`.
- **Online:** the same traffic → server → N-API → Zig engine (routing table, bump/slab arenas, regions, budget) → malloc fallback.

**Say:** "Offline we learn; online we only look things up."

### 6. Offline 1: Azure → k6 (0:35)
**Headline:** "Traffic, hold times and payload sizes come from the Azure
Functions 2019 trace."

**Visual:** three small panels:
1. a 4-state Markov diagram (Idle, Ramp, Burst, Cooldown), e.g. Idle→Idle 0.82, Burst→Cooldown 0.46;
2. a log-normal hold-time curve;
3. a payload-size distribution.

**On slide:**
- Cleaning: HTTP-triggered only, dormant functions dropped, anonymized zeros fixed, missing days handled.
- States map onto a min–max req/s range (5–500 at k = 1.0); the random walk is seeded, so every condition sees the same traffic.
- Memory percentiles normalized to the 1 GB P99 → payload sizes.

**Say:** k6 replays this as an open loop. k scales rate ×k and holds ÷k, so
live memory stays constant (Little's Law); only CPU pressure rises.

### 7. Offline 2: the server (1:00), the slide that needs the most explaining
**Headline:** "A synthetic microservice covering the three things that matter
to an allocator: object size, allocations per request, lifetime."

**Visual:** the endpoint table.

| Endpoint | Size | Per request | Hold | Represents | Mix |
|---|---|---|---|---|---|
| cache | 4 KB | 1 | none | small, short-lived | 25% |
| fetch | 1 MB fixed | 1 | log-normal (Azure) | held across an `await` | 25% |
| process | Azure payload, ≤ 16 MB | 1 | fixed 600 ms ±3% | large, held | 25% |
| ingest | 64 KB–1 MB | 1 | log-normal, base scale | medium, held | 10% |
| batch | 1–32 KB items, count from the payload draw | tens to hundreds | none | many small objects | 10% |
| aggregate | Azure payload, 64 KB–2 MB | 1 | none; kept in a global 50 MB FIFO store | **escapes its request** | 5% |

**Say:**
- The hold is a `setTimeout` standing in for downstream I/O (a database or API call). The buffer stays alive across the `await`, which is the everyday Node pattern.
- Every page of every buffer is written, so memory and page faults are real.
- Each endpoint is one call site with an explicit label, used by the profiler and by SAMM.
- aggregate is a deliberate escaping site: the ground truth Layer 1 must find.

**Limitation to say:** 6 call sites, hand-labelled (no stack traces).

### 8. Offline 3: the profiler (0:50), her field
**Headline:** "Two lifespans per object: when the GC freed it, and when its
request ended."

**Visual:** two aligned timelines for one object:
`request start ──── request end` and `allocated ─────────── finalized`,
with the **overhang** (finalized − request end) highlighted.

**On slide:**
- An N-API addon attaches a finalizer to each Buffer (`napi_add_finalizer`) and records call site, size, allocation time and request scope; the finalizer records finalization time.
- A second trace records each request's start and end.
- 10,046,390 objects; 345 still alive at shutdown (0.003%) removed. Profiler off in every benchmark.

**Say, before she does:** finalization happens at GC time, not at last use, so
overhang mixes real escape with GC delay. Request-scoped sites sit at 11–25 ms
(the GC delay); aggregate sits at 1.3 s. That's why Layer 1 works on overhang,
and also its main limitation. Invite her view (checklist A2).

### 9. Layer 1: request-scoped vs escaping (0:35)
**Headline:** "k-means on log-overhang separates request-scoped call sites
from escaping ones."

**Visual:** a 1-D strip plot of log-overhang, one dot per site: batch (11 ms);
cache, process, ingest, fetch (20–25 ms); aggregate (1,307 ms). Show the gap
(52× separation) and the clusters.

**On slide:**
- Elbow method on WCSS (14.60 → 0.43 → 0.031); elbow K = 2, floor raises it to K = 3.
- Highest cluster → System (malloc, managed by the GC); the rest → SAMM.

**Limitation to say:** the rule always sends exactly one cluster to System. A
server with no escaping sites, or with two escaping tiers, would be
misclassified. Being redesigned (natural break, zero or more System clusters).

### 10. Layer 2: bump vs slab (0:35)
**Headline:** "Each call site gets the structure that wastes less memory,
computed from the trace."

**Visual:** the two formulas, plus a bar pair per site (bump waste vs slab waste).
- **Bump waste** = arrival rate × spread of lifetimes (σ, s) × mean size: the bytes that arrive while a segment waits for its slowest object (Little's Law).
- **Slab waste** = Σ per-class peaks (sweep-line over the trace) − overall peak: rounding up to power-of-two classes, and each class reserved for its own peak.
- If both are under one huge page (2 MB) → bump (cheaper path).

**On slide (results):** process: bump 6.6 MB vs slab 366 MB → Bump. fetch: all
1 MB, slab wastes 0 → Slab. Closest call: ingest, 8.9 vs 14.9 MB (1.7×).

### 11. Layer 3: quotas + the compiled table (0:40)
**Headline:** "One global budget, a guaranteed floor per arena, shared headroom
for bursts."

**Visual:** a stacked bar of the 1 GB:
`80 MB V8 | 76 MB System (66 MB peak × 1.15) | 32 MB safety | 836 MB pool limit × β 0.75 = 627 MB budget`,
with the budget split into guaranteed floors (439 MB) and shared headroom (188 MB).

**On slide:**
- Floors = 90th-percentile concurrent demand; each arena's span = 4× its quota, so a busy arena can borrow what idle arenas don't use; the budget caps the total.
- Compiler output (`model_weights.zig`): FNV-1a hash table (load ≤ 0.5), arena layout, and huge pages (`MADV_HUGEPAGE`) for any arena spanning ≥ 32 huge pages (64 MB), which keeps 2 MB rounding to ≤ 3.125% of its size.

**Limitations to say:** β = 0.75 and the 80 MB V8 figure are fixed numbers,
not measured (being replaced by a data-derived ceiling). Whether huge pages
actually engage is unmeasured.

### 12. Online 1: allocation (where a new object goes) (0:40)
**Headline:** "A new object costs one hash lookup and one pointer bump or bit
flip, with malloc as the fallback."

**Visual:** the decision path:
`label → FNV-1a → table` → **bump arena** / **slab class** / **miss → malloc (GC-managed)**; a refused budget charge also goes to malloc.

**On slide:**
- Bump: segmented. The floor is cut into 8 segments (segment = floor ÷ 8, page-aligned), but the ring grows one segment at a time up to the arena's span (max segments: batch 122, process 47, ingest 48, cache 17). The cursor fills a segment, then moves to the next in the ring, entering it only if nothing in it is still alive. If the next one is still pinned, it takes the lowest segment that has fully drained (since 2026-11-11; before that it went straight to growing). Only if none has drained does the arena grow by a fresh segment (charged to the budget on first entry); if the budget refuses, the allocation goes to malloc (counted as `bumpResetBlocked`). 64-byte aligned, so an object spans the fewest cache lines possible.
- Slab: power-of-two classes; a 3-level bitmap (slot words → summary → root) finds a free slot in a few bit scans; hot and cold fields kept in separate structs for cache locality.
- One mmap at startup (2.64 GB of address space, `NORESERVE`: reserved, not yet memory). A global budget caps what SAMM may use at 627 MB: the first time an arena uses a segment or slot, its full size counts against the budget; reuse is free; once the budget is spent, new allocations go to malloc. Memory is handed to JavaScript as zero-copy external Buffers through N-API.

**Limitation to say:** the layout is fixed when the table is compiled. An arena
can't grow past its span (overflow goes to malloc), and a changed workload
needs a recompile.

### 13. Online 2: identification (what is dead) (0:25)
**Headline:** "For SAMM objects, the end of the request *is* the death."

**Visual:** a request lifeline with `region open` at the start and `region
close` at `finish`/`close`; every SAMM buffer inside it dies at close.

**On slide:**
- Middleware opens a region per request and closes it when the response finishes or the connection closes.
- System objects (aggregate) are still found dead by the GC, as before.

**Say:** this is what replaces the GC for managed sites: death is known, not
discovered.

### 14. Online 3: reclamation (0:40)
**Headline:** "At request end SAMM detaches and releases every buffer, with no
GC involved."

**Visual:** the close sequence:
`region close → napi_detach_arraybuffer (length becomes 0) → engine.release → bump segment live count − 1 (at 0 the segment can be reused when the cursor comes round to it) / slab bit cleared`.

**On slide:**
- Scoped buffers have no finalizer and are held by a strong reference until close; unscoped ones fall back to a finalizer.
- Reclaim policy `none`: a reset segment keeps its pages, so the next request reuses already-resident memory without new page faults. (A `dontneed` policy exists; not benchmarked.)

**Limitations to say:**
- Pages are not returned to the OS when traffic drops: idle memory stays high (416 MB at 50 VUs vs 259 for glibc; ~911 MB after the demo).
- The pool itself can't exceed 627 MB. Under heavier traffic, the OOM risk comes from fallbacks **outside** the pool: once the pool filled (at 200 VUs) it stayed at 626.9 MB, while memory outside it grew 121 MB until the kill at 500 VUs.
- A misrouted escaping buffer is detached while still referenced: it reads as empty (silent data loss, not memory corruption). Detach failures were 0.

### 15. Evaluation design + external benchmark (0:40)
**Headline:** "Same traffic, same container, three allocators."

**On slide:**
- glibc, jemalloc, SAMM on jemalloc (so SAMM vs jemalloc isolates the arena); 1 GB, 1 vCPU, swap off; same seed; one container at a time.
- External benchmark = the realistic Markov traffic (what the demo runs).

**Visual:** the demo pair at k = 2.5, as memory over time: the baseline climbs
to ~1,005 MB and is OOM-killed at ~151 s; SAMM stays flat at ~970–990 MB.

**Numbers:** SAMM 918 req/s, 1.2% dropped, 0 failed; baseline (V8 on jemalloc)
732 req/s, 22.7% dropped, killed. ML coverage 98.7% of allocations served by
the planned capacity.

### 16. Internal validation (0:40)
**Headline:** "Controlled tests: higher capacity from less CPU per request,
and flat latency where the others queue."

**Say:** suggested by Dr. Pavel Panchekha. A closed loop measures capacity; an
open loop measures latency without queueing.

**Visual:** two small charts: throughput vs VUs (knees marked) and p99 vs
offered rate.

| | glibc | jemalloc | SAMM |
|---|---|---|---|
| Capacity | 767 req/s | 642 | **928** |
| CPU per request | 1.29 ms | 1.50 | **1.13** |
| Page faults per request | 12.4 | 86.0 | **7.8** |
| No-hold p99 at 510 req/s | 14.4 ms | 62.1 | **2.9** |

**Say:** the mechanism is fewer page faults (reused pages) and less GC work
(9,937 major GC cycles vs ~15,000), which means less CPU per request:
more capacity and less queueing. Laptop pilot, one run each.

### 17. Microbenchmark (0:20)
**Headline:** "The allocator itself is fast; most of the cost is the bridge
and touching fresh memory."

**On slide:** engine 10–100 ns per allocation; through N-API 0.8–12 µs; with
page writes, a process-sized allocation costs 36 µs on SAMM vs 0.95 ms on V8
with jemalloc.

### 18. Limitations, next steps, questions (0:20)
**On slide (one line each):**
- Limitations: laptop pilot runs (n = 1); 6 hand-labelled call sites; no misprediction correction; fixed β; huge pages and fragmentation unmeasured.
- Next: final study on a GCP T2D VM (no SMT), recalibrated and retrained there, n = 100.
- "These are what I'd most like your view on." → open the checklist.

---

## Backup slides (prepare, don't present)

1. Calibration tables: glibc, jemalloc, SAMM, 50–500 VUs.
2. Closed loop vs open loop, and why each is used.
3. k and Little's Law (rate ×k, hold ÷k).
4. GC breakdown (gc-control): minor GCs equal; major GC cycles 15k vs 9.9k (35% fewer); external memory at the end ~400 MB vs 111 MB (Sept 25 rerun).
5. Microbenchmark full table (no touch / with page writes).
6. Region and detach mechanism in detail (strong reference, `napi_detach_arraybuffer`, what a detached Buffer returns).
7. ML validation panel: separation 52×, closest margin 1.7×, coverage 98.7%; routing matrix 6/6.
8. The one-mmap layout: 2.64 GB of address space vs the 627 MB budget.

---

## Changes from your draft

1. **Problem 2:** Buffers are outside V8's *heap*, but V8's GC still decides when they're freed ("outside the V8 engine" isn't quite right). Dropped "fragmentation" because it isn't measured; used the measured effects instead (page faults, CPU, OOM).
2. **Problem 4:** reworded as "GC is the right default when lifetimes are unknown", a fair point that sets up the gap.
3. **Gap:** points 2–5 were your design, so they moved to the Idea slide as four challenges → four answers. The Gap slide now says only what's missing: LLAMA (learned, runtime, C++), per-request pools (deterministic, manual), V8 (lifetime blurred).
4. **Layer 2:** your Little's-law reading is right: λ is the arrival rate, so bump waste = arrival rate × lifetime spread × mean size.
5. **Layer 3:** the span covers the peak, but the guaranteed floor is the 90th percentile; bursts borrow shared headroom (spans 4× quota) under one 627 MB budget.
6. **Huge-page condition:** arena span ≥ 32 huge pages (64 MB), keeping rounding to ≤ 3.125%. Engagement unmeasured.
7. **Profiler:** it attaches a *finalizer* to each Buffer, not an object.
8. **One mmap limitation** (unfinished in the draft): the layout is fixed at compile time, so an arena can't grow past its span and a new workload needs a recompile.
9. **Reclamation limitation, corrected:** policy `none` means memory isn't returned when traffic *drops* (idle RSS stays high). Higher traffic can't grow the pool past 627 MB; the OOM risk under load comes from fallbacks outside the pool.
10. **Online "give back to V8":** the memory is handed to JavaScript as a zero-copy external Buffer through N-API.
11. **Allocation / identification / reclamation:** kept your three-part split as slides 12–14, with call-site lookup under allocation.
12. **Credit:** the gc-control write-up credits Dr. Panchekha's MemBalancer / heap-limit feedback for the GC experiment. If he also suggested internal validation, credit both.

## Rehearsal checklist

- [ ] Full run under 10:00 with a timer, twice.
- [ ] Every number on a slide matches this guide (or the checklist's numbers table).
- [ ] Each limitation is said on its slide, not only at the end.
- [ ] The architecture diagram highlights the right box on slides 6–14.
- [ ] Backup slides open quickly (know their slide numbers).
