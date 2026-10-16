# Pending work — internal-validation

**The tool defense is done (2026-10-11).** Work resumes after the user's next
consultation. Nothing below is to be started until then. Resume from "Open
tasks", in order.

This folder is committed on the local branch `wip/internal-validation`. Keep it
private: do not push it. `results/` is gitignored and stays on disk.

## Done so far

**Suite.** `run.sh` (one container at a time, benchmark settings, cgroup
record every second, optional `POLL_SAMM_STATS=1`), `host-probe.sh` (four
checks, below), the three k6 scenarios, the analysis reports, and `README.md`.

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
equal medians, SAMM's tail tighter (p99 2.8 ms vs 5.1-6.3 glibc, 6.9-7.4 jemalloc).
Results: `results/calibrate-20261003-074658`, `results/throughput-20261003-082829`,
`results/latency-20261003-084551`.

**Timing fix (processing_time).** The server holds with `setTimeout`, and Node
truncates fractional delays to whole ms, so subtracting the fractional
`hold_ms` undercounted by up to 1 ms. `k6-scenarios/lib/workload.js` now
subtracts the delay Node actually schedules, and counts any remaining clamps in
`processing_clamped`. Checked live on Oct 4 (`results/latency-20261004-111551`,
glibc): held requests clamped to 0 went from 15.0 % to 0.7 % at 160 req/s, and
from 23.0 % to 2.9 % at 320 req/s.

**SAMM OOM at 500 VUs.** Instrumented re-run in `results/calibrate-20261004-110536`
(its `samm/allocator.jsonl` holds the counters):
- the pool reached its ceiling (626.9 of 627.1 MB) at 200 VUs and stayed there;
- fallbacks were all budget refusals, rising from 25/s to 97/s (0.1-0.3 % of allocations);
- detach failures and exhausted regions were 0;
- RSS grew 121 MB while the pool stayed flat.

During the 500-VU step `/samm/stats` stopped answering, so the last 34 s have no
counters. The cgroup shows faults per request rising from 10.9 to 15.9, then
25-35k faults/s at the end, with RSS going from 899 to 978 MB before the kill.
Containers reset cleanly after the deliberate OOM: checked and logged.

All of the above ran on the laptop (Ryzen 5 6600H, WSL2). It is pilot data now:
the final study moves to a cloud VM (task 1).

## Open tasks (in order)

1. **Move the final study to a dedicated-core cloud VM (GCP Tau T2D).**
   Replaces the old laptop tasks (fix the WSL clock, explain the page-fault
   anomaly, reverse-order replicate). Internal validation runs on the VM too,
   and comes first, because it sets the operating point there. Order:
   1. **Probe.** Port `host-probe.sh`: replace check 0 (it calls
      `powershell.exe`) with an NTP-based clock check, take a reference run on
      the VM for checks 1-3, and fix the VM's limits from that reference BEFORE
      any benchmark (never adjust them after seeing a result).
   2. **Calibrate glibc and jemalloc** (no routing table needed). Find the VM's
      CPU knee and confirm k = 1.0, the profiling load, sits well below it.
   3. **Profile and retrain on the VM** at k = 1.0, through
      `run_full_pipeline.sh` (see task 7). Fold in tasks 3 and 4 if ready; task
      4's two-pass calibration belongs here.
   4. **Calibrate SAMM** with the VM-trained table, then choose the operating
      point (the VM's equivalent of k = 2.5: a T2D core is not a 6600H core).
   5. **Throughput and latency validation** at that point. Extend the latency
      sweep past the shared ceiling. The calibration rule stops it at 80 % and
      95 % of the LOWEST capacity (on the laptop, jemalloc's 642 req/s gave
      510 and 610), so SAMM's own queueing onset was never reached: it was
      still flat at 610. Run each config on up to 80 % and 95 % of its OWN
      capacity (laptop equivalents: glibc ~615 / ~730, SAMM ~740 / ~880;
      recompute from the VM calibration). Report two views:
      - same absolute rate (the current table, extended for the configs that
        keep up);
      - same relative load (e.g. each config at 80 % of its own capacity), to
        separate "less CPU per request" from "steadier service time".
      Hypothesis to test: on the laptop glibc began queueing at ~66 % CPU
      (510 req/s × 1.287 ms) while SAMM was still flat at ~69 % (610 × 1.132
      ms). Queueing depends on utilisation AND service-time variability
      (Kingman), which fits SAMM having fewer page faults and GC pauses.
   6. **[review] Attribution and ablations** (added 2026-10-14 from the
      provisional conclusion; review before adopting). The pilot data can't
      yet separate why SAMM wins, so run these at the same operating point:
      - **Page retention.** With reclaim `none`, SAMM keeps its pages; 84 % of
        its CPU saving over jemalloc is kernel time (86 vs 7.8 page faults per
        request), and jemalloc has the lowest RSS because it gives pages back.
        Stock jemalloc (5.3.0 in the image) gives pages back: allocations
        ≥ 8 MiB go to a dedicated arena that purges immediately on free, the
        rest decay over 10 s, and purges skip `MADV_FREE` (muzzy decay 0).
        Stock glibc already keeps its pages (freed chunks stay in its free
        lists; its mmap threshold rises to 32 MB after warm-up), and SAMM still
        beat it by 14%. So the page-keeping baseline to add is jemalloc with
        `MALLOC_CONF=oversize_threshold:0,dirty_decay_ms:-1,muzzy_decay_ms:-1`
        (verified in the image: four 12 MB buffers left 12,677 dirty pages
        kept, 19 purged). Note: `glibc-tuned` is NOT page-keeping; it pins
        both thresholds to 128 KB, so every buffer ≥ 128 KB is mmapped and
        munmapped (pages returned): use it only as a low-RSS glibc point. Run
        SAMM with `SAMM_RECLAIM_POLICY=dontneed` to measure retention's share
        (bump segments only: the slab never returns pages under any policy).
        `run.sh` needs new configs for the jemalloc variant and SAMM-dontneed
        (it only knows glibc, jemalloc, samm, glibc-tuned).
      - **The ML vs simpler rules.** Layer 2 off (every managed site bump;
        then every site slab); Layer 3 off (one shared pool of the same total,
        no floors), or uniform quotas; Layer 1 replaced by a fixed overhang
        threshold; negative control: aggregate forced into SAMM (expect
        silent empty reads after detach, and see what memory does). Most of
        these need refinery or compiler options that don't exist yet, so this
        is implementation work.
      - For each: regenerate the table, rebuild, run throughput and latency
        (internal) plus the realistic benchmark, and compare with full SAMM.
      - **[review] Three measurements to add** (added 2026-10-15):
        1. **Huge-page counters.** Record the container cgroup's `anon_thp`
           and `thp_fault_alloc` (in `memory.stat`; present on this kernel)
           every second, plus `/proc/vmstat` `thp_fault_alloc` and
           `compact_stall` before and after each run. Indirect evidence that
           huge pages engage: in the Oct 8 demo SAMM's memory grew 775 MB in
           its first 2 s with only 53,682 faults (210 MB at 4 KB each). Shows
           whether huge pages engage and whether first touch stalls on
           compaction (host defrag is `madvise`). Checklist A9.
        2. **Cold vs warm SAMM** at the same load (`SAMM_WARMUP=false` vs
           `true`), comparing the first ~20 s: processing p95 (cold: ~275 ms
           for ~15 s, then ~50 ms), drops (cold: 1,102 of 2,130 in the first
           7 s), and memory headroom (the demo README measured warm SAMM at
           the 1 GB limit for 39 s on a 1-minute k = 1.0 run). Warmup only
           pre-faults the floors (~439 MB), not the ~190 MB of elastic
           segments. Tests the cold-start explanation.
        3. **Per-arena live-bytes counter** in SAMM, exposed through
           `/samm/stats` and sampled once a second: live bytes vs committed
           per arena, i.e. a fragmentation ratio over time (start-up vs
           steady state), separating pinned waste from free segments and slots
           held as spare capacity. Implementation work: `release` currently
           gets only the segment or slot index, so the object size must be
           tracked to subtract it. Checklist A8.
      - **[review] Validate Layer 2's bump-waste estimate** (found
        2026-10-15). `bump_extra = arrival rate × σ(time to request end) ×
        mean size` (`02_aggregate_call_sites.py`) is a first-order heuristic,
        not a model of the SEGMENTED arena. A straggler pins only its own
        segment, which is then held until its slowest member dies, so the
        real waste depends on objects per segment (expected maximum lifetime
        of the n objects sharing it, not σ), on the tail shape (fetch and
        ingest holds are log-normal), on skipped segment tails when the next
        object doesn't fit (process: objects up to 16 MB in 28 MB segments),
        and on the half-filled current segment. None of these is in the
        formula, and segment size (floor ÷ 8) is only fixed in Layer 3, after
        Layer 2 has used the estimate. Decisions at risk: only **ingest**
        (bump 8.9 vs slab 14.9 MB, a 1.7× margin); process (55×), batch (18×),
        fetch (slab exact at 0) and cache (tie) are safe. To do: replay the
        trace through the real engine (`microbench/engine_bench`) with the
        per-arena live-bytes counter, measure each site's actual bump waste
        (pinned + skipped bytes) and slab waste, compare with the formula,
        then either replace it with a segment-aware estimate or use the
        replayed numbers (the same simulator could serve task 4's option a).
      - **[review] Fix the GC kind labels** (found 2026-10-15). In
        `server/routes/_telemetry.js`, `GC_KIND_NAMES` is one bit off from
        Node's constants (Node 22: MINOR 1, MAJOR 4, INCREMENTAL 8, WEAKCB 16;
        the file has 2 = major, 4 = incremental, 8 = weakcb). So every
        "incremental" count so far is really major GCs and every "weakcb"
        count is incremental marking. Fix the map (better: read
        `perf_hooks.constants`), and correct the labels in
        `benchmark-results/gc-control/README.md` and `summary.txt`. Also
        record GC telemetry in an instrumented pass at the saturation point
        (gc-control has GC data only at k = 1.0, unsaturated).
   7. **Main study** (n = 100 runs), alternating SAMM and baseline so any drift
      or live-migration stall hits both conditions alike.

   Notes:
   - Machine: e.g. t2d-standard-4. Each vCPU is a full core (no SMT): pin the
     server container to one core (keep `--cpus=1.0 --memory=1024m`, swap off)
     and run k6 on the others. Avoid burstable types (e2-micro/small); use spot
     VMs only if each run can be retried safely.
   - Record the environment: machine type, zone, kernel, Docker version, THP
     mode (the design expects `madvise`).
   - Getting the code there: this branch exists only on the laptop. Copy it
     with a git bundle or `scp`; do not push it. `results/` will not come along.
   - No need to redo on the VM: the `processing_time` fix (Node behaviour;
     `processing_clamped` is recorded on every latency run anyway), the
     detached-Buffer behaviour, and the offline Layer 1 simulation.
   - Disclose for the laptop pilot data: the WSL VM clock ran at 92.7-99.99 %
     of real time depending on the session, and Hyper-V time sync stepped the
     wall clock forward (k6 latency spikes; monotonic-timed figures read
     short). The host's cost per page fault also varied between sessions
     (native jemalloc + page writes 0.76x of the Sept 19 reference on Oct 4,
     while fault counts per request were unchanged).

2. **Fix two inaccurate tooltip texts in `demo/ui/v2.html`** (unblocked: the
   frontend PR is merged; lines 147 and 165 on `main`):
   - "Page Faults / s" says "Memory pages loaded from disk per second", but
     they are first-touch faults;
   - "Dropped" says "Requests that were dropped or failed", but it counts
     dropped iterations only.

3. **Layer 1's System rule (design limitation, found 2026-10-08).**
   `ml-refinery/policy-assignment/01_variance_threshold_policy.py` always sends
   exactly one cluster to System, the one with the highest mean overhang, and
   its own TODO says so. Simulated with the real k-means settings:
   - with only request-scoped sites, process, ingest and fetch (24-25 ms) would
     go to System (safe, but a lost optimization);
   - with escaping sites at 1 s and 10 s, the K>=3 floor splits them and the
     1 s site lands in a SAMM arena.
   A misrouted escaping buffer is NOT memory corruption, because detach cuts
   off access. But the data is silently lost: a detached Buffer reads
   `length 0`, `toString() ""`, `write()` returns 0, and only bounds-checked
   reads such as `readUInt8` throw. Fix: decide System by a significant natural
   break in log-overhang (above the largest gap, if the gap clearly exceeds GC
   delay), allowing zero or several System clusters. Also correct the wording
   that claims misroutes surface loudly:
   - `zig-allocator/src/node-api-interface/addon.zig` (the REGIONS block and
     `reclaimEntry`) says a detached buffer "throws" / "fails loudly". In fact
     most operations see an empty buffer; only bounds-checked reads throw.
   - The demo's Layer 1 card shows "safety net held" when detach failures are
     0, and the comment in `renderValidation` (`demo/ui/js/dashboard.js`) says
     a misroute would surface there. Neither detach failures nor failed
     requests would reveal a misrouted escape.
   Re-check whether the K>=3 floor is still needed now that the clustering uses
   overhang. This means retraining and re-benchmarking.

4. **Layer 3: replace the fixed beta (0.75) with a data-derived pool ceiling
   (idea from the user, 2026-10-08).** System call sites are already sized from
   data: their measured peak of 66.0 MB × 1.15. Beta covers the fallback path:
   managed allocations the pool refuses go to malloc, outside both the pool
   and the System reservation. Characterization runs without SAMM, so the
   trace can't show those refusals, and that circularity is why beta is
   fixed. Two ways to derive it:
   (a) Simulate the arenas against the trace for a candidate ceiling C
       (floors, budget, segment pinning), and take the largest C with
       C + peak_fallback(C) + System + V8 baseline + margin <= container.
   (b) Two-pass calibration: run SAMM at the characterized load, record
       RSS - pool committed each second (V8 + System + fallback), set
       C = container - that peak - margin, and iterate once. The k=1.0
       gc-control run had RSS 876 MB with 626 MB committed, so about 250 MB
       sat outside the pool, which suggests C of roughly 740 MB (beta about
       0.89) before iterating. On the Oct 8 k=2.5 demo run, SAMM sat at
       844 MB anonymous memory after the run against a planned 783 MB
       (80 V8 + 76 System + 627 pool).
   Also measure the hardcoded 80 MB V8 baseline the same way. Either change
   means retraining and re-benchmarking; do it on the VM (task 1, step 3).

5. **Confusing folder name: `datasets/shadow-telemetry/intermediate/ml-refinery/`.**
   This is the refinery's OUTPUT data (clusters, policies, quotas, metadata),
   following the pipeline's `intermediate/<stage>/` layout. It is not code: the
   code is the top-level `ml-refinery/`. Renaming it (e.g. to
   `intermediate/step7-ml-refinery/`) is cosmetic. Do it before the VM run so
   the paths are settled. Update every path in:
   - writers: `ml-refinery/clustering/01_kmeans_strata_discovery.py`,
     `ml-refinery/policy-assignment/01_variance_threshold_policy.py`,
     `ml-refinery/quota-calculation/01_calculate_spatial_quotas.py`;
   - readers: `ml-refinery/table-compiler/01_compile_routing_table.py` (2 paths),
     `demo/table.js` (routing-table view and ML validation card),
     `zig-allocator/microbench/extract_trace.js`, and the comments in
     `zig-allocator/tests/hash_parity_test.zig` and the generated
     `model_weights.zig` header (regenerate the table).
   Then check that the demo's table and ML card still load, and run the tests.

6. **Stale comments about floors (comment-only fix).**
   `ml-refinery/table-compiler/01_compile_routing_table.py` (header: "floor =
   P_j ... reserved against the global budget at startup") and the text it
   emits into `model_weights.zig` ("Sum of the guaranteed floors, charged
   against the ceiling at startup") are both out of date. Floors are now the
   90th-percentile demand capped at 70 % of the pool, and bump (`chargeSegment`)
   and slab charge the budget on FIRST TOUCH, not at startup. Fix the wording in
   the compiler, then regenerate; the numbers should come out identical.

7. **`server/scripts/run_characterization.sh` defaults do not match the real
   profiling run.** Run on its own it uses 50 req/s, 50-200 VUs and 20 min. The
   trace was made through `run_full_pipeline.sh` at k = 1.0: MAX_RPS 500,
   400-1,400 VUs, HOLD_SCALE 4, PROCESS_HOLD_MS 600, 10 min, seed 19870601.
   Align the defaults or make it refuse to run without them, so the VM profile
   cannot be taken at the wrong load.

8. **`preprocessing/phase2-ml-telemetry/run_phase2.sh` prints the wrong
   banner:** "=== [Phase 1] Starting Azure Simulation Preprocessing ===",
   copied from the Phase 1 runner.

9. **Demo leftovers: two aborted runs show in History.** Started and stopped
   after about 4 s on 2026-10-08 at 21:50, 0 requests each:
   `demo/recordings/SAMM-baseline-k2.5-s2025-2026-10-08T13-50-09-662Z.jsonl`
   and `SAMM-samm-k2.5-s2025-2026-10-08T13-50-30-248Z.jsonl`, plus their
   `-final.json`. They no longer become the reference line (fixed on `main`,
   2ee8749). Move or delete them: the user's call.

10. **Statistical evaluation (`stats-eval/`): deferred until after the
    n = 100 runs (user's decision).** All three folders hold only `.gitkeep`.
    The README promises Shapiro-Wilk and Levene, then a t-test or Mann-Whitney
    U, with Bonferroni-adjusted alpha = 0.017 across the three metrics, plus
    the misclassification matrix (ML assignment vs compiled routing table;
    6 of 6 on the diagonal for the current table).

## Decisions already made (by the user)

- The final study runs on a cloud VM (GCP Tau T2D). The laptop runs are pilot
  data and are not mixed with VM results.
- `stats-eval` waits until after the n = 100 runs.
- The probe's V8/GC limit stays two-sided (0.90-1.10x). Do not make it
  one-sided: the write path running "faster than the reference" is a real
  anomaly, and the configs differ exactly in fault behaviour.
- A failed probe means stop and report. No rebooting on my own, and no
  loosening a limit after seeing a result.
- `load-generator/k6-scenarios/samm-load-test.js` stays untouched. The fixed
  metric here is the one used going forward. Apply the same fix there only if
  the realistic or gc-control benchmark is re-run before submission. The ~2 ms
  alloc p95 figure is not cited in the paper (confirmed).
- No longer-timeout re-run of the 500-VU stats: the indirect evidence is enough.
- This branch stays local and private.

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
  amount each WSL boot: 92.7 % on Oct 4, 98.5 % on Oct 8 afternoon, 99.99 %
  on Oct 8 evening (hyperv_clocksource_tsc_page), 98.2 % on Oct 9 (tsc).
  Hyper-V time sync (`hv_utils.timesync_implicit=1`) then steps the wall clock
  forward. k6 times requests with the wall clock, so latency spikes appear at
  each jump. The sysfs clocksource switch does not survive a WSL/Windows
  restart, and switching did not reliably fix the rate. Ratios within one
  session are fine; absolute numbers from different sessions need each
  session's clock rate.
- **Demo recordings.** Most demo sessions have clock jumps. Clean pairs (no
  wall-clock jumps):
  - Sept 25: `demo/recordings/BASELINE-baseline-k2.5-s2025-2026-09-24T23-03-57-170Z.jsonl`
    and `BASELINE-samm-k2.5-s2025-2026-09-24T23-08-17-730Z.jsonl`;
  - Oct 8 (VM clock measured at 99.99 % that evening):
    `demo/recordings/SAMM-baseline-k2.5-s2025-2026-10-08T13-27-11-406Z.jsonl`
    (OOM-killed at ~151 s of load) and
    `SAMM-samm-k2.5-s2025-2026-10-08T13-31-45-401Z.jsonl`
    (918 req/s, 1.2 % dropped, 0 failed).
- **Running the probe from `main` without switching branches:** copy it out
  with `git show wip/internal-validation:internal-validation/host-probe.sh`
  into a scratch folder `<dir>/internal-validation/`, and add links named
  `datasets`, `load-generator` and `zig-allocator` in `<dir>` pointing at the
  repo. The probe finds the repo relative to its own location.
- **Long jobs.** Run them detached (`setsid nohup ... &`) and watch the log;
  background tool calls die after about 30 min. `/tmp` is wiped when Windows or
  WSL restarts, so keep scripts in the repo.
- **This branch is one commit behind `main`.** It does not have 2ee8749 (the
  demo fixes), so run the demo from `main`, or merge `main` in first.
