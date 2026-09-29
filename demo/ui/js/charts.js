'use strict';
/**
 * The three live charts.
 *
 * Built once, then fed with setData on every sample -- destroying and
 * recreating a uPlot every second makes the legend flicker and throws away the
 * cursor. The x axis is seconds since the current run started.
 *
 * Each machine runs ONE allocator, so there is exactly one live line. The
 * dashed line is the other mode's last recorded run, and it is labelled as a
 * past run: a second live line would be a fiction.
 */

const LIVE_COLOR = { samm: '#2563eb', baseline: '#ef4444' };
const LIVE_FILL = { samm: 'rgba(37, 99, 235, 0.18)', baseline: 'rgba(239, 68, 68, 0.18)' };
const GHOST_COLOR = '#94a3b8';

const charts = {};

/**
 * Plot size for a chart container: its width, and its height minus whatever the
 * legend under the plot actually takes. uPlot appends that legend itself (a
 * <table class="u-legend"> after the canvas -- it is not in the HTML), and a
 * fixed 36 px guess let a legend that wrapped onto a second line spill out of
 * its card on the narrower v2 charts.
 */
function size(el, chart) {
  const legend = chart && chart.root && chart.root.querySelector('.u-legend');
  const legendPx = legend ? legend.offsetHeight + 8 : 36;
  return { width: el.clientWidth || 600, height: Math.max(80, (el.clientHeight || 256) - legendPx) };
}

/** Dashed horizontal rule at the container limit, drawn under the series. */
function limitLine(getLimit) {
  return (u) => {
    const limit = getLimit();
    if (!limit) return;
    const y = u.valToPos(limit, 'y', true);
    if (!Number.isFinite(y)) return;
    // Span the x SCALE, not u.bbox: bbox is in device pixels and drawing it
    // directly ran the rule past the plot and clipped the label off-canvas.
    const [x0, x1] = [u.scales.x.min, u.scales.x.max].map((v) => u.valToPos(v, 'x', true));
    if (!Number.isFinite(x0) || !Number.isFinite(x1)) return;
    const { ctx } = u;
    ctx.save();
    ctx.strokeStyle = '#ef4444';
    ctx.setLineDash([6, 4]);
    ctx.lineWidth = 1;
    ctx.beginPath();
    ctx.moveTo(x0, y);
    ctx.lineTo(x1, y);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = '#ef4444';
    ctx.font = '11px system-ui, sans-serif';
    ctx.textAlign = 'right';
    ctx.fillText(`container limit ${limit} MB`, x1 - 6, y - 5);
    ctx.restore();
  };
}

// The live mode, read by the stroke/fill callbacks below. uPlot wraps
// series.stroke in fnOrSelf() at init and calls it on every draw, so a colour
// that changes has to BE a function -- assigning a string over it afterwards
// makes uPlot call a string and the whole draw throws, which is why the charts
// rendered empty.
let liveMode = 'samm';

function build(key, elId, opts) {
  const el = document.getElementById(elId);
  if (!el) return null;
  const s = size(el);
  const chart = new uPlot({
    width: s.width,
    height: s.height,
    scales: { x: { time: false }, y: { auto: true, range: opts.range } },
    axes: [
      { label: 'seconds into run', labelSize: 22, grid: { stroke: '#e2e8f0' }, stroke: '#64748b' },
      { grid: { stroke: '#e2e8f0' }, stroke: '#64748b' },
    ],
    legend: { show: true },
    hooks: opts.hooks || {},
    series: [
      {},
      {
        label: opts.liveLabel,
        stroke: () => LIVE_COLOR[liveMode] || LIVE_COLOR.samm,
        width: 2,
        fill: opts.fill ? () => LIVE_FILL[liveMode] || LIVE_FILL.samm : undefined,
        value: opts.fmt,
      },
      { label: 'previous run', stroke: GHOST_COLOR, width: 1, dash: [5, 4], value: opts.fmt },
    ],
  }, [[], [], []], el);
  charts[key] = { chart, el };
  // The legend exists only now that uPlot has built it, so this is the first
  // moment its real height can be subtracted.
  chart.setSize(size(el, chart));
  return chart;
}

/**
 * Renames the live series in the legend. uPlot builds the legend once at init
 * and has no API for renaming a series, so the label cell is edited in place;
 * the colour needs nothing here, because the stroke callback reads liveMode.
 */
function applyLabel(entry, label) {
  if (entry.label === label) return;
  entry.label = label;
  entry.chart.series[1].label = label;
  // No legend (or no DOM, as in the tests) is not a failure: the label is
  // cosmetic, and throwing here would abort the whole render.
  const root = entry.chart.root;
  const row = root && root.querySelectorAll('.u-legend .u-series')[1];
  const cell = row && row.querySelector('.u-label');
  if (cell) cell.textContent = label;
}

const Charts = {
  init() {
    build('memory', 'memory-chart', {
      liveLabel: 'RSS (MB)',
      fmt: (u, v) => (v == null ? '--' : `${v.toFixed(1)} MB`),
      range: (u, min, max) => [0, Math.max(max || 0, Charts._limit || 0) * 1.08 || 100],
      hooks: { draw: [limitLine(() => Charts._limit)] },
    });
    // Both axes start at zero. Auto-scaling turned a 30 ms band into a
    // mountain range, which reads as instability that is not there -- and two
    // machines side by side could not be compared if each picked its own
    // scale. The headline number above the chart carries the precision.
    const fromZero = (u, min, max) => [0, (max || 1) * 1.1];
    build('throughput', 'throughput-chart', {
      liveLabel: 'requests/s',
      fill: true,
      range: fromZero,
      fmt: (u, v) => (v == null ? '--' : `${Math.round(v)} req/s`),
    });
    build('latency', 'latency-chart', {
      liveLabel: 'p95 (ms)',
      range: fromZero,
      fmt: (u, v) => (v == null ? '--' : `${v.toFixed(1)} ms`),
    });
  },

  render(live) {
    Charts._limit = live.sample && live.sample.limit_mb ? live.sample.limit_mb : null;
    const mode = (live.status && live.status.mode) || 'samm';
    const modeLabel = mode === 'samm' ? 'SAMM' : 'V8 baseline';
    const ghost = live.ghost ? live.ghost.series : null;

    liveMode = mode;
    const feed = (key, field, unit) => {
      const entry = charts[key];
      if (!entry) return;
      applyLabel(entry, modeLabel);
      // uPlot needs every series on the same x values, so the recorded run is
      // resampled onto the live clock: both are seconds since their own start.
      const t = live.series.t;
      const past = ghost ? t.map((sec) => valueAt(ghost, field, sec)) : t.map(() => null);
      entry.chart.setData([t, live.series[field], past]);
    };

    feed('memory', 'rss', '(MB)');
    feed('throughput', 'rps', '(req/s)');

    // Latency: live and reference must be the SAME statistic or the reference
    // is not drawn. A cumulative p95 is smoother than a rolling one by
    // construction, so plotting one against the other flatters whichever is
    // cumulative.
    const lat = live.latency || { source: 'cumulative' };
    const rollingLive = lat.source === 'rolling';
    const field = rollingLive ? 'p95r' : 'p95c';
    const entry = charts.latency;
    if (entry) {
      applyLabel(entry, modeLabel);
      const t = live.series.t;
      // Live.referenceComparable when running in the page; the same rule inline
      // when a test hands in a plain state object.
      const comparable = ghost && (typeof Live !== 'undefined'
        ? Live.referenceComparable(live) : Boolean(ghost.hasRolling) === rollingLive);
      const past = comparable ? t.map((sec) => valueAt(ghost, field, sec)) : t.map(() => null);
      entry.chart.setData([t, live.series[field], past]);
    }
  },
};

/** Nearest recorded value at `sec` seconds into the past run, or null past its end. */
function valueAt(series, field, sec) {
  const t = series.t;
  if (!t.length || sec > t[t.length - 1]) return null;
  let lo = 0, hi = t.length - 1;
  while (lo < hi) {
    const mid = (lo + hi) >> 1;
    if (t[mid] < sec) lo = mid + 1; else hi = mid;
  }
  return series[field][lo] ?? null;
}

const resizeObserver = new ResizeObserver((entries) => {
  for (const entry of entries) {
    const found = Object.values(charts).find((c) => c.el === entry.target);
    if (found) found.chart.setSize(size(found.el, found.chart));
  }
});

window.addEventListener('DOMContentLoaded', () => {
  Charts.init();
  for (const c of Object.values(charts)) resizeObserver.observe(c.el);
});
