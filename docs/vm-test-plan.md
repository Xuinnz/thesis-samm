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
   **Result (2026-11-13): `chunk`.** The rule, set before the numbers were
   read: chunk if it clearly uses less CPU per request or serves more in most
   seed pairs, and is no worse on survival, fallback share and peak memory.
   Ten seeds (20261201-10), both modes 10 of 10 survived. Chunk against
   detach: CPU per request 0.984 against 1.015 ms (lower in 9 of 10 pairs),
   processing p99 26.1 against 30.7 ms (9 of 10), peak memory 841.3 against
   856.6 MiB (9 of 10), fallback share 0.26 against 0.34 % (higher in 6 of 10:
   no difference), throughput the same (768.1 req/s: at this load SAMM serves
   everything offered). The VM's `~/.bashrc` exports `SAMM_BUFFER_MODE=chunk`;
   a run's `-allocator.json` shows it as `sharedBuffers` above zero.

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

**Result (2026-11-13): β = 0.843, table frozen.** All runs k = 2.0, chunk
mode, seeds 20261401-03 (apart from the main study's), host probe clean.

| | Pass 1 (β = 0.75) | Pass 2 (β = 0.843) | | |
| :--- | ---: | ---: | ---: | ---: |
| Seed | 20261401 | 20261401 | 20261402 | 20261403 |
| Survived | yes | yes | yes | yes |
| Memory outside the pool, peak of the 1 s samples | 288.9 MiB | 219.1 | 229.2 | 138.3 |
| Kernel's peak for the container | 938.6 MiB | 946.5 | 971.3 | 857.4 |
| Share of the 1 GiB limit | 91.7 % | 92.4 % | 94.8 % | 83.7 % |
| Capacity fallbacks | 37,394 | 14,662 | 24,285 | 575 |
| Processing p99 | 48.6 ms | 40.6 | 42.2 | 20.9 |
| Throughput | 895.6 req/s | 896.2 | 899.6 | 757.9 |
| β this run gives | **0.843** | 0.927 | 0.915 | 1.024 |

- Pass 1: C = 1,024 − 288.9 − 32 = 703.1 MiB, over a pool hard limit of
  833.8 MiB, so β = 0.843. Recompiled: ceiling 737,037,149 bytes (702.9 MiB),
  floors 491.2 MiB, 211.7 MiB shared.
- Pass 2 is the method's "repeat the run once", done on three seeds instead of
  one. All three survived, and none gives a β below 0.843, so 0.843 stands. The
  higher values are **not** applied: the method does not iterate a second time,
  and they are optimistic. The 1 s samples miss short spikes that the kernel's
  peak counter records: by that counter, memory outside the pool peaked at
  244, 269 and 155 MiB, 17-40 MiB above the sampled peaks. On the heaviest of
  the three seeds the container came within 52.7 MiB of its limit.
- **Frozen:** `model_weights.zig` sha256
  `b2318961ebee4cde36f018db4874de2ee50b938bd5d729d14bbc5f46d8cb997c`, workload
  fingerprint `0ab98bb5b39546bd`, image
  `sha256:83d271ff0c6103e5446b429935571ead594f17f32469dc1b638c3c91f02fb34e`.
- Two things this shows about the main study. Seeds differ a great deal in how
  heavy they are (896-900 req/s on two of these, 758 on the third, 751-794 on
  the ten buffer-mode seeds), and SAMM's peak memory follows: with the larger
  pool it sits at 84-95 % of the limit, above the baseline pilot's mean. And a
  seed heavier than any of these three could take SAMM past the limit; such a
  run counts against SAMM's survival, as the rule fixed on 2026-11-13 says.

## Phase 7: microbenchmark (half a day)

`zig-allocator/microbench/gated_run.sh results-vm-<date>`: 7 layers × 7 traces,
with and without page writes, 5 trials each, plus the 30-trial aggregate cell,
on one pinned core. Output: ns per allocation, and where an allocation's time
goes. On the VM (where `PROBE_REFERENCE` is set) the gate is the VM's own host
probe, before and after; the script's older checks compare against the
laptop's 2026-09-19 run. The traces are extracted from the VM's
characterization the first time. `SAMM_BUFFER_MODE` reaches the SAMM layers,
so with the VM's `~/.bashrc` they run in the main study's mode, and each
results folder has a `run-settings.txt` (image, table hash, buffer mode, core).
The image must be newer than the table: run after a SAMM benchmark on the
frozen table.

**Result (2026-11-13), `zig-allocator/microbench/results-vm-2026-11-13/` on the
VM (copy in the laptop's `vm-results/`).** Host probe clean before and after,
all seven layers completed, frozen table and image, chunk mode, core 1. Median
ns per allocation over 5 trials:

| | mix | batch | cache | ingest | fetch | process |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| **No memory touched** | | | | | | |
| SAMM engine, no bridge | 15.9 | 12.2 | 77.4 | 83.3 | 86.4 | 83.5 |
| SAMM through Node-API (the server's path) | 2,054 | 283 | 1,530 | 1,524 | 2,800 | 13,399 |
| V8 `allocUnsafe` on jemalloc | 6,849 | 2,725 | 820 | 8,053 | 46,581 | 194,258 |
| V8 `allocUnsafe` on glibc | 6,604 | 2,451 | 823 | 7,861 | 46,556 | 202,642 |
| **One write per 4 KiB page** | | | | | | |
| SAMM engine, no bridge | 188 | 30.5 | 78.3 | 1,113 | 2,373 | 13,459 |
| SAMM through Node-API | 2,633 | 402 | 3,924 | 6,410 | 9,269 | 30,181 |
| V8 `allocUnsafe` on jemalloc | 11,468 | 4,205 | 2,568 | 21,438 | 81,627 | 716,360 |
| V8 `allocUnsafe` on glibc | 7,578 | 2,623 | 1,989 | 14,988 | 60,934 | 298,159 |

- On the mix as served, SAMM takes 2,054 ns against 6,849 on jemalloc (3.3
  times less) with no memory touched, and 2,633 against 11,468 (4.4 times) with
  page writes. Most of both is collector time: 1,419 of SAMM's 2,054 ns (1,312
  collections) and 4,977 of V8's 6,849 (3,766 collections).
- **SAMM is slower on cache**, the one 4 KiB site: 1,530 against 820 ns, and
  3,924 against 2,568 with page writes (that cell varies: SD 984 and 801).
- The engine itself costs 12-86 ns; the rest of SAMM's time is the bridge, the
  Buffer object and the collector (batch: 283 ns in all, 12 of it the engine).
- **Do not quote the aggregate column yet.** Aggregate is routed to System, so
  it is not a SAMM allocation in any row. With page writes it came out ten
  times apart between the 5-trial run and the 30-trial cell for every layer,
  plain jemalloc with no V8 included (33,932 against 3,331 ns). That is the
  host's page handling for 2 MiB blocks (huge pages are the first suspect), not
  an allocator difference; look at it before the column is used.

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

**Run 2026-11-13/14** (frozen table, chunk mode, `LOAD_K=2.5` as in Phase 5's
calibration, seed 20250911, host probe clean). On the load point (2026-11-15;
this replaces a wrong note in commit 0b23ce2, which called 2.5 a mistake):
Phase 5's capacities (880, 1,128 req/s) were calibrated with these same
k = 2.5 holds, and 2.5 is the k Phase 5's rule selects, the lowest whose
`MAX_RPS` (1,250) covers every allocator's capacity. The main study stepped
down to 2.0 only because the baseline did not survive the trace at 2.5. In a
closed loop the holds set how many requests a user can send, not how much
memory is live: 400 users offer about 1,238 req/s with k = 2.5 holds (240 ms)
and about 990 req/s with k = 2.0 holds (300 ms), with the same 400 requests in
flight. So k = 2.0 cannot saturate glibc or SAMM (capacities 1,092-1,185)
inside 1 GiB; k = 2.5 can. A k = 2.0 pass was decided 2026-11-15 and is
recorded below as a supplement. Two fixes first, both in `run.sh`: the samm
config was not given `SAMM_BUFFER_MODE`, so it would have run in detach mode;
and a relative `RESULTS_DIR` made k6 fail at once.

*Calibration* (`calibrate-20261113-232648`, `CAL_VUS=50,...,500`):

| | glibc | jemalloc | SAMM |
| :--- | ---: | ---: | ---: |
| Capacity | 1,092 req/s | 877 req/s | 1,163 req/s |
| Saturated (>= 98 % CPU) from | 400 VUs | 300 VUs | 400 VUs |
| Peak memory at 400 VUs | 949.6 MB | 787.5 MB | 963.1 MB |
| At 500 VUs | OOM-killed | survived, 912.2 MB | OOM-killed |
| Processing p95 at 300 VUs | 28.5 ms | 62.2 ms | 17.6 ms |

SAMM's capacity is up from 1,128 (Phase 5: β = 0.75, detach) to 1,163.
`calibration_report.py`: NOT FEASIBLE as measured (no VU count at or above
the highest knee was safe for every config). **Decided 2026-11-14 (user):
throughput at `SATURATION_VUS=400` for all three**, the highest knee with no
margin, the same closed-loop pressure for every allocator. An OOM kill during
the run is reported as that allocator's result: capacity not sustainable in
1 GiB.

*Latency:* the report's sweep `20,40,80,160,320,640,830` for all three, then
each at 80 % and 95 % of its own capacity (glibc 874, 1,037; jemalloc 702, 833;
SAMM 930, 1,105). About 18 minutes per config for the seven-rate sweep, 70 %
longer than the README's estimate.

*Throughput at 400 VUs* (closed loop, MEASURE window; `throughput-20261114`,
reverse order `throughput-reverse-20261114`, SAMM with its counters
`throughput-samm-polled-20261114`):

| | glibc | jemalloc | SAMM |
| :--- | ---: | ---: | ---: |
| Throughput, forward order | 1,153 req/s | 881.2 | 1,185 |
| Throughput, reverse order | OOM-killed | 876 | 1,184 |
| SAMM against each (forward) | +2.7 % | +34.5 % | |
| CPU used (user / kernel) | 1.00 (0.92 / 0.08) | 1.00 (0.82 / 0.18) | 0.99 (0.93 / 0.07) |
| Page faults per request | 10.2 | 81.4 | 4.83 |
| Peak memory | 982.0 MB | 806.4 MB | 909.3 MB |

SAMM with its counters polled: 1,189 req/s, so polling did not change it.
Drift between the two orders is under 1 % for SAMM and jemalloc. glibc
survived the forward run at 982 MB and was OOM-killed in the reverse run: at
this load it sits at the limit, as calibration predicted.

*Latency, shared rates* (open loop, `latency-shared-20261114`; one container
per allocator for the whole sweep):

| Processing time, p95 / p99 (ms) | glibc | jemalloc | SAMM |
| :--- | ---: | ---: | ---: |
| 20 req/s | 3.01 / 5.23 | 4.26 / 6.92 | 2.29 / 4.31 |
| 160 req/s | 7.37 / 10.9 | 8.62 / 12.2 | 5.29 / 9.16 |
| 320 req/s | 9.93 / 14.1 | 11.9 / 17.3 | 8.11 / 11.9 |
| 640 req/s | 18.8 / 29.9 | 35.1 / 55.6 | 14.7 / 20.4 |
| 830 req/s | 41.2 / 59.7 | OOM-killed | 22.1 / 32.1 |

- jemalloc was OOM-killed at the start of the 830 step (95 % of its
  capacity). Its memory read 721 MiB a second before, so the spike was shorter
  than the 1 s sampling. The report then marks every jemalloc step "not flat"
  because the container's fate is applied to the whole sweep: read jemalloc's
  steps up to 640 from the numbers, not the verdict column.
- The flatness gate (p95 at most 1.5 times the 20 req/s step) fails from 80 or
  160 req/s for everyone, because p95 at 20 req/s is only 2-4 ms. The table
  above is the comparison; "where queueing starts" is not informative here.

*Latency at each allocator's own 80 % and 95 %:* the first attempt
(`latency-own-20261114`) is **invalid**. k6 creates every step's VUs before
the test begins, about 12 minutes at these rates, while the server sits idle;
the first step then hit a cold server at 702-930 req/s, and all three were
OOM-killed within about 4 seconds (SAMM: 20 MiB to 929 MiB). That is a harness
artefact, not an allocator result. Re-run with a warm-up ramp
(160, 320, 640 req/s, then the 80 % and 95 % steps): `latency-own-warm-20261114`.

*Latency at each allocator's own 80 % and 95 %, warmed* (host probe clean):

| | glibc | jemalloc | SAMM |
| :--- | ---: | ---: | ---: |
| 80 % of own capacity | 874 req/s | 702 req/s | 930 req/s |
| p95 / p99 there | 275.5 / 432.5 ms | 59.3 / 103.9 ms | 336.6 / 538.2 ms |
| Survived the 80 % step | yes | yes | no: OOM-killed late in it (7,202 of 46,500 failed) |
| 95 % of own capacity | 1,037: OOM-killed | 833: OOM-killed | 1,105: not reached |

- **No allocator can run open-loop at 95 % of its own closed-loop capacity
  inside 1 GiB**, and at 80 % all three are queueing (p95 6-59 times their
  160 req/s value). An open loop keeps sending while requests wait, the
  waiting requests hold their Buffers, and memory, not CPU, is what gives out.
- **By relative load, SAMM does worst**: at 80 % of its capacity it is the one
  killed, and its p95 is the highest. Its extra capacity cannot be used under
  an open loop near the limit; memory is SAMM's binding constraint, as the β
  passes already showed. By absolute rate it does best (the shared sweep: at
  830 req/s SAMM 22.1 ms p95, glibc 41.2, jemalloc killed). Report both views;
  they answer different questions.
- The warm-up steps repeat the shared sweep within about 10 % (p95 at 640
  req/s: SAMM 15.3 against 14.7, jemalloc 38.5 against 35.1, glibc 20.1
  against 18.8), so the latency measurements are reproducible.

*Checks on the k = 2.5 pass (2026-11-15):*
- No bug found: every valid run has 0 failed requests, every OOM matches
  Docker's flag, run order moves throughput under 1 %, polling changes nothing.
- SAMM against jemalloc reproduces the laptop's October run (+32 % there,
  +34.5 % here). SAMM against glibc does not (+13.6 % there, +2.7 % here):
  the laptop container was not pinned and was CFS-throttled in 8.6 of every
  10 periods (here 0.2-0.3), and kernel time per fault was 2-3 times higher
  under WSL2, which taxed the fault-heavy configs. The laptop numbers are not
  comparable; the VM's match the main study's setup.
- At 400 VUs SAMM's arena budget (702.9 MiB) is fully granted within about
  30 s of load; after that about 67 allocations/s (0.13 %, about 1 request in
  18) fall back to jemalloc. The throughput figure is SAMM with that spillover.
- SAMM's CPU per request against glibc: about -15 % at 200 VUs, -10 % at 300,
  -3 % at saturation. glibc keeps freed memory (10 faults/request) and gets
  most of the reuse SAMM gives, at the price of peak memory (982 MB, OOM in
  the reverse run).
- The "80 %" and "95 %" own-capacity rates are fractions of the calibration
  capacities; against the throughput runs glibc ran at 76 %, SAMM 78.5 %,
  jemalloc 79.7 %.

**Pass at `LOAD_K=2.0`** (decided 2026-11-15; pass `LOAD_K=2.0` explicitly,
`run.sh` defaults to 2.5).

*Calibration* (`calibrate-k2-20261115`, host probe clean):

| | glibc | jemalloc | SAMM |
| :--- | ---: | ---: | ---: |
| Highest step survived | 350 VUs: 868 req/s, 91 % CPU, 878 MB | 500 VUs | 400 VUs: 985 req/s, 93 % CPU, 968 MB |
| Reached 98 % CPU | no: OOM-killed at 400 | yes, at 400: 859 req/s | no: OOM-killed at 500 |
| CPU per request at 350 VUs | 1.05 ms | 1.18 ms | 0.97 ms |

With these holds 400 users offer about 990 req/s, which SAMM serves without
saturating; only jemalloc is CPU-bound. The throughput figure for SAMM at this
k is the offered load, a lower bound on its capacity. Decided (user): 400 VUs
for all, as at k = 2.5.

*Launch 1* (`throughput-k2-*`, `latency-k2-shared-*`, 06:22-08:22 UTC):
**invalid, host slowed during the run.** jemalloc gave 841 req/s at 06:31 and
687 at 07:05 (same CPU share, same faults per request); SAMM 983, then
942-950. In the latency sweep, which ran last, the non-held endpoints' median
at 160 req/s was about 1.9 times the k = 2.5 pass's for every allocator (1.17
against 0.59 ms for glibc), while the k = 2.0 calibration, on an earlier boot,
matched the k = 2.5 pass at low load, so the holds are not the cause. The
probe was clean before the launch and after the next boot; nothing was
recorded in between. Kept on the VM, not used.

*Launch 2 of the same* (`*-k2r2-*`, 08:35-10:59 UTC): a full host probe
before each part and after the last (five, **all clean**), `/proc/stat` logged
between parts (`results/p8k2r2-cpustat.log`; steal reads 0 throughout, so the
hypervisor does not report it here). **These are the k = 2.0 results.**

*Throughput at 400 VUs, k = 2.0 holds* (closed loop; about 990 req/s offered):

| | glibc | jemalloc | SAMM |
| :--- | ---: | ---: | ---: |
| Throughput, forward order | 969.4 req/s | 875.4 | 985.6 |
| Throughput, reverse order | OOM-killed | 877.6 | 986.6 |
| CPU used (user / kernel) | 0.98 (0.91 / 0.07) | 1.00 (0.83 / 0.17) | 0.95 (0.89 / 0.05) |
| CPU per request | 1.01 ms | 1.14 ms | 0.96 ms |
| Page faults per request | 9.79 | 78.6 | 3.10 |
| Peak memory | 1,003.7 MB | 844.8 MB | 948.8 MB |

- The two orders agree within 0.3 % for jemalloc and 0.1 % for SAMM (launch 1:
  18 % and 4 %), and SAMM with its counters polled gave 987.5. Launch 1 was the
  host.
- Only jemalloc is CPU-bound (859-878 req/s, as in calibration). SAMM serves
  the offered load with 5-6 % of the core to spare; its figure is a lower bound
  on its capacity. glibc serves it at 98 % CPU and at the memory limit: it
  survived once at 1,003.7 MB and was killed once.
- SAMM's arena budget is fully granted here too (702.5 MiB), with about 84
  allocations a second falling back to jemalloc (about 1 request in 12).

*Latency, shared rates, k = 2.0 holds* (open loop; processing time p95 / p99, ms):

| | glibc | jemalloc | SAMM |
| :--- | ---: | ---: | ---: |
| 20 req/s | 3.8 / 5.8 | 4.5 / 6.3 | 2.5 / 4.5 |
| 160 req/s | 7.9 / 11.7 | 9.1 / 13.1 | 6.0 / 10.0 |
| 320 req/s | 10.8 / 15.3 | 14.1 / 19.7 | 9.2 / 13.4 |
| 640 req/s | 23.2 / 33.4 | 42.0 / 57.1 | 16.3 / 21.7 |
| 820 req/s | 67.1 / 111.8 | OOM-killed | 30.3 / 42.9 |

Same order as at k = 2.5 at every rate: SAMM lowest, jemalloc highest and
killed at 95 % of its capacity. Not run at this k: each allocator at 80 % and
95 % of its own capacity (glibc and SAMM have no CPU capacity to take a share
of here; decided 2026-11-15).

**Phase 8 is reported from the k = 2.5 pass** (every allocator CPU-saturated,
which is what "throughput at saturation" needs); the k = 2.0 pass is its
supplement: with the main study's holds, SAMM serves the whole offered load
with CPU to spare, jemalloc saturates, glibc sits at the memory limit
(decided 2026-11-15, user). Results on the VM under
`internal-validation/results/`, copies in the laptop's `vm-results/phase8/`
and `vm-results/phase8-k2/` (without the raw sample files).

## Phase 9: external validation, the main study (about 2 days of machine time)

**From here to the end of the thesis every run is one command**
(`server/scripts/study.sh`, written and rehearsed 2026-11-15, before any
main-study run). It takes every setting from `infra/study.env` (k, pinning,
buffer mode, probe settings, seeds) and none from the shell, checks the
machine before it runs anything, is resumable, and refuses rather than guesses.
From the laptop:

```bash
infra/vm.sh start && infra/vm.sh update     # pull; refuses while anything runs on the VM
infra/vm.sh study pilot                     # start it detached; the VM powers off when it ends
infra/vm.sh wait                            # repeat until it says the VM is off
infra/vm.sh start && infra/vm.sh fetch benchmark-results/main-study-pilot
```

| Step | Command (after `infra/vm.sh study`) | Time | Results folder |
| :--- | :--- | :--- | :--- |
| 1. Pilot, 2 replicates, end to end | `pilot` | 1 h | `benchmark-results/main-study-pilot` |
| 2. **Main study, n = 100** | `main` | 42 h | `benchmark-results/main-study` |
| 3. GC pass, 3 replicates with the GC observer on | `gc` | 1.3 h | `benchmark-results/main-study-gc` |

What each run does, in order: preflight (tools, a clean checkout on `main`,
no other container or benchmark, the pinning fits, the probe reference
exists); the runs, through `run_replicates.sh`; then the integrity check, the
statistics and the figures (Phase 11), written under `<folder>/stats/`.

Three protections added on 2026-11-15, all before any main-study data:

- **Campaign lock.** The first start writes `campaign.json` into the results
  folder: load point, seeds, pinning, buffer mode, the table's hash and a hash
  of every file the measured system is built from. A resume with anything
  different is refused, so one folder never mixes two configurations.
- **Host probe inside the campaign.** The full probe runs before the first
  replicate of every start, before every 10th replicate (about every four
  hours) and after the last one. A failed probe waits ten minutes and tries
  again, up to six times, then stops the campaign (it resumes later). Every
  attempt is in `host-health.tsv`. This is the runbook's "probe before every
  batch and daily", built in, after the VM slowed by up to 18 % inside one
  boot on 2026-11-15 (Phase 8, launch 1). The order rotation already makes a
  slow stretch hit both conditions alike; the probe says when one happened.
- **Each result records more:** the buffer mode asked for and SAMM's count of
  shared Buffers (the allocator's own evidence of the mode it ran in), whether
  telemetry was on, the git commit, the hypervisor's steal time, and a hash of
  the image's layer digests. The **image ID is not an identity**: under
  Docker's containerd image store it changes on every build even when nothing
  was rebuilt (ten runs, ten IDs in the buffer-mode comparison), so the "image
  ID" frozen in Phase 6 identifies one build, not the image's content. What is
  held fixed across a campaign is the table's hash and the hash of the
  measured system's source (the campaign lock); the layer digests show
  whether the image was rebuilt from scratch part-way.

If a command prints `REFUSED`, read the reason; do not work around it. The
overrides that exist (`CAMPAIGN_ALLOW_CHANGE=1`, `--allow-integrity-errors`)
are recorded in the results and reported by the statistics.

**What each possible result means and what to do about it** (a run that stops
early, killed runs, a failed probe, a β step that refuses, what the thesis may
and may not say): `docs/finishing-the-thesis.md`. Read it before acting on any
result of Phases 9 to 11.

**Pilot, 2026-11-15** (`main-study-pilot`, seeds 20261114-15, through
`infra/vm.sh study pilot`): the command exited 0, both host probes clean,
integrity ok, chunk mode confirmed in both SAMM runs (1.47 and 1.54 million
shared Buffers), 14.2 minutes per run.

| | jemalloc | SAMM |
| :--- | ---: | ---: |
| Seed 20261114: peak / processing p99 / throughput | 802.6 MB / 172.5 ms / 751.6 req/s | 844.8 MB / 29.3 ms / 753.7 req/s |
| Seed 20261115 | **OOM-killed** at 1,020.1 MB, in the run's last seconds (1.4 % of requests failed) | 943.4 MB / 51.9 ms / 785.7 req/s |

The baseline survived seed 20261115 on 2026-11-13 at 964.9 MB (Phase 5's
pilot) and died on it today: on a heavy seed it sits at the limit, and which
side of it a run lands on varies. Expect baseline kills in the main study; if
they pass 10 % of its runs, survival is the principal result (rule of
2026-11-13).

**Main study launched 2026-11-15 12:17 UTC** (`infra/vm.sh study main`;
campaign lock: system `be95c55e9d5d`, table `b2318961ebee`). At 14.2 minutes a
run and eleven probes it should end near 2026-11-17 12:30 UTC.

**Result (finished 2026-11-17 12:28 UTC, exit 0).** Integrity ok: 200 runs,
every one of the twelve host probes passed, hypervisor steal 0 %, no run
timing-suspect. Copied to `vm-results/main-study/`; the report is
`stats/report.txt`.

- **Survival is the principal result:** 16 of 100 jemalloc runs were
  OOM-killed (r01-r04, r08, r28, r39, r41, r51, r62, r71, r78, r84, r89, r90,
  r97), none of SAMM's (Fisher p < .001, supplementary). Full-window
  throughput, every run counted: 756.4 against 792.6 req/s.
- **The three tests** (84 jemalloc runs, 100 SAMM; Mann-Whitney chosen for all
  three; α = 0.0167), all rejected: peak memory 843.6 ± 53.8 against
  890.7 ± 36.8 MiB (+5.6 %, against SAMM: the pool it reserves); processing p99
  184.6 ± 91.3 against 29.6 ± 14.0 ms (-84.0 %); throughput 768.7 ± 15.0
  against 784.0 ± 32.7 req/s (+2.0 %). jemalloc's completing runs are its
  lighter seeds; the paired supplement (84 seeds where both completed) agrees:
  +36.9 MiB, -159 ms.
- **Supporting, descriptive:** CPU 67.6 % against 54.7 % of the core; page
  faults per request 82.5 against 3.4; dropped iterations per run 3,422
  against 294.
- **Why throughput differs by only 2 %:** the throughput is the offered load.
  SAMM dropped a median 0.00 % of the requests offered (max 0.69 %), jemalloc
  0.28 % (max 6.29 %): at k = 2.0 most minutes are below both capacities and
  only jemalloc falls short at the peaks (Phase 5). The capacity gap is
  Phase 8's; here the efficiency gap shows in CPU.
- `stats/figures/campaign_order.png` from the VM joins points in text order
  (r10, r100, r11); regenerate it locally with the fixed script (commit
  99164fb): `venv/bin/python3 stats-eval/hypothesis-testing/main_study_figures.py vm-results/main-study`.

**GC pass launched 2026-11-17 13:25 UTC** (`infra/vm.sh study gc`).

**GC pass result (finished 14:59 UTC, exit 0).** Copied to
`vm-results/main-study-gc/`. The probe before replicate 1 passed; the one
after the last replicate failed on page writes (0.90x, at the limit). jemalloc
was OOM-killed in r01 and r03 (as in the main study, where r01-r03 jemalloc
were all killed), so only r02 has GC telemetry for both conditions. The
`gc_summary.md` written on the VM is wrong (baseline CPU 0.0 s from a killed
run, "-8 %, opposite sign"); regenerated locally with the fixed script
(commit 83a3130):

| r02, GC observer on | jemalloc | SAMM |
| :--- | ---: | ---: |
| Major GC cycles | 19,682 | 16,848 (-14 %) |
| Minor GCs | 33,763 | 28,053 |
| Total GC pause, s | 243.8 | 203.4 |
| CPU time, main study's completed runs (n = 84 / 100), s | 572.6 | 463.9 |

GC pause differs by -40.5 s per run against -108.6 s of CPU: 37 % of the CPU
difference, same sign (September, k = 1.0: about 5 %). Main-study r02 jemalloc
was killed, so the CPU is not from the same seed.

**Decided by the user 2026-11-17, the wording for Chapter 4:** GC accounts for
about a third of SAMM's CPU saving, through 14 % fewer major collections, an
effect of where Buffers live; the rest is outside GC. Stated with its caveats:
one replicate with both conditions instrumented, CPU from the main study's
completed runs rather than the same seed, and the observer perturbs the runs.
No further GC replicates.

## Phase 10: the panel's extra results (about 27 h of machine time at n = 15)

Run after the main study. Every variant retrains the table, so **each one gets
a branch of its own** (`git switch -c extras/...`) and the frozen main table on
`main` is never overwritten; `git switch main` brings it back. All variants use
the same 15 seeds (`SCHEDULE_SEED=20261300`), apart from the main study's, so
they can be compared with each other. Results land in a folder named after the
variant (`replicates-k2.0-mem2048m`, `replicates-k2.0-d08-d14`), and every
result file records its `mem_limit_mb` and `traffic_batch`. Tooling written and
tested on the laptop 2026-11-13 (2 GB and 4 GB tables compile and pass the
allocator's tests; one short 2 GB run on week-2 traffic).

**(a) 2 GB and 4 GB limits** (about 8 h each). Same load as the main study, so
memory stops being the constraint and the comparison shifts to CPU per request,
latency and how much memory each side holds.

```bash
infra/vm.sh study extra-mem 2048m      # then, when the VM is off and restarted:
infra/vm.sh study extra-mem 4096m
```

Each does, on its own branch (`extras/mem-2048m`): profile in a container of
that size, retrain, compile, run the allocator's tests; β exactly as in Phase 6
(a SAMM run with its counters, `derive_beta.py`, recompile, a confirming run);
commit the table on that branch; 15 replicates of both conditions; statistics;
back to `main`, checking that `main`'s table is still the main study's. It
stops, without running the 15 replicates, if a β run dies or if the confirming
run gives a smaller β than the one applied (the method iterates once; a second
iteration is a person's decision). A β above 1 is applied as 1.0: the pool
cannot be larger than the container allows. Interrupted, the same command
continues from the step it reached (`benchmark-results/extras-state/`).

- The quota step takes the container size from the trace's own record
  (`workload_manifest.json`), so a recompile on this branch is sized for 2 GB
  without being told again, and it refuses a size that disagrees with the trace.
- `run_replicates.sh` refuses to run SAMM when `MEM_LIMIT` is not the limit the
  table was trained for. Without that check a 1 GiB table would run in a 2 GB
  container unnoticed, because at k ≠ 1.0 the server's own check is switched off.
- State in the write-up: the pool's floors do not grow with the limit (they come
  from demand), only its ceiling does; and V8 sizes its own heap limit from the
  container, for both conditions alike.
- Optional second pass: holds ×2 / ×4 to keep memory pressure proportional.

**(a) 2 GB result (finished 2026-11-18 00:20 UTC, exit 0).** Copied to
`vm-results/replicates-k2.0-mem2048m/` (and the two β passes). Integrity ok,
every probe passed, steal 0 %.

*Layer 3 at 2 GB:* pool hard limit 1,860.1 MiB (1 GiB: 833.8). Pass 1 (β =
0.75, ceiling 1,395.1 MiB): memory outside the pool peaked at 128.0 MiB (1 GiB:
288.9), so C = 2,048 − 128.0 − 32 = 1,888 MiB and β = 1.015, above 1: applied
as 1.0, ceiling 1,860.1 MiB (floors 559.9 MiB, 1,300.2 MiB shared). Pass 2 at
1.0 gave β = 1.014 (outside peak 130.2 MiB): confirmed. Container peak in the
passes 1,103 and 1,100 MiB of 2,048. Table `dc19d07` on `extras/mem-2048m`.

*The 15 replicates (k = 2.0):* no run killed in either condition. Peak memory
910.5 ± 148.6 against 996.2 ± 74.3 MiB (+9.4 %, Mann-Whitney p = 0.013,
rejected, against SAMM); processing p99 246.3 ± 211.7 against 23.9 ± 5.4 ms
(−90.3 %, p < .001, rejected); throughput 777.9 against 796.8 req/s (+2.4 %,
p = 0.507, not detected at n = 15). CPU 67.3 % against 52.9 % of the core; page
faults per request 82.9 against 2.5; dropped iterations per run 11,000 against
415. Same picture as the 1 GiB study without the kills: memory no longer
binds, SAMM holds more of it, and the CPU, fault and latency gaps stay.

**(b) Azure days 1-7 against days 8-14** (about 13 h). The table is trained on
the first week's traffic and tested on both weeks. The two batches are already
built and committed under `datasets/azure-trace-2019/processed/{d01-d07,d08-d14}`
(the VM has no raw trace and needs none):

```bash
infra/vm.sh study extra-weeks
```

On branch `extras/week1`: the table is trained on days 1-7 (β as above), then
15 replicates on days 1-7 traffic and 15 on days 8-14, same seeds.

How the batches are built (`preprocessing/phase1-azure-simulation/_batch.py`):
`AZURE_DAYS=1-7 bash run_phase1.sh`, then
`AZURE_DAYS=8-14 AZURE_SCALE_FROM=d01-d07 bash run_phase1.sh`. With no setting
the scripts read every day and write where they always have, so the main
study's models are unchanged. `AZURE_SCALE_FROM` measures the second week on
the first week's scale (its traffic-state thresholds and its memory anchor): on
its own percentiles every batch is a quarter idle and a quarter busy by
construction, and no surge or quiet week could show. The memory files end at
day 12, so the second week's payload model is days 8-12.

What the two weeks look like (`batch_summary.py d01-d07 d08-d14`, at the main
study's 1,000 req/s peak):

| | d01-d07 | d08-d14 |
| :--- | ---: | ---: |
| days | d01, d02, d03, d04, d05, d06, d07 | d08, d09, d10, d11, d12, d13, d14 |
| states classified on | d01-d07 | d01-d07 |
| minutes | 10,080 | 10,080 |
| mean invocations / min | 133,490 | 134,202 |
| peak invocations / min | 209,993 | 768,890 |
| share of minutes: Idle | 25.0 % | 20.9 % |
| share of minutes: Ramp | 50.0 % | 59.0 % |
| share of minutes: Burst | 10.1 % | 7.1 % |
| share of minutes: Cooldown | 14.9 % | 13.0 % |
| long-run share of the walk: Idle | 25.2 % | 21.1 % |
| long-run share of the walk: Ramp | 50.0 % | 59.1 % |
| long-run share of the walk: Burst | 10.0 % | 7.1 % |
| long-run share of the walk: Cooldown | 14.7 % | 12.8 % |
| mean stay in Idle | 5.6 min | 4.8 min |
| mean stay in Ramp | 6.2 min | 7.2 min |
| mean stay in Burst | 2.0 min | 2.0 min |
| mean stay in Cooldown | 1.9 min | 2.0 min |
| request rate in Idle | 748 req/s | 749 req/s |
| request rate in Ramp | 854 req/s | 845 req/s |
| request rate in Burst | 980 req/s | 1,000 req/s |
| request rate in Cooldown | 1,000 req/s | 999 req/s |
| mean request rate over the walk | 861 req/s | 856 req/s |
| hold time, median | 445 ms | 459 ms |
| hold time, 99th percentile | 2249 ms | 2355 ms |
| memory files (apps) | 21,409 | 21,421 |
| memory anchor (Azure, P99 app) | 670.7 MB | 670.7 MB (from d01-d07; own 706.2) |
| payload model, invocation-weighted median | 188.0 MB | 186.7 MB |
|   as allocated (largest = 16 MB) | 3.65 MB | 3.63 MB |

**The two weeks are close.** On the first week's scale the second has fewer
idle minutes (20.9 % against 25.0 %) and fewer busy ones (20.1 % against
25.0 %), a mean request rate within 1 % (856 against 861 req/s), holds 3 %
longer and payloads within 1 %. So this is a mild drift test, and "no
difference between the weeks" is the likely and honest result. It is not a
surge-against-off-peak contrast: summed over all HTTP functions the trace's
quietest state still runs at 75 % of its busiest, and the load generator maps
each batch's busiest state to `MAX_RPS`, so a batch's absolute level never
reaches the server. Surge against off-peak is what the load levels (k) show.

**(c) 2 GB at a load that saturates both** (about 9 h; added 2026-11-17, before
any 2 GB result existed). The 1 GiB study could not apply Phase 5's rule (the
lowest k whose peak covers both capacities): at k = 2.5 the baseline died in
every pilot run, so it stepped down to 2.0, where SAMM never reaches its
ceiling and the throughput gap is only the baseline's shortfall at peaks. In a
2 GB container memory need not bind, so the rule can be applied there. (a)'s
2 GB run stays as it is: it changes only the limit, which is what answers the
panel's question. This one is reported beside it, as each allocator's ceiling
when memory does not bind; it complements Phase 8 (saturation at 1 GiB, where
SAMM was limited by memory, not CPU).

```bash
infra/vm.sh study extra-sat 2048m        # after extra-mem 2048m
```

On branch `extras/mem-2048m-sat`, made from (a)'s 2 GB table:

1. Host probe, then both capacities at 2 GB, closed loop (`internal-validation/run.sh
   calibrate jemalloc samm`, `MEM_LIMIT=2048m`, k = 2.5 holds as in Phase 5,
   VUs 100-800).
2. **The k, decided by the user 2026-11-17 before any data:** 2.5 (1,250 req/s)
   if it covers both capacities, else 3.0 (1,500 req/s), and no higher. If
   SAMM never reaches 98 % CPU in the sweep and its capacity is under 1,250,
   that is only a lower bound and the script stops to ask. The choice is
   written to `extras-state/sat2048m/k.txt` and never revisited.
3. β pass at that k. If it gives the β the 2 GB table already has (likely 1.0,
   the cap), the table stands and the pass is its own confirmation; otherwise
   recompile, confirm once, commit, as in (a).
4. 15 replicates, same seeds as the other extras, into
   `replicates-k<k>-mem2048m`. Baseline kills there are results, as everywhere:
   there is no step-down.

**(c) launched 2026-11-18 02:04 UTC** (`infra/vm.sh study extra-sat 2048m`).
**It stopped at 02:39 UTC with an invalid calibration (exit 1).** The branch
was made from `extras/mem-2048m`, which predates the `MEM_LIMIT` setting in
`internal-validation/run.sh`, so the sweep ran in 1 GiB (both `run.json` say
`1024m`; SAMM was OOM-killed at 400 VUs, jemalloc at 600). The script refused
(SAMM below 98 % CPU), rightly but for the wrong reason. Set aside on the VM as
`extras-state/INVALID-sat2048m-calibrated-at-1GiB-20261118`, the branch removed
(it had no commits of its own). Fixed: the branch now starts from `main` and
takes only the table's files from `extras/mem-2048m`, and the k step refuses if
a calibration's recorded limit is not the one asked for. No k was chosen and
nothing was measured, so the decision rule is untouched.

## Phase 11: statistics and reporting

Every `study.sh` run ends with its own statistics, so nothing has to be
started by hand. To redo them for everything that exists (on the VM or, after
`infra/vm.sh fetch benchmark-results`, on a copy): `server/scripts/study.sh
stats`. Under each results folder's `stats/`:

| File | What it is |
| :--- | :--- |
| `report.txt` | integrity, run completion, the three primary tests, supporting measures, the paired supplement, the host-health sensitivity check |
| `tables.md` | Chapter 4's three tables, filled in |
| `tests.csv`, `descriptives.csv`, `survival.csv` | the same numbers, unrounded |
| `host_sensitivity.csv` | only if a host probe failed: the tests again without the replicates before it |
| `figures/primary_distributions.png`, `figures/campaign_order.png` | every run per metric; the metrics in campaign order |

and, at the top level, `benchmark-results/extras-summary.md` (the main study
and every extra side by side) and `main-study-gc/gc_summary.md`.

The method is the approved one (`main_study_stats.py`, written 2026-11-13
before any main-study data): Shapiro-Wilk and Levene, then an
independent-samples t-test or Mann-Whitney U; Bonferroni across the three
metrics (α = 0.017); the relative percentage difference per metric; survival
counts and full-window throughput if any run was killed. Two additions of
2026-11-15, also before any data, neither of which changes a test:

- **Integrity gate** (`verify_campaign.py`). The folder must be one coherent
  sample: complete, each replicate's two runs on one seed and in the planned
  order, one routing table, the buffer mode that was asked for, no telemetry.
  Otherwise nothing is tested and the reason is printed.
- **Host-health sensitivity.** If a host probe failed, the replicates between
  the last passed probe and the failed one are tested again without, and the
  report says whether any decision changes. Reported beside the main result,
  never instead of it.

Also for the write-up: the Layer 1 oracle matrix (Phase 4 step 5).

---

## Operations

- **Long jobs:** `infra/vm.sh study <command>` from the laptop (Phase 9). It
  starts the job through `infra/then-poweroff.sh`, detached: it survives a
  dropped SSH session and the VM powers off when it ends, so it stops costing
  money. While it runs, only `infra/vm.sh wait` and `status`: they ask Google,
  not the VM. Scripts are resumable.
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

The ISMM work (branch `ismm`, no dated go/no-go) can share the VM once the
thesis runs are done: its first experiments are the pooling baseline and one
real Buffer-heavy workload.
