# internal-validation — controlled throughput and latency experiments

## Why this folder exists

The realistic benchmark (`load-generator/k6-scenarios/samm-load-test.js`) replays
a Markov-simulated day of traffic. That is **external validity**: does SAMM help
under traffic that looks like production? Its weakness is that throughput and
latency move together there. Bursts raise both at once, so a difference between
allocators could come from either.

This folder adds **internal validity**: two deliberately artificial experiments,
each holding everything fixed except the thing it measures.

| Experiment | Question | Load | Result |
|---|---|---|---|
| `throughput-saturation.js` | How much work can each config finish per second at most? | closed loop, a fixed number of VUs, always saturated | completed requests / s in a steady window |
| `latency-baseline.js` | What does each config's allocator cost per request, when nothing queues? | open loop, fixed low rates | the full processing-time distribution per rate |

Nothing outside this folder was changed. The request logic of
`samm-load-test.js` (endpoint weights, payload sampler setup, hold model, the six
endpoint handlers, the `processing_time` pattern) is **duplicated on purpose**
into `k6-scenarios/lib/workload.js`, with a comment saying so. If the realistic
script changes how a request is built, change it there too. `jitter.js` and
`payload-sampler.js` are imported unmodified; `markov-chain.js` is not used (its
small `makeRng` is copied, so seeded request streams match).

```
internal-validation/
  run.sh                        runs an experiment against each config, one container at a time
  host-probe.sh                 the host-health check to run before benchmarking
  k6-scenarios/
    throughput-saturation.js    Experiment 1
    calibrate-saturation.js     finds SATURATION_VUS for Experiment 1
    latency-baseline.js         Experiment 2
    lib/workload.js             the duplicated request logic
    lib/run-shape.js            phases, sequential steps, summary helpers
  analysis/                     Python (pandas + numpy; matplotlib for plots)
    calibration_report.py  throughput_report.py  latency_report.py  common.py  requirements.txt
  results/                      created by run.sh, ignored by git
```

## What stays the same across every run

- **The same requests for every config.** `SEED` (default 20250911, the
  validated benchmark's) fixes request N's endpoint, payload and hold. So every
  config serves the same request stream, and the comparison is paired.
- **The same containers as the benchmark.** 1 GB memory, swap off, 1 vCPU,
  jemalloc preloaded where the config calls for it. The settings mirror
  `server/scripts/_bench-lib.sh`. One container runs at a time, so configs never
  share the CPU.
- **Holds scaled to keep memory where the table was trained.** At saturation
  the server finishes roughly 700–950 requests/s. With the validated k=1.0
  holds (fetch averages 2.3 s), that would keep about 2.5× the memory live that
  the routing table was fit to, and the baselines would be OOM-killed. `run.sh`
  therefore takes the holds for `LOAD_K` from `demo/loads.js`, the repo's load
  table. Rate scales by k and every hold by 1/k, so rate × hold (live memory)
  stays constant. The default is `LOAD_K=2.5`, the table's highest point (holds
  ×0.4), used by all three scenarios so they share one workload shape. SAMM's
  boot check hashes hold and rate separately and can't see that the product is
  unchanged, so at k≠1.0 `run.sh` sets `SAMM_ALLOW_WORKLOAD_MISMATCH=true`,
  exactly as the demo does. With `LOAD_K=1.0` the check verifies normally, but
  then keep the rates well below saturation.

## Experiment 1 — throughput at saturation

**Load: closed loop** (`constant-vus`). `SATURATION_VUS` virtual users each send
their next request as soon as the previous one returns. With enough of them the
server always has work waiting, so the rate at which requests complete is its
capacity.

**Why not a fixed arrival rate.** The first design was one open-loop rate above
every config's capacity, with no drops allowed. That can't work here. Capacities
differ by about 30% (on the Ryzen 5 6600H, roughly 925 req/s for SAMM and 695
for jemalloc). At any rate above SAMM's limit, jemalloc's backlog grows by
hundreds of requests per second, about 67,000 waiting requests over a few
minutes, each needing its own VU and connection. A closed loop can't drop
(there's no schedule to fall behind), and its queue is bounded at
`SATURATION_VUS`.

**Phases.** `WARMUP_SECONDS`, `MEASURE_SECONDS` and `COOLDOWN_SECONDS` (default
60 / 180 / 30). Each finished iteration is counted under the phase it **completed**
in, using k6's monotonic clock (the WSL wall clock can step). Only the MEASURE
window counts:

- **Warmup is discarded** because it covers JIT compilation, the allocator
  committing its first pages, and the queue filling up.
- **Cooldown is discarded** because it absorbs the requests cut off at the end.

**Result:** completed requests in MEASURE ÷ `MEASURE_SECONDS`.

**A run only counts if all of these hold** (`throughput_report.py` checks each):

| Check | Why |
|---|---|
| `dropped_iterations` = 0 | always reported; a closed loop should never drop |
| no failed requests in MEASURE | errors finish fast and would inflate throughput |
| container not OOM-killed | its number would be cut short |
| container CPU ≥ 90 % of its vCPU during MEASURE | otherwise k6 was the limit, not the server; raise `SATURATION_VUS` |
| steady per-second series (CV ≤ 15 %, drift ≤ 10 %) | warning only: a drifting window is not a steady state |

The report also gives each config's CPU split into **user** and **kernel** time,
its page faults per request, and peak memory, all from the container's cgroup.
Page faults and returning memory to the kernel count as kernel time; GC and
JavaScript count as user time.

Latency isn't measured here. A closed loop understates it, which is what
Experiment 2 is for.

### Calibration: finding SATURATION_VUS

`SATURATION_VUS` has no default on purpose. Run `calibrate-saturation.js`, a
short closed-loop sweep (one step per value in `CAL_VUS`, 45 s each by default,
15 s of it warmup, then a 10 s gap), against every config. Below saturation,
more VUs means more throughput. At saturation it stops: extra VUs only wait in
line, so throughput flattens while processing time climbs.
`calibration_report.py` reports per config:

- **Capacity:** the highest throughput any valid step reached.
- **Knee:** the fewest VUs that reach 97% of capacity.

It recommends `SATURATION_VUS` = highest knee × 1.15, never above the largest
VU count every config survived without errors (the slower configs run out of
memory first). It warns if a config never flattened, which means `CAL_VUS`
should go higher.

The same report also suggests the latency sweep: rates doubling up to 80% of
the lowest capacity, then one step at 95%.

## Experiment 2 — latency below saturation

**Load: open loop** (`constant-arrival-rate`) at fixed rates. An open loop sends
on schedule whatever the server does, so slow responses can't hide by delaying
the next request (the coordinated-omission problem a closed loop has).

**What's measured:** `processing_time` = `http_req_duration` − the artificial
hold: the allocator's and server's own cost per request, without the simulated
downstream wait. The server holds with `setTimeout(resolve, hold_ms)`, and Node
truncates fractional delays to whole milliseconds. Subtracting the fractional
value k6 sent undercounts by up to 1 ms. In the 2026-10-03 run, 13–25% of held
requests at 160–320 req/s were clamped to 0 that way. This suite subtracts the
delay Node actually schedules (`samm-load-test.js` does the same since
2026-10-21).

Some error can't be removed from the client. libuv keeps time in whole
milliseconds, so a wait can start up to 1 ms before the call, and the event loop
can fire it late. That leaves about ±1 ms on the three held endpoints (fetch,
ingest, process). Remaining negatives are still clamped to 0, and counted in
`processing_clamped`. The three non-held endpoints (cache, batch, aggregate)
have nothing subtracted, so their times are exact. **Take medians and anything
under a millisecond from those.** `latency_report.py` prints both groups.

**The rate sweep.** `LATENCY_RPS_SWEEP` (e.g. `10,20,40,80`, or a single
`LATENCY_RPS`) runs one step per rate, back to back. Each step is
`LATENCY_STEP_SECONDS` long (default 60), starts with a discarded
`LATENCY_STEP_WARMUP_SECONDS` (default 10), and is followed by a
`LATENCY_GAP_SECONDS` drain (default 15). VUs are sized from the hold model,
rate × mean hold × 4 + 20, and all of them are created before the test starts.

Below saturation the distribution should stay put as the rate rises. If it
shifts, requests have started queueing, and from that rate on the numbers no
longer describe the allocator alone. `latency_report.py` compares each step
with the same config's lowest rate:

| Measure | Gate |
|---|---|
| p95 ratio (this step ÷ lowest step) | ≤ 1.5 |
| drift: rise of the per-second median across the step | ≤ 0.5 × lowest-step p95, at least 5 ms |
| dropped iterations or failed requests | none (a drop means the generator fell behind) |
| KS distance between the two distributions | shown, not gated: with thousands of samples it flags differences too small to matter |

A step passing all of them is **flat**. The first step that fails is where
queueing begins for that config. The limits are command-line options.

**The full distribution, not just percentiles.** k6's `handleSummary()` only
ever receives aggregates; individual samples never reach it. So the raw values
come from k6's own sample stream: `run.sh` always runs k6 with
`--out csv=raw.csv.gz`. Every `processing_time` row is tagged with `step`,
`phase`, `endpoint` and `t_s` (second within the step). As well,
`handleSummary()` writes each step's whole quantile function (every 0.5% from
0.5 to 99.5, plus 99.9 / 99.95 / 99.99), so the analysis can still plot
distributions if the raw file is missing.

## Running it

**Prerequisites:**
- Docker, k6, Node and Python 3.
- matplotlib for the plots: `venv/bin/pip install -r internal-validation/analysis/requirements.txt`. The project venv already has pandas and numpy.
- Nothing else on port 3000: stop the demo collector's container first.
- A healthy host. `internal-validation/host-probe.sh <out-dir>` runs the three checks that caught the 2026-09-24 slowdown: k6 startup ≤ 80 s (60–77 s healthy, 103–139 s degraded), the V8 microbench within 0.90–1.10× of the Sept 19 reference, and GC time per collection ≤ 1.10×. Add `k6-only` for a one-minute recheck between stages. If the host fails, reboot Windows and let it settle first. The limits were calibrated on the Ryzen 5 6600H, so another machine needs its own reference run.

**Order (each command runs the configs one after another: glibc, jemalloc, SAMM):**

```bash
# 1. calibrate (about 8 min per config)
CAL_VUS=50,100,150,200,300,400,500 internal-validation/run.sh calibrate
venv/bin/python internal-validation/analysis/calibration_report.py internal-validation/results/calibrate-<timestamp>

# 2. throughput, with the recommended SATURATION_VUS (about 6 min per config)
SATURATION_VUS=<from step 1> internal-validation/run.sh throughput
venv/bin/python internal-validation/analysis/throughput_report.py internal-validation/results/throughput-<timestamp>

# 3. latency, with the recommended sweep (about 75 s per rate, plus startup, per config)
LATENCY_RPS_SWEEP=<from step 1> internal-validation/run.sh latency
venv/bin/python internal-validation/analysis/latency_report.py internal-validation/results/latency-<timestamp>
```

Each command prints the exact analysis command at the end. To also record
SAMM's own counters once a second (fallbacks, budget refusals,
`bumpResetBlocked`, detach failures) into `samm/allocator.jsonl`, add
`POLL_SAMM_STATS=1`. It's off by default because it sends the server one extra
request per second; leave it off for any run you compare against unpolled ones. To run a subset or
change the order, list the configs: `internal-validation/run.sh throughput samm
jemalloc glibc`. Running a second pass in reverse order exposes drift over time
(heat, background load) that would otherwise favour whichever config ran first.
`glibc-tuned` (glibc with pinned mmap/trim thresholds, as in
`run_allocator_attribution.sh`) is an optional fourth config.

**Running k6 by hand** (another host, or a server you started yourself): start
one config's server on a port, then run the scenario from `k6-scenarios/` with
`BASE_URL` pointing at it:

```bash
cd internal-validation/k6-scenarios
BASE_URL=http://127.0.0.1:3000 SEED=20250911 HOLD_SCALE=1.6 PROCESS_HOLD_MS=240 \
  SATURATION_VUS=400 CONFIG_LABEL=samm SUMMARY_PATH=../results/manual/samm/summary.json \
  K6_CSV_TIME_FORMAT=unix_milli k6 run --out csv=../results/manual/samm/raw.csv.gz throughput-saturation.js
```

Repeat with the next config's server, with the same seed and holds, writing to
`../results/manual/<config>/`. Then point the report at `../results/manual`. A
hand-run directory lacks `container.tsv` and `run.json`, so the report can't
check CPU saturation or OOM for it. `run.sh` is the way to get those.

## What the reports produce

Every report prints its table, saves it as a CSV beside the results, and writes
plots to `<results-dir>/plots/`:

- **`calibration_report.py`:** throughput vs VUs with each knee marked, p95 vs
  VUs, and the recommended settings.
- **`throughput_report.py`:** steady throughput per config (and relative to
  glibc), drops, failures, per-second CV and drift, CPU user / kernel, faults per
  request, peak memory, and a VALID / INVALID verdict. Plots: a bar chart of
  steady throughput, and completed requests per second across the window.
- **`latency_report.py`:** p50 / p90 / p95 / p99 / p99.9 per config and rate,
  KS / p95-ratio / drift against the lowest rate, the flat verdict per step,
  where queueing starts, and a second table splitting each step into non-held
  (exact) and held endpoints, with the held share at 0. Plots:
  - ECDF per rate with the configs overlaid;
  - ECDF per config with its rates overlaid, which is the flatness picture;
  - log-binned histograms;
  - p50 / p95 / p99 against offered rate.

Each config has one colour in every chart (glibc blue, jemalloc orange, SAMM
aqua, tuned glibc yellow). Rates go from light to dark blue.

## Limits worth stating

- **Single runs.** Each command measures each config once. Repeat it, and
  reverse the order, before quoting differences smaller than run-to-run noise.
- **This machine only.** Capacity depends on the CPU: the container gets one
  vCPU, so single-core speed decides it. Report the hardware (`run.json`
  records it) and compare configs only within one machine.
- **Depends on the request mix.** Throughput here is for this request mix and
  these holds. It's a controlled comparison between allocators, not a capacity
  figure for any other workload.
- **Zero values in the distribution plots.** A held request whose duration
  comes out shorter than the hold the server waited is clamped to 0, from the
  ±1 ms timer error above. On the log-scale charts those zeros aren't drawn, but
  they are counted, so an ECDF starts at that share instead of at 0. The
  endpoint-type table reports the share.
