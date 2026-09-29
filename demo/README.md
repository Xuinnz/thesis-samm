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

```bash
node demo/collector.js --label SAMM --container samm-demo --port 9100
```

Then open <http://localhost:9100/>. On the second laptop, run the same command
with `--label BASELINE` and switch that one to baseline mode from its own page.

Useful flags: `--k6 http://127.0.0.1:6565`, `--server http://127.0.0.1:3000`,
`--mode samm|baseline`, `--replay demo/recordings/<file>.jsonl`, `--warmup true`,
`--window 5` (rolling latency window, seconds), `--k6-dashboard-port 5665`.

## Two layouts

`index.html` is the original. `v2.html` puts throughput, latency and RSS on one
screen: three headline numbers, the three charts side by side, and the
supporting counters, with the routing table and allocator below the fold. The
classic layout needs about 1,190 px for its three charts, so the third is always
off-screen on a laptop.

Both render from the same state and the same element ids, and each links to the
other in its header. A panel that exists on only one of them is skipped by the
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
- **Warmup** (`v2.html`, SAMM mode only) — restarts SAMM with its floors
  pre-faulted (`SAMM_WARMUP`). Off by default, as in every benchmark. Measured
  on a 1-minute k=1.0 run, it put idle RSS at 523 MB and held RSS against the
  1,024 MB limit for 39 s, where cold SAMM peaked at 926 MB. Warmed runs are
  labelled `-warm` in recordings, the history and the run summary, so they are
  never compared as if they were cold. `--warmup true` sets the default. The dashed line is
  the other mode's most recent recorded run, drawn against the same clock and
  labelled as a recording. p99 is not available live; it appears in the
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
    least-escaping escaped call site and the most-lingering managed one, plus the
    runtime invariants a misroute would break — detach failures and failed
    requests.
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
