# Paused work — internal-validation

**Paused 2026-10-08 to focus on the tool defense.** Resume from "Open tasks"
below, in order. Nothing in this folder is committed yet (it is untracked).

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

## Open tasks (in order)

1. **Fix the VM clock.** TRIED on 2026-10-08, and it did NOT help. After
   switching to `hyperv_clocksource_tsc_page` (done as root through
   `wsl -d Ubuntu -u root`), the VM clock still read 98.5 % of real time, the
   same as with `tsc` (probe in `results/host-probe-20261008-171955-k6-clockfix`).
   Checked against internet time (NTP, time.google.com, 60 s): Windows' clock
   reads 100.01 % of real time and the VM's monotonic clock 98.46 %. So
   Windows is right and the VM is slow, but the slowness is in Hyper-V's time
   base for the VM, not in how the kernel converts CPU ticks. The clock source
   doesn't matter. (The switch reverts at the next WSL restart; both clock
   sources run at the same rate.) Remaining options, all needing a decision:
   - a time daemon inside WSL (e.g. chrony, steered by NTP or Hyper-V's PTP
     clock `/dev/ptp0`) that corrects the kernel's clock rate. That would remove
     both the slow monotonic clock and the wall-clock jumps. It needs `apt` and
     sudo, and its rate correction must reach about 2-8 % (beyond the plain
     500 ppm limit).
   - `wsl --update` and/or Windows power-plan changes, then re-measure.
   - Or accept the drift: the probe's check 0 records it each session.
     Correct monotonic-timed figures by the measured rate; the wall-clock jumps
     still distort k6 latencies.
   Do NOT use `wsl --shutdown`: it kills any running Claude session.
2. **Understand, or at least disclose, the write/fault anomaly before any
   replicate.** On Oct 4, native page writes (jemalloc, no V8) ran at 0.76x of
   the Sept 19 reference (about 0.82x after correcting for the clock), while pure
   CPU work ran at 1.03x (about 1.11x corrected). SAMM's page faults per request
   were the same as on Oct 3. Fault counts don't depend on the clock, so what
   changed is the host's cost per fault, not the application. Next steps, after
   the clock fix:
   - run the full probe (`internal-validation/host-probe.sh internal-validation/results/host-probe-<date>`);
   - measure the cost of one page fault directly (the Python mmap test: 256 MB,
     one write per 4 KB page, first pass minus second pass). It was 3.49 µs on Sept 25.
3. **Reverse-order throughput replicate.** HOLD until 1 and 2 are settled and
   the full probe passes on its own terms:
   `SKIP_BUILD=1 SATURATION_VUS=350 internal-validation/run.sh throughput samm jemalloc glibc`
   Then compare with `results/throughput-20261003-082829`.
4. Later, after the frontend PR is merged, fix two inaccurate tooltip texts in
   `demo/ui/v2.html`:
   - "Page Faults / s" says "loaded from disk", but they are first-touch faults;
   - "Dropped" says "dropped or failed", but it counts dropped iterations only.

5. **Layer 1's System rule (design limitation, found 2026-10-08).**
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
   delay), allowing zero or several System clusters. Also correct the comments
   in `zig-allocator/src/node-api-interface/addon.zig` (the REGIONS block and
   `reclaimEntry`): they say a detached buffer "throws" / "fails loudly". In
   fact most operations see an empty buffer; only bounds-checked reads throw.
   Re-check whether the K>=3
   floor is still needed now that the clustering uses overhang. This means
   retraining and re-benchmarking.

6. **Layer 3: replace the fixed beta (0.75) with a data-derived pool ceiling
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
       0.89) before iterating.
   Also measure the hardcoded 80 MB V8 baseline the same way. Either change
   means retraining and re-benchmarking.

7. **Confusing folder name: `datasets/shadow-telemetry/intermediate/ml-refinery/`.**
   This is the refinery's OUTPUT data (clusters, policies, quotas, metadata),
   following the pipeline's `intermediate/<stage>/` layout. It is not code: the
   code is the top-level `ml-refinery/`. Renaming it (e.g. to
   `intermediate/step7-ml-refinery/`) is cosmetic. Do NOT move it before the
   defense: `demo/table.js` reads the policy CSV from it for the routing-table
   view and the ML validation card. If it is moved later, update every path in:
   - writers: `ml-refinery/clustering/01_kmeans_strata_discovery.py`,
     `ml-refinery/policy-assignment/01_variance_threshold_policy.py`,
     `ml-refinery/quota-calculation/01_calculate_spatial_quotas.py`;
   - readers: `ml-refinery/table-compiler/01_compile_routing_table.py` (2 paths),
     `demo/table.js`, `zig-allocator/microbench/extract_trace.js`, and the
     comments in `zig-allocator/tests/hash_parity_test.zig` and the generated
     `model_weights.zig` header (regenerate the table).
   Then check that the demo's table and ML card still load, and run the tests.

8. **Stale comments about floors (comment-only fix).**
   `ml-refinery/table-compiler/01_compile_routing_table.py` (header: "floor =
   P_j ... reserved against the global budget at startup") and the text it
   emits into `model_weights.zig` ("Sum of the guaranteed floors, charged
   against the ceiling at startup") are both out of date. Floors are now the
   90th-percentile demand capped at 70 % of the pool, and bump (`chargeSegment`)
   and slab charge the budget on FIRST TOUCH, not at startup. Fix the wording in
   the compiler, then regenerate; the numbers should come out identical.

## Decisions already made (by the user)

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

## Probe history (x = ratio to the Sept 19 reference; lower is faster)

| Probe | k6 startup | V8 | V8 + page writes | GC per collection | Result |
|---|---|---|---|---|---|
| Oct 3 07:43 | 62.1 s | 1.04x | 1.04x | 1.03x | pass |
| Oct 3 21:20 | 71.4 s | 0.98x | 0.8977x | 0.98x | fail (writes fast) |
| Oct 3 21:38 | 87.2 s | 1.06x | 0.93x | 1.06x | fail (k6 slow, browser open) |
| Oct 4 10:58 | 58.2 s | 0.90x | 0.81x | 0.89x | fail (writes fast; native jemalloc+writes 0.76x, engine 1.03x) |

## Things to remember

- **WSL clock drift.** The VM clock (clocksource `tsc`, calibrated once at boot)
  can run slow by a different amount each WSL boot: 92.7 % on Oct 4, 98.5 % on
  Oct 8, about 100 % on Oct 3. Hyper-V time sync (`hv_utils.timesync_implicit=1`)
  then steps the wall clock forward. k6 times requests with the wall clock, so
  latency spikes appear at each jump. Anything timed with the monotonic clock
  reads short. Ratios within one session are fine; absolute numbers from
  different sessions need each session's clock rate. `host-probe.sh` check 0
  now catches it (limit +-1 %).
- **Demo recordings.** Most demo sessions have clock jumps. The clean pair is
  Sept 25: `demo/recordings/BASELINE-baseline-k2.5-s2025-2026-09-24T23-03-57-170Z.jsonl`
  and `BASELINE-samm-k2.5-s2025-2026-09-24T23-08-17-730Z.jsonl`.
- **Long jobs.** Run them detached (`setsid nohup ... &`) and watch the log;
  background tool calls die after about 30 min. `/tmp` is wiped when Windows or
  WSL restarts, so keep scripts in the repo.
- **Frontend PR.** The resolved merge is commit `384d9c3` on the local branch
  `frontend`. It needs `git push origin frontend` from your terminal (Claude's
  shell has no GitHub credentials). Check whether that's already done.
