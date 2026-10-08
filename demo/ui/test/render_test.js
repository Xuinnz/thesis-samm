'use strict';
/**
 * Renders the dashboard in jsdom against real event payloads and asserts what
 * ends up on screen.
 *
 * The collector is not started here: EventSource and fetch are stubbed, so this
 * checks the page's own logic -- that every branch renders, that a null
 * allocator (baseline mode) and a dead container do not throw, and that the
 * numbers shown are the numbers that arrived.
 *
 * The allocator payload is a real one, copied from
 * benchmark-results/demo-ingest/samm-allocator.json.
 *
 * Usage: node test/render_test.js
 */

const fs = require('fs');
const path = require('path');
const assert = require('assert');
const { JSDOM } = require('jsdom');

const UI = path.resolve(__dirname, '..');
// Both layouts render from the same state, so both must pass this file.
const PAGE = process.argv[2] || 'index.html';

const ALLOCATOR = {
  unmanaged: 6892, capacityFallbacks: 57699, bumpOversizeFallbacks: 0, slabOversizeFallbacks: 0,
  slabZeroSlotFallbacks: 0, slabExhaustedFallbacks: 17435, bumpResetBlocked: 40264, bumpResets: 38958,
  grows: 32, committedBytes: 656953344, ceilingBytes: 657535795, reservedFloorBytes: 460169216,
  budgetRefusals: 57699, warmedBytes: 0, regionsOpened: 136272, regionsClosed: 136272,
  regionReclaimed: 5693169, unscopedAllocations: 0, regionsExhausted: 0, detachFailures: 0,
};

const STATUS = {
  label: 'SAMM', mode: 'samm', container_up: true, running: false, run: null,
  switching: false, replaying: false, defaults: { k: '2.0', seed: 2025, minutes: 3 },
  loads: ['1.0', '1.5', '2.0', '2.5'], replay: false,
};

function sample(over = {}) {
  return {
    t: Date.now(), label: 'SAMM', container: 'samm-demo', up: true,
    rss_mb: 931.0, peak_rss_mb: 940.2, limit_mb: 1024,
    cpu_pct: 66.8, throttled_periods: 1046, oom_kills: 0,
    faults_per_sec: 2800, faults_total: 540000,
    rps: 718.3, e2e_p95: 812.4, e2e_med: 120.2, alloc_p95: 64.1, alloc_med: 3.2,
    dropped: 190, requests: 10000, failed_pct: 0, vus: 400,
    allocator: ALLOCATOR, ...over,
  };
}

async function boot() {
  const table = JSON.parse(
    require('child_process').execSync('node -e "console.log(JSON.stringify(require(\'../table\').readTable()))"',
      { cwd: UI }).toString(),
  );

  const dom = new JSDOM(fs.readFileSync(path.join(UI, PAGE), 'utf8'), {
    runScripts: 'outside-only', url: 'http://localhost:9100/', pretendToBeVisual: true,
  });
  const { window } = dom;

  // uPlot is vendored for the browser; the charts only need to not explode.
  window.uPlot = class {
    constructor(opts, data, el) {
      this.series = (opts.series || []).map((s) => ({ ...s }));
      this.el = el;
      // Real uPlot builds a root element with the legend inside it.
      this.root = window.document.createElement('div');
      this.root.innerHTML = '<div class="u-legend">' +
        this.series.map(() => '<div class="u-series"><span class="u-label"></span></div>').join('') +
        '</div>';
    }
    setData(data) { this.data = data; } setSize() {} setSeries() {} redraw() {} destroy() {}
  };
  window.ResizeObserver = class { observe() {} disconnect() {} };

  // characterized_k arrives from readTable(), derived from the manifest.
  assert.ok(table.characterized_k, 'readTable() should recover the characterized load point');
  const routes = {
    '/status': STATUS,
    '/table': table,
    '/recordings': { recordings: [{ name: 'SAMM-baseline-k2.0-s2025-x.jsonl', mode: 'baseline', k: '2.0', seed: 2025, mtime: 1 }] },
  };
  const ghostLines = [0, 1, 2].map((i) => JSON.stringify({
    event: 'metrics', data: { t: 1000 + i * 1000, up: true, rss_mb: 900 + i, rps: 600 + i, e2e_p95: 1500 + i },
  })).join('\n');

  const posted = [];
  window.fetch = async (url, init) => {
    if (init && init.method === 'POST') {
      posted.push({ url, body: JSON.parse(init.body) });
      return { ok: true, status: 202, json: async () => ({ ok: true }) };
    }
    if (url.startsWith('/recordings/')) return { ok: true, text: async () => ghostLines };
    const body = routes[url];
    return { ok: body !== undefined, json: async () => body, text: async () => JSON.stringify(body) };
  };
  window.__posted = posted;

  const listeners = {};
  window.EventSource = class {
    constructor() { setTimeout(() => this.emit('open', {}), 0); }
    addEventListener(type, fn) { listeners[type] = fn; }
    emit(type, data) { if (listeners[type]) listeners[type]({ data: JSON.stringify(data) }); }
  };
  window.__emit = (type, data) => listeners[type] && listeners[type]({ data: JSON.stringify(data) });

  const errors = [];
  window.addEventListener('error', (e) => errors.push(e.message));
  // render() failures are caught and logged by Live.notify, so a silent console
  // error still has to fail this test.
  window.console.error = (...args) => errors.push(args.map(String).join(' '));
  // One eval, not three: classic <script> tags share a top-level lexical scope,
  // but each window.eval gets its own, and `Live` would be invisible to the
  // others.
  window.eval(['js/live.js', 'js/charts.js', 'js/dashboard.js']
    .map((f) => fs.readFileSync(path.join(UI, f), 'utf8')).join('\n;\n')
    + '\n;window.__Live = Live; window.__charts = charts;');
  window.document.dispatchEvent(new window.Event('DOMContentLoaded'));
  await new Promise((r) => setTimeout(r, 50));      // let start() settle its fetches
  return { window, errors, table, routes };
}

const txt = (w, id) => w.document.getElementById(id).textContent.trim();

(async () => {
  const { window, errors, table, routes } = await boot();
  const Live = window.__Live;
  const emit = (type, data) => { window.__emit(type, data); };

  // ---------------------------------------------------- a healthy SAMM sample
  emit('metrics', sample());
  assert.strictEqual(txt(window, 'mode-badge'), 'SAMM ALLOCATOR');
  // Panels that exist on only one layout are asserted only where they exist.
  const has = (id) => Boolean(window.document.getElementById(id));
  if (has('memory-density-current')) assert.match(txt(window, 'memory-density-current'), /931 MB \/ 1024 MB/);
  if (has('hero-rps')) {
    assert.strictEqual(txt(window, 'hero-rps'), '718');
    assert.strictEqual(txt(window, 'hero-p95'), '812');
    assert.strictEqual(txt(window, 'hero-rss'), '931');
    assert.match(txt(window, 'hero-rss-limit'), /of 1024 MB/);
  }
  assert.strictEqual(txt(window, 'kpi-cpu'), '67%');
  assert.strictEqual(txt(window, 'kpi-peak'), '940 MB');
  assert.strictEqual(txt(window, 'kpi-oom'), 'no OOM kills');
  assert.strictEqual(txt(window, 'kmeans-clusters-value'), String(table.cluster_count));

  // Fallback rate must match the benchmark scripts' formula exactly.
  const allocs = ALLOCATOR.regionReclaimed + ALLOCATOR.unmanaged + ALLOCATOR.capacityFallbacks;
  const expected = `${((100 * ALLOCATOR.capacityFallbacks) / allocs).toFixed(2)}%`;
  assert.strictEqual(txt(window, 'fallback-rate-value'), expected);

  // ------------------------------------------------------ ML validation card
  // Expected values are DERIVED from the routing table here, never typed in:
  // a retrain changes them, and the test must follow.
  if (has('ml-validation')) {
    const esc = table.sites.filter((x) => x.policy === 'System');
    const man = table.sites.filter((x) => x.policy !== 'System');
    const e = esc.reduce((m, x) => (x.median_overhang_ms < m.median_overhang_ms ? x : m));
    const m = man.reduce((mx, x) => (x.median_overhang_ms > mx.median_overhang_ms ? x : mx));
    assert.strictEqual(txt(window, 'val1-big'), `${Math.round(e.median_overhang_ms / m.median_overhang_ms)}×`);
    assert.match(txt(window, 'val1-caption'), new RegExp(e.name));
    assert.strictEqual(txt(window, 'val1-chip'), 'safety net held');

    const huge = table.budget.huge_page_size / 1048576;
    const closest = table.sites.filter((x) => x.policy === 'Bump' || x.policy === 'Slab').map((x) => {
      const bump = x.policy === 'Bump';
      const win = bump ? x.bump_extra_mb : x.slab_extra_mb;
      const lose = bump ? x.slab_extra_mb : x.bump_extra_mb;
      return { x, margin: Math.max(win, lose) >= huge && win > 0 ? lose / win : null };
    }).filter((c) => c.margin !== null).sort((p, q) => p.margin - q.margin)[0];
    assert.strictEqual(txt(window, 'val2-big'), `${closest.margin.toFixed(1)}×`);
    assert.match(txt(window, 'val2-caption'), new RegExp(`closest call: ${closest.x.name}`));

    // Coverage is the complement of the fallback-rate tile, same denominator.
    const cover = (100 * (allocs - ALLOCATOR.capacityFallbacks)) / allocs;
    assert.strictEqual(txt(window, 'val3-big'), `${cover.toFixed(1)}%`);
    // Every refusal was a budget refusal in this payload, so the ceiling binds.
    assert.match(txt(window, 'val3-rows'), /the global budget ceiling/);
    assert.match(txt(window, 'val3-legend'), /bump could not wrap or grow/);
    assert.match(txt(window, 'val3-caveat'), new RegExp(`quotas trained at k = ${table.characterized_k}`));
  }

  // Health: 931/1024 is 91% of the limit, so the memory penalty is most of it.
  const health = Number(txt(window, 'health-score-value'));
  assert.ok(health > 0 && health < 100, `health should be scored, got ${health}`);

  // ------------------------------------------------- rates need two samples
  const first = sample({ t: Date.now(), dropped: 190, throttled_periods: 1046 });
  emit('metrics', first);
  emit('metrics', sample({ t: first.t + 1000, dropped: 200, throttled_periods: 1051 }));
  assert.match(txt(window, 'kpi-faults-req'), /per request/);
  // Dropped is the run so far, like the summary: the last sample carried 200
  // dropped and 10,000 served, so 200 / (10,000 + 200).
  assert.strictEqual(txt(window, 'kpi-dropped'), `${((100 * 200) / 10200).toFixed(2)}%`);
  assert.match(txt(window, 'kpi-failed'), /last second .* · failed 0\.00%/);
  assert.match(txt(window, 'kpi-throttle'), /throttled 5\.0\/s/);

  // The clock bug: this machine steps its wall clock ~3.4 s every 32 s. Over
  // such a step, 5 throttled periods in ONE real second must still read 5.0/s,
  // not 5 / 4.4 = 1.1/s -- which is what drew the fake dips in the charts.
  emit('metrics', sample({ t: 1_000_000, tm: 50_000, throttled_periods: 2000, dropped: 300 }));
  emit('metrics', sample({ t: 1_004_400, tm: 51_000, throttled_periods: 2005, dropped: 310 }));
  assert.match(txt(window, 'kpi-throttle'), /throttled 5\.0\/s/,
    'rates must be taken over the monotonic clock, not the stepped wall clock');

  // Rolling latency: the last k6 dashboard window wins over the cumulative p95,
  // and the page says which one it is showing.
  emit('metrics', sample({ e2e_p95: 1500, e2e_p95_roll: 480, e2e_p99_roll: 900, roll_window_s: 5 }));
  if (has('hero-p95')) {
    assert.strictEqual(txt(window, 'hero-p95'), '480');
    assert.match(txt(window, 'hero-p95-source'), /last 5 s · p99 900 ms/);
    assert.match(txt(window, 'latency-note'), /rolling, over the last 5 s/);
  }
  assert.strictEqual(Live.series.p95r[Live.series.p95r.length - 1], 480, 'the chart must plot the rolling p95');

  // The reference run was recorded with cumulative latency only, so against a
  // rolling live line it must NOT be drawn -- the two statistics differ.
  const lat = window.__charts.latency.chart.data;
  assert.ok(lat[2].every((v) => v === null), 'a cumulative reference must not be drawn against a rolling line');
  if (has('latency-note')) assert.match(txt(window, 'latency-note'), /reference run not drawn/);
  if (has('hero-p95-prev')) assert.match(txt(window, 'hero-p95-prev'), /not comparable/);

  // Once a run is rolling it stays rolling: a missing window is a gap, never a
  // cumulative value spliced in -- that splice is what made SAMM look cumulative.
  emit('metrics', sample());
  if (has('hero-p95')) {
    assert.strictEqual(txt(window, 'hero-p95'), '—');
    assert.strictEqual(txt(window, 'hero-p95-source'), 'no window this moment');
  }
  assert.strictEqual(Live.series.p95r[Live.series.p95r.length - 1], null);

  // A new run starts clean, and without windows it shows cumulative, labelled.
  emit('stage', { name: 'k6', status: 'running', k: '2.0', seed: 2025, minutes: 3 });
  emit('metrics', sample());
  if (has('hero-p95')) {
    assert.strictEqual(txt(window, 'hero-p95'), '812');
    assert.strictEqual(txt(window, 'hero-p95-source'), 'cumulative');
  }
  emit('stage', { name: 'k6', status: 'done', code: 0 });

  // ------------------------------------------ arenas come from the ML output
  const arenaText = txt(window, 'arena-content');
  for (const site of table.sites) {
    assert.ok(arenaText.includes(site.name), `arena card missing for ${site.name}`);
  }
  assert.ok(arenaText.includes('arena overflow'), 'live fallback count missing from arena footer');

  // --------------------------------- baseline mode: a null allocator is normal
  emit('metrics', sample({ allocator: null }));
  assert.strictEqual(txt(window, 'fallback-rate-value'), '—');
  if (has('ml-validation')) {
    // The baseline has no quotas and no regions: say so, do not show zeros.
    assert.match(txt(window, 'val3-caption'), /SAMM mode only/);
    assert.strictEqual(txt(window, 'val1-chip'), 'SAMM mode only');
    // Layers 1 and 2 come from the routing table and stay visible.
    assert.notStrictEqual(txt(window, 'val1-big'), '—');
  }

  assert.match(txt(window, 'allocator-body'), /Waiting for the allocator|baseline/);

  // A detach failure must turn the Layer 1 chip red.
  if (has('ml-validation')) {
    emit('metrics', sample({ allocator: { ...ALLOCATOR, detachFailures: 3 } }));
    assert.strictEqual(txt(window, 'val1-chip'), 'detach failed');
  }

  // ------------------------------------------------- a container that is down
  emit('metrics', sample({ up: false, rss_mb: null, limit_mb: null, allocator: null, cpu_pct: null }));
  if (has('status-headline')) assert.strictEqual(txt(window, 'status-headline'), 'Container is not running.');
  assert.strictEqual(txt(window, 'system-status-value'), 'OFFLINE');

  // --------------------------------------------------------- an OOM kill run
  emit('metrics', sample({ oom_kills: 1, rss_mb: 1024 }));
  assert.strictEqual(txt(window, 'health-score-value'), '0');
  assert.strictEqual(txt(window, 'system-status-value'), 'OOM KILLED');

  // ------------------------------------------------ stage events drive the modal
  window.document.getElementById('boost-btn').dispatchEvent(new window.Event('click'));
  await new Promise((r) => setTimeout(r, 10));
  emit('stage', { name: 'container', status: 'starting', mode: 'baseline' });
  emit('stage', { name: 'container', status: 'ready', mode: 'baseline' });
  assert.match(txt(window, 'modal-stage-list'), /container: ready/);
  assert.ok(!window.document.getElementById('modal-done-btn').classList.contains('hidden'),
    'Done should appear once the container is ready');

  // ------------------------------------------------------ end-of-run summary
  emit('final', {
    mode: 'samm', label: 'SAMM', requests: 136246, throughput_rps: 718.3, dropped: 190,
    dropped_pct: 0.14, failed_pct: 0, e2e_p95: 812.4, e2e_p99: 3056.7, alloc_p95: 64.1,
    alloc_p99: 193.14, peak_rss_mb: 931.0, oom_kills: 0, container_survived: true,
    run: { k: '2.0', seed: 2025, minutes: 3 },
  });
  const final = txt(window, 'final-body');
  // A run at a different load from the characterization is flagged, because
  // part of every miss is then the load rather than the model.
  if (has('ml-validation')) {
    emit('metrics', sample());
    assert.match(txt(window, 'val3-caveat'), new RegExp(`trained at k = ${table.characterized_k}, running at k = 2\\.0`));
  }
  assert.match(final, /136,246/);
  assert.match(final, /3056\.7 ms/, 'p99 should come from the end-of-run summary');
  assert.ok(!window.document.getElementById('final-modal').classList.contains('hidden'));

  // ------------------------------------------------ the container dying
  emit('container', {
    event: 'died', oom_killed: true, exit_code: 137, finished_at: '2026-09-20T06:45:00Z',
    docker_status: 'exited', oom: true, sigkill: true, uncertain: false, during_run: true,
    run: { k: '2.5', seed: 2025, minutes: 3 },
    last: { rss_mb: 1016.7, peak_rss_mb: 1016.7, limit_mb: 1024, oom_kills: 1, t: Date.now() },
  });
  await new Promise((r) => setTimeout(r, 10));
  assert.ok(!window.document.getElementById('death-modal').classList.contains('hidden'),
    'a dead container must raise the dialog, not just go quiet');
  assert.match(txt(window, 'death-title'), /out of memory/);
  assert.match(txt(window, 'death-body'), /1016\.7 MB/);
  assert.match(txt(window, 'death-body'), /137 \(SIGKILL\)/);
  window.document.getElementById('death-close').dispatchEvent(new window.Event('click'));

  // A hand-stopped container also exits 137. Claiming THAT was an
  // out-of-memory kill in front of examiners is exactly the bug to avoid.
  Live.death = null;
  emit('container', {
    event: 'died', oom_killed: false, exit_code: 137, docker_status: 'exited',
    oom: false, sigkill: true, uncertain: false, during_run: false,
    run: null, last: { rss_mb: 75, peak_rss_mb: 89.9, limit_mb: 1024, oom_kills: 0 },
  });
  await new Promise((r) => setTimeout(r, 10));
  assert.doesNotMatch(txt(window, 'death-title'), /out of memory/,
    'SIGKILL without Docker reporting OOM must not be announced as an OOM kill');
  assert.match(txt(window, 'death-reason'), /does not report this as an out-of-memory kill/);
  window.document.getElementById('death-close').dispatchEvent(new window.Event('click'));

  // ------------------------------------------------------------- history
  // One archived run and one reconstructed from a recording: the second must
  // show dashes rather than invented numbers.
  routes['/history'] = { runs: [
    { source: 'archive', mode: 'samm', recording: 'SAMM-samm-k2.0-s2025-x.jsonl',
      finished_at: '2026-09-20T07:00:00Z', run: { k: '2.0', seed: 2025, minutes: 3 },
      requests: 136246, dropped_pct: 0.14, peak_rss_mb: 931, e2e_p99: 3056.7, alloc_p99: 193.14,
      container_survived: true },
    { source: 'recording', mode: 'baseline', recording: 'SAMM-baseline-k2.0-s2025-x.jsonl',
      finished_at: '2026-09-20T06:45:00Z', run: { k: '2.0', seed: 2025, minutes: null },
      requests: null, dropped_pct: null, peak_rss_mb: 1016.7, e2e_p99: null, alloc_p99: null,
      container_survived: false, samples: 246 },
  ] };
  window.document.getElementById('history-btn').dispatchEvent(new window.Event('click'));
  await new Promise((r) => setTimeout(r, 20));
  const history = txt(window, 'history-body');
  assert.match(history, /136,246/, 'the archived run should show its request count');
  assert.match(history, /container died/, 'a dead container must be visible in the history');
  assert.match(history, /from recording/, 'a reconstructed row should say so');
  const rows = window.document.querySelectorAll('#history-body tbody tr');
  assert.strictEqual(rows.length, 2);
  // The reconstructed row knows its peak but nothing about requests or p99.
  assert.match(rows[1].textContent, /1017 MB/);
  assert.strictEqual([...rows[1].querySelectorAll('td')][5].textContent, '—');

  // Clicking a row pins it as the chart reference.
  rows[1].dispatchEvent(new window.Event('click'));
  await new Promise((r) => setTimeout(r, 20));
  assert.ok(Live.ghost && Live.ghost.pinned, 'clicking a history row should pin it as the reference');
  assert.strictEqual(Live.ghost.name, 'SAMM-baseline-k2.0-s2025-x.jsonl');

  // -------------------------------------------------------------- run form
  window.document.getElementById('test-btn').dispatchEvent(new window.Event('click'));
  const opts = [...window.document.getElementById('run-k').options].map((o) => o.value);
  assert.deepStrictEqual(opts, STATUS.loads, 'k options should come from the collector');
  assert.strictEqual(window.document.getElementById('run-seed').value, '2025');

  // The form must post what the user chose, to the collector's own endpoint.
  window.document.getElementById('run-k').value = '1.5';
  window.document.getElementById('run-seed').value = '4242';
  window.document.getElementById('run-minutes').value = '7';
  window.document.getElementById('run-form').dispatchEvent(new window.Event('submit'));
  await new Promise((r) => setTimeout(r, 10));
  const run = window.__posted.filter((p) => p.url === '/run').pop();
  assert.deepStrictEqual(run && run.body, { k: '1.5', seed: 4242, minutes: 7 });
  assert.ok(window.document.getElementById('run-modal').classList.contains('hidden'),
    'the form should close once the run is accepted');
  assert.ok(window.__posted.some((p) => p.url === '/mode' && p.body.mode === 'baseline'),
    'the boost button should post the opposite mode');

  // ------------------------------------------------ warmup (v2.html, SAMM only)
  if (has('warmup-btn')) {
    const group = window.document.getElementById('warmup-group');
    routes['/status'] = { ...STATUS, warmup: false };
    await Live.refreshStatus();
    assert.ok(!group.classList.contains('hidden'), 'the warmup control belongs to SAMM mode');
    assert.strictEqual(txt(window, 'warmup-btn'), 'Warmup: off');

    window.document.getElementById('warmup-btn').dispatchEvent(new window.Event('click'));
    await new Promise((r) => setTimeout(r, 10));
    const post = window.__posted.filter((x) => x.url === '/warmup').pop();
    assert.deepStrictEqual(post && post.body, { enabled: true }, 'clicking must ask to turn warmup ON');

    routes['/status'] = { ...STATUS, warmup: true };
    await Live.refreshStatus();
    emit('metrics', sample({ allocator: { ...ALLOCATOR, warmedBytes: ALLOCATOR.reservedFloorBytes } }));
    assert.strictEqual(txt(window, 'warmup-btn'), 'Warmup: on');
    assert.strictEqual(txt(window, 'warmup-note'),
      `${Math.round(ALLOCATOR.reservedFloorBytes / 1048576)} MB pre-faulted`);

    // The baseline has nothing to warm, so the control disappears.
    routes['/status'] = { ...STATUS, mode: 'baseline' };
    await Live.refreshStatus();
    assert.ok(group.classList.contains('hidden'), 'no warmup control in baseline mode');
    routes['/status'] = STATUS;
    await Live.refreshStatus();
  }

  assert.deepStrictEqual(errors, [], `uncaught errors: ${errors.join(', ')}`);
  console.log(`render_test (${PAGE}): all assertions passed`);
  // The page keeps timers running (the run pill ticks every second), so jsdom
  // never goes idle on its own.
  window.close();
  process.exit(0);
})().catch((err) => { console.error(err); process.exit(1); });
