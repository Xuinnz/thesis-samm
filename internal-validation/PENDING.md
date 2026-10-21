# Pending work — SAMM

**Updated 2026-10-17.** The tool defense is done. This file holds both plans:

- **Part A — Finishing the thesis course (priority).** The n = 100 main study
  on a GCP Tau T2D VM, the extra results the panel asked for, then statistics.
- **Part B — ISMM 2027 plan.** The research extension. Starts with two cheap
  experiments; go/no-go around mid-December 2026. Never let it delay Part A.
- **Shared** (end of file): results so far, decisions, probe history, things
  to remember.

This folder was merged into `main` on 2026-10-17 (user's decision) and is
published with the next push. `results/` is gitignored and stays on disk.

---

# Part A — Finishing the thesis course

Thesis deadline: ____ (fill in). Deliverables: the main study (n = 100) on the
VM, the panel's additional results, the statistics, the write-up.

## A1. Final study on a dedicated-core cloud VM (GCP Tau T2D)

**The runbook is `docs/vm-test-plan.md`** (phases 1-11: laptop prep, VM setup,
health reference, characterization, finding the stress point, deriving β,
microbenchmark, internal validation, the n = 100 main study, the panel's
extras, statistics). Decisions locked on 2026-10-17:
- **Main study (n = 100):** V8 on jemalloc vs SAMM on jemalloc (two-way).
- **Internal validation:** all allocators (glibc, jemalloc, SAMM, plus the
  variants when implemented).
- **Load point:** profile at k = 1.0; find the VM's near-saturation stress
  point first, then lock the main study to it (as the paper states). Still to
  decide: the selection rule (recommended: highest k where the jemalloc
  baseline is CPU-saturated but survives) and how to treat OOM-killed runs.
- **Statistical metrics:** throughput = achieved req/s (k6 `http_reqs` rate,
  as on the demo); latency = processing p99 (p95 reported too); peak memory =
  cgroup `memory.peak`. All other dashboard metrics still collected.
- **Model:** fix the Layer 1 System rule and derive β from data (A4).

The steps below are the original outline; the runbook supersedes their order
(notably: find the stress point, then derive β there, then freeze the table).

Replaces the old laptop tasks (WSL clock, page-fault anomaly, reverse-order
replicate). Internal validation runs on the VM too, and comes first, because it
sets the operating point there. Order:

1. **Probe.** Port `host-probe.sh`: replace check 0 (it calls `powershell.exe`)
   with an NTP-based clock check, take a reference run on the VM for checks
   1-3, and fix the VM's limits from that reference BEFORE any benchmark (never
   adjust them after seeing a result).
2. **Calibrate glibc and jemalloc** (no routing table needed). Find the VM's CPU
   knee and confirm k = 1.0, the profiling load, sits well below it.
3. **Profile and retrain on the VM** at k = 1.0, through `run_full_pipeline.sh`
   (fix A3's `run_characterization.sh` defaults first). Apply A4's decisions
   here; A4(b)'s two-pass calibration belongs to this step.
4. **Calibrate SAMM** with the VM-trained table, then choose the operating
   point (the VM's equivalent of k = 2.5: a T2D core is not a 6600H core).
5. **Throughput and latency validation** at that point. Extend the latency
   sweep past the shared ceiling. The calibration rule stops it at 80 % and 95 %
   of the LOWEST capacity (on the laptop, jemalloc's 642 req/s gave 510 and
   610), so SAMM's own queueing onset was never reached: it was still flat at
   610. Run each config up to 80 % and 95 % of its OWN capacity (laptop
   equivalents: glibc ~615 / ~730, SAMM ~740 / ~880; recompute from the VM
   calibration). Report two views:
   - same absolute rate (the current table, extended for the configs that keep
     up);
   - same relative load (e.g. each config at 80 % of its own capacity), to
     separate "less CPU per request" from "steadier service time".
   Hypothesis to test: on the laptop glibc began queueing at ~66 % CPU
   (510 req/s × 1.287 ms) while SAMM was still flat at ~69 % (610 × 1.132 ms).
   Queueing depends on utilisation AND service-time variability (Kingman), which
   fits SAMM having fewer page faults and GC pauses.
6. **Main study** (n = 100 runs), alternating SAMM and baseline so any drift or
   live-migration stall hits both conditions alike.

Notes:
- Machine: e.g. t2d-standard-4. Each vCPU is a full core (no SMT): pin the
  server container to one core (keep `--cpus=1.0 --memory=1024m`, swap off) and
  run k6 on the others. Avoid burstable types (e2-micro/small); use spot VMs
  only if each run can be retried safely.
- Record the environment: machine type, zone, kernel, Docker version, THP mode
  (the design expects `madvise`).
- Getting the code there: clone or pull `main` from GitHub (after pushing).
  `results/` (laptop pilot data) will not come along.
- No need to redo on the VM: the `processing_time` fix (Node behaviour;
  `processing_clamped` is recorded on every latency run anyway), the
  detached-Buffer behaviour, and the offline Layer 1 simulation.
- Disclose for the laptop pilot data: the WSL VM clock ran at 92.7-99.99 % of
  real time depending on the session, and Hyper-V time sync stepped the wall
  clock forward (k6 latency spikes; monotonic-timed figures read short). The
  host's cost per page fault also varied between sessions (native jemalloc +
  page writes 0.76x of the Sept 19 reference on Oct 4, while fault counts per
  request were unchanged).

## A2. Additional results the panel asked for (added 2026-10-17)

Extra results, not the main claim: run after (or alongside) A1's main study,
with a smaller n per condition (decide how many).

**(a) Other memory limits: 2 GB and 4 GB** (besides 1 GB). Likely intent:
does SAMM's advantage depend on the 1 GB constraint, and does Layer 3 size the
pool correctly for other budgets?
- Layer 3 derives the budget from the container limit, so **retrain the table
  per limit** (regenerate from refinery output; never hardcode), and run with
  `--memory=2048m` / `4096m`, swap off.
- Decide the workload: (i) the same load as at 1 GB, where memory is no longer
  the constraint and differences shift to CPU, GC and RSS; or (ii) live memory
  scaled with the limit (e.g. holds ×2 / ×4) to keep the pressure equal.
  At least (i); (ii) if time allows.
- Expect the baseline to stop OOM-ing at the same load, so the story becomes
  CPU per request, latency and bounded RSS rather than survival.

**(b) Traffic from different Azure days: d01-d07 vs d08-d14.** Answers the
panel's question about traffic surges vs off-peak periods, and doubles as a
drift test.
- Phase 1 preprocessing needs a day-range option and per-batch output folders
  (today it overwrites `datasets/azure-trace-2019/processed/`).
- Invocation and duration files cover d01-d14, but the memory files
  (`app_memory_percentiles`) only d01-d12. Either build the payload model from
  d01-d07 vs d08-d12, or keep one payload model and vary only the traffic.
- Runs: profile and train on one batch, test on both (in-distribution vs the
  other week). Report each batch's traffic character (share of Burst / Idle
  states, peak rates) so surge vs off-peak is visible. Optionally isolate
  peak-hour and off-peak windows as separate schedules.

## A3. Fixes before the VM profiling run (cheap)

1. **`server/scripts/run_characterization.sh` defaults do not match the real
   profiling run.** Run on its own it uses 50 req/s, 50-200 VUs and 20 min. The
   trace was made through `run_full_pipeline.sh` at k = 1.0: MAX_RPS 500,
   400-1,400 VUs, HOLD_SCALE 4, PROCESS_HOLD_MS 600, 10 min, seed 19870601.
   Align the defaults or make it refuse to run without them.
2. **[review] Fix the GC kind labels** (found 2026-10-15). In
   `server/routes/_telemetry.js`, `GC_KIND_NAMES` is one bit off from Node's
   constants (Node 22: MINOR 1, MAJOR 4, INCREMENTAL 8, WEAKCB 16; the file has
   2 = major, 4 = incremental, 8 = weakcb). So every "incremental" count so far
   is really major GCs and every "weakcb" count is incremental marking. Fix the
   map (better: read `perf_hooks.constants`), and correct the labels in
   `benchmark-results/gc-control/README.md` and `summary.txt`. Optionally record
   the GC entries' `flags` (trigger reasons).
3. **`preprocessing/phase2-ml-telemetry/run_phase2.sh` prints the wrong
   banner:** "=== [Phase 1] Starting Azure Simulation Preprocessing ===".
4. **Stale comments about floors (comment-only).**
   `ml-refinery/table-compiler/01_compile_routing_table.py` (header: "floor =
   P_j ... reserved against the global budget at startup") and the text it
   emits into `model_weights.zig` ("charged against the ceiling at startup")
   are out of date. Floors are the 90th-percentile demand capped at 70 % of the
   pool, and bump (`chargeSegment`) and slab charge the budget on FIRST USE, not
   at startup. Fix the wording, regenerate; numbers should come out identical.
5. **Confusing folder name: `datasets/shadow-telemetry/intermediate/ml-refinery/`.**
   It is the refinery's OUTPUT data, not code. Rename (e.g.
   `intermediate/step7-ml-refinery/`) before the VM run so paths are settled.
   Update every path in: writers `ml-refinery/clustering/01_kmeans_strata_discovery.py`,
   `ml-refinery/policy-assignment/01_variance_threshold_policy.py`,
   `ml-refinery/quota-calculation/01_calculate_spatial_quotas.py`; readers
   `ml-refinery/table-compiler/01_compile_routing_table.py` (2 paths),
   `demo/table.js`, `zig-allocator/microbench/extract_trace.js`, and the
   comments in `zig-allocator/tests/hash_parity_test.zig` and the generated
   `model_weights.zig` header. Then check the demo's table and ML card, and run
   the tests.
6. **Fix two inaccurate tooltip texts in `demo/ui/v2.html`:** "Page Faults / s"
   says "Memory pages loaded from disk per second" (they are first-touch
   faults); "Dropped" says "dropped or failed" (it counts dropped iterations
   only).
7. **Demo leftovers: two aborted runs** (2026-10-08 21:50, 0 requests each):
   `demo/recordings/SAMM-baseline-k2.5-s2025-2026-10-08T13-50-09-662Z.jsonl`
   and `SAMM-samm-k2.5-s2025-2026-10-08T13-50-30-248Z.jsonl`, plus their
   `-final.json`. They still show in History, and the UI test fixture picks the
   newest SAMM recording, so it falls back to synthetic data. Move or delete
   them: the user's call.
8. **Apply the `processing_time` fix to
   `load-generator/k6-scenarios/samm-load-test.js`** (subtract
   `Math.trunc(hold_ms)`, count remaining clamps), as in
   `internal-validation/k6-scenarios/lib/workload.js`. The earlier decision was
   to do this only if the realistic benchmark is re-run; the main study re-runs
   it, and processing p99 is now a statistical metric.

## A4. Model fixes before retraining on the VM

**Decided 2026-10-17: fix both** (a) and (b). (a) is implemented on the laptop
before profiling (runbook Phase 1); (b) is derived on the VM at the locked
load point (runbook Phase 6), then the table is frozen.

**(a) Layer 1's System rule (design limitation, found 2026-10-08).**
`ml-refinery/policy-assignment/01_variance_threshold_policy.py` always sends
exactly one cluster to System, the one with the highest mean overhang (its own
TODO says so). Simulated with the real k-means settings:
- with only request-scoped sites, process, ingest and fetch (24-25 ms) would go
  to System (safe, but a lost optimization);
- with escaping sites at 1 s and 10 s, the K>=3 floor splits them and the 1 s
  site lands in a SAMM arena.
A misrouted escaping buffer is NOT memory corruption, because detach cuts off
access, but the data is silently lost: a detached Buffer reads `length 0`,
`toString() ""`, `write()` returns 0; only bounds-checked reads such as
`readUInt8` throw. Fix: decide System by a significant natural break in
log-overhang (above the largest gap, if it clearly exceeds GC delay), allowing
zero or several System clusters; re-check whether the K>=3 floor is still
needed. Also correct the wording that claims misroutes surface loudly:
`zig-allocator/src/node-api-interface/addon.zig` (REGIONS block,
`reclaimEntry`), and the demo's Layer 1 card ("safety net held") and its
comment in `renderValidation` (`demo/ui/js/dashboard.js`).

**(b) Layer 3: a data-derived pool ceiling instead of β = 0.75** (user's idea,
2026-10-08). β covers the fallback path: refused managed allocations go to
malloc, outside both the pool and the System reservation. Characterization runs
without SAMM, so the trace can't show refusals; that circularity is why β is
fixed. Two ways:
1. Simulate the arenas against the trace for a candidate ceiling C and take the
   largest C with C + peak_fallback(C) + System + V8 baseline + margin <=
   container.
2. Two-pass calibration: run SAMM at the target load, record RSS - committed
   each second, set C = container - that peak - margin, iterate once. Laptop
   data: at k = 1.0 (gc-control rerun) ~250 MB sat outside the pool, giving
   C ≈ 742 MB (β ≈ 0.89); at the k = 2.5 demo ~364 MB (incl. ~62 MB cache),
   giving C ≈ 628 MB (β ≈ 0.75). So the right β depends on the load point:
   choose the study's load point first.
Also measure the hardcoded 80 MB V8 baseline the same way. Either way means
retraining and re-benchmarking; do it on the VM.

## A5. Statistics, after the n = 100 runs

`stats-eval/` holds only `.gitkeep` (user's decision: after the runs). The
README promises Shapiro-Wilk and Levene, then a t-test or Mann-Whitney U, with
Bonferroni-adjusted alpha = 0.017 across the three metrics, plus the
misclassification matrix (ML assignment vs compiled routing table; 6 of 6 on
the diagonal for the current table). Consider (ask the adviser): the same seed
per pair makes it a paired design (paired t / Wilcoxon signed-rank); report
effect sizes and confidence intervals; a second baseline doubles the
comparisons (alpha ≈ 0.008).

## A6. Optional for the thesis (also in Part B)

- **Cold vs warm SAMM** at the same load: explains SAMM's start-up latency
  spike and drops (details in B5).
- **Huge-page counters:** whether THP engages (details in B5).

---

# Part B — ISMM 2027 plan

## B0. Target and dates

- **ISMM 2027.** Call not published yet; ISMM 2026's deadline was 2026-03-27
  (co-located with PLDI), so expect **late March 2027**. ISMM 2026 also took
  intellectual abstracts and practitioner reports: check the 2027 call.
- **Go/no-go: mid-December 2026,** after B1.
- Fallbacks: a shorter ISMM 2027 format if offered; MPLR or the VMIL workshop
  (SPLASH); an ACM Student Research Competition; ISMM 2028 for the full paper.
- Framing to aim for: profile-guided, request-scoped region allocation for
  off-heap memory in a garbage-collected runtime, **with safe runtime
  adaptation**, beating simple pooling on real Buffer-heavy applications.

## B1. Decisive experiments first (by mid-December)

1. **App-level Buffer pooling baseline:** a server config that reuses Buffers
   per call site (a free list). A few days. If it gets close to SAMM, the
   contribution shrinks: rethink before investing more.
2. **One real Buffer-heavy workload, labelled by hand:** does the advantage
   hold outside our own server? 2-3 weeks.
Go = SAMM clearly beats pooling AND the real workload shows a gain.

## B2. Dynamic SAMM: runtime adaptation (user's priority)

1. **Call-site demotion (and re-promotion).** Detect sites whose objects
   outlive their request and route them to System at runtime: the static table
   plus a runtime override bit per site. Signal options: a low-rate sampled
   finalizer probe in production (the profiler's request-end vs finalization
   comparison, per site: an escape rate). Thresholds with hysteresis;
   re-promotion after a quiet period. Objects allocated before demotion are
   still at risk: pair with **verified reuse** for low-confidence sites (delay
   reusing a segment until finalizers confirm its objects died; safe but
   GC-dependent and costs memory). Evaluate by injecting escaping behaviour
   mid-run (a site starts retaining buffers): data-loss window, overhead.
   Related: leaky regions (Harris 2006) use a write barrier for the same goal;
   N-API has none, which is why sampling is the realistic signal.
2. **Dynamic budget rebalancing (user's idea, 2026-10-17).** A periodic
   controller (every 1-5 s) reads per-arena signals: fallback rate, elastic
   (beyond-floor) segments that are currently free, live vs committed bytes.
   Rule sketch: an arena with ~0 fallbacks that holds free elastic segments
   gives them back (`MADV_DONTNEED` + return the bytes to the budget); an arena
   with a high fallback rate gets that room. Constraints: never below a floor;
   hysteresis / cooldown to avoid thrashing; deterministic given the counters
   (keeps the determinism claim). Needs: an un-commit path (today committed
   never goes down), per-arena accounting, the live-bytes counter (B5), and a
   slab equivalent (the slab never returns slots today).
3. **Overflow control / adaptive ceiling.** An online version of A4(b): watch
   memory outside the pool (RSS - committed) and shrink the pool or throttle
   fallbacks before an OOM. The laptop's 500-VU OOM came from fallback memory
   outside a full pool piling up while the CPU was saturated (GC lag); this is
   the mechanism that should prevent it.
Evaluate B2 under drift (endpoint mix shifting mid-run; d01-d07 → d08-d14
traffic) and sustained overload (the 500-VU case).

## B3. Predictor evaluation (LLAMA-style)

- Classification accuracy on held-out data: other seeds, the other Azure week
  (A2b), other workloads (B4). Ground truth from the code, or Merlin-style
  death-time reconstruction instead of finalization time.
- Metrics: share of allocations and bytes classified correctly
  (request-scoped vs escaping); cost of each misprediction (data lost, memory);
  stability of the System rule (natural break) and of K.
- Compare against fixed thresholds: does learning add anything?

## B4. Workloads (×4) and call-site identification

- Candidates (Buffer-heavy, real): file upload + compression (zlib), a
  streaming proxy, binary protocol encode/decode, log or metrics ingestion;
  image processing only if its memory goes through Buffers (native libraries
  often allocate outside them). Plus the current synthetic server.
- Measure applicability: per app, the share of allocated bytes that are
  Buffers (SAMM manages nothing else).
- Call-site identification: manual labels at application level vs automatic
  interception (patch `Buffer.alloc` / `allocUnsafe`, hash a sampled stack);
  measure its cost. Buffers allocated inside Node core and libraries (fs, net,
  zlib, http) are not covered: say so.

## B5. Attribution and ablations

- **Page retention.** With reclaim `none`, SAMM keeps its pages; 84 % of its CPU
  saving over jemalloc is kernel time (86 vs 7.8 page faults per request), and
  jemalloc has the lowest RSS because it gives pages back. Stock jemalloc
  (5.3.0 in the image): allocations ≥ 8 MiB go to a dedicated arena that purges
  immediately on free, the rest decay over 10 s, and purges skip `MADV_FREE`
  (muzzy decay 0). Stock glibc already keeps its pages (free lists; mmap
  threshold rises to 32 MB after warm-up), and SAMM still beat it by 14 %.
  Page-keeping baseline to add: jemalloc with
  `MALLOC_CONF=oversize_threshold:0,dirty_decay_ms:-1,muzzy_decay_ms:-1`
  (verified in the image: four 12 MB buffers left 12,677 dirty pages kept, 19
  purged). `glibc-tuned` is NOT page-keeping (both thresholds pinned at
  128 KB: every buffer ≥ 128 KB is mmapped and munmapped); use it only as a
  low-RSS glibc point. Also SAMM with `SAMM_RECLAIM_POLICY=dontneed` (affects
  bump segments only; the slab never returns pages). `run.sh` needs configs for
  the jemalloc variant and SAMM-dontneed.
- **The ML vs simpler rules.** Layer 2 off (every managed site bump; then every
  site slab); Layer 3 off (one shared pool of the same total, no floors) or
  uniform quotas; Layer 1 as a fixed overhang threshold; negative control:
  aggregate forced into SAMM. Needs refinery / compiler options that don't
  exist yet. For each: regenerate, rebuild, run internal + realistic
  benchmarks, compare with full SAMM. Plus the pooling baseline (B1).
- **[review] Validate Layer 2's bump-waste estimate** (found 2026-10-15).
  `bump_extra = arrival rate × σ(time to request end) × mean size`
  (`02_aggregate_call_sites.py`) is a first-order heuristic, not a model of the
  SEGMENTED arena: a straggler pins only its own segment, held until its
  slowest member dies, so real waste depends on objects per segment (expected
  maximum lifetime of the n objects sharing it, not σ), the tail shape (fetch
  and ingest holds are log-normal), skipped segment tails (process: objects up
  to 16 MB in 28 MB segments) and the half-filled current segment. Segment size
  (floor ÷ 8) is only fixed in Layer 3, after Layer 2 used the estimate. At
  risk: only **ingest** (8.9 vs 14.9 MB, 1.7×); process (55×), batch (18×),
  fetch (slab exact at 0) and cache (tie) are safe. To do: replay the trace
  through the real engine (`microbench/engine_bench`) with the live-bytes
  counter, measure each site's actual bump and slab waste, compare, then use a
  segment-aware estimate or the replayed numbers (the same simulator could
  serve A4(b) option 1).
- **[review] Measurements to add** (2026-10-15):
  1. **Huge-page counters:** the container cgroup's `anon_thp` and
     `thp_fault_alloc` (`memory.stat`) every second, plus `/proc/vmstat`
     `thp_fault_alloc` and `compact_stall` before and after each run. Indirect
     evidence they engage: in the Oct 8 demo SAMM's memory grew 775 MB in its
     first 2 s with only 53,682 faults (210 MB at 4 KB each). Checklist A9.
  2. **Cold vs warm SAMM** at the same load (`SAMM_WARMUP=false` vs `true`),
     first ~20 s: processing p95 (cold: ~275 ms for ~15 s, then ~50 ms), drops
     (cold: 1,102 of 2,130 in the first 7 s), memory headroom (the demo README
     measured warm SAMM at the 1 GB limit for 39 s on a 1-minute k = 1.0 run).
     Warmup pre-faults only the floors (~439 MB), not the ~190 MB of elastic
     segments.
  3. **Per-arena live-bytes counter** in `/samm/stats`, sampled once a second:
     live vs committed per arena = a fragmentation ratio over time, separating
     pinned waste from free segments and slots held as spare capacity. `release`
     gets only the segment or slot index today, so the object size must be
     available there. Checklist A8.

## B6. Rigour

The VM (shared with A1); repeats per condition; confidence intervals and
effect sizes; GC telemetry in an instrumented pass at the saturation point
(gc-control has GC data only at k = 1.0, unsaturated); the GC `flags` (trigger
reasons) to confirm the major-GC split.

## B7. Positioning and writing

- Related work to cite: FiLiP (ISMM 2024, finalizer-based lifetime profiling);
  Merlin (TOPLAS 2006, exact death times); Barrett & Zorn (PLDI 1993);
  pretenuring for Java (OOPSLA 2001); V8 allocation-site pretenuring (ISMM
  2015); NG2C (ISMM 2017) and POLM2 (Middleware 2017, offline profile →
  allocation-site placement); ROLP; Yak (OSDI 2016, epoch regions); leaky
  regions (Harris 2006); reaps (OOPSLA 2002); LLAMA (ASPLOS 2020); escape
  analysis (OOPSLA 1999); drag (Röjemo & Runciman 1996; Shaham et al. 2001).
- Reword the README's description of LLAMA (the paper amortizes prediction
  cost; contrast designs, not speed).
- Artifact: scripts, traces, the VM setup.

## B8. Rough timeline (to a late-March deadline)

| Window | Work |
|---|---|
| Oct 20 - Nov 16 | A1 VM setup and probe (shared); A3 fixes; B1.1 pooling baseline |
| Nov 17 - Dec 14 | A1 calibration and retraining; B1.2 one real workload; B2 design |
| **Dec 15** | **Go/no-go** |
| Dec 15 - Jan 31 | A1 main study runs; B2 demotion + rebalancing; two more workloads |
| Feb | B3 predictor evaluation; B5 ablations; remaining runs |
| Mar 1 - deadline | Writing (B7) |

Total B effort was estimated at ~22-36 weeks against ~23 available, so the
scope must be cut if behind: drop to fewer workloads or a shorter format
before cutting A1.

## B9. Risks and kill criteria

- Pooling gets close to SAMM → rethink the contribution (B1).
- Real workloads show little gain (most Node allocation is JS heap, not
  Buffers) → narrow the claim to Buffer-heavy services, or stop.
- Safe demotion can't bound data loss acceptably → present adaptivity as
  future work and keep the safety discussion honest.
- Automatic call-site identification too costly → manual labels, stated as a
  limitation.

---

# Shared

## Done so far

**Suite.** `run.sh` (one container at a time, benchmark settings, cgroup
record every second, optional `POLL_SAMM_STATS=1`), `host-probe.sh` (four
checks), the three k6 scenarios, the analysis reports, and `README.md`.

**Oct 3 runs** (host passed the full probe: k6 62.1 s, V8 1.04x / 1.04x, GC 1.03x):

| | glibc | jemalloc | SAMM |
|---|---|---|---|
| Calibration: saturated (>= 98 % CPU) from | 250 VUs | 250 VUs | 300 VUs |
| Calibration: capacity | 767 req/s | 642 req/s | 928 req/s (OOM-killed at 500 VUs) |
| Throughput at 350 VUs (all VALID) | 773.8 req/s | 663.6 (-14 %) | **878.8 (+14 %)** |
| CPU per request = user + kernel | 1.287 = 1.102 + 0.185 ms | 1.502 = 1.058 + 0.443 | **1.132 = 0.999 + 0.133** |
| Page faults per request | 12.4 | 86.0 | 7.8 |
| Latency: first non-flat rate | 510 req/s | 510 req/s | flat through 610 |

SAMM vs jemalloc: 84 % of the CPU saving is kernel time (page faults). SAMM vs
glibc: 66 % is user time. Exact-duration endpoints (cache/batch/aggregate):
equal medians, SAMM's tail tighter (p99 2.8 ms vs 5.1-6.3 glibc, 6.9-7.4
jemalloc). Results: `results/calibrate-20261003-074658`,
`results/throughput-20261003-082829`, `results/latency-20261003-084551`.

**Timing fix (processing_time).** The server holds with `setTimeout`, and Node
truncates fractional delays to whole ms, so subtracting the fractional
`hold_ms` undercounted by up to 1 ms. `k6-scenarios/lib/workload.js` now
subtracts the delay Node actually schedules, and counts remaining clamps in
`processing_clamped`. Checked on Oct 4 (`results/latency-20261004-111551`,
glibc): held requests clamped to 0 went from 15.0 % to 0.7 % at 160 req/s, and
from 23.0 % to 2.9 % at 320 req/s.

**SAMM OOM at 500 VUs.** In the Oct 3 calibration SAMM served ~850-960 req/s
for the first 19 s of the 500-VU step, then was killed at 19.4 s (4.4 s into
the measured window, hence the row's 122 req/s and 558,047 instant failures).
The instrumented re-run `results/calibrate-20261004-110536` (counters in
`samm/allocator.jsonl`): the pool reached its ceiling (626.9 of 627.1 MB) at
200 VUs and stayed there; fallbacks were all budget refusals (0.1-0.3 % of
allocations); detach failures and exhausted regions were 0; memory outside the
pool grew until the kill. 500 VUs is 28 % above the most requests in flight
during profiling (max 390), sustained, with the CPU saturated; glibc and
jemalloc survived the same step. Oct 4 is not valid for throughput (host failed
its probe; CPU per request rose 1.2 → 3.2 ms past 250 VUs, mostly user time).

All of the above ran on the laptop (Ryzen 5 6600H, WSL2). It is pilot data now.

## Decisions already made (by the user)

- The final study runs on a cloud VM (GCP Tau T2D). Laptop runs are pilot data
  and are not mixed with VM results.
- `stats-eval` waits until after the n = 100 runs.
- The panel's extra results (2 GB / 4 GB limits; Azure d01-d07 vs d08-d14) are
  additional, not the main study.
- The ISMM work (Part B) never delays the thesis (Part A).
- The probe's V8/GC limit stays two-sided (0.90-1.10x).
- A failed probe means stop and report. No rebooting on my own, and no
  loosening a limit after seeing a result.
- `samm-load-test.js` gets the `processing_time` fix now (A3 item 8): its
  condition ("only if the realistic benchmark is re-run") is met. The ~2 ms
  alloc p95 figure from before is not cited in the paper.
- Main study (2026-10-17): V8 on jemalloc vs SAMM on jemalloc, n = 100, paired
  seeds, 10-minute runs, at the VM's near-saturation stress point (found first,
  then locked). Statistical metrics: achieved throughput, processing p99, peak
  RSS (`memory.peak`). Internal validation covers all allocators. Fix the
  Layer 1 System rule and derive β from data. Runbook: `docs/vm-test-plan.md`.
- No longer-timeout re-run of the 500-VU stats.
- The internal-validation work is merged into `main` (2026-10-17); it was kept
  on a private branch until then.

## Probe history (x = ratio to the Sept 19 reference; lower is faster)

| Probe | Clock | k6 startup | V8 | V8 + page writes | GC per collection | Result |
|---|---|---|---|---|---|---|
| Oct 3 07:43 | — | 62.1 s | 1.04x | 1.04x | 1.03x | pass |
| Oct 3 21:20 | — | 71.4 s | 0.98x | 0.8977x | 0.98x | fail (writes fast) |
| Oct 3 21:38 | — | 87.2 s | 1.06x | 0.93x | 1.06x | fail (k6 slow, browser open) |
| Oct 4 10:58 | — | 58.2 s | 0.90x | 0.81x | 0.89x | fail (writes fast; native jemalloc+writes 0.76x, engine 1.03x) |
| Oct 8 17:19 (k6-only) | 98.5 % (hyperv_clocksource_tsc_page) | 71.5 s | | | | fail (clock) |
| Oct 9 07:43 (full) | 98.2 % (tsc) | 62.1 s | 1.05x | 0.97x | 1.04x | fail (clock only); output was in a scratch folder, not kept |

## Things to remember

- **WSL clock drift (laptop only).** The VM clock can run slow by a different
  amount each WSL boot: 92.7 % on Oct 4, 98.5 % on Oct 8 afternoon, 99.99 % on
  Oct 8 evening (hyperv_clocksource_tsc_page), 98.2 % on Oct 9 (tsc). Hyper-V
  time sync then steps the wall clock forward; k6 latency spikes appear at each
  jump. The sysfs clocksource switch does not survive a restart and did not
  reliably fix the rate.
- **Demo recordings.** Clean pairs (no wall-clock jumps):
  - Sept 25: `demo/recordings/BASELINE-baseline-k2.5-s2025-2026-09-24T23-03-57-170Z.jsonl`
    and `BASELINE-samm-k2.5-s2025-2026-09-24T23-08-17-730Z.jsonl`;
  - Oct 8 (VM clock 99.99 % that evening):
    `demo/recordings/SAMM-baseline-k2.5-s2025-2026-10-08T13-27-11-406Z.jsonl`
    (OOM-killed at ~151 s of load) and
    `SAMM-samm-k2.5-s2025-2026-10-08T13-31-45-401Z.jsonl`
    (918 req/s, 1.2 % dropped, 0 failed).
- **Long jobs.** Run them detached (`setsid nohup ... &`) and watch the log;
  background tool calls die after about 30 min. `/tmp` is wiped when Windows or
  WSL restarts, so keep scripts in the repo.
- **The old branch `wip/internal-validation`** is fully merged into `main`
  (9be2e20) and can be deleted (`git branch -d wip/internal-validation`).
