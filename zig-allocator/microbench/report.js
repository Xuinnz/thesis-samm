#!/usr/bin/env node
'use strict';
/**
 * Summarises results/*.jsonl from run.sh. Reads only.
 * The first two tables are MEDIANS across measured trials; the next two give
 * mean ± sample standard deviation for the same cells, and any cell with 10 or
 * more trials also gets its full spread (median, min-max, CV, 95% CI).
 *
 * Usage: node report.js [results-dir]
 */
const fs = require('fs');
const path = require('path');

const DIR = path.resolve(process.argv[2] || path.join(__dirname, 'results'));
const TRACES = ['mix', 'batch', 'cache', 'ingest', 'fetch', 'process', 'aggregate'];
// aggregate.js is routed to System, so SAMM never serves it: the engine row is the
// routing lookup + malloc, and the N-API row is the bridge round trip + Buffer.allocUnsafe
// -- the same allocation as the baseline rows. Marked so it is not read as a SAMM result.
const HEAD = { aggregate: 'aggregate*' };
const FOOTNOTE = '* aggregate is routed to System: SAMM declines it, so both SAMM rows measure the decline plus\n' +
  '  the fallback (engine: malloc; N-API: Buffer.allocUnsafe), not a SAMM allocation. Their gap to the\n' +
  '  baseline rows is the cost of declining plus noise.';
const ROWS = [
  ['engine-jemalloc', 'SAMM engine, no bridge'],
  ['samm-jemalloc', 'SAMM via N-API (server path)'],
  ['v8-jemalloc', 'V8 allocUnsafe on jemalloc'],
  ['v8-glibc', 'V8 allocUnsafe on glibc'],
  ['malloc-jemalloc', 'jemalloc, no V8'],
  ['malloc-glibc', 'glibc, no V8'],
];

const runs = {};
for (const f of fs.readdirSync(DIR).filter((f) => f.endsWith('.jsonl'))) {
  const label = f.replace(/\.jsonl$/, '');
  for (const line of fs.readFileSync(path.join(DIR, f), 'utf8').split('\n')) {
    if (!line.trim()) continue;
    const r = JSON.parse(line);
    const key = `${label}|${r.trace}|${r.touch ? 1 : 0}`;
    (runs[key] ||= []).push(r);
  }
}

const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};
const get = (label, trace, touch, field = 'ns_per_alloc') => {
  const rs = runs[`${label}|${trace}|${touch}`];
  return rs ? median(rs.map((r) => r[field])) : null;
};
const spread = (label, trace, touch) => {
  const rs = runs[`${label}|${trace}|${touch}`];
  if (!rs) return null;
  const v = rs.map((r) => r.ns_per_alloc);
  return (Math.max(...v) - Math.min(...v)) / median(v);
};
const mean = (xs) => xs.reduce((a, b) => a + b, 0) / xs.length;
// Sample standard deviation (n - 1).
const sd = (xs) => (xs.length < 2 ? 0 : Math.sqrt(xs.reduce((a, x) => a + (x - mean(xs)) ** 2, 0) / (xs.length - 1)));
const values = (label, trace, touch) => {
  const rs = runs[`${label}|${trace}|${touch}`];
  return rs ? rs.map((r) => r.ns_per_alloc) : null;
};
const fmt = (v) => (v === null ? '—' : v >= 100 ? v.toFixed(0) : v.toFixed(1));
const pad = (s, n) => String(s).padStart(n);

function table(touch) {
  const title = touch
    ? 'ns per allocation, WITH one write per 4 KB page (as writeWholeBuffer)'
    : 'ns per allocation, allocation + release only (no memory touched)';
  console.log(`\n${title}`);
  console.log(`${''.padEnd(32)}${TRACES.map((t) => pad(HEAD[t] || t, 11)).join('')}`);
  for (const [label, name] of ROWS) {
    console.log(`${name.padEnd(32)}${TRACES.map((t) => pad(fmt(get(label, t, touch)), 11)).join('')}`);
  }
  let worst = 0;
  for (const [label] of ROWS) for (const t of TRACES) worst = Math.max(worst, spread(label, t, touch) || 0);
  console.log(`(max trial-to-trial spread in this table: ${(worst * 100).toFixed(0)}% of median)`);
  console.log(FOOTNOTE);
}

function meanTable(touch) {
  console.log(`\nmean ± SD, ns per allocation, ${touch ? 'WITH page writes' : 'no memory touched'} (n = trials in that cell)`);
  console.log(`${''.padEnd(32)}${TRACES.map((t) => pad(HEAD[t] || t, 17)).join('')}`);
  for (const [label, name] of ROWS) {
    console.log(`${name.padEnd(32)}${TRACES.map((t) => {
      const v = values(label, t, touch);
      return pad(v ? `${fmt(mean(v))}±${fmt(sd(v))} n${v.length}` : '—', 17);
    }).join('')}`);
  }
  console.log(FOOTNOTE);
}

// Cells measured with many trials, where the spread itself is the result.
function distributions() {
  const rows = [];
  for (const [label, name] of ROWS) for (const t of TRACES) for (const touch of [0, 1]) {
    const v = values(label, t, touch);
    if (!v || v.length < 10) continue;
    const m = mean(v), s = sd(v);
    rows.push({ cell: `${name} | ${HEAD[t] || t} | ${touch ? 'touch' : 'no touch'}`, n: v.length,
      mean: fmt(m), sd: fmt(s), median: fmt(median(v)), min: fmt(Math.min(...v)), max: fmt(Math.max(...v)),
      'CV %': (100 * s / m).toFixed(0), '95% CI of mean': `${fmt(m - 1.96 * s / Math.sqrt(v.length))}–${fmt(m + 1.96 * s / Math.sqrt(v.length))}` });
  }
  if (!rows.length) return;
  console.log('\ncells with 10+ trials: full spread (ns per allocation)');
  for (const r of rows) {
    console.log(`  ${r.cell}`);
    console.log(`    n ${r.n}   mean ${r.mean} ± ${r.sd} (CV ${r['CV %']}%)   median ${r.median}   min–max ${r.min}–${r.max}   95% CI of mean ${r['95% CI of mean']}`);
  }
}

function breakdown(trace) {
  const eng = get('engine-jemalloc', trace, 0);
  const sam = get('samm-jemalloc', trace, 0);
  const v8 = get('v8-jemalloc', trace, 0);
  const bridge = runs['bridge-jemalloc|null|0'] ? median(runs['bridge-jemalloc|null|0'].map((r) => r.ns_per_call)) : null;
  const allocs = get('samm-jemalloc', trace, 0, 'allocs');
  const perAlloc = (ms) => (ms === null ? null : (ms * 1e6) / allocs);
  console.log(`\n${trace}: where one allocation's time goes (no touch, median)`);
  const row = (k, v, note = '') => console.log(`  ${k.padEnd(44)}${pad(fmt(v), 8)} ns  ${note}`);
  row('SAMM engine alone (alloc + release)', eng);
  row('one bridge round trip, no memory work', bridge);
  row('SAMM through the bridge, total', sam);
  row('  of which request close (region + detach)', get('samm-jemalloc', trace, 0, 'close_ns_per_alloc'));
  row('  of which GC pauses', perAlloc(get('samm-jemalloc', trace, 0, 'gc_ms')),
    `(${fmt(get('samm-jemalloc', trace, 0, 'gc_count'))} GCs)`);
  row('  bridge + V8 object overhead (total - engine)', sam === null ? null : sam - eng);
  row('V8 allocUnsafe on jemalloc, total', v8);
  row('  of which GC pauses', perAlloc(get('v8-jemalloc', trace, 0, 'gc_ms')),
    `(${fmt(get('v8-jemalloc', trace, 0, 'gc_count'))} GCs)`);
  const fb = get('samm-jemalloc', trace, 0, 'fallbacks');
  console.log(`  SAMM capacity fallbacks per trial: ${fmt(fb)} of ${allocs} allocations; ` +
    `detach failures: ${fmt(get('samm-jemalloc', trace, 0, 'detach_failures'))}`);
}

console.log(`results: ${DIR}`);
table(0);
table(1);
meanTable(0);
meanTable(1);
distributions();
breakdown('batch');
breakdown('mix');
