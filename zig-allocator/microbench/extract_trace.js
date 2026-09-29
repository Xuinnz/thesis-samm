#!/usr/bin/env node
'use strict';
/**
 * Turns the characterization trace into a replayable event stream.
 *
 * The microbenchmark does not invent a workload. It replays the one the routing
 * table was trained on: the real per-request allocation sequences from
 * training_trace.csv, opened and closed at the real request boundaries from
 * scope_trace.csv. The replay is compressed in time, but ordering, sizes,
 * per-request overlap and lifetimes are exactly what the server saw.
 *
 * Events (one per row of the output arrays, in trace-time order):
 *   OPEN  scope        a request begins                 (samm: region open)
 *   ALLOC scope site n  the handler allocates n bytes
 *   CLOSE scope        the request ends                 (samm: region close;
 *                                                        v8: references dropped)
 *   FREE  seq          an escaping allocation is dropped (System call-sites,
 *                                                        at their finalization)
 *
 * Which call-sites escape is read from the ML's own policy assignment, not
 * decided here.
 *
 * Output, per trace:   <out>/<name>/{ops.u8, arg.u32, size.u32, site.u8, meta.json}
 *   mix       every call-site, as served
 *   <site>    one call-site alone, with only the requests that used it
 *
 * Usage: node extract_trace.js <out-dir> [scopes=30000] [skip-fraction=0.2]
 */

const fs = require('fs');
const path = require('path');
const readline = require('readline');

const REPO = path.resolve(__dirname, '..', '..');
const RAW = path.join(REPO, 'datasets', 'shadow-telemetry', 'raw');
const POLICY_CSV = path.join(REPO, 'datasets', 'shadow-telemetry', 'intermediate',
  'ml-refinery', 'call_site_policy_assignment.csv');

const OUT = path.resolve(process.argv[2] || path.join(__dirname, '.out', 'traces'));
const N_SCOPES = Number(process.argv[3] || 30000);
const SKIP = Number(process.argv[4] || 0.2);

const OP = { OPEN: 0, ALLOC: 1, CLOSE: 2, FREE: 3 };
// Tie-break for events at the same timestamp: a request must be open before it
// allocates, and allocate before it closes.
const RANK = [0, 1, 2, 3];

// The call-site identifiers the routes pass to allocateBuffer(). Resolved to the
// trace's hashes below with the profiler's own FNV-1a -- so a renamed route
// fails loudly here instead of silently replaying under the wrong name.
const CANDIDATE_SITES = [
  'batch.js:batchRoute', 'cache.js:cacheRoute', 'fetch.js:fetchRoute',
  'process.js:processRoute', 'ingest.js:ingestRoute', 'aggregate.js:aggregateRoute',
];

// Byte-identical to Fnv1aHash() in profiler/src/profiler.cc, including its
// non-canonical offset basis.
function fnv1a(s) {
  let h = 1469598103934665603n;
  for (const b of Buffer.from(s, 'utf8')) {
    h ^= BigInt(b);
    h = (h * 1099511628211n) & 0xffffffffffffffffn;
  }
  return h.toString();
}

async function* csvRows(file) {
  const rl = readline.createInterface({ input: fs.createReadStream(file), crlfDelay: Infinity });
  let header = null;
  for await (const line of rl) {
    if (!line) continue;
    if (header === null) { header = line.split(','); continue; }
    yield line.split(',');
  }
}

async function main() {
  // ---------------------------------------------------------- policies
  const escaping = new Map();   // hash -> true when the ML routed it to System
  {
    const lines = fs.readFileSync(POLICY_CSV, 'utf8').trim().split('\n');
    const cols = lines[0].split(',');
    const hi = cols.indexOf('call_site_hash');
    const pi = cols.indexOf('allocation_policy');
    for (const l of lines.slice(1)) {
      const c = l.split(',');
      escaping.set(c[hi], c[pi] === 'System');
    }
  }
  const nameOf = new Map(CANDIDATE_SITES.map((s) => [fnv1a(s), s]));

  // ---------------------------------------------------------- scope window
  const scopes = [];
  for await (const [id, start, end] of csvRows(path.join(RAW, 'scope_trace.csv'))) {
    const s = Number(start), e = Number(end);
    if (Number.isFinite(s) && Number.isFinite(e)) scopes.push({ id: Number(id), s, e });
  }
  scopes.sort((a, b) => a.s - b.s);
  // Skip the ramp-up at the start of the characterization, then take a
  // contiguous run of requests.
  const first = Math.floor(scopes.length * SKIP);
  const window = scopes.slice(first, first + N_SCOPES);
  const scopeIndex = new Map(window.map((sc, i) => [sc.id, i]));
  const windowEnd = window.reduce((m, sc) => Math.max(m, sc.e), 0);

  // ---------------------------------------------------------- allocations
  const allocs = [];          // {t, scope, site, size, free}
  const siteIds = [];         // index -> name
  const siteOf = new Map();   // hash -> index
  let clamped = 0;
  for await (const [hash, size, at, fin, sid] of
    csvRows(path.join(RAW, 'training_trace.csv'))) {
    const si = scopeIndex.get(Number(sid));
    if (si === undefined) continue;
    if (!siteOf.has(hash)) {
      const name = nameOf.get(hash);
      if (!name) throw new Error(`trace hash ${hash} matches no known call-site`);
      if (!escaping.has(hash)) throw new Error(`no policy for ${name} (${hash})`);
      siteOf.set(hash, siteIds.length);
      siteIds.push(name);
    }
    const sc = window[si];
    let t = Number(at);
    // An allocation stamped a hair outside its own request (clock
    // granularity) is placed at the boundary, never outside it.
    if (t < sc.s) { t = sc.s; clamped++; }
    if (t > sc.e) { t = sc.e; clamped++; }
    const f = Number(fin);
    allocs.push({
      t, scope: si, site: siteOf.get(hash), size: Number(size),
      // Escaping objects live until the GC finalized them (right-censored
      // ones until the end of the window); everything else ends with its
      // request.
      free: escaping.get(hash) ? (Number.isFinite(f) ? Math.min(f, windowEnd) : windowEnd) : null,
    });
  }
  const escapingSite = siteIds.map((n) => escaping.get(fnv1a(n)));

  fs.mkdirSync(OUT, { recursive: true });
  const summary = [];
  write('mix', () => true);
  siteIds.forEach((name, i) => write(name.split('.')[0], (a) => a.site === i));

  console.log(`window: ${window.length} requests (skipped first ${(SKIP * 100).toFixed(0)}%), ` +
    `${((windowEnd - window[0].s) / 1000).toFixed(1)} s of trace, ${clamped} timestamps clamped`);
  console.table(summary);

  function write(name, keep) {
    const mine = allocs.filter(keep);
    const used = new Set(mine.map((a) => a.scope));
    const ev = [];   // [t, op, arg, size, site]
    for (const si of used) {
      ev.push([window[si].s, OP.OPEN, si, 0, 255]);
      ev.push([window[si].e, OP.CLOSE, si, 0, 255]);
    }
    mine.forEach((a, seq) => {
      ev.push([a.t, OP.ALLOC, a.scope, a.size, a.site, seq]);
      if (a.free !== null) ev.push([Math.max(a.free, a.t), OP.FREE, seq, 0, 255]);
    });
    // Stable on equal (time, rank): allocations keep their trace order.
    ev.sort((x, y) => (x[0] - y[0]) || (RANK[x[1]] - RANK[y[1]]) ||
      ((x[5] ?? 0) - (y[5] ?? 0)));

    // The replay numbers allocations in the order it EXECUTES them -- time
    // order -- while `seq` above is CSV row order, which the profiler writes at
    // finalization. A FREE must name the replay's number, or it frees the
    // wrong slot and the escaping buffer it meant leaks for the whole run.
    const ordinal = new Uint32Array(mine.length);
    let next = 0;
    for (const e of ev) if (e[1] === OP.ALLOC) ordinal[e[5]] = next++;

    const n = ev.length;
    const ops = new Uint8Array(n), arg = new Uint32Array(n), size = new Uint32Array(n),
      site = new Uint8Array(n);
    // Walk the stream once exactly as the replay will, tracking live bytes. A
    // leak or a bad reference fails here rather than as an OOM mid-benchmark.
    const liveBytes = new Float64Array(mine.length);   // by ordinal, escaping only
    const scopeBytes = new Map();
    let live = 0, maxLive = 0, bytes = 0, liveNow = 0, peakLive = 0, emitted = 0;
    ev.forEach((e, i) => {
      ops[i] = e[1]; size[i] = e[3]; site[i] = e[4];
      arg[i] = e[1] === OP.FREE ? ordinal[e[2]] : e[2];
      switch (e[1]) {
        case OP.OPEN: maxLive = Math.max(maxLive, ++live); scopeBytes.set(e[2], 0); break;
        case OP.CLOSE: live--; liveNow -= scopeBytes.get(e[2]); scopeBytes.delete(e[2]); break;
        case OP.ALLOC:
          bytes += e[3]; liveNow += e[3];
          if (escapingSite[e[4]]) liveBytes[emitted] = e[3];
          else scopeBytes.set(e[2], scopeBytes.get(e[2]) + e[3]);
          emitted++;
          break;
        case OP.FREE: {
          const o = arg[i];
          if (o >= emitted || liveBytes[o] === 0) throw new Error(`${name}: FREE of allocation ${o} that is not live`);
          liveNow -= liveBytes[o]; liveBytes[o] = 0;
          break;
        }
      }
      peakLive = Math.max(peakLive, liveNow);
    });
    if (Math.abs(liveNow) > 0.5) throw new Error(`${name}: ${liveNow} bytes still live at the end of the trace`);

    const dir = path.join(OUT, name);
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'ops.u8'), ops);
    fs.writeFileSync(path.join(dir, 'arg.u32'), Buffer.from(arg.buffer));
    fs.writeFileSync(path.join(dir, 'size.u32'), Buffer.from(size.buffer));
    fs.writeFileSync(path.join(dir, 'site.u8'), site);
    const meta = {
      name, sites: siteIds, escaping: escapingSite,
      n_events: n, n_allocs: mine.length, n_scopes: window.length,
      requests_used: used.size, max_concurrent_requests: maxLive, total_bytes: bytes,
      peak_live_bytes: peakLive,
    };
    fs.writeFileSync(path.join(dir, 'meta.json'), JSON.stringify(meta, null, 2));
    summary.push({
      trace: name, requests: used.size, allocations: mine.length,
      'allocs/request': +(mine.length / Math.max(used.size, 1)).toFixed(1),
      'mean size (KB)': +(bytes / Math.max(mine.length, 1) / 1024).toFixed(1),
      'max concurrent': maxLive,
      'peak live (MB)': +(peakLive / 1048576).toFixed(1),
    });
  }
}

main().catch((err) => { console.error(err); process.exit(1); });
