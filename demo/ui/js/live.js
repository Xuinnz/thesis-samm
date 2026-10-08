'use strict';
/**
 * Live data for the dashboard: one SSE stream, one state object.
 *
 * Everything drawn on the page comes from here, and everything here comes from
 * the collector -- cgroup counters, k6's REST API, the allocator's own stats
 * and the compiled routing table. Nothing is generated client-side except the
 * rates and the health score, both defined below in the open.
 */

const MAX_POINTS = 900;            // 15 minutes at 1 Hz
// Exposed as Live.NA. dashboard.js declares its own alias, and two top-level
// `const NA_TEXT` in classic scripts would be a redeclaration error.
const NA_TEXT = '—';

const Live = {
  connected: false,
  hello: null,
  status: null,       // GET /status
  table: null,        // GET /table (routing table + ML output)
  sample: null,       // newest metrics event
  prev: null,         // the one before it, for rates
  derived: {},
  // p95r: rolling window (null where a window is missing). p95c: cumulative.
  series: { t: [], rss: [], rps: [], p95r: [], p95c: [] },
  hasRolling: false, // has this run produced a rolling window yet?
  hasLatency: false, // ...or any p95 at all?
  t0: null,
  ghost: null,        // the other mode's last recorded run
  stages: [],
  run: null,
  final: null,
  death: null,       // set when the container dies; cleared on the next start
  history: [],       // archived run summaries, newest first
  listeners: new Set(),
};

function notify() {
  for (const fn of Live.listeners) {
    try { fn(Live); } catch (err) { console.error('render failed', err); }
  }
}
Live.subscribe = (fn) => { Live.listeners.add(fn); return () => Live.listeners.delete(fn); };

// ------------------------------------------------------------------ helpers
const clamp01 = (x) => Math.max(0, Math.min(1, x));
const num = (v, digits = 0) => (v === null || v === undefined || Number.isNaN(v) ? NA_TEXT : Number(v).toFixed(digits));
Live.NA = NA_TEXT;
Live.num = num;

async function getJson(url) {
  try {
    const r = await fetch(url, { cache: 'no-store' });
    return r.ok ? await r.json() : null;
  } catch { return null; }
}

Live.post = async function post(url, body) {
  try {
    const r = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {}),
    });
    // An empty or non-JSON body must still come back as an object: callers
    // read res.data.error to show why a request was refused.
    const data = (await r.json().catch(() => null)) || {};
    return { ok: r.ok, status: r.status, data };
  } catch (err) {
    return { ok: false, status: 0, data: { error: err.message } };
  }
};

// ------------------------------------------------- rates and health scoring
/**
 * Per-second rates, which the collector deliberately does not compute: it sends
 * the raw cumulative counters so nothing is lost if a sample is missed.
 */
// The collector's monotonic timestamp when it sent one, else wall clock (older
// recordings). Wall clock is stepped ~3.4 s every 32 s on this machine, and a
// rate over a stepped interval reads ~70% low.
const clock = (x) => (x.tm !== undefined && x.tm !== null ? x.tm : x.t);

function rates(s, p) {
  if (!p || !s || !(clock(s) > clock(p))) return {};
  const dt = (clock(s) - clock(p)) / 1000;
  const delta = (a, b) => (a === null || b === null || a === undefined || b === undefined ? null : Math.max(0, a - b) / dt);
  const droppedPerSec = delta(s.dropped, p.dropped);
  const offered = droppedPerSec === null || s.rps === null ? null : droppedPerSec + s.rps;
  return {
    throttled_per_sec: delta(s.throttled_periods, p.throttled_periods),
    dropped_per_sec: droppedPerSec,
    // Share of the WHOLE RUN so far, computed like the end-of-run summary:
    // dropped / (served + dropped). The per-interval figure below swings with
    // every burst; this one is what the run is actually doing overall.
    dropped_pct_run: s.dropped !== null && s.dropped !== undefined && s.requests
      ? (100 * s.dropped) / (s.requests + s.dropped) : null,
    // Share of the load k6 wanted to send that it could not start.
    dropped_pct: offered ? (100 * droppedPerSec) / offered : (droppedPerSec === null ? null : 0),
    faults_per_req: s.faults_per_sec && s.rps ? s.faults_per_sec / s.rps : null,
  };
}

/**
 * Health score -- a presentation summary, not a measurement. It is a weighted
 * penalty on four numbers the study already reports, so anyone can check it:
 *
 *   memory    40 pts, ramping in from 70% of the container limit
 *   dropped   30 pts, full penalty at 10% of offered load
 *   failed    20 pts, full penalty at 5% of requests
 *   throttle  10 pts, full penalty at 10 throttled periods per second
 *   an OOM kill is not a penalty: it is a zero.
 */
const HEALTH = [
  { key: 'memory', weight: 40, text: 'RSS above 70% of the limit' },
  { key: 'dropped', weight: 30, text: 'dropped requests, full at 10%' },
  { key: 'failed', weight: 20, text: 'failed requests, full at 5%' },
  { key: 'throttled', weight: 10, text: 'CPU throttling, full at 10 periods/s' },
];
Live.HEALTH = HEALTH;

function health(s, r) {
  if (!s || !s.up || s.rss_mb === null || !s.limit_mb) return { score: null, parts: {} };
  const parts = {
    memory: clamp01((s.rss_mb / s.limit_mb - 0.70) / 0.30) * 40,
    dropped: clamp01((r.dropped_pct ?? 0) / 10) * 30,
    failed: clamp01((s.failed_pct ?? 0) / 5) * 20,
    throttled: clamp01((r.throttled_per_sec ?? 0) / 10) * 10,
  };
  if (s.oom_kills) return { score: 0, parts, oom: true };
  const score = Math.round(100 - Object.values(parts).reduce((a, b) => a + b, 0));
  return { score: Math.max(0, score), parts };
}

function derive() {
  const s = Live.sample;
  const r = rates(s, Live.prev);
  const h = health(s, r);
  const load = !s || !s.up || s.rss_mb === null || !s.limit_mb ? null : s.rss_mb / s.limit_mb;
  Live.derived = {
    ...r,
    health: h.score,
    health_parts: h.parts,
    oom: Boolean(s && s.oom_kills),
    memory_fraction: load,
    memory_load: load === null ? NA_TEXT : load < 0.6 ? 'LOW' : load < 0.8 ? 'MODERATE' : 'HIGH',
    system_status: !s || !s.up ? 'OFFLINE'
      : h.score === null ? NA_TEXT
      : h.oom ? 'OOM KILLED'
      : h.score >= 80 ? 'STABLE' : h.score >= 50 ? 'AT RISK' : 'CRITICAL',
  };
}

// --------------------------------------------------------------- the stream
function pushSample(s) {
  Live.prev = Live.sample;
  Live.sample = s;
  derive();

  if (s.up) {
    if (Live.t0 === null) Live.t0 = clock(s);
    Live.series.t.push((clock(s) - Live.t0) / 1000);
    Live.series.rss.push(s.rss_mb);
    Live.series.rps.push(s.rps ?? 0);
    const roll = s.e2e_p95_roll !== null && s.e2e_p95_roll !== undefined ? s.e2e_p95_roll : null;
    Live.series.p95r.push(roll);
    Live.series.p95c.push(s.e2e_p95 ?? null);
    if (roll !== null) {
      Live.hasRolling = true;
      Live.rollWindow = s.roll_window_s;
    }
    if (s.e2e_p95 !== null && s.e2e_p95 !== undefined) Live.hasLatency = true;
    // 'none' until the first request: before then there is no statistic to
    // name, and calling it cumulative made the label flip when load began.
    Live.latency = Live.hasRolling
      ? { source: 'rolling', window_s: Live.rollWindow }
      : Live.hasLatency ? { source: 'cumulative', window_s: null }
      : { source: 'none', window_s: null };
    for (const key of Object.keys(Live.series)) {
      if (Live.series[key].length > MAX_POINTS) Live.series[key].shift();
    }
  }
}

/**
 * The p95 a live chart should draw: the last dashboard window when there is
 * one, else k6's cumulative p95. Cumulative is right for an end-of-run summary
 * and wrong for "now" -- an early burst dominates it for minutes and a late one
 * barely moves it.
 */
function latencyOf(s) {
  // Once a run has rolling windows it shows only rolling values: splicing
  // cumulative points into the gaps would draw a line that is half one
  // statistic and half another -- which is exactly how a SAMM run once ended
  // up plotted as cumulative against a rolling baseline.
  if (Live.hasRolling) return s.e2e_p95_roll !== undefined ? s.e2e_p95_roll : null;
  return s.e2e_p95;
}
Live.latencyOf = latencyOf;

/**
 * Can the reference run's latency be drawn next to the live one? Only if both
 * are the same statistic. One definition, used by the chart and the labels, so
 * the chart and the note under it can never disagree.
 */
function referenceComparable(live) {
  const g = live.ghost && live.ghost.series;
  if (!g) return true;
  const source = live.latency && live.latency.source;
  if (source !== 'rolling' && source !== 'cumulative') return true;  // nothing live yet
  return Boolean(g.hasRolling) === (source === 'rolling');
}
Live.referenceComparable = referenceComparable;

/**
 * Which p95 series the latency chart and the hero read, for the live run and
 * the reference alike. Before the live run has any latency, the reference's
 * own statistic.
 */
function latencyField(live) {
  const source = live.latency && live.latency.source;
  if (source === 'rolling') return 'p95r';
  if (source === 'cumulative') return 'p95c';
  const g = live.ghost && live.ghost.series;
  return g && g.hasRolling ? 'p95r' : 'p95c';
}
Live.latencyField = latencyField;
Live.latency = { source: 'none', window_s: null };

/** A run is the natural zero for the x axis, so the charts start with it. */
function resetSeries() {
  Live.series = { t: [], rss: [], rps: [], p95r: [], p95c: [] };
  Live.t0 = null;
  Live.hasRolling = false;
  Live.hasLatency = false;
  Live.latency = { source: 'none', window_s: null };
}
Live.resetSeries = resetSeries;

function connect() {
  const es = new EventSource('/events');

  es.addEventListener('open', () => { Live.connected = true; notify(); });
  es.addEventListener('error', () => { Live.connected = false; notify(); });  // EventSource retries on its own

  es.addEventListener('hello', (e) => {
    const hello = JSON.parse(e.data);
    // A different collector than before (restarted, or a new replay): the old
    // run's points must not carry over, and its run-start event, which would
    // normally clear them, was sent before this page reconnected.
    if (Live.hello && hello.session !== Live.hello.session) {
      resetSeries();
      Live.final = null;
      Live.death = null;
      // Its mode may differ, and the reference line is the other mode's run.
      refreshStatus().then(loadGhost);
    }
    Live.hello = hello;
    notify();
  });

  es.addEventListener('metrics', (e) => {
    Live.connected = true;
    pushSample(JSON.parse(e.data));
    notify();
  });

  es.addEventListener('stage', (e) => {
    const stage = JSON.parse(e.data);
    Live.stages.push({ ...stage, at: Date.now() });
    if (stage.name === 'container' && stage.status === 'starting') Live.death = null;
    if (stage.name === 'k6' && stage.status === 'running') {
      resetSeries();
      Live.final = null;
      Live.death = null;
      Live.run = stage;
    }
    if (stage.name === 'k6' && stage.status !== 'running') Live.run = null;
    refreshStatus();
    notify();
  });

  es.addEventListener('log', (e) => {
    Live.stages.push({ name: 'log', status: 'error', detail: JSON.parse(e.data).line, at: Date.now() });
    notify();
  });

  // The container going away mid-demo is the point of the exercise when it is
  // the baseline. Without this the page would simply fall silent.
  es.addEventListener('container', (e) => {
    Live.death = { ...JSON.parse(e.data), at: Date.now() };
    refreshStatus();
    refreshHistory();
    notify();
  });

  es.addEventListener('final', (e) => {
    Live.final = JSON.parse(e.data);
    Live.run = null;
    refreshStatus();
    loadGhost();          // this run becomes the next comparison line
    notify();
  });
}

// ------------------------------------------------------------ side channels
async function refreshStatus() {
  Live.status = await getJson('/status');
  notify();
}
Live.refreshStatus = refreshStatus;

async function refreshTable() {
  Live.table = await getJson('/table');
  notify();
}

/**
 * The reference line: the most recent recording made in the OTHER mode. Each
 * machine runs one allocator, so a second live line is impossible -- this is
 * the closest honest thing, and it is labelled as a past run everywhere it
 * appears.
 */
async function loadGhost() {
  const mine = Live.status && Live.status.mode;
  const list = await getJson('/recordings');
  if (!list || !mine) return;
  if (Live.ghost && Live.ghost.pinned) return;      // the user chose this one
  // Newest first, skipping runs that never carried traffic: a run stopped in
  // its first seconds still leaves a recording, and as the reference it would
  // draw nothing and label the latency "not comparable".
  for (const other of list.recordings.filter((r) => r.mode && r.mode !== mine)) {
    if (Live.ghost && Live.ghost.name === other.name) return;
    let text;
    try {
      const res = await fetch(`/recordings/${encodeURIComponent(other.name)}`, { cache: 'no-store' });
      if (!res.ok) continue;
      text = await res.text();
    } catch { continue; }
    const series = seriesFromRecording(text);
    if (!series || !series.rps.some((v) => v > 0)) continue;
    Live.ghost = { ...other, series };
    notify();
    return;
  }
  Live.ghost = null;
}

/** The metrics events of a recording, as chart series on their own clock. */
function seriesFromRecording(text) {
  const series = { t: [], rss: [], rps: [], p95r: [], p95c: [], hasRolling: false };
  let t0 = null;
  for (const line of text.trim().split('\n')) {
    if (!line) continue;
    let row;
    try { row = JSON.parse(line); } catch { continue; }
    if (row.event !== 'metrics' || !row.data || !row.data.up) continue;
    if (t0 === null) t0 = clock(row.data);
    series.t.push((clock(row.data) - t0) / 1000);
    series.rss.push(row.data.rss_mb);
    series.rps.push(row.data.rps ?? 0);
    const roll = row.data.e2e_p95_roll ?? null;
    series.p95r.push(roll);
    series.p95c.push(row.data.e2e_p95 ?? null);
    if (roll !== null) series.hasRolling = true;
  }
  return series.t.length ? series : null;
}
Live.loadGhost = loadGhost;

async function refreshHistory() {
  const data = await getJson('/history');
  Live.history = data ? data.runs : [];
  notify();
}
Live.refreshHistory = refreshHistory;

/** Pin a specific recording as the reference line, from the history dialog. */
Live.useAsReference = async function useAsReference(name) {
  if (!name) return false;
  let text;
  try {
    const res = await fetch(`/recordings/${encodeURIComponent(name)}`, { cache: 'no-store' });
    if (!res.ok) return false;
    text = await res.text();
  } catch { return false; }
  const series = seriesFromRecording(text);
  if (!series) return false;
  const meta = (Live.history.find((r) => r.recording === name) || {});
  Live.ghost = {
    name, pinned: true,
    mode: meta.mode || (name.includes('-baseline-') ? 'baseline' : 'samm'),
    k: meta.run ? meta.run.k : null, seed: meta.run ? meta.run.seed : null,
    series,
  };
  notify();
  return true;
};

Live.start = async function start() {
  await refreshStatus();
  await refreshTable();
  await refreshHistory();
  await loadGhost();
  connect();
  // The routing table changes only on a retrain, but a rehearsal may retrain
  // between runs; a slow poll keeps the page honest without hammering the disk.
  setInterval(refreshTable, 60000);
};
