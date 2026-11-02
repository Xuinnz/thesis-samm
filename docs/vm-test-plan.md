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
| **Load point** | Profile and train at **k = 1.0**. **Find the VM's near-saturation stress point first** (Phase 5), then lock the main study to it, as the paper states. |
| **Statistical metrics** (per run) | **Throughput:** achieved req/s (k6 `http_reqs` rate, the demo's number). **Latency:** processing time **p99** (report p95 too). **Peak memory:** peak RSS (cgroup `memory.peak`, reset at run start, the demo's number). Everything else on the dashboard is still collected. `_bench-lib.sh` / `run_replicates.sh` already use these definitions. |
| **Model changes** | Layer 1 **fixed at K = 2** with its limitation stated (2026-10-22), checked against the **reachability oracle** (Phase 4); **derive β from data** at the locked load point (two-pass). |
| **Timing fix** | Apply the `processing_time` fix to `samm-load-test.js` now: the earlier decision was "only if the realistic benchmark is re-run", and it will be. |

**Throughput, two meanings:** *achieved* = requests completed per second under
the realistic schedule (drops count against it); *capacity* = the closed-loop
maximum (internal validation). The statistics use achieved; at the stress point
it mostly reflects capacity.

### Still to decide (before Phase 5 ends)

- **How to choose the stress point.** Recommended: the highest k at which the
  jemalloc baseline is CPU-saturated (≥ 98 % of its vCPU, sustained) but still
  **survives** its 10-minute runs, so all three metrics are comparable for both
  conditions. Write the rule down **before** looking at SAMM's results, and
  apply it to the baseline only.
- **OOM-killed runs.** If a baseline run dies anyway, its metrics cover only
  the time it survived. Decide in advance: count survival as its own outcome
  (survival rate; Fisher's exact test), and either exclude killed runs from the
  three metric tests or analyse them separately. Optionally run a smaller
  survival experiment at a higher k.

---

## Phase 1: prepare on the laptop (before renting the VM)

1. **PENDING A3 fixes:** done 2026-11-02 except the empty Oct 8 recordings
   (your call). Two new ones from that batch: decide whether floors should be
   reserved at init (A3 item 9), and the failing steady-state allocator test
   (A3 item 10).
2. **Layer 1:** done: K fixed at 2 (be17915), the reachability oracle with
   its matrix analysis (77fc827), and the misroute wording (2026-11-02). The
   natural-break rule moved to ISMM (PENDING B3).
3. **β from data:** a helper that reads a SAMM run (with `POLL_SAMM_STATS=1`)
   and reports peak memory outside the pool (RSS − committed), then the
   ceiling C = 1024 − that peak − 32 MB and β = C ÷ 836 MB. The quota script
   already takes `SAMM_BETA_UTILIZATION`. Also measure the 80 MB V8 baseline.
4. **`processing_time` fix in `load-generator/k6-scenarios/samm-load-test.js`**
   (subtract the delay Node actually schedules, `Math.trunc(hold_ms)`, and
   count remaining clamps), as in `internal-validation/k6-scenarios/lib/workload.js`.
5. **Host probe:** replace the PowerShell clock check with an NTP check
   (`chronyc tracking`); keep checks 1-3, to be re-referenced on the VM.
6. **`run_replicates.sh`:** a way to choose conditions (`jemalloc samm` for the
   main study) and **rotate the condition order** across replicates.
7. **Optional (ISMM):** `run.sh` configs for page-keeping jemalloc
   (`MALLOC_CONF=oversize_threshold:0,dirty_decay_ms:-1,muzzy_decay_ms:-1`),
   SAMM with `SAMM_RECLAIM_POLICY=dontneed`, and the Buffer pooling baseline.
8. **Push `main`.**

## Phase 2: provision the VM (about a day)

- `t2d-standard-4` (4 full cores, no SMT, 16 GB), **on-demand**; Ubuntu 24.04
  LTS; 100 GB balanced persistent disk; a region that offers T2D.
- Install: Docker CE, **k6 v0.55.0**, Node 22, Python 3 + venv (pandas, numpy,
  scikit-learn, matplotlib), **Zig 0.15.2** (host: allocator tests and the
  microbenchmark), chrony (check it is in sync).
- Check and record: cgroup v2, swap off, THP `enabled` / `defrag`
  (expect `madvise` / `madvise`), kernel, Docker version.
- Clone the repo; build `samm-baseline:bench` and `samm-enabled:bench`;
  record image IDs.
- Core layout: core 0 for the OS; **core 1 for the server container**
  (`--cpuset-cpus=1 --cpus=1.0 --memory=1024m --memory-swap=1024m`);
  **cores 2-3 for k6** (`taskset -c 2,3`).
- Data: the profiling trace is regenerated on the VM. The raw Azure data
  (2.0 GB, not in git) is only needed for Phase 10b: upload or re-download it.

## Phase 3: health reference (half a day)

1. Run the clock check, k6 start-up, and a **reference microbenchmark** run.
2. **Set the probe limits from that reference** (same ±10 % bands as on the
   laptop) and write them down **before any benchmark**.
3. From then on: probe before every batch and once a day; a failed probe means
   stop and report.

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
2. **A short realistic k sweep** for the **jemalloc baseline** (one 10-minute
   run per k: 1.0, 1.5, 2.0, 2.5, and higher if needed): CPU, drops, peak
   memory, survival.
3. **Apply the pre-written rule** (see "Still to decide") to the baseline's
   results and **lock the main-study k**. Record it with the reasoning.

## Phase 6: derive β at the locked load point, then the final table (about a day)

1. Run SAMM at the locked k with `POLL_SAMM_STATS=1`: peak (RSS − committed)
   → C → β.
2. Recompile the table with that β (`SAMM_BETA_UTILIZATION`), rebuild the
   image, and **run once more to confirm** (iterate once: fewer fallbacks
   change the memory outside the pool).
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
2. **Main study:** `run_replicates.sh`, conditions **jemalloc, SAMM**,
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

`stats-eval`: Shapiro-Wilk and Levene, then t-test or Mann-Whitney, or the
**paired** versions (paired t / Wilcoxon signed-rank), since seeds are paired;
Bonferroni across the three metrics (α ≈ 0.017); effect sizes and confidence
intervals; survival rate if any run was killed; the Layer 1 oracle matrix
(Phase 4 step 5); figures.

---

## Operations

- **Long jobs:** `tmux` or `nohup`, logs to files. Scripts are resumable; a
  dropped SSH session doesn't lose a campaign.
- **Health:** probe before every batch and daily. Note VM restarts and Google
  maintenance events; discard an interrupted run, never patch it.
- **Backups:** copy results off the VM daily (`gsutil rsync` to a bucket, or
  `scp` to the laptop); snapshot the disk before major phases.
- **Fixed within a campaign:** image IDs, table, settings, environment.
- **Record per run:** machine type, zone, kernel, Docker, THP mode, image IDs,
  table hash (`run.json` already holds most of these).
- **Cost:** stop the VM between phases (the disk persists). Total machine time
  roughly 8-12 days including the extras; check current pricing (likely tens of
  dollars; new-account credits probably cover it).

## Rough calendar

| Week | Work |
|---|---|
| 1 | Phase 1 (laptop prep); Phases 2-3 (VM setup, health reference) |
| 2 | Phase 4 (characterization); Phase 5 (stress point); Phase 6 (β, final table); Phase 7 (microbenchmark); start Phase 8; ISMM pooling baseline if ready |
| 3-4 | Finish Phase 8; Phase 9 (n = 100); Phase 10 (extras); Phase 11 (statistics) |

The ISMM go/no-go (mid-December) can share the VM in week 2: its two decisive
experiments are the pooling baseline and one real Buffer-heavy workload.
