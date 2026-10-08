#!/usr/bin/env node
'use strict';
/**
 * Replays a trace through the SERVER'S OWN allocation path.
 *
 * Calls allocateBuffer() from server/routes/_alloc-utils.js -- the function every
 * route uses -- so what is timed is exactly what a request pays:
 *
 *   SAMM_ALLOCATOR_ENABLED=true   samm.allocate() across the Node-API bridge,
 *                                 falling back to Buffer.allocUnsafe() on null;
 *                                 regions opened/closed around each request.
 *   (unset)                       Buffer.allocUnsafe(), references dropped at
 *                                 request end and freed whenever V8 collects.
 *
 * Same replay loop, same event stream as engine_bench.zig; only the allocator
 * behind allocateBuffer() changes.
 *
 * Extra mode `bridge`: a tight loop of samm.allocate() on a System call-site,
 * which crosses the bridge, reads its arguments, gets `.none` from the routing
 * table and returns null -- the fixed cost of one round trip with no memory
 * work at all.
 *
 * Usage: node --expose-gc js_bench.js <trace-dir> <samm|v8|bridge> <trials> <touch 0|1> [warmup=1]
 * Env:   SAMM_APP_ROOT  directory containing server/ and zig-allocator/ (default: repo)
 *        BENCH_MALLOC   label for the C allocator underneath (glibc|jemalloc)
 */

const fs = require('fs');
const path = require('path');
const { PerformanceObserver } = require('perf_hooks');

const [dir, layer, trialsArg, touchArg, warmupArg] = process.argv.slice(2);
const TRIALS = Number(trialsArg || 5);
const TOUCH = touchArg === '1';
const WARMUP = Number(warmupArg ?? 1);
const APP = process.env.SAMM_APP_ROOT || path.resolve(__dirname, '..', '..');
const MALLOC = process.env.BENCH_MALLOC || 'glibc';

const wantSamm = layer === 'samm' || layer === 'bridge';
if (wantSamm !== (process.env.SAMM_ALLOCATOR_ENABLED === 'true')) {
  throw new Error(`layer ${layer} requires SAMM_ALLOCATOR_ENABLED=${wantSamm}`);
}

const { allocateBuffer, writeWholeBuffer } = require(path.join(APP, 'server', 'routes', '_alloc-utils.js'));
const samm = wantSamm ? require(path.join(APP, 'zig-allocator')) : null;

const OPEN = 0, ALLOC = 1, CLOSE = 2, FREE = 3;
// Yield to the event loop every this many events, so V8's posted GC tasks get
// to run as they would between requests. Same points for both layers.
const YIELD_EVERY = 1024;
// Small traces (one allocation per request) finish in milliseconds, too short
// to time reliably. Each trial replays the trace enough times to cover at least
// this many events; the pass count follows from the trace, not a per-trace knob.
const MIN_EVENTS = 1_000_000;

let gcMs = 0, gcCount = 0;
new PerformanceObserver((list) => {
  for (const e of list.getEntries()) { gcMs += e.duration; gcCount++; }
}).observe({ entryTypes: ['gc'] });

const tick = () => new Promise((r) => setImmediate(r));

function load(d) {
  const meta = JSON.parse(fs.readFileSync(path.join(d, 'meta.json'), 'utf8'));
  const u32 = (f) => { const b = fs.readFileSync(path.join(d, f)); return new Uint32Array(b.buffer, b.byteOffset, b.length / 4); };
  return {
    meta,
    ops: new Uint8Array(fs.readFileSync(path.join(d, 'ops.u8'))),
    arg: u32('arg.u32'),
    size: u32('size.u32'),
    site: new Uint8Array(fs.readFileSync(path.join(d, 'site.u8'))),
  };
}

async function settle() {
  if (global.gc) global.gc();
  for (let i = 0; i < 4; i++) await tick();
}

async function replay(tr) {
  const { ops, arg, size, site, meta } = tr;
  const sites = meta.sites, escaping = meta.escaping;
  const reqs = new Array(meta.n_scopes);
  const held = new Array(meta.n_scopes);
  const escaped = new Array(meta.n_allocs);
  let seq = 0;
  // Time spent tearing requests down: region close + detach for SAMM, dropping
  // references for V8 (whose real reclaim cost shows up as GC instead).
  let closeNs = 0n;

  // Touch mode is timed in microseconds per allocation, so one pass (87 s of
  // real traffic) is plenty -- and repeating it would touch hundreds of
  // millions of pages.
  const passes = TOUCH ? 1 : Math.max(1, Math.ceil(MIN_EVENTS / ops.length));
  const before = samm ? samm.stats() : null;
  gcMs = 0; gcCount = 0;
  const t0 = process.hrtime.bigint();
  for (let pass = 0; pass < passes; pass++) {
  for (let e = 0; e < ops.length; e++) {
    switch (ops[e]) {
      case OPEN: {
        const s = arg[e];
        const req = {};
        if (samm !== null) {
          const id = samm.openRegion();
          if (id >= 0) req.sammRegion = id;
        }
        reqs[s] = req;
        held[s] = [];
        break;
      }
      case ALLOC: {
        const s = arg[e];
        const buf = allocateBuffer(size[e], sites[site[e]], reqs[s]);
        if (TOUCH) writeWholeBuffer(buf);
        if (escaping[site[e]]) escaped[seq % meta.n_allocs] = buf; else held[s].push(buf);
        seq++;
        break;
      }
      case CLOSE: {
        const s = arg[e];
        const c0 = process.hrtime.bigint();
        if (samm !== null && reqs[s].sammRegion !== undefined) samm.closeRegion(reqs[s].sammRegion);
        reqs[s] = undefined;
        held[s] = undefined;
        closeNs += process.hrtime.bigint() - c0;
        break;
      }
      case FREE:
        escaped[arg[e]] = undefined;
        break;
    }
    if ((e & (YIELD_EVERY - 1)) === YIELD_EVERY - 1) await tick();
  }
  }
  const ns = Number(process.hrtime.bigint() - t0);
  await tick();   // deliver the last GC entries; not timed

  const after = samm ? samm.stats() : null;
  return {
    allocs: seq, passes, ns, ns_per_alloc: +(ns / seq).toFixed(1),
    close_ns_per_alloc: +(Number(closeNs) / seq).toFixed(1),
    gc_ms: +gcMs.toFixed(1), gc_count: gcCount,
    fallbacks: samm ? after.capacityFallbacks - before.capacityFallbacks : null,
    detach_failures: samm ? after.detachFailures : null,
    rss_mb: +(process.memoryUsage().rss / 1048576).toFixed(1),
  };
}

function bridge(n) {
  // aggregate.js is System-classified, so every call is a full round trip that
  // does no memory work: the bridge's fixed cost.
  const site = 'aggregate.js:aggregateRoute';
  let nulls = 0;
  const t0 = process.hrtime.bigint();
  for (let i = 0; i < n; i++) if (samm.allocate(site, 65536, -1) === null) nulls++;
  const ns = Number(process.hrtime.bigint() - t0);
  if (nulls !== n) throw new Error(`expected every call to return null; got ${n - nulls} buffers`);
  return { calls: n, ns, ns_per_call: +(ns / n).toFixed(1) };
}

async function main() {
  const tr = layer === 'bridge' ? null : load(dir);
  for (let t = 0; t < WARMUP + TRIALS; t++) {
    await settle();
    const r = layer === 'bridge' ? bridge(2_000_000) : await replay(tr);
    if (t < WARMUP) continue;
    console.log(JSON.stringify({
      layer: layer === 'bridge' ? 'bridge' : `${layer}`, malloc: MALLOC,
      trace: tr ? tr.meta.name : null, touch: TOUCH, trial: t - WARMUP, ...r,
    }));
  }
}

main().catch((err) => { console.error(err); process.exit(1); });
