# Consultation checklist: SAMM, with the author of LLAMA

LLAMA: Maas, Andersen, Isard, Javanmard, McKinley, Raffel, *Learning-based Memory
Allocation for C++ Server Workloads*, ASPLOS 2020.

---

## Presentation flow (10 min)

Story: **workload → observe → learn → execute → evaluate.** Reuse one
architecture diagram as the map. Follow `process.js` through sections 5, 7, 8
and 9. Skip definitions she already knows (bump/slab, k-means, THP).

| # | Section | Time | Depth |
|---|---|---|---|
| 1 | Problem | 0:30 | brief |
| 2 | Gap | 0:30 | brief, worded as a different design point |
| 3 | Idea | 0:20 | one sentence |
| 4 | Architecture | 0:30 | map only |
| 5 | Workload I: the server | 1:30 | **deep** |
| 6 | Workload II: Azure → k6 | 0:50 | medium |
| 7 | Profiler | 1:20 | **deep** (her field) |
| 8 | ML refinery | 0:50 | brief |
| 9 | SAMM: identification, allocation, reclamation | 1:50 | **deep** |
| 10 | Evaluation: external, internal, microbenchmark | 1:30 | medium |
| 11 | Close → questions | 0:20 | |

1. **Problem.** Node services in 1 GB containers; V8's GC is reactive: wasted
   CPU, latency spikes, OOM kills.
2. **Gap.** "LLAMA predicts lifetimes from calling context and adapts while
   running, for C++. We asked how far a fully ahead-of-time approach gets in a
   garbage-collected runtime." Don't call LLAMA slow.
3. **Idea.** Learn offline, compile to a fixed O(1) table, run it in a Zig allocator.
4. **Architecture.** Offline: trace → profile → ML → table. Runtime:
   Node → N-API → Zig engine.
5. **The server.** A synthetic microservice built to cover size, allocations
   per request, and lifetime:

| Endpoint | Size | Per request | Hold | Represents | Mix | SAMM |
|---|---|---|---|---|---|---|
| cache | 4 KB | 1 | none | small, short-lived | 25% | Bump |
| fetch | 1 MB fixed | 1 | log-normal (Azure) | held across an `await` | 25% | Slab |
| process | Azure payload, ≤ 16 MB | 1 | fixed 600 ms ±3% | large, held | 25% | Bump |
| ingest | 64 KB–1 MB | 1 | log-normal, base scale | medium, held | 10% | Bump |
| batch | 1–32 KB items, count from the payload draw | tens to hundreds | none | many small objects | 10% | Bump |
| aggregate | Azure payload, 64 KB–2 MB | 1 | none; kept in a global 50 MB FIFO store | escapes the request | 5% | System |

   - The hold is a `setTimeout` standing in for downstream I/O; the buffer
     stays alive across the `await`.
   - Every page is written, so memory and page faults are real.
   - Buffers are external memory, which drives V8's GC.
   - Each allocation passes an explicit call-site label (used by the profiler
     and by SAMM).
   - aggregate is the known escaping site: Layer 1's ground truth.
6. **Azure → k6.** Clean the trace (HTTP only, drop dormant, fix zeros, missing
   days) → 4-state Markov traffic (Idle/Ramp/Burst/Cooldown) mapped onto a
   min–max req/s range, seeded → log-normal holds fitted from the trace →
   memory percentiles normalized to the 1 GB P99 as the payload distribution →
   k6 open loop. k scales rate ×k and holds ÷k, so live memory is constant
   (Little's Law).
7. **Profiler.** N-API addon: `track()` stores hash, size, allocation time and
   request scope, and attaches a finalizer that records finalization time.
   Per request: scope start/end. Two lifespans: finalizer (finalization −
   allocation) and request scope (end − start), combined into
   **overhang = finalization − request end**. Censored records 0.003%. Off in
   every benchmark. **Caveat, said first:** finalization happens at GC time,
   not last use, so overhang mixes escape with GC delay (request-scoped sites
   11–25 ms; aggregate 1.3 s). Then ask her view (A2).
8. **ML refinery.** Layer 1: k-means on log overhang (elbow, K ≥ 3, top cluster
   → System). Layer 2: lower waste of bump vs slab. Layer 3: quotas (1 GB − V8
   − System − safety, × β; floors at p90; spans 4× quota). Compiler: hash
   table, arena layout, huge-page rule. `process.js`: overhang 24 ms → bump
   6.6 MB vs slab 366 MB waste → floor 225 MB, span 1.3 GB, huge pages on.
9. **SAMM.**
   - Identification: label → FNV-1a → table → arena; a miss → malloc. No
     model at runtime.
   - Allocation: one mmap (2.64 GB of address space); segmented bump (the
     floor is 8 segments, but the ring grows up to the span, 47–122 segments,
     whenever the next segment is still pinned; a segment is reused only once
     nothing in it is alive); slab (power-of-two classes,
     bitmaps); global 627 MB budget charged on first touch, refusals → malloc;
     huge pages per arena; zero-copy Buffers.
   - Reclamation: one region per request; scoped buffers have no finalizer and
     a strong reference; at response end each is detached and released
     (segment count − 1 or slab bit cleared), independent of GC. Caveat: a
     misrouted escaping buffer reads as empty.
10. **Evaluation.** Controls: glibc, jemalloc, SAMM on jemalloc; 1 GB / 1 vCPU
    / no swap; same seed; one container at a time.
    - External: k = 2.5 demo pair (baseline OOM-killed at ~151 s; SAMM 918 req/s, 1.2% dropped).
    - Internal: capacity 928 / 767 / 642 req/s; latency flat through 610 req/s
      vs queueing from 510; CPU per request 1.13 / 1.29 / 1.50 ms; faults per
      request 7.8 / 12.4 / 86; 35% fewer major GCs.
    - Microbenchmark: engine 10–100 ns; N-API path 0.8–12 µs; with page
      writes, process 36 µs vs 0.95 ms on jemalloc.
    - Laptop pilot runs; the final study runs on a T2D VM.
11. **Close.** Open points: 6 sites, hand-written labels, no misprediction
    correction, huge pages and fragmentation unmeasured. "Those are what I'd
    most like your view on." → Part A.

---

## Before the meeting

- [ ] Re-read LLAMA, focusing on: lifetime classes (an order of magnitude
      apart), how classes adapt at block granularity, how mispredictions are
      tolerated, how prediction cost is amortized, huge pages, and how
      fragmentation is defined and measured.
- [ ] Re-word how the README describes LLAMA. It currently says LLAMA relies
      on "live neural inference" that is too slow for allocation, but the
      paper amortizes prediction cost. Contrast the designs instead (table
      below).
- [ ] Prepare one slide comparing SAMM and LLAMA:

| | LLAMA | SAMM |
|---|---|---|
| Language | C++ servers, manual free | Node.js / V8, garbage-collected; Buffers live outside the JS heap |
| Allocation context | symbolized stack traces | an explicit label per allocation site (e.g. `'process.js:processRoute'`), FNV-1a hashed |
| Model | neural language model, lifetime classes | k-means on GC overhang (Layer 1) + minimum-waste rule (Layer 2) + quotas (Layer 3) |
| At runtime | predictions, cost amortized | no model: a compiled O(1) table |
| Unseen sites | generalizes to unseen contexts and binary versions | not in table → System (malloc) |
| Mispredictions | tolerated; classes adapt per block | not corrected; a misrouted escaping buffer is detached at request end, so its data reads as empty |
| Heap layout | huge-page blocks per lifetime class | one mmap; bump/slab arenas per stratum; region per request; global 627 MB budget |
| Headline metric | fragmentation (up to 78% less) | RSS, latency, throughput in a 1 GB container |

- [ ] Backup slides: demo pair, calibration tables (glibc/jemalloc/SAMM,
      50–500 VUs), gc-control GC breakdown, microbenchmark table,
      closed vs open loop, k and Little's Law, region/detach mechanism.
- [ ] Know what is NOT measured and say so plainly:
  - whether huge pages actually engage (the poller doesn't read `AnonHugePages` / `thp_fault_alloc`);
  - fragmentation, directly.

### Don't claim
- that LLAMA pays inference on every allocation;
- an "accuracy %" for the ML (there are no labels);
- that a misrouted buffer fails loudly (it reads as empty: silent data loss);
- a p99 win in the realistic benchmark (p99 is about the same for all three there; cause unknown);
- that huge pages help (unmeasured);
- **[review]** that SAMM uses less memory: it is bounded, not lower (peak RSS is equal to or higher than the baselines');
- **[review]** that the ML is what makes SAMM win (no ablations yet).

---

## Opening (30 s)

- [ ] Where I am: tool defense done, final study moving to a cloud VM.
- [ ] What I want: your view on the design against LLAMA, and on whether the
      evaluation is convincing before the final runs.

---

## Part A: questions for the LLAMA author

- [ ] **A1. Positioning.** Is our contrast with LLAMA fair? How would you
      describe LLAMA's runtime cost, and what is the real distinction?
      → Answer:
- [ ] **A2. Lifetime in a GC'd runtime.** In C++ a lifetime is free − malloc.
      In Node, "death" is when the GC runs the finalizer, so our feature
      (overhang = finalization − request end) mixes real escape with GC delay.
      Is that sound? Better ways to observe liveness in V8 (reachability at
      request end, weak references, a liveness check at region close)?
      → Answer:
- [ ] **A3. Lifetime classes.** LLAMA uses fixed classes an order of magnitude
      apart. We use k-means with a floor of K = 3 on 6 call sites. Is learning
      the strata defensible, or should we switch to fixed log-scale classes?
      → Answer:
- [ ] **A4. Mispredictions.** LLAMA tolerates them; SAMM doesn't. What is the
      minimal safe runtime correction for a region allocator: detect escape at
      region close and demote the site to System; copy on escape; something else?
      → Answer:
- [ ] **A5. Allocation context.** We label each allocation site by hand instead
      of using stack traces. Is that acceptable for a thesis? What do we lose
      (the same helper reached from different routes)? Is there a cheap way to
      get calling context in Node?
      → Answer:
- [ ] **A6. Drift and generalization.** LLAMA generalizes to new contexts and
      binary versions; our table is static. What drift experiment would
      convince you: shifted inputs (endpoint mix, payload sizes, holds) without
      retraining, or code changes? How did you evaluate robustness?
      → Answer:
- [ ] **A7. Ablation: what does the ML add?** Which comparisons convince best:
      every request-scoped site in one bump arena; all slab; no quotas (one
      shared pool); random strata; SAMM in full?
      → Answer:
- [ ] **A8. Fragmentation.** Should SAMM report fragmentation directly, beyond
      RSS / latency / throughput? How did you define and measure it?
      → Answer:
- [ ] **A9. Huge pages.** Our rule enables THP for arenas ≥ 64 MB (≤ 3.125% RSS
      rounding), but engagement is unmeasured. Is it worth it in a 1 GB
      container? How should we measure it (`AnonHugePages`, `thp_fault_alloc`,
      TLB misses)?
      → Answer:
- [ ] **A10. Evaluation method.** Should we add a trace-driven simulator that
      replays the profile against the arena model (it would also derive the
      pool ceiling, replacing β = 0.75)? Cloud VM with no SMT vs bare metal?
      How much repetition do allocator results need?
      → Answer:
- [ ] **A11. Baselines.** For allocator work: glibc and jemalloc enough, or
      also tcmalloc / mimalloc? Is a tuned-V8 baseline expected? (Our probe:
      heap-size flags didn't change GC counts, because external Buffer memory
      drives GC.)
      → Answer:
- [ ] **A12. Overhead framing.** The engine takes 10–100 ns per allocation, but
      the N-API bridge brings it to ~0.8–12 µs on the server path. Is "O(1)
      routing" a fair claim when the bridge dominates?
      → Answer:
- [ ] **A13. Contribution.** What would make this a contribution you'd find
      convincing? (Optional: a suitable venue.)
      → Answer:

---

## Part B: evaluation decisions

- [ ] **B1. Benchmark validity overall.** Realistic open-loop Markov benchmark
      + internal validation (closed loop for capacity, open loop for latency)
      + microbenchmark: is the combination sound? Is a `setTimeout` hold an
      acceptable stand-in for downstream waits?
      → Answer:
- [ ] **B2. Control.** glibc (stock Node, matches "Baseline V8"), jemalloc
      (SAMM runs on it, so it isolates the arena), or both? Both doubles the
      comparisons: Bonferroni goes from α ≈ 0.017 to ≈ 0.008. (The demo's
      baseline currently runs on jemalloc.)
      → Answer:
- [ ] **B3. Metric definitions.**
  - Throughput: capacity at saturation, or achieved rate under realistic load? (At k = 1.0 all three achieved ≈ 360 req/s.)
  - Latency: processing time, or end-to-end (mostly the artificial hold)?
  - RSS: container memory (includes page cache), or process RSS?
      → Answer:
- [ ] **B4. Load point.** The training load (k = 1.0, small differences), the
      saturation point (large differences, away from the training load), or both?
      → Answer:
- [ ] **B5. Statistics.** The same seed per pair makes it a paired design, so
      paired t / Wilcoxon signed-rank rather than independent tests. Should
      seeds vary across cycles? Report effect sizes and confidence intervals?
      Is n = 100 per condition, or in total?
      → Answer:
- [ ] **B6. What is one cycle?** Retrain every cycle, or one table for all runs
      (which leaves out the variance of the training step)?
      → Answer:
- [ ] **B7. Environment.** Laptop (WSL clock drift, host variance) → GCP Tau
      T2D (no SMT, server pinned to its own core). Acceptable? Report the
      laptop runs as pilot data?
      → Answer:
- [ ] **B8. Model changes after the tool defense.** May we fix the Layer 1
      System rule and derive the pool ceiling from data before the final
      study, or freeze the tool and list them as future work?
      → Answer:
- [ ] **B9. Memory at low load.** SAMM keeps its pool (416 MB at 50 VUs vs
      259 MB for glibc; reclaim policy `none`). Report it as a trade-off, or
      test a reclaim policy?
      → Answer:
- [ ] **B10. Timeline.** When are the VM results due, and what does the final
      defense expect?
      → Answer:

---

## If time is short

A1 → A4 → A7 → A2 → B2 → B3 → A6

## Before leaving

- [ ] Read back the decisions in your own words, and note who decides each
      open one.
- [ ] Ask whether you may follow up by email with results.

---

## [review] Provisional conclusion (from the pilot data)

Laptop pilot runs, one run per condition. Review before using any of this.

**Verdict:** the core idea holds up: freeing request-scoped buffers
deterministically at request end, from a bounded arena pool, makes a 1 GB Node
service faster under load and keeps it alive where the baselines die. Not yet
shown: that SAMM uses *less* memory; that the ML, rather than simpler rules,
is what makes it work; how much of the gain over jemalloc is page retention.

| Thesis metric | Verdict | Evidence |
|---|---|---|
| Throughput | Supported, under load | At saturation 878.8 req/s vs 773.8 (glibc, +14%) and 663.6 (jemalloc, +32%); CPU per request −12% / −25%. At k = 1.0 throughput is equal (not saturated) but CPU is 24–31% lower. |
| Tail latency | Supported in the controlled test; not in the realistic one | No-hold p99 at 510 req/s: 2.9 vs 14.4 / 62.1 ms; flat through 610; medians equal. Realistic benchmark at k = 1.0: processing p95 better (2.25 vs 8.5 / 11.5 ms), p99 the same (~460–490 ms). |
| Peak RSS | Not supported as "lower"; supported as "bounded" | Equal or higher: 876 vs 825 / 696 MB (k = 1.0); 855 vs 854 / 756 (saturation); 416 vs 259 (50 VUs). But it plateaus under the pool cap while the baseline climbs until killed: SAMM survived 10 of 11 demo runs, the baseline 2 of 10. |

**Is it just the "no reclaim" policy?**
- **vs jemalloc: partly, not yet ruled out.** 84% of the saving is kernel time (86 vs 7.8 faults per request). SAMM keeps its pages; jemalloc gives them back and re-faults them, which is also why jemalloc has the lowest RSS. A page-keeping jemalloc hasn't been tested.
- **vs glibc: no.** glibc faults little (12.4 vs 7.8), yet SAMM wins by 14%, 66% of it user time: fewer major GC cycles (9,937 vs 15,251), far less external memory waiting for collection (111 vs ~400 MB), no finalizers.
- **Microbenchmark, no page faults involved:** batch allocation 674 ns via SAMM vs 2,224 ns via V8, over half of V8's cost (1,202 ns) being GC pauses.
- **Survival is not a reclaim effect:** keeping pages adds memory. The baselines die because, with the CPU saturated, the GC falls behind and buffers pile up; SAMM frees at request end, inside a capped pool.
- If asked "is SAMM hiding memory from V8?": SAMM frees those buffers itself at request end, so there's nothing for V8 to collect; the JavaScript wrappers are still collected (minor GCs equal, ~13,000).

**Do the profiler and the refinery do work?** Their decisions are correct and
consequential for this workload; their value over simpler rules is unproven.

| Component | Demonstrably did | Unproven |
|---|---|---|
| Profiler | Overhang separated the escaping site (1.3 s) from request-scoped ones (11–25 ms) | Whether it works when escape is short, near the GC delay |
| Layer 1 (k-means) | Sent exactly aggregate to malloc (6/6 against the code) | With 6 points and one outlier, a fixed threshold makes the same call |
| Layer 2 (waste model) | Slab for process would waste 366 MB vs 6.6 MB for bump; chose correctly everywhere | A cost model, not ML; value over "all bump" not measured |
| Layer 3 (quotas) | A budget that held (0.17% fallback at k = 1.0); it is what caps memory | Value over a uniform split or one shared pool; β hand-picked |

**To make it solid:** a page-keeping jemalloc (`MALLOC_CONF=oversize_threshold:0,dirty_decay_ms:-1,muzzy_decay_ms:-1`;
stock glibc already keeps its pages, and `glibc-tuned` does the opposite),
SAMM with reclaim `dontneed`, and ML ablations (Layer 2 off,
Layer 3 off, Layer 1 as a fixed threshold, aggregate forced into SAMM). See
PENDING.md, Part B, B5.

**Draft wording:**
> "Pilot results on a single laptop suggest that request-scoped, deterministic
> reclamation through a profile-guided arena allocator reduces CPU per request
> by 12–31% in a 1 GB Node.js service, through fewer page faults and less GC
> work. It yields 14% higher saturated throughput than stock Node, much tighter
> tail latency under load, and survival at load levels where the baselines are
> OOM-killed. Memory use is bounded and predictable, but not lower: SAMM holds
> its pool resident, trading memory for fewer page faults. Whether the
> profile-guided decisions outperform simpler rules, and how much of the
> advantage over jemalloc comes from page retention, remain to be tested with
> ablations in the final study."

---

## Results tables (backup)

### Quick numbers

| | glibc | jemalloc | SAMM |
|---|---|---|---|
| Capacity (laptop calibration, Oct 3) | 767 req/s | 642 req/s | 928 req/s |
| CPU per request at saturation | 1.287 ms | 1.502 ms | 1.132 ms |
| Page faults per request | 12.4 | 86.0 | 7.8 |
| Latency, no-hold p99 at 510 req/s | 14.4 ms | 62.1 ms | 2.9 ms |
| Major GC cycles (gc-control rerun, k = 1.0) | 15,251 | 14,887 | 9,937 |
| Demo pair, k = 2.5 (Oct 8; baseline on jemalloc) | — | 732 req/s, OOM-killed at ~151 s | 918 req/s, 1.2% dropped, 0 failed |

ML validation: separation 52×, closest margin 1.7×, coverage 98.7%; routing
matrix 6/6 on the diagonal.

All runs below are on the laptop (Ryzen 5 6600H, Windows + WSL2), one run per
allocator unless stated. They are pilot data for the final study on the VM.

---

### 1. Internal validation

**Common setup:** `internal-validation/run.sh`; containers 1 GB, swap off,
1 vCPU; one container at a time; seed 20250911; load point k = 2.5
(`HOLD_SCALE` 1.6, process hold 240 ms); glibc = stock Node, jemalloc =
`LD_PRELOAD`, SAMM = the SAMM image on jemalloc. Host probe before the Oct 3
runs: k6 startup 62.1 s, V8 1.04× / 1.04×, GC 1.03× (pass).

#### 1a. Calibration (Oct 3): closed loop, 50 → 500 VUs

Each step 45 s: 15 s warmup (discarded), 30 s measured, then a 10 s gap.
Dropped iterations: 0 in every run. Knees: glibc and jemalloc at 250 VUs,
SAMM at 300 (first step at ≥ 98% CPU).

Columns: **req/s, completed, failed** from k6 (success = HTTP 2xx/3xx);
**CPU, user/kernel ms per request, faults per request, peak MB,
throttled/s** from the container's cgroup (`cpu.stat`, `memory.stat`,
`memory.current`; throttled/s = 100 ms slices per second spent at the 1-vCPU
cap, 10 at most); **proc** = processing time in ms (response − hold; this
run was before the timing fix); **resp** = full response time in ms,
including the hold; **VUs ÷ req/s** = Little's Law prediction of the mean
response time in ms.

**glibc**

| VUs | req/s | completed | failed | CPU | user ms/req | kernel ms/req | CPU ms/req | faults/req | peak MB | throttled/s | proc p50 | p95 | p99 | max | resp p50 | resp p99 | resp mean | VUs ÷ req/s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 50 | 155.0 | 4,650 | 0 | 25.0% | 1.363 | 0.253 | 1.615 | 18.4 | 259 | 0.0 | 0.8 | 2.1 | 4.8 | 24.6 | 235 | 2,382 | 323 | 323 |
| 100 | 324.2 | 9,727 | 0 | 49.9% | 1.332 | 0.208 | 1.540 | 18.0 | 367 | 0.1 | 0.7 | 2.6 | 6.8 | 26.2 | 234 | 2,238 | 308 | 308 |
| 150 | 487.0 | 14,610 | 0 | 67.9% | 1.247 | 0.147 | 1.394 | 6.3 | 474 | 0.6 | 0.7 | 2.4 | 6.3 | 53.6 | 234 | 2,255 | 309 | 308 |
| 200 | 638.3 | 19,150 | 0 | 89.9% | 1.233 | 0.176 | 1.409 | 11.5 | 564 | 4.8 | 0.8 | 14.0 | 39.6 | 119.4 | 235 | 2,361 | 314 | 313 |
| 250 | 746.4 | 22,392 | 0 | 99.6% | 1.153 | 0.181 | 1.334 | 12.9 | 690 | 10.0 | 11.4 | 68.1 | 110.0 | 240.6 | 244 | 2,416 | 336 | 335 |
| 300 | 767.3 | 23,020 | 0 | 99.5% | 1.098 | 0.198 | 1.297 | 15.1 | 755 | 10.0 | 74.4 | 165.8 | 224.3 | 316.9 | 294 | 2,503 | 391 | 391 |
| 350 | 740.3 | 22,208 | 0 | 99.7% | 1.141 | 0.206 | 1.347 | 16.8 | 848 | 10.0 | 153.3 | 300.5 | 364.7 | 590.7 | 391 | 2,600 | 472 | 473 |
| 400 | 740.9 | 22,226 | 0 | 99.6% | 1.134 | 0.210 | 1.344 | 13.6 | 894 | 10.0 | 206.6 | 403.1 | 475.8 | 688.6 | 424 | 2,652 | 539 | 540 |
| 500 | 756.2 | 22,686 | 0 | 99.6% | 1.141 | 0.176 | 1.316 | 9.3 | 1,021 | 10.0 | 274.8 | 549.4 | 658.1 | 924.2 | 503 | 2,799 | 606 | 661 |

**jemalloc**

| VUs | req/s | completed | failed | CPU | user ms/req | kernel ms/req | CPU ms/req | faults/req | peak MB | throttled/s | proc p50 | p95 | p99 | max | resp p50 | resp p99 | resp mean | VUs ÷ req/s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 50 | 154.7 | 4,642 | 0 | 30.3% | 1.396 | 0.562 | 1.959 | 114.1 | 237 | 0.1 | 0.9 | 5.2 | 9.9 | 31.3 | 236 | 2,382 | 324 | 323 |
| 100 | 323.1 | 9,693 | 0 | 56.1% | 1.281 | 0.455 | 1.737 | 92.7 | 353 | 0.2 | 0.8 | 5.3 | 10.4 | 33.7 | 235 | 2,240 | 308 | 310 |
| 150 | 484.9 | 14,547 | 0 | 78.4% | 1.215 | 0.402 | 1.617 | 87.6 | 418 | 1.9 | 0.9 | 8.3 | 18.2 | 79.1 | 235 | 2,254 | 309 | 309 |
| 200 | 616.9 | 18,507 | 0 | 96.6% | 1.160 | 0.407 | 1.566 | 82.7 | 500 | 7.9 | 4.8 | 54.6 | 83.8 | 166.6 | 238 | 2,357 | 324 | 324 |
| 250 | 624.5 | 18,734 | 0 | 99.7% | 1.142 | 0.454 | 1.597 | 86.0 | 601 | 10.0 | 63.5 | 212.5 | 698.1 | 1,124.8 | 286 | 2,427 | 398 | 400 |
| 300 | 642.0 | 19,261 | 0 | 99.6% | 1.120 | 0.431 | 1.552 | 81.1 | 665 | 10.0 | 151.4 | 275.3 | 340.1 | 479.9 | 387 | 2,525 | 466 | 467 |
| 350 | 631.7 | 18,950 | 0 | 99.5% | 1.155 | 0.421 | 1.576 | 80.4 | 681 | 10.0 | 229.6 | 418.1 | 478.4 | 659.1 | 460 | 2,664 | 551 | 554 |
| 400 | 620.1 | 18,603 | 0 | 99.7% | 1.132 | 0.475 | 1.607 | 91.5 | 758 | 10.0 | 297.3 | 543.4 | 678.8 | 907.2 | 529 | 2,736 | 621 | 645 |
| 500 | 628.6 | 18,859 | 0 | 99.8% | 1.139 | 0.449 | 1.588 | 87.8 | 833 | 10.0 | 357.0 | 647.1 | 760.3 | 963.8 | 599 | 2,816 | 676 | 795 |

**SAMM**

| VUs | req/s | completed | failed | CPU | user ms/req | kernel ms/req | CPU ms/req | faults/req | peak MB | throttled/s | proc p50 | p95 | p99 | max | resp p50 | resp p99 | resp mean | VUs ÷ req/s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 50 | 154.2 | 4,626 | 0 | 25.5% | 1.494 | 0.160 | 1.655 | 6.5 | 416 | 0.1 | 0.9 | 9.0 | 26.5 | 55.8 | 236 | 2,384 | 325 | 324 |
| 100 | 324.6 | 9,738 | 0 | 34.9% | 0.937 | 0.138 | 1.075 | 3.9 | 473 | 0.0 | 0.6 | 1.7 | 2.6 | 25.8 | 234 | 2,234 | 307 | 308 |
| 150 | 486.8 | 14,603 | 0 | 54.4% | 0.973 | 0.146 | 1.118 | 3.6 | 749 | 0.1 | 0.7 | 2.0 | 3.3 | 38.8 | 234 | 2,261 | 309 | 308 |
| 200 | 641.7 | 19,252 | 0 | 68.5% | 0.943 | 0.124 | 1.067 | 3.1 | 787 | 0.5 | 0.6 | 2.1 | 3.6 | 32.4 | 234 | 2,358 | 312 | 312 |
| 250 | 792.8 | 23,783 | 0 | 86.7% | 0.984 | 0.110 | 1.094 | 3.2 | 836 | 3.4 | 0.7 | 6.7 | 27.1 | 88.4 | 235 | 2,421 | 316 | 315 |
| 300 | 892.9 | 26,787 | 0 | 99.5% | 0.991 | 0.124 | 1.115 | 3.3 | 874 | 9.8 | 11.0 | 62.7 | 104.5 | 224.1 | 244 | 2,486 | 336 | 336 |
| 350 | 871.3 | 26,138 | 0 | 99.4% | 1.023 | 0.118 | 1.141 | 4.0 | 908 | 10.0 | 82.8 | 167.6 | 198.5 | 301.6 | 299 | 2,581 | 401 | 402 |
| 400 | 927.7 | 27,830 | 0 | 99.6% | 0.967 | 0.107 | 1.074 | 4.6 | 916 | 10.0 | 102.5 | 222.4 | 261.0 | 359.9 | 317 | 2,601 | 431 | 431 |
| 500 ✝ | 122.1 | 3,663 | 558,047 | — | — | — | — | — | 950 | — | — | — | — | — | — | — | — | — |

✝ SAMM served ~850–960 req/s for the first 19 s of the 500-VU step, then was
OOM-killed at 19.4 s, 4.4 s into the measured window. So the row's 122 req/s
counts only those ~4 s, and its 558,047 failures are instant connection errors
after the kill. In the last 2–3 s, page faults jumped to 15–26k/s and kernel
CPU to 14–21%: overflow allocations going to malloc outside the full pool.

Recommendations from this run: SATURATION_VUS = the next tested step above the
highest knee that every config ran safely (peak ≤ 90% of 1 GB) = **350**.
Latency rates = doubling up to 80% of the lowest capacity (jemalloc, 642),
plus 80% and 95% points = 20, 40, 80, 160, 320, **510, 610** req/s.

#### 1b. Throughput at saturation (Oct 3): closed loop, 350 VUs

60 s warmup, 180 s measured, 30 s cooldown.

| | glibc | jemalloc | SAMM |
|---|---|---|---|
| Throughput (measured window) | 773.8 req/s | 663.6 req/s (−14.2%) | **878.8 req/s (+13.6%)** |
| Dropped / failed | 0 / 0 | 0 / 0 | 0 / 0 |
| Per-second CV / drift | 7.1% / +0.2% | 6.0% / +0.1% | 6.9% / +0.9% |
| CPU (of 1 vCPU) | 99.6% | 99.6% | 99.5% |
| User / kernel (of 1 vCPU) | 85.3% / 14.3% | 70.2% / 29.4% | 87.8% / 11.7% |
| CPU per request (user + kernel) | 1.287 ms (1.102 + 0.185) | 1.502 ms (1.058 + 0.443) | **1.132 ms (0.999 + 0.133)** |
| Page faults per request | 12.4 | 86.0 | **7.8** |
| Peak memory | 854 MB | 756 MB | 855 MB |
| Verdict | VALID | VALID | VALID |

Valid = no drops, no failures in the window, no OOM kill, CPU ≥ 90%.

#### 1c. Latency sweep (Oct 3): open loop, 20 → 610 req/s

Each rate 60 s (10 s warmup discarded), then a 15 s drain. Dropped and failed:
0 at every rate. A step is **flat** if its p95 is ≤ 1.5× the lowest rate's,
its per-second median drifts ≤ 0.5 × that p95 (at least 5 ms), and nothing
dropped.

All endpoints, processing time (ms):

| Config | Offered | Achieved | n | p50 | p90 | p95 | p99 | p99.9 | p95 ratio | Drift ms | Verdict |
|---|---|---|---|---|---|---|---|---|---|---|---|
| glibc | 20 | 20.0 | 1,001 | 1.44 | 2.52 | 2.97 | 6.08 | 12.5 | 1.00 | -0.03 | flat |
| glibc | 40 | 40.0 | 2,001 | 1.07 | 1.95 | 2.31 | 4.73 | 10.3 | 0.78 | -0.05 | flat |
| glibc | 80 | 80.0 | 4,000 | 0.87 | 1.59 | 2.23 | 4.90 | 9.5 | 0.75 | 0.03 | flat |
| glibc | 160 | 160.0 | 8,000 | 0.82 | 1.89 | 3.11 | 8.27 | 17.3 | 1.05 | 0.01 | flat |
| glibc | 320 | 320.0 | 16,001 | 0.71 | 1.70 | 2.62 | 8.96 | 25.9 | 0.88 | -0.04 | flat |
| glibc | 510 | 510.0 | 25,502 | 0.65 | 2.43 | 5.59 | 18.94 | 53.1 | 1.88 | 1.11 | **not flat**: p95 x1.9 |
| glibc | 610 | 610.0 | 30,501 | 0.72 | 11.71 | 23.20 | 55.77 | 105.0 | 7.81 | -0.66 | **not flat**: p95 x7.8 |
| jemalloc | 20 | 20.0 | 1,001 | 1.55 | 4.76 | 6.09 | 8.51 | 11.0 | 1.00 | -0.25 | flat |
| jemalloc | 40 | 40.0 | 2,001 | 1.18 | 3.70 | 5.72 | 9.00 | 12.6 | 0.94 | 0.25 | flat |
| jemalloc | 80 | 80.0 | 4,001 | 0.91 | 3.33 | 5.04 | 8.84 | 15.6 | 0.83 | 0.09 | flat |
| jemalloc | 160 | 160.0 | 8,000 | 0.84 | 3.49 | 5.28 | 11.33 | 35.9 | 0.87 | 0.01 | flat |
| jemalloc | 320 | 320.0 | 16,001 | 0.80 | 3.81 | 5.83 | 11.32 | 26.9 | 0.96 | 0.16 | flat |
| jemalloc | 510 | 510.0 | 25,500 | 0.89 | 11.35 | 30.99 | 90.61 | 143.4 | 5.09 | -13.16 | **not flat**: p95 x5.1 |
| jemalloc | 610 | 610.0 | 30,501 | 3.93 | 38.73 | 57.15 | 191.00 | 316.1 | 9.39 | 0.92 | **not flat**: p95 x9.4 |
| SAMM | 20 | 20.0 | 1,001 | 1.51 | 2.67 | 3.11 | 4.71 | 8.0 | 1.00 | -0.29 | flat |
| SAMM | 40 | 40.0 | 2,000 | 1.10 | 1.92 | 2.36 | 3.18 | 4.0 | 0.76 | -0.06 | flat |
| SAMM | 80 | 80.0 | 4,000 | 0.87 | 1.45 | 1.81 | 2.80 | 3.7 | 0.58 | 0.03 | flat |
| SAMM | 160 | 160.0 | 8,001 | 0.79 | 1.39 | 1.74 | 2.64 | 3.5 | 0.56 | 0.16 | flat |
| SAMM | 320 | 320.0 | 16,001 | 0.69 | 1.33 | 1.71 | 2.75 | 13.8 | 0.55 | -0.10 | flat |
| SAMM | 510 | 510.0 | 25,502 | 0.59 | 1.30 | 1.72 | 3.02 | 26.0 | 0.55 | 0.04 | flat |
| SAMM | 610 | 610.0 | 30,502 | 0.58 | 1.39 | 1.90 | 4.25 | 31.6 | 0.61 | 0.06 | flat |

Split by endpoint type (ms). **No-hold** (cache, batch, aggregate) is exact.
**Held** (fetch, ingest, process) has the hold subtracted. This run was before
the timing fix, so "held at 0" is the share wrongly clamped to 0.

| Config | Offered | No-hold n | p50 | p95 | p99 | Held n | p50 | p95 | p99 | Held at 0 |
|---|---|---|---|---|---|---|---|---|---|---|
| glibc | 20 | 439 | 1.36 | 2.39 | 3.51 | 562 | 1.65 | 3.32 | 6.78 | 0.5% |
| glibc | 40 | 799 | 1.08 | 2.27 | 3.38 | 1,202 | 1.05 | 2.37 | 5.82 | 3.8% |
| glibc | 80 | 1,570 | 0.93 | 2.24 | 3.54 | 2,430 | 0.71 | 2.22 | 5.76 | 11.5% |
| glibc | 160 | 3,144 | 0.88 | 2.60 | 5.14 | 4,856 | 0.63 | 3.85 | 9.17 | 15.0% |
| glibc | 320 | 6,404 | 0.81 | 2.28 | 6.30 | 9,597 | 0.47 | 3.34 | 10.21 | 23.0% |
| glibc | 510 | 10,283 | 0.73 | 3.24 | 14.36 | 15,219 | 0.46 | 7.10 | 21.26 | 25.6% |
| glibc | 610 | 12,222 | 0.75 | 15.84 | 41.97 | 18,279 | 0.66 | 27.24 | 64.44 | 21.9% |
| jemalloc | 20 | 439 | 1.40 | 3.32 | 5.30 | 562 | 1.82 | 6.78 | 9.12 | 1.1% |
| jemalloc | 40 | 799 | 1.15 | 2.69 | 4.32 | 1,202 | 1.21 | 6.37 | 9.56 | 3.3% |
| jemalloc | 80 | 1,570 | 0.93 | 2.74 | 5.21 | 2,431 | 0.87 | 5.72 | 10.43 | 7.8% |
| jemalloc | 160 | 3,144 | 0.87 | 3.00 | 6.94 | 4,856 | 0.76 | 6.22 | 12.81 | 13.0% |
| jemalloc | 320 | 6,404 | 0.83 | 3.41 | 7.44 | 9,597 | 0.69 | 6.88 | 12.47 | 18.1% |
| jemalloc | 510 | 10,282 | 0.83 | 17.86 | 62.13 | 15,218 | 1.00 | 40.63 | 102.46 | 17.7% |
| jemalloc | 610 | 12,223 | 1.43 | 41.14 | 126.81 | 18,278 | 7.17 | 68.58 | 225.27 | 10.1% |
| SAMM | 20 | 439 | 1.44 | 3.36 | 4.86 | 562 | 1.60 | 2.95 | 3.62 | 1.1% |
| SAMM | 40 | 799 | 1.18 | 2.78 | 3.49 | 1,201 | 1.03 | 2.18 | 2.65 | 4.7% |
| SAMM | 80 | 1,570 | 0.94 | 2.37 | 3.10 | 2,430 | 0.68 | 1.71 | 2.49 | 11.6% |
| SAMM | 160 | 3,144 | 0.87 | 2.06 | 2.80 | 4,857 | 0.56 | 1.61 | 2.43 | 15.3% |
| SAMM | 320 | 6,404 | 0.82 | 1.91 | 2.85 | 9,597 | 0.44 | 1.60 | 2.70 | 23.5% |
| SAMM | 510 | 10,283 | 0.71 | 1.85 | 2.90 | 15,219 | 0.32 | 1.62 | 3.16 | 29.6% |
| SAMM | 610 | 12,223 | 0.69 | 2.00 | 3.43 | 18,279 | 0.33 | 1.79 | 4.59 | 30.7% |

Queueing begins at **510 req/s** for glibc and jemalloc. SAMM is flat through
610; its own onset was not reached (see PENDING.md, Part A, A1 step 5).

#### 1d. Timing-fix check (Oct 4, glibc only)

| Offered | Held at 0, before the fix (Oct 3) | Held at 0, after the fix (Oct 4) |
|---|---|---|
| 160 req/s | 15.0% | **0.7%** |
| 320 req/s | 23.0% | **2.9%** |

Use this run for the clamp share only. That day the VM clock ran at 92.7% and
the wall clock jumped ~2.6 s every ~31 s, which put held p99 at ~2.8 s and the
"achieved" rate at 361 req/s for 320 offered.

#### 1e. SAMM with its own counters (Oct 4): closed loop, `POLL_SAMM_STATS=1`

Allocations = reclaimed at region close + sent to malloc by design
(aggregate) + fallbacks. Every fallback was a budget refusal.

| VUs | req/s | CPU | Peak MB | Pool committed | Allocations | Fallbacks | Fallback share | Bump blocked | Slab exhausted | Bump resets | Grows |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 50 | 141.4 | 21.7% | 420 | 317.2 MB | 178,714 | 0 | 0.00% | 0 | 0 | 1,139 | 0 |
| 100 | 290.9 | 37.6% | 478 | 372.9 MB | 358,419 | 0 | 0.00% | 0 | 0 | 2,329 | 4 |
| 150 | 441.4 | 54.0% | 619 | 510.8 MB | 575,847 | 0 | 0.00% | 0 | 0 | 3,564 | 7 |
| 200 | 589.8 | 69.3% | 781 | **626.9 MB (full)** | 747,029 | 672 | 0.09% | 60 | 612 | 4,730 | 0 |
| 250 | 630.7 | 93.6% | 822 | 626.9 MB | 780,800 | 1,520 | 0.19% | 167 | 1,353 | 4,954 | 0 |
| 300 | 624.9 | 99.4% | 857 | 626.9 MB | 748,247 | 1,929 | 0.26% | 290 | 1,639 | 4,734 | 0 |
| 350 | 437.2 | 99.3% | 875 | 626.9 MB | 320,798 | 829 | 0.26% | 189 | 640 | 1,996 | 0 |
| 400 | 315.9 | 100.0% | 893 | 626.9 MB | 97,183 | 298 | 0.31% | 91 | 207 | 620 | 0 |
| 500 ✝ | — | — | 899 → 978 | no counters | | | | | | | |

✝ OOM-killed (exit 137). `/samm/stats` stopped answering for the last 34 s.
The cgroup shows faults per request rising from 10.9 to 15.9, then 25–35k
faults/s, and memory going from 899 to 978 MB before the kill. Detach failures
and exhausted regions: 0 throughout. Use this table for the counters only:
the Oct 4 host had the slow VM clock and the page-write anomaly, and polling
adds one request per second, so its req/s (falling at 350–400 VUs) and
latencies aren't comparable with Oct 3.

---

### 2. External validation (realistic Markov traffic)

#### 2a. Demo settings

| k | Peak arrival rate (MAX_RPS) | Process hold | HOLD_SCALE (other holds) |
|---|---|---|---|
| 1.0 (profiled) | 500 req/s | 600 ms | 4 |
| 1.5 | 750 | 400 | 2.667 |
| 2.0 | 1,000 | 300 | 2 |
| **2.5 (demo)** | **1,250** | **240** | **1.6** |

| Setting | Value |
|---|---|
| Scenario | `samm-load-test.js`, open loop, 4-state Markov traffic from the Azure trace |
| Arrival rate | 5 → MAX_RPS req/s, following the seeded state walk |
| VU pool | 400 pre-allocated, 1,400 max |
| Duration / seed | 3 min of load (after ~60 s of k6 start-up) / 2025 |
| Container | 1 GB, swap off, 1 vCPU, jemalloc preloaded in both modes |
| SAMM | reclaim policy `none`, warmup off, `SAMM_ALLOW_WORKLOAD_MISMATCH` at k ≠ 1.0 |
| Collector | samples once a second; rolling p95 over 5 s windows |

#### 2b. The Oct 8 pair (k = 2.5): the clock-clean demo

| | Baseline (V8 on jemalloc) | SAMM |
|---|---|---|
| Requests | 131,830 | 168,320 |
| Throughput (k6 summary) | 732 req/s | **918 req/s** |
| Mean req/s while running (collector) | 694 | 920 |
| Dropped | 38,625 (22.7%) | 2,130 (1.2%) |
| Failed | 19.6% (mostly after the kill) | 0% |
| End-to-end p95 / p99 | 1,660 / 2,836 ms | 1,365 / 2,506 ms |
| Allocation-path p95 / p99 | 646 / 808 ms | **110 / 209 ms** |
| Peak memory | 1,005 MB sampled; killed | 991 MB sampled; 1,018.5 MB `memory.peak` |
| Mean CPU during load | 99.7% | 97.7% |
| Peak VUs used | 579 | 400 |
| Page faults per request | 93.0 | **3.7** |
| Container | **OOM-killed after ~151 s of load** | survived |

The baseline's latency figures cover only the part of the run it survived.

Peak VUs is an outcome, not a setting: in an open loop, VUs in use = requests
in flight = arrival rate × response time. The baseline's climbed from ~360 to
571 as its processing p95 rose from ~320 to 814 ms; SAMM stayed at ~290–350
while serving ~30% more req/s. Going past the 400 pre-allocated VUs makes k6
create new ones mid-run, which likely adds to the baseline's drops.

When the drops happen: 1,102 of SAMM's 2,130 drops (52%) came in the first
7 s (cold start: the pool filling, all 400 VUs busy at 1 s); afterwards ~6
per second in short bursts (~0.6% of requests). The baseline dropped ~200–400
every second throughout, because its ~700 req/s capacity is below the offered
rate.

SAMM's own counters at the end of the run: coverage **98.71%** (7,135,835
allocations; 92,372 fallbacks, all budget refusals: 70,567 bump segments
blocked + 21,805 slab classes exhausted); 8,495 sent to malloc by design
(aggregate, ≈ 5% of requests); pool committed 627.1 of 627.1 MB; 48,480 bump
segment resets; 32 grows; 168,345 regions opened, 168,344 closed; detach
failures 0. No wall-clock jumps during either run; the VM clock measured
99.99% that evening.

#### 2c. Every recorded demo run (k = 2.5, seed 2025, 3 min, this laptop)

The label is the collector's `--label`, not a different machine.

| Finished (UTC) | Collector label | Allocator | req/s | Dropped | Failed | e2e p95 / p99 (ms) | alloc p95 / p99 (ms) | Peak memory (MB) | Survived |
|---|---|---|---|---|---|---|---|---|---|
| 2026-09-20 07:21 | samm-demo | baseline | 703 | 25.8% | 11.3% | 1763 / 2955 | 717 / 917 | — | **no** |
| 2026-09-20 07:27 | samm-demo | SAMM | 900 | 2.5% | 0.0% | 1393 / 2537 | 180 / 271 | 938.3 | yes |
| 2026-09-20 13:12 | SAMM | baseline | 656 | 28.3% | 0.0% | 1865 / 3066 | 765 / 975 | 1019.4 | yes |
| 2026-09-20 13:31 | SAMM | SAMM | 878 | 5.0% | 0.0% | 1431 / 2592 | 253 / 391 | 951.6 | yes |
| 2026-09-22 03:21 | BASELINE | SAMM | 838 | 1.7% | 0.0% | 1501 / 3452 | 147 / 2787 | 915.4 | yes |
| 2026-09-22 03:26 | BASELINE | baseline | 643 | 26.3% | 14.9% | 2017 / 4529 | 767 / 3683 | — | **no** |
| 2026-09-22 04:26 | BASELINE | SAMM | 822 | 1.2% | 0.0% | 1467 / 3756 | 111 / 3344 | 918.2 | yes |
| 2026-09-22 04:31 | BASELINE | baseline | 604 | 30.6% | 10.7% | 2180 / 4682 | 950 / 3778 | — | **no** |
| 2026-09-24 22:18 | BASELINE | baseline | 537 | 41.3% | 0.0% | 2046 / 3407 | 994 / 1310 | 1024.0 | yes |
| 2026-09-24 22:23 ‡ | BASELINE | SAMM | 715 | 24.5% | 19.2% | 1601 / 2823 | 600 / 837 | — | **no** |
| 2026-09-24 23:08 | BASELINE | baseline | 660 | 29.1% | 0.7% | 1903 / 3115 | 842 / 1109 | — | **no** |
| 2026-09-24 23:12 | BASELINE | SAMM | 896 | 1.9% | 0.0% | 1406 / 2557 | 172 / 487 | 917.6 | yes |
| 2026-09-30 02:14 | SAMM | SAMM | 841 | 4.9% | 0.0% | 1510 / 2758 | 288 / 1301 | 921.2 | yes |
| 2026-09-30 02:18 | SAMM | baseline | 696 | 22.6% | 19.4% | 1881 / 3196 | 709 / 2067 | — | **no** |
| 2026-09-30 02:51 | SAMM | SAMM | 852 | 3.6% | 0.0% | 1506 / 2859 | 224 / 1575 | 897.1 | yes |
| 2026-09-30 02:56 | SAMM | baseline | 671 | 25.7% | 9.6% | 1980 / 3363 | 788 / 2176 | — | **no** |
| 2026-09-30 07:56 | SAMM | baseline | 655 | 25.4% | 3.8% | 2164 / 3913 | 824 / 2968 | — | **no** |
| 2026-09-30 08:05 | SAMM | SAMM | 839 | 0.6% | 0.0% | 1456 / 3112 | 71 / 2302 | 933.8 | yes |
| 2026-10-01 04:32 § | SAMM | SAMM | 745 | 18.2% | 0.0% | 1700 / 2946 | 559 / 736 | 1018.4 | yes |
| 2026-10-08 13:31 | SAMM | baseline | 732 | 22.7% | 19.6% | 1660 / 2836 | 646 / 808 | — | **no** |
| 2026-10-08 13:35 | SAMM | SAMM | 918 | 1.2% | 0.0% | 1365 / 2506 | 110 / 209 | 1018.5 | yes |

Survived: SAMM 10 of 11, baseline 2 of 10. ‡ During the host slowdown, before
the Sept 25 reboot. § Wall-clock jumps of up to 2.4 s during the run.
Clock-clean pairs: Sept 25 (09-24 23:08 / 23:12 UTC) and Oct 8. The two
aborted 0-request runs (Oct 8, 13:50 UTC) are left out.

#### 2d. Realistic benchmark at the training load (gc-control rerun, Sept 25)

k = 1.0: MAX_RPS 500, process hold 600 ms, HOLD_SCALE 4, VUs 400 / 1,400,
10 min, seed 20250911, 1 GB / 1 vCPU, reclaim `none`, warmup off. A clean pass
gives every metric; a second, instrumented pass gives the GC numbers only.

| | glibc | jemalloc | SAMM |
|---|---|---|---|
| Requests | 227,997 | 227,996 | 227,515 |
| Throughput | 361.8 req/s | 361.8 req/s | 360.9 req/s |
| Dropped / failed | 0 / 0 | 0 / 0 | 482 / 0 |
| Peak RSS | 825.1 MB | 695.5 MB | 876.3 MB |
| CPU (of 1 vCPU, wall-clock window) | 57.2% | 63.1% | **43.6%** |
| CPU throttled periods | 345 | 577 | 76 |
| Page faults per request (per second) | 15.4 (4,947) | 88.8 (28,856) | **5.9** (1,942) |
| End-to-end avg / p95 / p99 | 800 / 3,313 / 6,063 ms | 800 / 3,313 / 6,070 ms | 800 / 3,317 / 6,058 ms |
| Processing avg / p95 / p99 | 13.5 / 8.53 / 493 ms | 13.2 / 11.5 / 457 ms | 14.0 / **2.25** / 459 ms |
| GC events, total (instrumented) | 43,384 | 42,778 | 32,825 |
| Minor GCs | 12,882 | 13,004 | 12,951 |
| Major GC cycles (each reported twice: incremental marking + the major pause) | 15,251 | 14,887 | **9,937** |
| GC pause total / p99 / max | 31.7 s / 1.52 / 64.3 ms | 30.9 s / 1.55 / 59.3 ms | 24.2 s / 1.54 / 47.9 ms |
| JS heap peak used (limit 524 MB) | 14.9 MB | 14.8 MB | 15.5 MB |
| External memory at the end | 398 MB | 377 MB | **111 MB** |

GC labels: until 2026-10-21 the server's telemetry (`server/routes/_telemetry.js`)
mapped Node's GC kinds one bit off (fixed in f0f8cff). Its "incremental" (kind 4) is really the major
GC (mark-sweep-compact) and its "weakcb" (kind 8) is incremental marking (Node
22: minor 1, major 4, incremental 8, weakcb 16). Each major cycle is reported
twice (marking + the major pause), so total = minor + 2 × major cycles:
SAMM ran ~5,300 fewer major cycles (35% fewer), not 10,500 fewer GCs.

At this load all three serve what is offered, so throughput is equal; the
differences show in CPU, page faults, processing p95 and GC. SAMM's pool was
full here too (626.2 of 627.1 MB), and 0.17% of allocations fell back (16,229
of 9.71 million). CPU % divides by a wall-clock window that the WSL clock
stretches, equally for every condition.

---

### 3. Microbenchmark (Sept 25 gated run)

Replays the characterization's own request stream (real per-request
allocation sequences, opened and closed at the real request boundaries)
through each layer between a route and physical memory. One pinned core; no
network, JSON or Express. 5 trials + 1 warmup per cell; 7 traces (all call
sites mixed, plus one per call site), each with and without one write per
4 KB page. Host probe before the run: k6 65.1 s, V8 1.00× / 0.94×, GC 0.98×
(pass). The Sept 19 reference run gives similar numbers.

Layers: **SAMM engine** (the Zig engine alone); **SAMM via N-API** (the
server's `allocateBuffer()` → SAMM); **V8 allocUnsafe** (the server's
`allocateBuffer()` → `Buffer.allocUnsafe()`, on jemalloc or glibc);
**jemalloc / glibc, no V8** (the C allocator alone).

ns per allocation, allocation + release only (median of 5):

| | mix | batch | cache | ingest | fetch | process | aggregate* |
|---|---|---|---|---|---|---|---|
| SAMM engine, no bridge | 16.1 | 9.2 | 49.7 | 89.3 | 63.2 | 58.5 | 270 |
| SAMM via N-API (server path) | 2,672 | 674 | 1,066 | 1,558 | 2,747 | 10,693 | 63,819 |
| V8 allocUnsafe on jemalloc | 5,487 | 2,224 | 660 | 6,004 | 35,776 | 119,979 | 60,927 |
| V8 allocUnsafe on glibc | 5,259 | 2,092 | 707 | 6,088 | 35,628 | 124,704 | 61,326 |
| jemalloc, no V8 | 313 | 289 | 51.5 | 375 | 274 | 424 | 259 |
| glibc, no V8 | 129 | 104 | 71.0 | 433 | 105 | 3,328 | 514 |

Largest trial-to-trial spread: 67% of the median.

ns per allocation, with one write per 4 KB page (as the server does):

| | mix | batch | cache | ingest | fetch | process | aggregate* |
|---|---|---|---|---|---|---|---|
| SAMM engine, no bridge | 302 | 57.1 | 55.5 | 2,127 | 5,196 | 18,148 | 25,736 |
| SAMM via N-API (server path) | 3,237 | 842 | 2,852 | 6,942 | 10,430 | **33,613** | 577,297 |
| V8 allocUnsafe on jemalloc | 11,657 | 4,307 | 2,255 | 22,773 | 85,956 | **840,447** | 494,271 |
| V8 allocUnsafe on glibc | 5,925 | 2,217 | 3,052 | 15,075 | 58,643 | 311,606 | 182,398 |
| jemalloc, no V8 | 4,783 | 1,700 | 53.0 | 2,164 | 35,048 | 701,306 | 25,244 |
| glibc, no V8 | 1,108 | 82.0 | 64.0 | 9,932 | 1,818 | 179,377 | 67,375 |

Largest trial-to-trial spread: 219% of the median (single-call-site cells with
page writes are noisy).

\* aggregate is routed to System, so SAMM declines it: both SAMM rows measure
the decline plus the fallback (engine: malloc; N-API: `Buffer.allocUnsafe`),
not a SAMM allocation.

Where one allocation's time goes (no touch, median):

| | batch | mix |
|---|---|---|
| SAMM engine alone (alloc + release) | 9.2 ns | 16.1 ns |
| One bridge round trip, no memory work | 31.4 ns | 31.4 ns |
| SAMM through the bridge, total | 674 ns | 2,672 ns |
| … of which request close (region + detach) | 105 ns | 137 ns |
| … of which GC pauses | 22.9 ns (25 GCs) | 1,569 ns (1,904 GCs) |
| V8 allocUnsafe on jemalloc, total | 2,224 ns | 5,487 ns |
| … of which GC pauses | 1,202 ns (1,056 GCs) | 3,646 ns (3,697 GCs) |
| SAMM capacity fallbacks per trial | 0 of 1,246,654 | 16,536 of 1,273,696 |
| Detach failures | 0 | 0 |
