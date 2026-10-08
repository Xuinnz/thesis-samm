'use strict';
/**
 * Renders the dashboard from Live's state and wires the controls.
 *
 * Every value on the page traces back to a measurement: cgroup counters, k6's
 * REST API, the allocator's own stats, or the compiled routing table. The one
 * computed number is the health score, and the help dialog shows its formula.
 */

const $ = (id) => document.getElementById(id);
const NA = Live.NA;

function text(id, value) {
  const el = $(id);
  if (el) el.textContent = value === null || value === undefined ? NA : value;
}

/**
 * Runs `fn` only if that element exists on this page.
 *
 * index.html and v2.html are two layouts over the same state, so a panel that
 * lives on one is simply absent on the other. Missing means "not shown here",
 * never an error -- a throw would abort the rest of the render.
 */
function on(id, fn) {
  const el = $(id);
  if (el) fn(el);
}

const mb = (v, d = 0) => (v === null || v === undefined ? NA : `${Number(v).toFixed(d)} MB`);
const pct = (v, d = 2) => (v === null || v === undefined ? NA : `${Number(v).toFixed(d)}%`);
const int = (v) => (v === null || v === undefined ? NA : Math.round(v).toLocaleString());

// --------------------------------------------------------------- header
function renderHeader(live) {
  const mode = live.status ? live.status.mode : null;
  const isSamm = mode === 'samm';
  on('mode-badge', (badge) => {
    badge.textContent = mode ? (isSamm ? 'SAMM ALLOCATOR' : 'V8 BASELINE') : 'NO CONTAINER';
    badge.className = `w-fit rounded-full px-3 py-1 text-xs font-bold tracking-wide ${
      !mode ? 'bg-slate-200 text-slate-600' : isSamm ? 'bg-[#0b1428] text-white' : 'bg-red-100 text-red-700'}`;
  });

  const up = live.sample && live.sample.up;
  on('link-dot', (dot) => {
    dot.className = `inline-block h-2 w-2 rounded-full ${
      !live.connected ? 'bg-slate-300' : up ? 'bg-green-500' : 'bg-amber-400'}`;
  });
  const label = live.status ? live.status.label : (live.hello && live.hello.label) || '';
  text('link-text', !live.connected ? 'disconnected — retrying'
    : up ? `${label} · container up` : `${label} · container down`);

  const running = Boolean(live.status && live.status.running);
  const busy = Boolean(live.status && (live.status.switching || live.status.replaying));
  on('test-btn', (btn) => {
    btn.textContent = running ? 'Stop run' : 'Test with K6';
    btn.disabled = busy || (!running && !up);
  });
  on('boost-btn', (btn) => {
    btn.textContent = isSamm ? 'Back to V8 Baseline' : 'Boost with SAMM';
    btn.disabled = running || busy;
  });

  // SAMM only, and v2.html only: the element simply does not exist elsewhere.
  on('warmup-group', (group) => {
    group.classList.toggle('hidden', !isSamm);
    group.classList.toggle('flex', isSamm);
  });
  // Display-only: hide ML validation numbers until SAMM. Data still renders underneath.
  on('ml-validation', (el) => {
    if (isSamm) el.setAttribute('data-mode', 'samm');
    else el.removeAttribute('data-mode');
  });
  const warm = Boolean(live.status && live.status.warmup);
  on('warmup-btn', (btn) => {
    btn.textContent = `Warmup: ${warm ? 'on' : 'off'}`;
    btn.disabled = running || busy;
    btn.className = `whitespace-nowrap rounded-full px-4 py-2 text-sm font-medium disabled:cursor-not-allowed disabled:opacity-40 ${
      warm ? 'bg-amber-100 text-amber-800 border border-amber-300' : 'border border-slate-300 bg-white text-slate-700'}`;
  });
  const alloc = live.sample && live.sample.allocator;
  text('warmup-note', warm && alloc && alloc.warmedBytes
    ? `${Math.round(alloc.warmedBytes / 1048576)} MB pre-faulted` : '');

  const run = live.status && live.status.run;
  on('run-pill', (pill) => {
    if (run) {
      const elapsed = Math.round((Date.now() - run.startedAt) / 1000);
      pill.textContent = `running k=${run.k} · seed ${run.seed}${run.warmup ? ' · warmed' : ''} · ${Math.floor(elapsed / 60)}m${String(elapsed % 60).padStart(2, '0')}s of ${run.minutes}m`;
      pill.classList.remove('hidden');
    } else {
      pill.classList.add('hidden');
    }
  });
}

// ------------------------------------------------------------- left column
function renderHeadline(live) {
  const d = live.derived;
  const s = live.sample;
  if (!s || !s.up) return text('status-headline', 'Container is not running.');
  if (d.oom) return text('status-headline', 'Container was OOM killed.');
  if (d.system_status === 'STABLE') return text('status-headline', 'System looks good!');
  if (d.system_status === 'AT RISK') return text('status-headline', 'System is under pressure.');
  if (d.system_status === 'CRITICAL') return text('status-headline', 'System needs optimization.');
  text('status-headline', 'Waiting for traffic…');
}

function renderDensity(live) {
  const s = live.sample;
  const limit = s && s.limit_mb ? s.limit_mb : 1024;
  const rss = s && s.rss_mb !== null ? s.rss_mb : null;
  text('memory-density-current', rss === null ? NA : `${rss.toFixed(0)} MB / ${limit} MB`);
  text('density-cap', `${limit} MB cap`);

  const blocks = $('memory-density-blocks');
  if (!blocks) return;
  blocks.replaceChildren();
  const filled = rss === null ? 0 : Math.round((rss / limit) * 24);
  const stops = live.derived.system_status === 'STABLE'
    ? ['#0b1428', '#2563eb', '#7dd3fc']
    : ['#0b1428', '#2563eb', '#7f1d1d'];

  for (let i = 0; i < 24; i++) {
    const block = document.createElement('div');
    block.style.height = '128px';
    block.style.flex = '1';
    block.style.borderRadius = '2px';
    if (i < filled) {
      block.style.background = gradientColorAt(filled <= 1 ? 1 : i / (filled - 1), stops);
    } else {
      block.style.background = '#ffffff';
      block.style.border = '1px solid #cbd5e1';
    }
    blocks.appendChild(block);
  }
}

const hexToRgb = (hex) => { const n = parseInt(hex.slice(1), 16); return { r: (n >> 16) & 255, g: (n >> 8) & 255, b: n & 255 }; };
const lerp = (a, b, t) => a + (b - a) * t;
function mixHex(from, to, t) {
  const a = hexToRgb(from); const b = hexToRgb(to);
  return `rgb(${Math.round(lerp(a.r, b.r, t))}, ${Math.round(lerp(a.g, b.g, t))}, ${Math.round(lerp(a.b, b.b, t))})`;
}
function gradientColorAt(t, stops) {
  if (t <= 0) return stops[0];
  if (t >= 1) return stops[stops.length - 1];
  const scaled = t * (stops.length - 1);
  const i = Math.min(Math.floor(scaled), stops.length - 2);
  return mixHex(stops[i], stops[i + 1], scaled - i);
}

const POLICY_STYLE = {
  Bump: 'bg-blue-50 text-blue-700 border-blue-200',
  Slab: 'bg-emerald-50 text-emerald-700 border-emerald-200',
  System: 'bg-slate-100 text-slate-600 border-slate-300',
};

/**
 * Arena cards. The sizes are CAPACITY from the routing table, not live
 * occupancy: the addon reports committed bytes for the pool as a whole, not per
 * arena, so a per-arena "used" figure would have to be invented.
 */
function renderArenas(live) {
  const host = $('arena-content');
  if (!host) return;
  host.replaceChildren();
  const table = live.table;
  const alloc = live.sample && live.sample.allocator;

  if (!table || !table.sites || !table.sites.length) {
    const empty = document.createElement('div');
    empty.className = 'flex w-full flex-1 items-center justify-center text-slate-400';
    empty.textContent = 'No routing table found';
    host.append(empty, arenaFooter(live, alloc));
    return;
  }

  const grid = document.createElement('div');
  grid.className = 'w-full flex-1';
  grid.style.display = 'grid';
  grid.style.gridTemplateColumns = 'repeat(auto-fit, minmax(150px, 1fr))';
  grid.style.gap = '12px';
  grid.style.alignContent = 'start';

  for (const site of table.sites) {
    const card = document.createElement('div');
    card.className = 'flex flex-col gap-1 rounded-xl border border-slate-200 bg-white p-4 text-slate-800 shadow-sm';

    const head = document.createElement('div');
    head.className = 'mb-1 flex items-center justify-between';
    const title = document.createElement('p');
    title.className = 'font-bold';
    title.textContent = site.name;
    const tag = document.createElement('span');
    tag.className = `rounded-full border px-2 py-0.5 text-[10px] font-semibold ${POLICY_STYLE[site.policy] || POLICY_STYLE.System}`;
    tag.textContent = site.policy;
    head.append(title, tag);

    const rows = [
      ['lifespan', site.mean_lifespan_ms === null ? NA : `${site.mean_lifespan_ms} ms`],
      ['variance', site.variance === null ? NA : site.variance.toLocaleString()],
      ['size CV', site.size_cv === null ? NA : site.size_cv.toFixed(2)],
      ['objects', int(site.objects)],
    ];
    if (site.policy === 'Bump') {
      rows.push(['floor / span', `${mb(site.floor_mb, 1)} / ${mb(site.span_mb, 0)}`]);
      rows.push(['segment', `${mb(site.segment_mb, 1)} × ${site.max_segments}`]);
    } else if (site.policy === 'Slab') {
      const cls = (live.table.slab_classes || [])[0];
      rows.push(['class', cls ? `${cls.class_kb} KB` : NA]);
      rows.push(['floor / max', cls ? `${mb(cls.floor_mb)} / ${mb(cls.max_mb)}` : NA]);
    } else {
      rows.push(['reclaim', 'V8 garbage collector']);
      rows.push(['overhang', site.median_overhang_ms === null ? NA : `${site.median_overhang_ms} ms`]);
    }
    if (site.huge_pages) rows.push(['huge pages', '2 MB on']);

    card.append(head);
    for (const [k, v] of rows) {
      const row = document.createElement('p');
      row.className = 'flex justify-between text-xs text-slate-600';
      const kEl = document.createElement('span'); kEl.textContent = k;
      const vEl = document.createElement('span'); vEl.className = 'font-medium text-slate-800'; vEl.textContent = v;
      row.append(kEl, vEl);
      card.append(row);
    }
    grid.appendChild(card);
  }

  host.append(grid, arenaFooter(live, alloc));
}

function arenaFooter(live, alloc) {
  const wrap = document.createElement('div');
  wrap.className = 'mt-4 flex flex-col gap-2';

  if (alloc) {
    const committed = alloc.committedBytes / 1048576;
    const ceiling = alloc.ceilingBytes / 1048576;
    const bar = document.createElement('div');
    bar.className = 'h-2 w-full overflow-hidden rounded-full bg-white/20';
    const fill = document.createElement('div');
    fill.className = 'h-full rounded-full bg-sky-400';
    fill.style.width = `${Math.min(100, (committed / ceiling) * 100).toFixed(1)}%`;
    bar.appendChild(fill);
    const caption = document.createElement('div');
    caption.className = 'flex justify-between text-xs text-slate-300';
    caption.innerHTML = `<span>pool committed ${committed.toFixed(1)} MB of ${ceiling.toFixed(0)} MB ceiling</span>` +
      `<span>arena overflow: ${int(alloc.capacityFallbacks)}</span>`;
    wrap.append(bar, caption);
  } else {
    const note = document.createElement('p');
    note.className = 'text-center text-xs text-slate-400';
    note.textContent = live.status && live.status.mode === 'baseline'
      ? 'V8 baseline: the arenas above are the plan SAMM would use; no allocator is active'
      : 'allocator statistics unavailable';
    wrap.append(note);
  }
  return wrap;
}

function renderMlTiles(live) {
  const t = live.table;
  text('kmeans-clusters-value', t ? t.cluster_count : NA);
  text('kmeans-note', t ? `cluster ${t.system_cluster} escapes its request → System` : '');

  const alloc = live.sample && live.sample.allocator;
  if (alloc) {
    // Same denominator the benchmark scripts use.
    const allocs = alloc.regionReclaimed + alloc.unmanaged + alloc.capacityFallbacks;
    text('fallback-rate-value', allocs ? pct((100 * alloc.capacityFallbacks) / allocs) : '0.00%');
    text('fallback-note', `${int(alloc.capacityFallbacks)} of ${int(allocs)} allocations`);
  } else {
    text('fallback-rate-value', NA);
    text('fallback-note', 'SAMM mode only');
  }

  // Arena choice: the minimum-waste comparison, per call-site.
  const policyBody = $('policy-rule-body');
  if (policyBody) {
  policyBody.replaceChildren();
  for (const site of (t ? t.sites : []).filter((s) => s.policy !== 'System')) {
    const row = document.createElement('div');
    row.className = 'flex items-center justify-between gap-2 border-b border-slate-100 py-1 last:border-0';
    const win = site.policy === 'Bump' ? site.bump_extra_mb : site.slab_extra_mb;
    const lose = site.policy === 'Bump' ? site.slab_extra_mb : site.bump_extra_mb;
    row.innerHTML = `<span class="font-semibold text-slate-700">${site.name}</span>` +
      `<span class="text-slate-500">${Number(win).toFixed(1)} vs ${Number(lose).toFixed(1)} MB</span>` +
      `<span class="rounded-full border px-2 py-0.5 text-[10px] font-semibold ${POLICY_STYLE[site.policy]}">${site.policy}</span>`;
    policyBody.appendChild(row);
  }
  }

  const escapeBody = $('escape-rule-body');
  if (!escapeBody) return;
  escapeBody.replaceChildren();
  for (const site of (t ? t.sites : [])) {
    const row = document.createElement('div');
    row.className = 'flex items-center justify-between gap-2 border-b border-slate-100 py-1 last:border-0';
    const escapes = site.policy === 'System';
    row.innerHTML = `<span class="font-semibold text-slate-700">${site.name}</span>` +
      `<span class="text-slate-500">${site.median_overhang_ms === null ? NA : `${site.median_overhang_ms} ms`}</span>` +
      `<span class="${escapes ? 'text-slate-600' : 'text-blue-700'} font-semibold">${escapes ? 'System' : `cluster ${site.cluster}`}</span>`;
    escapeBody.appendChild(row);
  }
}

// ------------------------------------------------------------ hero tiles
/**
 * The three headline metrics as plain numbers (v2.html only).
 *
 * Each shows the reference run's value at the SAME point in its run, so the
 * comparison is like-for-like rather than "now" against "someone's average".
 * It is labelled as a recording everywhere it appears.
 */
function renderHero(live) {
  if (!$('hero-rps')) return;                  // the classic layout has no hero row
  const s = live.sample || {};
  const mode = live.status && live.status.mode;
  const color = mode === 'baseline' ? '#b91c1c' : '#0b1428';

  const rollingNow = live.latency && live.latency.source === 'rolling';

  // Where the live run currently is, in seconds.
  const t = live.series.t;
  const now = t.length ? t[t.length - 1] : null;
  const past = (field) => {
    const g = live.ghost && live.ghost.series;
    if (!g || now === null || !g.t.length || now > g.t[g.t.length - 1]) return null;
    let lo = 0, hi = g.t.length - 1;
    while (lo < hi) { const mid = (lo + hi) >> 1; if (g.t[mid] < now) lo = mid + 1; else hi = mid; }
    return g[field][lo] ?? null;
  };
  const prevLabel = (value, unit) => {
    if (!live.ghost) return 'no reference run yet';
    const who = live.ghost.mode === 'samm' ? 'SAMM' : 'V8 baseline';
    return value === null ? `${who} run ended before this point`
      : `${who} at this point: ${value}${unit} (recorded)`;
  };

  for (const id of ['hero-rps', 'hero-p95', 'hero-rss']) on(id, (el) => { el.style.color = color; });

  text('hero-rps', s.rps === null || s.rps === undefined ? NA : int(s.rps));
  const pastRps = past('rps');
  text('hero-rps-prev', prevLabel(pastRps === null ? null : int(pastRps), ' req/s'));

  const p95 = Live.latencyOf(s);
  text('hero-p95', p95 === null || p95 === undefined ? NA : int(p95));
  text('hero-p95-source', rollingNow
    ? (p95 === null || p95 === undefined ? 'no window this moment'
      : `last ${live.latency.window_s} s${s.e2e_p99_roll ? ` · p99 ${int(s.e2e_p99_roll)} ms` : ''}`)
    : (p95 === null || p95 === undefined ? '' : 'cumulative'));
  const noLatency = !live.latency || live.latency.source === 'none';
  text('latency-note', (rollingNow
    ? `— rolling, over the last ${live.latency.window_s} s`
    : noLatency ? '— waiting for the first requests'
    : '— cumulative since the run began')
    + (live.ghost && !Live.referenceComparable(live)
      ? ` · reference run not drawn: it only has ${live.ghost.series.hasRolling ? 'rolling' : 'cumulative'} latency` : ''));
  const g = live.ghost && live.ghost.series;
  if (g && !Live.referenceComparable(live)) {
    text('hero-p95-prev', `reference run recorded ${g.hasRolling ? 'rolling' : 'cumulative'} latency — not comparable`);
  } else {
    const pastP95 = past(Live.latencyField(live));
    text('hero-p95-prev', prevLabel(pastP95 === null ? null : int(pastP95), ' ms'));
  }

  const limit = s.limit_mb || 1024;
  text('hero-rss', s.rss_mb === null || s.rss_mb === undefined ? NA : Math.round(s.rss_mb));
  text('hero-rss-limit', `of ${limit} MB`);
  const pastRss = past('rss');
  text('hero-rss-prev', prevLabel(pastRss === null ? null : Math.round(pastRss), ' MB'));
  on('hero-rss-bar', (bar) => {
    const frac = s.rss_mb ? Math.min(1, s.rss_mb / limit) : 0;
    bar.style.width = `${(frac * 100).toFixed(1)}%`;
    // Same thresholds as Memory Load, so the bar and the label never disagree.
    bar.style.background = frac > 0.8 ? '#b91c1c' : frac > 0.6 ? '#d97706' : color;
  });

  // One line of ML, so zone 1 does not have to hide it completely.
  on('ml-summary', (el) => {
    const table = live.table;
    if (!table) { el.textContent = 'routing table ↓'; return; }
    const bump = table.sites.filter((x) => x.policy === 'Bump').length;
    const slab = table.sites.filter((x) => x.policy === 'Slab').length;
    const sys = table.sites.filter((x) => x.policy === 'System').length;
    el.textContent = `${bump} bump · ${slab} slab · ${sys} system ↓`;
  });
}

// ----------------------------------------------------------- ML validation
/**
 * Evidence for each ML layer (v2.html only).
 *
 * No layer has labelled ground truth, so there is no honest single "accuracy".
 * Each is judged by the kind of decision it makes:
 *
 *   Layer 1 classifies   -> how cleanly the escaping sites separate, plus the
 *                           runtime invariants a misroute would break
 *   Layer 2 optimises    -> how decisively each choice beat the alternative
 *   Layer 3 predicts     -> how often the provisioned capacity fell short
 *
 * Every number comes from /table or the live allocator counters. Nothing here
 * is a threshold: verdicts are statements of fact, not grades.
 */
function renderValidation(live) {
  if (!$('ml-validation')) return;
  const t = live.table;
  const a = live.sample && live.sample.allocator;
  const s = live.sample || {};
  const sites = t ? t.sites : [];

  const rowsInto = (id, rows) => on(id, (host) => {
    host.replaceChildren();
    for (const [k, v, cls] of rows) {
      const row = document.createElement('div');
      row.className = 'flex justify-between gap-3 border-b border-slate-100 py-1 last:border-0';
      const kEl = document.createElement('span'); kEl.className = 'text-slate-500'; kEl.textContent = k;
      const vEl = document.createElement('span'); vEl.className = cls || 'font-semibold text-slate-800'; vEl.textContent = v;
      row.append(kEl, vEl);
      host.appendChild(row);
    }
  });

  // ---------------------------------------------------------------- layer 1
  // The least-escaping escaped site against the most-lingering managed one:
  // the narrowest the gap between the two classes ever gets.
  const escaped = sites.filter((x) => x.policy === 'System' && x.median_overhang_ms !== null);
  const managed = sites.filter((x) => x.policy !== 'System' && x.median_overhang_ms !== null);
  if (escaped.length && managed.length) {
    const e = escaped.reduce((m, x) => (x.median_overhang_ms < m.median_overhang_ms ? x : m));
    const m = managed.reduce((mx, x) => (x.median_overhang_ms > mx.median_overhang_ms ? x : mx));
    text('val1-big', m.median_overhang_ms > 0
      ? `${Math.round(e.median_overhang_ms / m.median_overhang_ms)}×` : 'total');
    text('val1-caption', `${e.name} outlives its request by ${int(e.median_overhang_ms)} ms; ` +
      `the closest managed site, ${m.name}, by ${int(m.median_overhang_ms)} ms`);
  } else {
    text('val1-big', NA);
    text('val1-caption', escaped.length ? 'no managed call sites' : 'no call site escapes its request');
  }
  rowsInto('val1-rows', [
    ['sent to System', escaped.length ? escaped.map((x) => x.name).join(', ') : 'none'],
    // If an escaping site had been routed into a region, its buffer would be
    // detached while still in use -- these are where that would surface.
    ['detach failures', a ? int(a.detachFailures) : 'SAMM mode only',
      a && a.detachFailures > 0 ? 'font-bold text-red-600' : undefined],
    ['failed requests', s.failed_pct === null || s.failed_pct === undefined ? NA : pct(s.failed_pct)],
  ]);
  on('val1-chip', (chip) => {
    if (!a) {
      chip.textContent = 'SAMM mode only';
      chip.className = 'rounded-full bg-slate-100 px-2 py-0.5 text-[10px] font-semibold text-slate-500';
    } else if (a.detachFailures === 0) {
      chip.textContent = 'safety net held';
      chip.className = 'rounded-full bg-green-50 px-2 py-0.5 text-[10px] font-semibold text-green-700';
    } else {
      chip.textContent = 'detach failed';
      chip.className = 'rounded-full bg-red-50 px-2 py-0.5 text-[10px] font-semibold text-red-700';
    }
  });

  // ---------------------------------------------------------------- layer 2
  // Below one huge page the choice cannot matter for memory; the policy breaks
  // that tie on allocation-path cost, so those sites carry no margin.
  const hugeMb = t && t.budget && t.budget.huge_page_size ? t.budget.huge_page_size / 1048576 : 2;
  const choices = sites.filter((x) => x.policy === 'Bump' || x.policy === 'Slab').map((x) => {
    const bump = x.policy === 'Bump';
    const win = bump ? x.bump_extra_mb : x.slab_extra_mb;
    const lose = bump ? x.slab_extra_mb : x.bump_extra_mb;
    const material = Math.max(win, lose) >= hugeMb;
    return { x, win, lose, material, margin: !material ? null : win > 0 ? lose / win : Infinity };
  });
  const closest = choices.filter((c) => c.material && Number.isFinite(c.margin))
    .sort((p, q) => p.margin - q.margin)[0];
  if (closest) {
    const other = closest.x.policy === 'Bump' ? 'slab' : 'bump';
    text('val2-big', `${closest.margin.toFixed(1)}×`);
    text('val2-caption', `closest call: ${closest.x.name} — ${closest.x.policy.toLowerCase()} ` +
      `${closest.win.toFixed(1)} MB vs ${other} ${closest.lose.toFixed(1)} MB wasted`);
  } else {
    text('val2-big', NA);
    text('val2-caption', t ? 'no material choices' : 'routing table unavailable');
  }
  rowsInto('val2-rows', choices.map((c) => [
    `${c.x.name} → ${c.x.policy}`,
    !c.material ? `both < ${hugeMb} MB, tie-break`
      : c.margin === Infinity ? `exact: ${c.x.policy.toLowerCase()} wastes 0 MB`
      : `${c.margin.toFixed(1)}× better`,
    c === closest ? 'font-bold text-amber-700' : undefined,
  ]));
  const saved = choices.filter((c) => c.material).reduce((acc, c) => acc + (c.lose - c.win), 0);
  text('val2-saved', choices.length
    ? `the chosen structures avoid ${saved.toFixed(0)} MB of predicted waste versus the alternatives`
    : '');

  // ---------------------------------------------------------------- layer 3
  if (a) {
    // Same denominator as the fallback-rate tile and the benchmark scripts.
    const allocs = a.regionReclaimed + a.unmanaged + a.capacityFallbacks;
    const served = allocs - a.capacityFallbacks;
    text('val3-big', allocs ? pct((100 * served) / allocs, 1) : '100.0%');
    text('val3-caption', `${int(served)} of ${int(allocs)} allocations served by the provisioned capacity`);

    const binding = a.capacityFallbacks === 0 ? 'nothing — no misses'
      : a.budgetRefusals >= a.capacityFallbacks ? 'the global budget ceiling'
      : 'arena sizing';
    rowsInto('val3-rows', [
      ['binding constraint', binding],
      ['pool committed', a.ceilingBytes ? pct((100 * a.committedBytes) / a.ceilingBytes, 1) : NA],
      ['misses', int(a.capacityFallbacks)],
    ]);

    const causes = [
      ['bump could not wrap or grow', a.bumpResetBlocked, '#2563eb'],
      ['slab class exhausted', a.slabExhaustedFallbacks, '#059669'],
      ['bigger than any arena', a.bumpOversizeFallbacks + a.slabOversizeFallbacks, '#d97706'],
      ['class never provisioned', a.slabZeroSlotFallbacks, '#64748b'],
    ];
    const total = causes.reduce((acc, [, n]) => acc + n, 0);
    on('val3-bar', (bar) => {
      bar.replaceChildren();
      for (const [, n, color] of causes) {
        if (!n) continue;
        const seg = document.createElement('div');
        seg.style.width = `${((100 * n) / total).toFixed(2)}%`;
        seg.style.background = color;
        bar.appendChild(seg);
      }
    });
    on('val3-legend', (legend) => {
      legend.replaceChildren();
      for (const [label, n, color] of causes) {
        if (!n) continue;
        const item = document.createElement('span');
        item.innerHTML = `<span style="color:${color}">■</span> ${label} ${Math.round((100 * n) / total)}%`;
        legend.appendChild(item);
      }
    });
  } else {
    text('val3-big', NA);
    text('val3-caption', 'SAMM mode only — the baseline has no quotas');
    rowsInto('val3-rows', []);
    on('val3-bar', (bar) => bar.replaceChildren());
    on('val3-legend', (legend) => legend.replaceChildren());
  }

  // Quotas are trained at one load point. Running elsewhere is legitimate, but
  // a miss there is partly the load, not the model.
  const trained = t ? t.characterized_k : null;
  const running = live.status && live.status.run ? live.status.run.k
    : live.final && live.final.run ? live.final.run.k : null;
  text('val3-caveat', trained === null || trained === undefined
    ? 'characterized load point unknown'
    : running === null ? `quotas trained at k = ${trained}`
    : String(running) === String(trained) ? `running at the load the quotas were trained at (k = ${trained})`
    : `trained at k = ${trained}, running at k = ${running}: part of every miss is the extra load`);
}

// ------------------------------------------------------------ right column
function renderStatusStrip(live) {
  const d = live.derived;
  const el = $('health-score-value');
  if (!el) return;
  el.textContent = d.health === null || d.health === undefined ? NA : d.health;
  el.style.color = d.health === null || d.health === undefined ? '#e2e8f0'
    : d.health >= 80 ? '#4ade80' : d.health >= 50 ? '#fbbf24' : '#f87171';
  text('system-status-value', d.system_status);
  text('memory-load-value', d.memory_load);
}

function renderKpis(live) {
  const s = live.sample || {};
  const d = live.derived;
  text('kpi-faults', s.faults_per_sec === null || s.faults_per_sec === undefined ? NA : int(s.faults_per_sec));
  text('kpi-faults-req', d.faults_per_req ? `${d.faults_per_req.toFixed(1)} per request` : 'per request: —');
  text('kpi-cpu', s.cpu_pct === null || s.cpu_pct === undefined ? NA : `${s.cpu_pct.toFixed(0)}%`);
  text('kpi-throttle', d.throttled_per_sec === null || d.throttled_per_sec === undefined
    ? 'throttled: —' : `throttled ${d.throttled_per_sec.toFixed(1)}/s`);
  // Headline: the run so far, the figure the summary will report at the end.
  // Underneath: the last interval, which swings with every burst.
  text('kpi-dropped', d.dropped_pct_run === null || d.dropped_pct_run === undefined
    ? NA : pct(d.dropped_pct_run, 2));
  const now = d.dropped_pct === null || d.dropped_pct === undefined ? '—' : pct(d.dropped_pct, 1);
  // k6's failure rate is already a whole-run figure.
  const failed = s.failed_pct === null || s.failed_pct === undefined ? '—' : pct(s.failed_pct);
  text('kpi-failed', `last second ${now} · failed ${failed}`);
  text('kpi-peak', mb(s.peak_rss_mb, 0));
  text('kpi-oom', s.oom_kills ? `OOM kills: ${s.oom_kills}` : 'no OOM kills');

  text('ghost-note', live.ghost
    ? `dashed: ${live.ghost.mode} run, k=${live.ghost.k ?? NA}, seed ${live.ghost.seed ?? NA} ` +
      `(recorded${live.ghost.pinned ? ', pinned from history' : ''})`
    : '');
}

function renderAllocator(live) {
  const body = $('allocator-body');
  if (!body) return;
  body.replaceChildren();
  const a = live.sample && live.sample.allocator;
  if (!a) {
    const p = document.createElement('p');
    p.className = 'col-span-2 text-sm text-slate-500';
    p.textContent = live.status && live.status.mode === 'baseline'
      ? 'V8 baseline: allocations go to Buffer.allocUnsafe and are freed by the garbage collector.'
      : 'Waiting for the allocator…';
    body.appendChild(p);
    return;
  }
  const rows = [
    ['regions opened', int(a.regionsOpened)],
    ['objects reclaimed at scope end', int(a.regionReclaimed)],
    ['unscoped allocations', int(a.unscopedAllocations)],
    ['detach failures', int(a.detachFailures)],
    ['pool committed', mb(a.committedBytes / 1048576, 1)],
    ['budget refusals', int(a.budgetRefusals)],
    ['bump resets', int(a.bumpResets)],
    ['bump reset blocked', int(a.bumpResetBlocked)],
    ['slab exhausted', int(a.slabExhaustedFallbacks)],
    ['oversize fallbacks', int(a.bumpOversizeFallbacks + a.slabOversizeFallbacks)],
  ];
  for (const [k, v] of rows) {
    const row = document.createElement('div');
    row.className = 'flex justify-between border-b border-slate-100 py-1';
    const kEl = document.createElement('span'); kEl.className = 'text-slate-500'; kEl.textContent = k;
    const vEl = document.createElement('span');
    // Detach failures must stay zero: a non-zero value means an escaped buffer
    // could read recycled memory, and the run should not be trusted.
    vEl.className = k === 'detach failures' && a.detachFailures > 0
      ? 'font-bold text-red-600' : 'font-semibold text-slate-800';
    vEl.textContent = v;
    row.append(kEl, vEl);
    body.appendChild(row);
  }
}

// ------------------------------------------------------------------ modals
function setOpen(id, open) {
  const el = $(id);
  if (!el) return;
  el.classList.toggle('is-open', open);
  el.classList.toggle('hidden', !open);
  el.setAttribute('aria-hidden', open ? 'false' : 'true');
}

function openRunForm(live) {
  if (!$('run-modal')) return;
  const defaults = (live.status && live.status.defaults) || { k: '2.0', seed: 2025, minutes: 3 };
  const loads = (live.status && live.status.loads) || ['1.0', '1.5', '2.0', '2.5', '3.0'];
  const select = $('run-k');
  select.replaceChildren();
  for (const k of loads) {
    const opt = document.createElement('option');
    opt.value = k; opt.textContent = `k = ${k}`;
    if (k === String(defaults.k)) opt.selected = true;
    select.appendChild(opt);
  }
  $('run-seed').value = defaults.seed;
  $('run-minutes').value = defaults.minutes;
  $('run-error').classList.add('hidden');
  setOpen('run-modal', true);
}

/** Progress for a mode switch, from the collector's own stage events. */
const stageModal = {
  active: false,
  since: 0,
  open(title) {
    this.active = true;
    this.since = Date.now();
    $('modal-title').textContent = title;
    $('modal-status-text').textContent = 'starting…';
    $('modal-stage-list').replaceChildren();
    $('modal-spinner').classList.remove('hidden');
    $('modal-done-btn').classList.add('hidden');
    setOpen('boost-modal', true);
  },
  render(live) {
    if (!this.active) return;
    const list = $('modal-stage-list');
    list.replaceChildren();
    const mine = live.stages.filter((s) => s.at >= this.since && s.name !== 'k6');
    for (const stage of mine) {
      const li = document.createElement('li');
      const mark = stage.status === 'ready' ? '✓' : stage.status === 'failed' ? '✕' : '…';
      li.className = stage.status === 'failed' ? 'text-red-600' : 'text-slate-600';
      li.textContent = `${mark} ${stage.name}: ${stage.status}${stage.detail ? ` — ${String(stage.detail).slice(0, 120)}` : ''}`;
      list.appendChild(li);
    }
    const last = mine[mine.length - 1];
    if (!last) return;
    if (last.status === 'ready' || last.status === 'failed') {
      $('modal-status-text').textContent = last.status === 'ready'
        ? `${live.status && live.status.mode === 'samm' ? 'SAMM' : 'V8 baseline'} container is ready`
        : 'The switch failed';
      $('modal-spinner').classList.add('hidden');
      $('modal-done-btn').classList.remove('hidden');
    } else {
      $('modal-status-text').textContent = `${last.name}: ${last.status}`;
    }
  },
  close() { this.active = false; setOpen('boost-modal', false); },
};

function renderFinal(live) {
  if (!live.final || live.final._shown) return;
  live.final._shown = true;
  const f = live.final;
  const rows = [
    ['mode', f.mode === 'samm' ? `SAMM${f.run && f.run.warmup ? ' (warmup on)' : ''}` : 'V8 baseline'],
    ['load point', f.run ? `k = ${f.run.k}, seed ${f.run.seed}, ${f.run.minutes} min` : NA],
    ['requests served', int(f.requests)],
    ['throughput', f.throughput_rps === null ? NA : `${f.throughput_rps.toFixed(1)} req/s`],
    ['dropped', `${int(f.dropped)} (${pct(f.dropped_pct)})`],
    ['failed', pct(f.failed_pct)],
    ['end-to-end p95 / p99', `${f.e2e_p95 === null ? NA : f.e2e_p95.toFixed(1)} / ${f.e2e_p99 === null ? NA : f.e2e_p99.toFixed(1)} ms`],
    ['allocation p95 / p99', `${f.alloc_p95 === null ? NA : f.alloc_p95.toFixed(2)} / ${f.alloc_p99 === null ? NA : f.alloc_p99.toFixed(2)} ms`],
    ['peak RSS', mb(f.peak_rss_mb, 1)],
    ['OOM kills', int(f.oom_kills)],
    ['container survived', f.container_survived ? 'yes' : 'no'],
  ];
  const body = $('final-body');
  body.replaceChildren();
  for (const [k, v] of rows) {
    const row = document.createElement('div');
    row.className = 'flex justify-between gap-6 border-b border-slate-100 py-1.5';
    row.innerHTML = `<span class="text-slate-500">${k}</span><span class="font-semibold text-slate-800">${v}</span>`;
    body.appendChild(row);
  }
  setOpen('final-modal', true);
}

/**
 * The container is gone. Shown once per death: the collector asks Docker why,
 * because the cgroup counters vanish with the container.
 */
function renderDeath(live) {
  const d = live.death;
  if (!d || d._shown) return;
  d._shown = true;

  const who = live.status && live.status.mode === 'samm' ? 'SAMM' : 'the V8 baseline';
  const during = d.during_run ? ' in the middle of the run' : '';
  // Only Docker's OOMKilled flag justifies the words "out of memory". A bare
  // exit 137 is SIGKILL, which `docker kill` produces too.
  if (d.oom) {
    $('death-title').textContent = 'Container was killed — out of memory';
    $('death-reason').textContent = `The kernel killed ${who} for exceeding the memory limit${during}.`;
  } else if (d.uncertain) {
    $('death-title').textContent = 'Container was killed';
    $('death-reason').textContent = `${who} was killed with SIGKILL${during}. Docker could not be asked whether it ran out of memory.`;
  } else if (d.sigkill) {
    $('death-title').textContent = 'Container was killed';
    $('death-reason').textContent = `${who} was killed with SIGKILL${during}. Docker does not report this as an out-of-memory kill.`;
  } else {
    $('death-title').textContent = 'Container stopped';
    $('death-reason').textContent = `${who} exited with code ${d.exit_code === null ? 'unknown' : d.exit_code}${during}.`;
  }

  const last = d.last || {};
  const rows = [
    ['Docker reports OOM killed', d.oom_killed === null ? 'could not ask' : d.oom_killed ? 'yes' : 'no'],
    ['cgroup oom_kill counter', (d.last && d.last.oom_kills !== null && d.last.oom_kills !== undefined)
      ? String(d.last.oom_kills) : NA],
    ['exit code', d.exit_code === null ? NA : `${d.exit_code}${d.exit_code === 137 ? ' (SIGKILL)' : ''}`],
    ['last RSS before it died', mb(last.rss_mb, 1)],
    ['peak RSS', mb(last.peak_rss_mb, 1)],
    ['limit', mb(last.limit_mb, 0)],
    ['during a run', d.during_run ? 'yes' : 'no'],
  ];
  if (d.run) rows.push(['run', `k = ${d.run.k}, seed ${d.run.seed}, ${d.run.minutes} min`]);

  const body = $('death-body');
  body.replaceChildren();
  for (const [k, v] of rows) {
    const row = document.createElement('div');
    row.className = 'flex justify-between gap-6 border-b border-slate-100 py-1.5';
    row.innerHTML = `<span class="text-slate-500">${k}</span><span class="font-semibold text-slate-800">${v}</span>`;
    body.appendChild(row);
  }
  setOpen('death-modal', true);
}

/** Past runs on this machine, newest first. Clicking one pins it as the reference line. */
function renderHistory(live) {
  const body = $('history-body');
  body.replaceChildren();
  if (!live.history.length) {
    const empty = document.createElement('p');
    empty.className = 'samm-empty';
    empty.textContent = 'No completed runs yet. Finish a run and it will be archived here.';
    body.appendChild(empty);
    setOpen('history-modal', true);
    return;
  }

  const table = document.createElement('table');
  table.innerHTML = `<thead><tr>
    <th>when</th><th>mode</th><th>k</th><th>seed</th><th>min</th>
    <th>requests</th><th>dropped</th><th>peak RSS</th><th>e2e p99</th><th>alloc p99</th><th>outcome</th>
  </tr></thead>`;
  const tbody = document.createElement('tbody');

  // A run archived before the summary existed is reconstructed from its own
  // samples, so most columns are genuinely unknown and stay as dashes.
  const or = (v, fmt = (x) => x) => (v === null || v === undefined ? NA : fmt(v));

  for (const run of live.history) {
    const tr = document.createElement('tr');
    const when = run.finished_at ? new Date(run.finished_at).toLocaleString() : NA;
    const died = run.container_survived === false;
    tr.className = live.ghost && live.ghost.name === run.recording ? 'is-reference' : '';
    tr.innerHTML = `
      <td>${when}${run.source === 'recording' ? ' <span class="text-slate-400">(from recording)</span>' : ''}</td>
      <td>${run.mode === 'samm' ? 'SAMM' : 'V8 baseline'}${run.run && run.run.warmup ? ' <span class="text-amber-700">(warm)</span>' : ''}</td>
      <td>${or(run.run && run.run.k)}</td>
      <td>${or(run.run && run.run.seed)}</td>
      <td>${or(run.run && run.run.minutes)}</td>
      <td>${or(run.requests, int)}</td>
      <td>${or(run.dropped_pct, (v) => pct(v))}</td>
      <td>${or(run.peak_rss_mb, (v) => mb(v, 0))}</td>
      <td>${or(run.e2e_p99, (v) => `${v.toFixed(0)} ms`)}</td>
      <td>${or(run.alloc_p99, (v) => `${v.toFixed(1)} ms`)}</td>
      <td class="${died ? 'samm-dead' : ''}">${run.container_survived === null || run.container_survived === undefined
        ? NA : died ? 'container died' : 'completed'}</td>`;
    tr.title = run.recording ? 'Use this run as the reference line' : 'No recording kept for this run';
    if (run.recording) {
      tr.addEventListener('click', async () => {
        const ok = await Live.useAsReference(run.recording);
        if (ok) setOpen('history-modal', false);
      });
    }
    tbody.appendChild(tr);
  }
  table.appendChild(tbody);
  body.appendChild(table);
  setOpen('history-modal', true);
}

function renderHelp(live) {
  const parts = live.derived.health_parts || {};
  const body = $('help-body');
  body.innerHTML = `
    <h3>Health score</h3>
    <p>A presentation summary, not a measurement. It starts at 100 and subtracts
    penalties from four numbers this study already reports. An OOM kill is a zero.</p>
    <ul>
      ${Live.HEALTH.map((h) => `<li><b>${h.weight} pts</b> — ${h.text}
        <span class="text-slate-400">(now: −${(parts[h.key] || 0).toFixed(1)})</span></li>`).join('')}
    </ul>
    <h3>Why latency says p95</h3>
    <p>k6's live REST API exposes avg, min, med, max, p90 and p95 only. p99 exists
    in the end-of-run summary, and that is where the run-complete dialog reads it from.</p>
    <h3>The dashed line</h3>
    <p>Each machine runs one allocator, so only one line is live. The dashed line is
    the other mode's most recent recorded run, replayed against the same clock.</p>
    <h3>Arena sizes</h3>
    <p>Floor and span are capacity from the compiled routing table. The allocator
    reports committed bytes for the pool as a whole, not per arena, so the bar under
    the arena cards is the pool total.</p>
    <h3>Fallback rate</h3>
    <p>Allocations no arena could serve, over all allocations SAMM saw
    (reclaimed + unmanaged + fallbacks) — the same formula the benchmark scripts use.</p>`;
  setOpen('help-modal', true);
}

// ------------------------------------------------------------------ render
function render(live) {
  renderHeader(live);
  renderHeadline(live);
  renderDensity(live);
  renderArenas(live);
  renderMlTiles(live);
  renderStatusStrip(live);
  renderHero(live);
  renderValidation(live);
  renderKpis(live);
  renderAllocator(live);
  stageModal.render(live);
  renderFinal(live);
  renderDeath(live);
  Charts.render(live);
}

// ----------------------------------------------------------------- wiring
window.addEventListener('DOMContentLoaded', () => {
  Live.subscribe(render);

  // click(id, handler) instead of $(id).addEventListener: a control that only
  // exists on one of the two layouts is skipped, not a TypeError.
  const click = (id, handler) => on(id, (el) => el.addEventListener('click', handler));

  click('test-btn', async () => {
    if (Live.status && Live.status.running) {
      await Live.post('/stop');
      await Live.refreshStatus();
      return;
    }
    openRunForm(Live);
  });

  click('run-cancel', () => setOpen('run-modal', false));

  on('run-form', (form) => form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const body = {
      k: $('run-k').value,
      seed: Number($('run-seed').value),
      minutes: Number($('run-minutes').value),
    };
    $('run-start').disabled = true;
    const res = await Live.post('/run', body);
    $('run-start').disabled = false;
    if (!res.ok) {
      const err = $('run-error');
      err.textContent = res.data.error || `the collector refused the run (${res.status})`;
      err.classList.remove('hidden');
      return;
    }
    setOpen('run-modal', false);
    Live.resetSeries();
    await Live.refreshStatus();
  }));

  click('boost-btn', async () => {
    const toBaseline = Live.status && Live.status.mode === 'samm';
    const target = toBaseline ? 'baseline' : 'samm';
    stageModal.open(toBaseline ? 'Switching to the V8 baseline' : 'Boosting with SAMM');
    const res = await Live.post('/mode', { mode: target });
    if (!res.ok) {
      text('modal-status-text', res.data.error || 'the collector refused the switch');
      on('modal-spinner', (el) => el.classList.add('hidden'));
      on('modal-done-btn', (el) => el.classList.remove('hidden'));
      return;
    }
    Live.resetSeries();
    await Live.refreshStatus();
  });

  click('warmup-btn', async () => {
    const next = !(Live.status && Live.status.warmup);
    stageModal.open(next ? 'Restarting SAMM with warmup on' : 'Restarting SAMM with warmup off');
    const res = await Live.post('/warmup', { enabled: next });
    if (!res.ok) {
      text('modal-status-text', res.data.error || 'the collector refused the change');
      on('modal-spinner', (el) => el.classList.add('hidden'));
      on('modal-done-btn', (el) => el.classList.remove('hidden'));
      return;
    }
    Live.resetSeries();
    await Live.refreshStatus();
  });

  click('modal-done-btn', async () => {
    stageModal.close();
    await Live.refreshStatus();
    await Live.loadGhost();
  });

  click('final-close', () => setOpen('final-modal', false));
  click('death-close', () => setOpen('death-modal', false));
  click('history-btn', async () => {
    await Live.refreshHistory();
    renderHistory(Live);
  });
  click('history-close', () => setOpen('history-modal', false));
  click('help-btn', () => renderHelp(Live));
  click('health-info', () => renderHelp(Live));
  click('help-close', () => setOpen('help-modal', false));

  document.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return;
    for (const id of ['run-modal', 'final-modal', 'help-modal', 'death-modal', 'history-modal']) setOpen(id, false);
    const done = $('modal-done-btn');
    if (stageModal.active && done && !done.classList.contains('hidden')) stageModal.close();
  });

  // The run pill counts seconds, so tick even when no sample arrives.
  setInterval(() => renderHeader(Live), 1000);

  Live.start();
});
