# demo — live dashboard for a defense

One collector process per machine. It polls the container, k6 and the allocator
once a second, streams the result over SSE, and serves the dashboard that draws
it. Each machine runs **one** allocator, so the comparison is the two screens
side by side.

```
demo/
  collector.js     samples cgroup + k6 + /samm/stats, SSE at /events, controls
  table.js         reads model_weights.zig + the refinery's policy CSV
  ui/              the dashboard (Tailwind v4, uPlot, no build step at run time)
  recordings/      one .jsonl per run, written only while a run is in progress
```

## Run it

Every command below runs from the repository root. Use `v2.html` when
presenting: it fits on a laptop screen (see "Two layouts").

### Once per machine

Pull, then build the two images the collector starts (they are tagged
`:bench`, the same images the benchmarks use; rebuild after any pull):

```bash
git pull
```

```bash
docker build -f docker/baseline-environment/Dockerfile -t samm-baseline:bench .
```

```bash
docker build -f docker/samm-environment/Dockerfile -t samm-enabled:bench .
```

Live runs also need k6 (v0.55.0) and free ports 3000 (server), 6565 and 5665
(k6), 9100 (collector). A replay needs neither Docker nor k6.

### A. Replay: the safest way to present (one laptop)

Two recorded runs, side by side, from two collectors on one machine. The
recordings play in real time: about a minute of k6 start-up, then three
minutes of load. Terminal 1, SAMM (918 req/s, 1.2 % dropped, 0 failed):

```bash
node demo/collector.js --label SAMM --mode samm --port 9100 --replay demo/recordings/SAMM-samm-k2.5-s2025-2026-10-08T13-31-45-401Z.jsonl
```

Terminal 2, the V8 baseline on the same seed (OOM-killed about 151 s into the load):

```bash
node demo/collector.js --label BASELINE --mode baseline --port 9101 --replay demo/recordings/SAMM-baseline-k2.5-s2025-2026-10-08T13-27-11-406Z.jsonl
```

Then open <http://localhost:9100/v2.html> and <http://localhost:9101/v2.html>
in two windows. To restart, Ctrl+C both and run them again; an open page
clears itself on reconnect.

- `--mode` must match the recording. It sets the badge and which panels show;
  the recording does not carry it.
- The routing table and ML validation panels show the CURRENT table, not the
  one at recording time. Its numbers have not changed since 2026-09-21, so both
  pairs here match.
- Another clean pair, from Sept 25:
  `demo/recordings/BASELINE-samm-k2.5-s2025-2026-09-24T23-08-17-730Z.jsonl`
  (`--mode samm`) and
  `demo/recordings/BASELINE-baseline-k2.5-s2025-2026-09-24T23-03-57-170Z.jsonl`
  (`--mode baseline`).
- Your own rehearsal runs land in `demo/recordings/` as
  `<label>-<mode>-k<k>-s<seed>-<time>.jsonl`; replay them the same way.

### B. Live: two laptops, one allocator each

Check the host first (about two minutes). A failed probe (WSL's clock running
slow, k6 start-up over 80 s) means live numbers are not representative:
present the replay instead.

```bash
internal-validation/host-probe.sh /tmp/samm-probe k6-only
```

SAMM laptop, terminal 1 (the collector):

```bash
node demo/collector.js --label SAMM --port 9100
```

SAMM laptop, terminal 2 (start the SAMM container):

```bash
curl -s -X POST localhost:9100/mode -d '{"mode":"samm"}'
```

Baseline laptop, terminal 1:

```bash
node demo/collector.js --label BASELINE --port 9100
```

Baseline laptop, terminal 2:

```bash
curl -s -X POST localhost:9100/mode -d '{"mode":"baseline"}'
```

Open <http://localhost:9100/v2.html> on each and wait for "container up". Then
**Test with K6** on both with the **same k, seed and minutes** (defaults: k =
2.5, seed 2025, 3 minutes), started together. The header button switches a
machine to the OTHER mode, so at start-up, before any container exists, it may
offer the wrong one; the `curl` lines start the right one directly.

### C. Live: one laptop, one mode after the other

Start as on the SAMM laptop in B, run the test, then click **Back to V8
Baseline** and run the same k and seed. The dashed reference line is the other
mode's most recent recorded run.

### Stop and clean up

Ctrl+C the collector (it stops k6 and closes the recording), then remove the
container:

```bash
docker rm -f samm-demo
```

### Flags

| Flag | Default | |
|---|---|---|
| `--label` | the container name | name on the page and in recording file names |
| `--mode` | `samm` | `samm` or `baseline`: the mode the page starts in |
| `--port` | `9100` | the collector's own port |
| `--replay <file>` | | play a recording instead of sampling; no Docker or k6 |
| `--k`, `--seed`, `--minutes` | `2.5`, `2025`, `3` | defaults in the run form |
| `--warmup` | `false` | start SAMM with its floors pre-faulted |
| `--window` | `5` | rolling latency window, seconds |
| `--container` | `samm-demo` | container name |
| `--server` | `http://127.0.0.1:3000` | server URL |
| `--k6` | `http://127.0.0.1:6565` | k6 REST API |
| `--k6-dashboard-port` | `5665` | k6 web dashboard |

## Two layouts

`index.html` is the original. `v2.html` puts throughput, latency and RSS on one
screen: three headline numbers, the three charts side by side, and the
supporting counters, with the routing table and allocator below the fold. The
classic layout needs about 1,190 px for its three charts, so the third is always
off-screen on a laptop.

Both render from the same state and the same element ids. `index.html` links
to `v2.html` in its header; `v2.html` has no link back. A panel that exists on only one of them is skipped by the
renderer, so either file can be deleted without touching the JavaScript. To make
one the default, serve it as `/` by renaming.

## The page

- **Boost with SAMM / Back to V8 Baseline** — starts the other container and
  waits for it to become healthy. The dialog shows the collector's real stages;
  nothing is simulated.
- **Test with K6** — opens a form for load point (k), schedule seed and minutes,
  then posts it. Use the **same seed on both machines**: that is what makes the
  two screens a paired comparison rather than two different workloads.
- **Charts** — RSS, throughput and p95 latency, once a second, all on axes that
  start at zero so two machines side by side can be compared directly.
  - **Latency is a rolling p95** over the last k6 dashboard window (5 s, set
    with `--window`), read from k6's built-in web dashboard (`k6dash.js`). k6's
    REST API only offers a cumulative p95, where an early burst dominates for
    minutes and a late one barely registers; the page falls back to it, and says
    so, when no window is available. The run summary stays cumulative, which is
    right for a whole-run figure.
  - **A line is rolling or cumulative, never both.** Once a run has rolling
    windows, a missing window is a gap rather than a cumulative value spliced
    in, and a reference run recorded with the other statistic is not drawn on
    the latency chart (the note under it says so). A window where a metric had
    no samples arrives from k6 as an empty array; treating that as a format
    change once discarded most of a low-drop SAMM run's windows, leaving it
    cumulative against a rolling baseline.
  - **Rates use the monotonic clock.** This machine's wall clock is stepped
    ~3.4 s every 32 s (WSL2 time sync), which used to draw a fake 70% throughput
    dip every half minute on both machines at once.
- **Dropped** is the share of the whole run so far — dropped / (served +
  dropped), the ratio the run summary reports at the end — with the last
  second's ratio underneath. The per-second figure swings with every burst.
- **Warmup** (no button on either page; `--warmup true` or `POST /warmup`) —
  restarts SAMM with its floors pre-faulted (`SAMM_WARMUP`). Off by default, as
  in every benchmark. Measured
  on a 1-minute k=1.0 run, it put idle RSS at 523 MB and held RSS against the
  1,024 MB limit for 39 s, where cold SAMM peaked at 926 MB. Warmed runs are
  labelled `-warm` in recordings, the history and the run summary, so they are
  never compared as if they were cold. The dashed line is the other mode's most
  recent recorded run that carried traffic (a run stopped in its first seconds
  is skipped), drawn against the same clock and labelled as a recording. Until
  the first request the latency note says "waiting for the first requests"
  rather than naming a statistic. A page left open across a collector restart
  (a new replay, say) clears its charts on reconnect: `hello` carries a session
  id. p99 is not available live; it appears in the
  run-complete dialog, which reads k6's end-of-test summary.
- **Arena panel** — one card per call-site from the compiled routing table:
  policy, lifespan, variance, and the arena's floor and span. Those sizes are
  **capacity, not live occupancy** — the addon reports committed bytes for the
  pool as a whole. The bar underneath is that pool total.
- **Health score** — a presentation summary, not a measurement. "Need Help?"
  shows the formula and each penalty's current contribution.
- **When the container dies** a dialog says why, asking Docker for `OOMKilled`
  and the exit code, because the cgroup counters vanish with the container.
  Without it the page would simply fall silent, which is what happened the first
  time the baseline was killed under load.
- **ML validation** (`v2.html`) — evidence for each ML layer. There is no single
  accuracy figure, because none of the layers has labelled ground truth; each is
  judged by the kind of decision it makes:
  - *Layer 1, escape detection* (a classifier): the **separation** between the
    least-escaping escaped call site and the most-lingering managed one, plus
    detach failures and failed requests. Those two guard memory safety; they do
    not show that nothing escaped. A misrouted escaping buffer is detached
    without error and then reads as empty, so it fails a request only on a
    bounds-checked read (`readUInt8`). Escapes are measured offline by the
    reachability oracle (`server/scripts/run_oracle.sh`).
  - *Layer 2, structure choice* (an optimiser): each call site's **decision
    margin**, i.e. how much less the chosen structure wastes than the other, with
    the closest call highlighted. Sites where both costs are under one huge page
    are marked as tie-breaks, as the policy treats them.
  - *Layer 3, spatial quotas* (a capacity prediction): **coverage**, the share of
    allocations the provisioned capacity served, which constraint bound, and why
    each miss happened. It also says when the run's load point differs from the
    one the quotas were trained at, read from the characterization manifest.
- **History** — every finished run on this machine, newest first. Runs recorded
  before summaries were archived are reconstructed from their own samples and
  marked "from recording": mode, peak RSS and whether the container survived are
  all those samples can honestly give, and the rest stay dashes. Click a row to
  draw that run as the reference line.

## HTTP

| Route | What it does |
|---|---|
| `GET /events` | SSE: `hello`, `metrics` (1 Hz), `stage`, `log`, `final`, `container` |
| `GET /status` | mode, container, whether a run is going, defaults, load points |
| `GET /table` | routing table joined with the ML output |
| `GET /recordings`, `GET /recordings/<file>` | list and fetch recordings |
| `GET /history` | archived run summaries, plus runs reconstructed from recordings |
| `POST /mode {mode}` | swap the container; 409 while a run is going |
| `POST /warmup {enabled}` | set warmup and restart SAMM with it; 409 while a run is going |
| `POST /run {k,seed,minutes}` | start k6; 409 if one is already running |
| `POST /stop`, `POST /replay {file}` | stop a run; replay a recording |

## Working on the UI

```bash
cd demo/ui
npm install
npm run watch:css        # Tailwind v4, styles/main.css -> styles/output.css
npm test                 # renders the page in jsdom against real payloads
node test/chart_test.js  # feeds the charts through the real uPlot
./test/browser_check.sh  # loads both layouts in a real browser and checks they drew
node test/serve_fixture.js 9210   # the pages with canned data, for eyeballing
```

`serve_fixture.js` replays a real recording and ENDS its event stream, which is
what lets headless Chrome finish loading and screenshot the page; the live
collector holds `/events` open forever and a browser would wait for it.

`styles/output.css` is committed and served directly, so the demo machines need
no build step. Rebuild it after editing `main.css` or adding utility classes to
`index.html`, or the new classes will not exist at run time.

Run all three after any change to `js/`. They cover different ground, and the
gap between them is where the charts once rendered blank for a whole demo:

- `npm test` renders every branch (SAMM, baseline, container down, OOM kill,
  the dialogs) in jsdom, against BOTH layouts, but its uPlot is a stub.
- `chart_test.js` uses the real uPlot, but jsdom has no canvas, so uPlot's draw
  path never runs.
- `browser_check.sh` loads `test/visual.html` in headless Chrome or Edge and
  counts painted pixels, which is the only check that proves a line exists.
  It skips itself if no browser is found.
