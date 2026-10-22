'use strict';

/**
 * Optional reachability oracle: ground truth for Layer 1.
 *
 * OFF unless SAMM_ORACLE=true. Layer 1 labels each call-site request-scoped
 * (managed) or escaping (System) from the profiler's overhang, which is the time
 * from request end to FINALIZATION -- and finalization moves with GC scheduling
 * as well as with the object's role. This measures the role directly: it keeps
 * a WeakRef to every Buffer allocateBuffer() hands out, and every
 * SAMM_ORACLE_GC_MS it forces a full, synchronous GC and asks each WeakRef
 * whether its Buffer survived. A Buffer still alive at a forced GC after its
 * request ended was reachable then, which is exactly what region-per-request
 * reclamation assumes never happens for a managed call-site.
 *
 * Each object's death is bounded between two known times: the last forced GC
 * that found it alive and the first that found it dead. Reachability is
 * monotone (an unreachable object never comes back), so a coarser GC cadence
 * can be replayed offline from the GC times in gcs.csv.
 *
 * Writes, under SAMM_ORACLE_DIR (one run per directory, truncated at start):
 *   objects.csv  one row per tracked Buffer. Times are ms since the oracle
 *                started. first_dead_ms is empty if the Buffer was still alive
 *                at shutdown; request_end_ms is empty if its request never
 *                ended.
 *   gcs.csv      one row per forced GC.
 *   meta.json    settings, totals and the workload fingerprint, at exit.
 *
 * Run it on the baseline image with the profiler off. Forced full GCs every
 * few milliseconds take a large share of the CPU and stretch every timing, so
 * an oracle run measures reachability and nothing else -- never latency,
 * throughput or memory.
 */

const fs = require('fs');
const path = require('path');

const ENABLED = process.env.SAMM_ORACLE === 'true';
const GC_INTERVAL_MS = Number(process.env.SAMM_ORACLE_GC_MS) || 10;
const OUTPUT_DIR = process.env.SAMM_ORACLE_DIR
  || path.join(__dirname, '..', '..', 'datasets', 'oracle');

let active = false;
let gc = null;
let t0 = 0;
let startedAt = null;
let objectsFd = -1;
let gcsFd = -1;
let nextRequestId = 1;

// Buffers not yet seen dead. Each holds only a WeakRef, never the Buffer.
let pending = [];

const totals = { requests: 0, tracked: 0, dead: 0, censored: 0, gcs: 0, gcTotalMs: 0, gcMaxMs: 0 };

const now = () => performance.now() - t0;
const fmt = (n) => (n === null ? '' : n.toFixed(3));

function row(o, firstDeadMs) {
  const r = o.request;
  return `${o.site},${o.bytes},${r ? r.id : ''},${fmt(o.allocMs)},${r ? fmt(r.endMs) : ''},`
    + `${fmt(o.lastAliveMs)},${fmt(firstDeadMs)}\n`;
}

// Called from regionMiddleware: the request ends on the same events that
// close a SAMM region, so "after its request" means after its region.
function beginRequest(req, res) {
  if (!active) return;
  const request = { id: nextRequestId++, endMs: null };
  totals.requests += 1;
  req.oracleRequest = request;
  const end = () => { if (request.endMs === null) request.endMs = now(); };
  res.on('finish', end);
  res.on('close', end);
}

function track(buffer, callSiteId, req) {
  if (!active || !callSiteId) return;
  pending.push({
    ref: new WeakRef(buffer),
    site: callSiteId,
    bytes: buffer.length,
    request: (req && req.oracleRequest) || null,
    allocMs: now(),
    lastAliveMs: null,
  });
  totals.tracked += 1;
}

function collect() {
  // Liveness is as of the call: gc() is synchronous, so no JS runs between
  // here and the WeakRef checks below.
  const at = now();
  gc();
  const gcMs = now() - at;

  let rows = '';
  let died = 0;
  const alive = [];
  for (const o of pending) {
    if (o.ref.deref() === undefined) {
      rows += row(o, at);
      died += 1;
    } else {
      o.lastAliveMs = at;
      alive.push(o);
    }
  }
  const checked = pending.length;
  pending = alive;

  if (rows) fs.writeSync(objectsFd, rows);
  fs.writeSync(gcsFd, `${fmt(at)},${fmt(gcMs)},${checked},${died}\n`);
  totals.dead += died;
  totals.gcs += 1;
  totals.gcTotalMs += gcMs;
  if (gcMs > totals.gcMaxMs) totals.gcMaxMs = gcMs;
}

// A GC is only informative once some tracked Buffer's request has ended (or
// it had none): one that dies mid-request is request-scoped whenever it is
// found dead.
const settled = (o) => o.request === null || o.request.endMs !== null;

function tick() {
  if (pending.some(settled)) collect();
  setTimeout(tick, GC_INTERVAL_MS).unref();
}

function finish() {
  if (!active) return;
  active = false;
  collect();
  if (pending.length) fs.writeSync(objectsFd, pending.map((o) => row(o, null)).join(''));
  totals.censored = pending.length;
  fs.closeSync(objectsFd);
  fs.closeSync(gcsFd);

  const { workloadFingerprint } = require('./_workload');
  const round = (n) => Number(n.toFixed(3));
  fs.writeFileSync(path.join(OUTPUT_DIR, 'meta.json'), `${JSON.stringify({
    started: startedAt,
    ended: new Date().toISOString(),
    durationMs: round(now()),
    node: process.version,
    gcIntervalMs: GC_INTERVAL_MS,
    totals: { ...totals, gcTotalMs: round(totals.gcTotalMs), gcMaxMs: round(totals.gcMaxMs) },
    profilerEnabled: process.env.SHADOW_PROFILER_ENABLED === 'true',
    ldPreload: process.env.LD_PRELOAD || '',
    workload: workloadFingerprint(),
  }, null, 2)}\n`);
  console.log(`[oracle] ${totals.tracked} Buffers tracked over ${totals.gcs} forced GCs: `
    + `${totals.dead} seen dead, ${totals.censored} alive at shutdown -> ${OUTPUT_DIR}`);
}

function start() {
  if (!ENABLED) return false;

  // The same gc() --expose-gc gives, obtained at runtime so the image's
  // command line stays the one every other run uses.
  require('v8').setFlagsFromString('--expose-gc');
  gc = require('vm').runInNewContext('gc');

  fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  objectsFd = fs.openSync(path.join(OUTPUT_DIR, 'objects.csv'), 'w');
  gcsFd = fs.openSync(path.join(OUTPUT_DIR, 'gcs.csv'), 'w');
  fs.writeSync(objectsFd, 'call_site,bytes,request_id,alloc_ms,request_end_ms,last_alive_ms,first_dead_ms\n');
  fs.writeSync(gcsFd, 'gc_ms,duration_ms,checked,died\n');

  t0 = performance.now();
  startedAt = new Date().toISOString();
  active = true;
  setTimeout(tick, GC_INTERVAL_MS).unref();
  // Synchronous on purpose: server.js exits with process.exit(), which would
  // drop an asynchronous write of the censored rows.
  process.on('exit', finish);
  return true;
}

module.exports = { enabled: ENABLED, start, beginRequest, track, outputDir: OUTPUT_DIR, gcIntervalMs: GC_INTERVAL_MS };
