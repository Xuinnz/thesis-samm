'use strict';
/**
 * Draws the charts with the REAL vendored uPlot, not a stub.
 *
 * The render test stubs uPlot, so it happily passed while the charts were
 * blank: uPlot wraps series.stroke in fnOrSelf() at init and calls it on every
 * draw, and the old code assigned a colour STRING over it, so each draw threw
 * "s.stroke is not a function" and no line was ever painted.
 *
 * jsdom has no canvas, so 2d contexts are stubbed -- enough for uPlot to lay
 * out and run its draw path, which is where that bug lived.
 *
 * Usage: node test/chart_test.js
 */

const fs = require('fs');
const path = require('path');
const assert = require('assert');
const { JSDOM } = require('jsdom');

const UI = path.resolve(__dirname, '..');

/** jsdom implements neither of these, and uPlot calls matchMedia at load. */
function stubPlatform(window) {
  window.devicePixelRatio = 1;
  window.matchMedia = () => ({
    matches: false, media: '', onchange: null,
    addEventListener() {}, removeEventListener() {},
    addListener() {}, removeListener() {}, dispatchEvent() { return false; },
  });
}

function stubCanvas(window) {
  const ctx = new Proxy({}, {
    get(target, key) {
      if (key in target) return target[key];
      if (key === 'measureText') return () => ({ width: 10 });
      if (key === 'createLinearGradient') return () => ({ addColorStop() {} });
      if (key === 'getImageData') return () => ({ data: new Uint8ClampedArray(4) });
      return () => undefined;           // every other ctx method is a no-op
    },
    set(target, key, value) { target[key] = value; return true; },
  });
  window.HTMLCanvasElement.prototype.getContext = () => ctx;
  return ctx;
}

const series = (n, fn) => Array.from({ length: n }, (_, i) => fn(i));

function live(mode, points) {
  const none = series(points, () => null);
  return {
    status: { mode },
    sample: { limit_mb: 1024 },
    latency: { source: 'cumulative', window_s: null },
    series: {
      t: series(points, (i) => i),
      rss: series(points, (i) => 300 + i * 2),
      rps: series(points, (i) => 600 + i),
      p95c: series(points, (i) => 100 + i),
      p95r: none,
    },
    ghost: {
      mode: mode === 'samm' ? 'baseline' : 'samm', k: '2.0', seed: 2025,
      series: {
        t: series(points, (i) => i),
        rss: series(points, (i) => 900 - i),
        rps: series(points, (i) => 400 + i),
        p95c: series(points, (i) => 800 + i),
        p95r: none,
        hasRolling: false,
      },
    },
  };
}

const dom = new JSDOM(fs.readFileSync(path.join(UI, 'index.html'), 'utf8'), {
  runScripts: 'outside-only', url: 'http://localhost:9100/', pretendToBeVisual: true,
});
const { window } = dom;
stubPlatform(window);
stubCanvas(window);
window.ResizeObserver = class { observe() {} disconnect() {} };

const errors = [];
window.addEventListener('error', (e) => errors.push(e.message));

try {
  window.eval(fs.readFileSync(path.join(UI, 'vendor/uPlot.iife.min.js'), 'utf8'));
} catch (err) {
  console.error(`loading uPlot failed: ${err.message}`);
  process.exit(1);
}
assert.ok(window.uPlot, 'vendored uPlot failed to load');
// charts.js is strict, so its top-level const stays inside this eval: the two
// handles the test needs are exported from the same evaluation.
window.eval(`${fs.readFileSync(path.join(UI, 'js/charts.js'), 'utf8')}
;window.__Charts = Charts; window.__charts = charts;`);

const Charts = window.__Charts;
Charts.init();

// ------------------------------------------------------- data reaches uPlot
Charts.render(live('samm', 30));
const chart = window.__charts.memory.chart;
assert.strictEqual(chart.data[1].length, 30, 'live series was not fed');
assert.strictEqual(chart.data[1][10], 320, 'live values are wrong');
assert.strictEqual(chart.data[2][10], 890, 'the recorded run should be resampled onto the live clock');

// --------------------------------------------- the stroke stays a function
// This is the regression: after uPlot's init, series.stroke MUST be callable,
// and it must return the colour for the current mode.
for (const key of ['memory', 'throughput', 'latency']) {
  const c = window.__charts[key].chart;
  const stroke = c.series[1].stroke;
  assert.strictEqual(typeof stroke, 'function', `${key}: series.stroke must stay a function`);
  assert.strictEqual(stroke(c, 1), '#2563eb', `${key}: SAMM should draw blue`);
}

// A mode change recolours without breaking the callback.
Charts.render(live('baseline', 10));
for (const key of ['memory', 'throughput', 'latency']) {
  const c = window.__charts[key].chart;
  assert.strictEqual(c.series[1].stroke(c, 1), '#ef4444', `${key}: baseline should draw red`);
}
assert.match(window.__charts.memory.chart.series[1].label, /V8 baseline/);

// ------------------------------------------------- a real draw must not throw
// The draw path calls series.stroke(self, i). This is exactly what used to
// fail, and a throw here means nothing gets painted.
for (const key of ['memory', 'throughput', 'latency']) {
  const c = window.__charts[key].chart;
  assert.doesNotThrow(() => c.redraw(), `${key}: redraw threw, so no line would be drawn`);
}

// NOTE: jsdom has no canvas, so uPlot's draw path stops before it calls
// series.stroke(). That means this file CANNOT prove a line is painted --
// test/visual.html + test/browser_check.sh do that in a real browser, by
// counting painted pixels.

// Same statistic on both sides: the reference IS drawn on the latency chart.
Charts.render(live('samm', 20));
assert.strictEqual(window.__charts.latency.chart.data[2][5], 805, 'a like-for-like reference must be drawn');
// Rolling live against a cumulative-only reference: it must not be.
const mixed = live('samm', 20);
mixed.latency = { source: 'rolling', window_s: 5 };
mixed.series.p95r = series(20, (i) => 50 + i);
Charts.render(mixed);
assert.ok(window.__charts.latency.chart.data[2].every((v) => v === null), 'mixed statistics must not be drawn together');
assert.strictEqual(window.__charts.latency.chart.data[1][3], 53, 'the live line must be the rolling series');

// --------------------------------------------------- no ghost is fine as well
Charts.render({ ...live('samm', 5), ghost: null });
assert.deepStrictEqual(window.__charts.memory.chart.data[2], [null, null, null, null, null]);

assert.deepStrictEqual(errors, [], `uncaught errors: ${errors.join(', ')}`);
console.log('chart_test: all assertions passed');
window.close();
process.exit(0);
