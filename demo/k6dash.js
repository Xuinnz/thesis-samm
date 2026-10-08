'use strict';
/**
 * Rolling latency from k6's built-in web dashboard.
 *
 * k6's REST API only exposes CUMULATIVE trend statistics -- every request since
 * the run began -- so an early burst of slow requests dominates the live p95 for
 * minutes and a late one barely moves it. The web dashboard (built into k6 since
 * v0.49, enabled with K6_WEB_DASHBOARD=true) also aggregates per time window and
 * streams each window as a `snapshot` event. That window is the rolling view.
 *
 * Asking k6 for it costs one aggregation inside k6. The alternative, writing
 * every request to a file (`--out json`) and parsing it here, is ~3 MB/s at demo
 * load on the same laptop that is being measured.
 *
 * Wire format, as observed from k6 v0.55 (captured in test/fixtures/):
 *   param      {"period": ms, "aggregates": {"trend": ["avg", ..., "p(95)", "p(99)"], ...}}
 *   metric     {"<name>": {"type": "trend" | "counter" | "rate" | "gauge"}, ...}
 *   snapshot   [[...], [...], ...]   one array per metric, metrics in NAME order
 *
 * Because snapshot arrays are positional, the decoder checks every array's
 * length against its metric's type before trusting any of it. A future k6 that
 * reorders them fails that check and that window is skipped, rather
 * than silently reporting another metric's numbers as latency.
 */

const http = require('http');

/** Splits an SSE byte stream into {event, data} frames; returns the unparsed tail. */
function parseFrames(buffer) {
  const frames = [];
  let rest = buffer;
  let cut;
  while ((cut = rest.indexOf('\n\n')) !== -1) {
    const block = rest.slice(0, cut);
    rest = rest.slice(cut + 2);
    let event = 'message';
    const data = [];
    for (const line of block.split('\n')) {
      if (line.startsWith('event:')) event = line.slice(6).trim();
      else if (line.startsWith('data:')) data.push(line.slice(5).replace(/^ /, ''));
    }
    if (data.length) frames.push({ event, data: data.join('\n') });
  }
  return { frames, rest };
}

/** Values per aggregate type, as k6 declares them in the `param` event. */
function widths(aggregates) {
  const w = {};
  for (const [type, stats] of Object.entries(aggregates || {})) w[type] = stats.length;
  return w;
}

/**
 * Turns one snapshot into named metrics, or returns null if the arrays do not
 * line up with the declared metrics -- the guard against a format change.
 */
function decodeSnapshot(state, arrays) {
  const names = Object.keys(state.metrics).sort();
  if (!Array.isArray(arrays) || arrays.length !== names.length) return null;
  const w = widths(state.aggregates);
  const out = {};
  for (let i = 0; i < names.length; i++) {
    const meta = state.metrics[names[i]];
    const expected = w[meta.type];
    if (expected === undefined || !Array.isArray(arrays[i])) return null;
    // A metric with no samples in this window arrives as [] -- still in its
    // slot, so positions hold. Treating [] as a format change threw away every
    // window without a dropped iteration: SAMM drops ~2.5%, so most of its
    // windows went, and its latency line fell back to cumulative for the run.
    if (arrays[i].length === 0) { out[names[i]] = null; continue; }
    if (arrays[i].length !== expected) return null;
    out[names[i]] = arrays[i];
  }
  return out;
}

/** p95 / p99 of one trend metric out of a decoded snapshot. */
function trendStats(state, decoded, metric) {
  const stats = (state.aggregates && state.aggregates.trend) || [];
  const row = decoded && decoded[metric];
  if (!row) return { p95: null, p99: null };
  const at = (name) => {
    const i = stats.indexOf(name);
    return i === -1 || row[i] === null || row[i] === undefined ? null : +Number(row[i]).toFixed(1);
  };
  return { p95: at('p(95)'), p99: at('p(99)') };
}

/**
 * Follows a running k6's dashboard stream and reports each window.
 *
 * k6 starts its dashboard server only once it is up, which takes tens of
 * seconds at demo load while it builds its VUs, so connecting is retried until
 * it answers or `stop()` is called.
 */
function follow({ host = '127.0.0.1', port, onWindow, onError = () => {} }) {
  let stopped = false;
  let req = null;
  let timer = null;
  const state = { metrics: {}, aggregates: null, period: null, misaligned: false };

  const connect = () => {
    if (stopped) return;
    req = http.get({ host, port, path: '/events', headers: { Accept: 'text/event-stream' } }, (res) => {
      if (res.statusCode !== 200) { res.resume(); return retry(); }
      res.setEncoding('utf8');
      let buffer = '';
      res.on('data', (chunk) => {
        const parsed = parseFrames(buffer + chunk);
        buffer = parsed.rest;
        for (const { event, data } of parsed.frames) handle(event, data);
      });
      res.on('end', retry);
    });
    req.on('error', retry);
  };

  // Reconnecting after the test's `stop` would keep k6 alive: it holds the
  // process open while a dashboard client is attached. Measured: a 1-minute
  // run was still going seven minutes later, and exited the moment the client
  // went away. So `stop` ends the follow for good.
  const retry = () => {
    if (stopped || timer) return;
    timer = setTimeout(() => { timer = null; connect(); }, 2000);
  };

  const handle = (event, data) => {
    let body;
    try { body = JSON.parse(data); } catch { return; }
    if (event === 'param') {
      state.aggregates = body.aggregates || null;
      state.period = body.period || null;
    } else if (event === 'metric') {
      Object.assign(state.metrics, body);
    } else if (event === 'stop') {
      stopped = true;
      if (req) req.destroy();
    } else if (event === 'snapshot') {
      const decoded = decodeSnapshot(state, body);
      if (!decoded) {
        // Refuse to guess -- a wrong index would show some other metric as
        // latency -- but only for THIS window. A metric first seen mid-run
        // (dropped_iterations appears with the first dropped iteration) shifts
        // the arrays until its declaration arrives, after which they line up.
        if (!state.misaligned) {
          onError(new Error('k6 dashboard window did not match its declared metrics; skipped until it does'));
        }
        state.misaligned = true;
        return;
      }
      state.misaligned = false;
      const e2e = trendStats(state, decoded, 'http_req_duration');
      const alloc = trendStats(state, decoded, 'processing_time');
      onWindow({
        window_s: state.period ? state.period / 1000 : null,
        e2e_p95: e2e.p95, e2e_p99: e2e.p99,
        alloc_p95: alloc.p95, alloc_p99: alloc.p99,
      });
    }
  };

  connect();
  return {
    stop() {
      stopped = true;
      if (timer) clearTimeout(timer);
      if (req) req.destroy();
    },
  };
}

module.exports = { parseFrames, decodeSnapshot, trendStats, follow };
