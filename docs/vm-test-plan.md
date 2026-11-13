# VM test runbook: GCP Tau T2D

The plan for moving the thesis study to a dedicated-core cloud VM: workload
characterization, microbenchmark, internal validation, external validation
(the n = 100 main study), the panel's extra results, then statistics. Tracked
from `internal-validation/PENDING.md`, Part A.

Laptop results (Ryzen 5 6600H, WSL2) are pilot data. They are not mixed with VM
results.

---

## Locked decisions (2026-10-17)

| Topic | Decision |
|---|---|
| **Main study baseline** | **V8 on jemalloc** vs **SAMM on jemalloc** (two-way, n = 100). Same C allocator underneath, so the arena is the only difference. |
| **Internal validation** | **All allocators**: glibc, jemalloc, SAMM. Plus the variants when implemented: page-keeping jemalloc, SAMM with `dontneed`, `glibc-tuned`, app-level Buffer pooling. |
| **Load point** | Profile and train at **k = 1.0**. **Find the VM's near-saturation stress point first** (Phase 5: the lowest k whose peak rate saturates both configurations), then lock the main study to it, as the paper states. |
| **Statistical metrics** (per run) | **Throughput:** achieved req/s (k6 `http_reqs` rate, the demo's number). **Latency:** processing time **p99** (report p95 too). **Peak memory:** peak RSS (cgroup `memory.peak`, reset at run start, the demo's number). Everything else on the dashboard is still collected. `_bench-lib.sh` / `run_replicates.sh` already use these definitions. |
| **Model changes** | Layer 1 **fixed at K = 2** with its limitation stated (2026-10-22), checked against the **reachability oracle** (Phase 4); **derive β from data** at the locked load point (two-pass). |
| **Timing fix** | Apply the `processing_time` fix to `samm-load-test.js` now: the earlier decision was "only if the realistic benchmark is re-run", and it will be. |

**Throughput, two meanings:** *achieved* = requests completed per second under
the realistic schedule (drops count against it); *capacity* = the closed-loop
maximum (internal validation). The statistics use achieved; at the stress point
it mostly reflects capacity.

### Decided 2026-11-13 (written down before any VM data)

- **Stress point: saturate both.** The main study runs at the **lowest k whose
  peak arrival rate (`MAX_RPS`) is at or above the calibrated capacity of BOTH
  configurations** (jemalloc baseline and SAMM, from the closed-loop
  calibration). Below that, SAMM's achieved throughput is capped by what was
  offered rather than by what it can do, and the throughput gap is understated.
  The rule uses the calibration, a separate experiment, and is the same for
  both sides. **Guard:** the jemalloc baseline must survive at least 2 of 3
  pilot runs (3 seeds, 10 minutes each) at that k; if it does not, step down
  one k level for both and record it.
- **Killed runs.** A run that is OOM-killed is excluded from that condition's
  sample for the three metric tests (unequal sample sizes are fine). Survival
  is reported separately as a count per condition. As a check against
  survivorship bias, throughput over the full 10-minute window is also reported
  with killed runs included. If more than about 10 % of a condition's runs die,
  survival is the headline result and the metric tests carry that caveat.
- **Statistics: the approved methodology as written.** Shapiro-Wilk and Levene,
  then an independent-samples t-test, or Mann-Whitney U if an assumption fails;
  Bonferroni α = 0.017 across the three metrics; relative percentage
  difference for each metric.
- **Seeds.** Each of the 100 runs has its own seed, and both conditions in a
  run share it (`run_replicates.sh`: base seed + run number). The shared seed
  makes the two samples related, which the independent tests do not use: that
  makes them conservative (harder to reach significance, never easier). State
  this in the thesis; a paired test goes in an appendix only if the adviser
  asks.

---

## Phase 1: prepare on the laptop (before renting the VM)

1. **PENDING A3 fixes:** done, except the empty Oct 8 recordings (your call).
   Floors stay charged on first use (reserving them changed nothing on the
   replayed traces: A3 item 9, state it in the thesis). The steady-state test
   now schedules its own collections (A3 item 10).
2. **Layer 1:** done: K fixed at 2 (be17915), the reachability oracle with
   its matrix analysis (77fc827), and the misroute wording (2026-11-02). The
   natural-break rule moved to ISMM (PENDING B3).
3. **β from data:** done 2026-11-03. `server/scripts/derive_beta.py` reads a
   SAMM run (`_bench-lib.sh` with `POLL_SAMM_STATS=1`, an internal-validation
   run, or a demo recording) and reports memory outside the pool
   (memory.current − committed: median, p99, peak), the ceiling C = container −
   peak − 32 MB and β = C ÷ POOL_HARD_LIMIT (from `spatial_quotas.json`), plus
   memory before the pool is touched (the 80 MB V8 assumption). Checked on the
   Oct 1 k = 2.5 demo run: peak 359.7 MB outside, β = 0.756.
4. **`processing_time` fix in `load-generator/k6-scenarios/samm-load-test.js`**
   (subtract the delay Node actually schedules, `Math.trunc(hold_ms)`, and
   count remaining clamps), as in `internal-validation/k6-scenarios/lib/workload.js`.
5. **Host probe:** done 2026-11-03. Off WSL, check 0 compares the monotonic
   clock with an NTP server (`metadata.google.internal` on GCP) over 60 s,
   limit ±1 % as before, and fails if `chronyc tracking` says unsynchronised.
   Checks 1-3 take a recorded reference: `host-probe.sh <dir> reference`, then
   `PROBE_REFERENCE=<dir>`, `K6_STARTUP_LIMIT_S`, `PROBE_CPU`.
6. **`run_replicates.sh`:** done 2026-11-03. `CONDITIONS="jemalloc samm"`,
   condition order rotated per replicate (`ROTATE=0` to fix it), `DRY_RUN=1`
   to print the plan. `_bench-lib.sh` takes `CPUSET_CPUS` (server core) and
   `K6_TASKSET` (k6 cores), and every result records its seed, image ID,
   routing-table hash, start time, order and position, and pinning.
7. **Optional (ISMM):** `run.sh` configs for page-keeping jemalloc
   (`MALLOC_CONF=oversize_threshold:0,dirty_decay_ms:-1,muzzy_decay_ms:-1`),
   SAMM with `SAMM_RECLAIM_POLICY=dontneed`, and the Buffer pooling baseline.
8. **Buffer modes** (`SAMM_BUFFER_MODE`, default `detach`): merged
   2026-11-13; the default is chosen on the VM (Phase 5, step 4).
9. **Fresh-clone rehearsal:** done 2026-11-13. A fresh clone ran the whole
   chain with short durations: environment from `requirements.txt`, the test
   suite, both images, the probe, `run_full_pipeline.sh`, the oracle, trace
   extraction, a pinned two-condition replicate, `derive_beta.py`, and an
   internal-validation calibration. It found and fixed: no requirements file;
   a relative `RESULTS_DIR` losing k6's summary; the probe needing files that
   only existed on the laptop (its trace is now in git as
   `microbench/probe-trace`); and core pinning missing outside `_bench-lib.sh`.
10. **VM scripts:** `infra/` (create / start / stop, provisioning, automatic
   power-off). Not yet run against a real project.
11. **Push `main`.**

## Phase 2: provision the VM (about a day)

Scripts and commands: `infra/README.md`.

1. **Create:** `infra/vm.sh create` on the laptop: `t2d-standard-4` (4 full
   cores, no SMT, 16 GB), **on-demand**, Ubuntu 24.04 LTS, 100 GB balanced
   disk. Do this early: a trial account may not be able to raise quotas, so
   find out now whether T2D is available to it.
2. **Provision:** `bash provision.sh <clone URL>` on the VM. It installs Docker
   CE, **Node 22**, **k6 v0.55.0**, **Zig 0.15.2**, the Python environment
   from `requirements.txt` and node-gyp's Node headers (the Zig addon build
   reads them), clones the repo, builds `samm-baseline:bench` and
   `samm-enabled:bench`, and writes `infra-environment.txt`.
3. **Check the record:** cgroup v2, no swap, THP `enabled` / `defrag`
   (`madvise` expected), one thread per core, chrony synchronised.
4. **Test suite:** `cd zig-allocator && PATH="$PWD/../venv/bin:$PATH"
   ./run_tests.sh` must pass all 8 steps.
- **Core layout, for every script:** `export CPUSET_CPUS=1 K6_TASKSET=2,3`
  (core 0 for the OS, core 1 for the server container, cores 2-3 for k6).
  `_bench-lib.sh`, `run_replicates.sh`, `internal-validation/run.sh`,
  `run_characterization.sh` and `run_oracle.sh` all read them; the probe and
  the microbenchmark take `PROBE_CPU=1` / `CPU=1`.
- **Data:** the profiling trace is regenerated on the VM. The raw Azure data
  (2.0 GB, not in git) is only needed for Phase 10b: upload or re-download it.

## Phase 3: health reference (half a day)

1. Record the reference: `PROBE_CPU=1 internal-validation/host-probe.sh
   results/probe-reference reference` (clock check, k6 start-up, reference
   microbenchmark on the server's core).
2. **Set the probe limits from that reference** and write them down **before
   any benchmark**: `PROBE_REFERENCE=results/probe-reference`, the same
   0.90-1.10x / ≤ 1.10x bands for checks 2-3, and `K6_STARTUP_LIMIT_S` (e.g.
   1.10 × the reference's k6 start-up; the laptop used 80 s against 60-77 s
   healthy).
3. From then on: probe before every batch and once a day; a failed probe means
   stop and report.

**The VM's reference and limits (set 2026-11-13, before any benchmark).**
VM `samm-bench`, `t2d-standard-4`, asia-southeast1-b, AMD EPYC 7B13, kernel
7.0.0-1017-gcp, Docker 29.9.3, Node 22.23.5.

The reference is the pooled median of **six probe runs** taken before any
benchmark (`results/probe-reference-pooled` on the VM; not in git, a copy is
fetched to the laptop). One run alone was not a sound centre: the first was the
fastest of the six, and the second already sat at 1.07-1.09x of it. Across the
six the VM varies by about ±5 %.

| Check | Six runs | Reference (median) | Limit |
|---|---|---|---|
| 0. Clock vs NTP | 100.00 % each time, chrony synchronised | | 99-101 % and synchronised |
| 1. k6 start-up | 123.3-131.5 s | 125.4 s | **≤ 138 s** (1.10 × reference) |
| 2. V8 microbench, no touch | 6,948-7,646 ns | 7,289.7 ns | 0.90-1.10x |
| 2. V8 microbench, page writes | 11,582-12,671 ns | 12,323.2 ns | 0.90-1.10x |
| 3. GC time per collection | 1.71-1.90 ms | 1.79 ms | ≤ 1.10x |

Every probe on the VM runs with
`PROBE_REFERENCE=$HOME/samm-final/results/probe-reference-pooled
K6_STARTUP_LIMIT_S=138 PROBE_CPU=1` (set in `~/.bashrc` there). These do not
change after a benchmark result is seen.

## Phase 4: workload characterization (1-2 days)

1. **Calibrate glibc and jemalloc** (closed loop, no routing table needed):
   find the VM's knee and confirm **k = 1.0 sits well below it** (a profile
   taken while requests queue would be distorted).
2. **Profile at k = 1.0** with `run_full_pipeline.sh` (`SKIP_BENCHMARK=1`):
   MAX_RPS 500, VUs 400 / 1,400, HOLD_SCALE 4, PROCESS_HOLD_MS 600, 10 min,
   seed 19870601, `SHADOW_PROFILER_CAPACITY` 150000. Optionally confirm
   convergence (`run_characterization_jsd.sh`).
3. Phase 2 preprocessing → ML refinery (**Layer 1 at K = 2**, β still
   0.75 for now) → table compiler → `zig build test`. **Restore the workload
   fingerprint** afterwards (`run_tests.sh` overwrites it). Rebuild the SAMM
   image.
4. **Characterization results for the thesis:** traffic state shares and
   rates; endpoint mix; per-site sizes, lifetimes and overhang; requests in
   flight (laptop: median 305, max 390); clusters, policies, quotas; a sanity
   comparison with the laptop (sizes should match, timings will differ).
5. **Layer 1 ground truth (reachability oracle).** With the new table,
   `server/scripts/run_oracle.sh` twice: the characterization seed (19870601,
   the default) and a held-out seed (`SCHEDULE_SEED=2025
   ORACLE_LABEL=seed2025-gc10ms`); then `oracle_matrix.py` with both run
   folders for the cross-run table. About 10 min each. Not a performance run
   (forced GCs every 10 ms), so no probe gate. β does not change Layer 1's
   decisions; re-run only if Phase 6 changes a policy. Thesis output: the
   per-site table, the weighted matrix, the sensitivity table.

## Phase 5: find the near-saturation stress point (about a day)

1. **Closed-loop capacities:** calibrate all three allocators (internal
   validation's calibration; widen `CAL_VUS` if the VM is faster).
2. **Apply the rule** ("Decided 2026-11-13"): take the lowest k whose
   `MAX_RPS` is at or above both calibrated capacities (k table: 1.0 = 500,
   1.5 = 750, 2.0 = 1,000, 2.5 = 1,250, 3.0 = 1,500 req/s).
3. **Baseline pilot at that k:** 3 seeds, 10 minutes each, jemalloc baseline.
   If fewer than 2 survive, step down one level and repeat. **Lock the
   main-study k** and record it with the calibration numbers and the pilot
   outcomes.
   **Result (2026-11-13): k = 2.0 is locked.** Capacities 880 (jemalloc) and
   1,128 req/s (SAMM), so the rule gave k = 2.5 (1,250 req/s); there the
   baseline was OOM-killed in 3 of 3 pilot runs (kernel log confirms; 58-64 %
   of each run's requests failed), so the guard stepped down. At k = 2.0
   (1,000 req/s) it survived 3 of 3: peak 858.8 ±107.3 MiB, processing p99
   165.5 ±64.9 ms, 758.2 ±5.8 req/s. Pilot seeds 20261114-16, apart from the
   main study's. At k = 2.0 the peak rate is above the baseline's capacity but
   below SAMM's, so the main study's throughput gap is the baseline's
   shortfall at peak, not the full capacity gap.
4. **Choose the buffer mode** at the locked k:
   `K=2.0 N=10 server/scripts/compare_buffer_modes.sh` runs SAMM in `detach`
   and `chunk` mode on the same ten seeds, alternating which goes first, and
   prints CPU per request, throughput, processing p99, peak memory, fallback
   share and survival, with the per-seed differences
   (`docs/buffer-modes-report.md`). About 5 hours. Fix the choice before
   Phase 6, because the memory outside the pool, and so β, depends on it.

## Phase 6: derive β at the locked load point, then the final table (about a day)

1. Run SAMM at the locked k with `POLL_SAMM_STATS=1` (one 10-minute run, e.g.
   `K=<locked> N=1 CONDITIONS=samm POLL_SAMM_STATS=1 CPUSET_CPUS=1
   K6_TASKSET=2,3 RESULTS_DIR=benchmark-results/beta-pass1
   server/scripts/run_replicates.sh`), then
   `server/scripts/derive_beta.py benchmark-results/beta-pass1/r01-samm-samm-stats.jsonl`.
2. Recompile the table with that β (`SAMM_BETA_UTILIZATION` for the quota
   script, then the table compiler), rebuild the image, and **run once more to
   confirm** (iterate once: fewer fallbacks change the memory outside the
   pool).
3. **Freeze the table** for everything after this (record the
   `model_weights.zig` hash, fingerprint and image ID). At k ≠ 1.0 SAMM needs
   `SAMM_ALLOW_WORKLOAD_MISMATCH=true` (as in the demo).

## Phase 7: microbenchmark (half a day)

`extract_trace.js` on the VM's trace, then `gated_run.sh`: 7 layers × 7 traces,
with and without page writes, 5 trials each, plus the 30-trial aggregate cell,
on one pinned core. Output: ns per allocation, and where an allocation's time
goes.

## Phase 8: internal validation (2-3 days)

All allocators (glibc, jemalloc, SAMM; plus the variants if ready), final table:
1. **Calibration** → knees, capacities, saturation VU count, latency rates.
2. **Throughput at saturation** (closed loop).
3. **Latency sweep** (open loop): shared rates up to the lowest capacity, plus
   each allocator up to 80 % and 95 % of its OWN capacity (two views: same
   absolute rate, same relative load).
4. A separate **instrumented SAMM run** (`POLL_SAMM_STATS=1`) for counters.
5. A **reverse-order replicate**, to check drift.
6. Optional (ISMM): a GC-instrumented pass at saturation (with the corrected
   labels and the GC `flags`), huge-page counters, the live-bytes counter.

## Phase 9: external validation, the main study (about 2 days of machine time)

1. **Pilot:** 2-3 runs at the locked k, to confirm stability.
2. **Main study:** `K=2.0 N=100 CONDITIONS="jemalloc samm" CPUSET_CPUS=1
   K6_TASKSET=2,3 RESULTS_DIR=benchmark-results/main-study
   server/scripts/run_replicates.sh` (check the plan first with `DRY_RUN=1`):
   **n = 100**, paired seeds (one seed per replicate, shared by both), rotated
   order, **10-minute runs**, resumable. About **40 h** (~12 min per run).
3. A small **GC-instrumented pass** (clean pass for metrics, instrumented pass
   for GC only, as in gc-control).

## Phase 10: the panel's extra results (2-3 days; smaller n, e.g. 15-20 replicates)

- **(a) 2 GB and 4 GB limits:** retrain the table for each limit (Layer 3
  depends on it; β re-derived the same way), run at the same load. Optionally
  also with holds ×2 / ×4 to keep memory pressure equal.
- **(b) Azure d01-d07 vs d08-d14:** Phase 1 preprocessing needs a day-range
  option and per-batch output folders. Train on d01-d07, test on both weeks.
  Memory files cover only d01-d12: payload model d01-d07 vs d08-d12, or one
  shared model.

## Phase 11: statistics and reporting

`stats-eval`, as the approved methodology states: Shapiro-Wilk and Levene, then
an independent-samples t-test or Mann-Whitney U; Bonferroni across the three
metrics (α = 0.017); the relative percentage difference per metric; survival
counts and full-window throughput if any run was killed; the Layer 1 oracle matrix
(Phase 4 step 5); figures.

---

## Operations

- **Long jobs:** inside `tmux`, through `infra/then-poweroff.sh <log>
  <command...>`: the job survives a dropped SSH session and the VM powers off
  when it ends, so it stops costing money. Scripts are resumable. Use
  `KEEP_ON=1` when another job follows.
- **Health:** probe before every batch and daily. Note VM restarts and Google
  maintenance events; discard an interrupted run, never patch it.
- **Backups:** copy results off the VM after each phase
  (`infra/vm.sh fetch benchmark-results`); snapshot the disk before major
  phases.
- **Fixed within a campaign:** image IDs, table, settings, environment.
- **Record per run:** machine type, zone, kernel, Docker, THP mode, image IDs,
  table hash (`run.json` already holds most of these).
- **Cost:** about $0.17 an hour on demand (check the console), so the main
  study is about $7 and the whole plan (8-12 days of machine time) about
  $35-50. A stopped VM costs only its disk. The trial credit's time limit, not
  its amount, is the constraint. Set a budget alert.
- **After every start:** run the probe. A stopped VM can come back on
  different hardware.

## Rough calendar

| Week | Work |
|---|---|
| 1 | Phase 1 (laptop prep); Phases 2-3 (VM setup, health reference) |
| 2 | Phase 4 (characterization); Phase 5 (stress point); Phase 6 (β, final table); Phase 7 (microbenchmark); start Phase 8; ISMM pooling baseline if ready |
| 3-4 | Finish Phase 8; Phase 9 (n = 100); Phase 10 (extras); Phase 11 (statistics) |

The ISMM go/no-go (mid-December) can share the VM in week 2: its two decisive
experiments are the pooling baseline and one real Buffer-heavy workload.
