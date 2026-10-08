'use strict';
/**
 * Reads the routing table and the ML output the dashboard displays.
 *
 * Everything here is derived, never typed in: the arena geometry comes from the
 * generated model_weights.zig, and the per-call-site statistics come from the
 * refinery's own policy assignment CSV. Call-sites are matched by hash, using
 * the profiler's FNV-1a, so a renamed route shows up as an unknown hash instead
 * of silently displaying the wrong name.
 *
 * Read on demand (the file is tiny), so a retrain shows up on the next refresh
 * without restarting the collector.
 */

const fs = require('fs');
const path = require('path');
const { LOAD } = require('./loads');

const REPO = path.resolve(__dirname, '..');
const WEIGHTS = path.join(REPO, 'zig-allocator/src/routing-table/model_weights.zig');
const POLICY_CSV = path.join(REPO, 'datasets/shadow-telemetry/intermediate/ml-refinery/call_site_policy_assignment.csv');
// What the characterization run recorded about its own workload. The load
// point the quotas were trained at is recovered from this, not typed in.
const MANIFEST = path.join(REPO, 'datasets/shadow-telemetry/raw/workload_manifest.json');

// The call-site identifiers the routes pass to allocateBuffer().
const SITES = [
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

const NAME_OF = new Map(SITES.map((s) => [fnv1a(s), s]));
const shortName = (id) => (id ? id.split('.')[0] : null);

/** Every `.{ ... }` record inside `pub const <name> = [_]T{ ... };`. */
function records(src, name) {
  const start = src.indexOf(`pub const ${name} = [_]`);
  if (start < 0) return [];
  // The array's own brace. Starting at the FIRST record's brace instead would
  // make split('.{') treat record 0 as the pre-delimiter chunk, and slice(1)
  // would drop it -- every call-site then links to its neighbour's arena.
  const open = src.indexOf('{', start);
  const end = src.indexOf('\n};', open);
  return src.slice(open, end).split('.{').slice(1).map((chunk) => {
    const out = {};
    for (const [, k, v] of chunk.matchAll(/\.(\w+)\s*=\s*([^,}]+)/g)) {
      const raw = v.trim();
      if (raw === 'true' || raw === 'false') out[k] = raw === 'true';
      else if (/^\.?[a-z_]+$/i.test(raw)) out[k] = raw.replace(/^\./, '');
      // Call-site hashes are u64. Number() rounds them, and a rounded hash
      // matches nothing -- every arena would come back unlinked.
      else if (/hash/.test(k)) out[k] = raw.replace(/_/g, '');
      else out[k] = Number(raw.replace(/_/g, ''));
    }
    return out;
  });
}

function constant(src, name) {
  const m = src.match(new RegExp(`pub const ${name}\\s*:[^=]+=\\s*([0-9_]+)`));
  return m ? Number(m[1].replace(/_/g, '')) : null;
}

function readPolicyCsv() {
  const rows = new Map();
  let text;
  try { text = fs.readFileSync(POLICY_CSV, 'utf8').trim(); } catch { return rows; }
  const lines = text.split('\n');
  const cols = lines[0].split(',');
  for (const line of lines.slice(1)) {
    const cells = line.split(',');
    const row = {};
    cols.forEach((c, i) => {
      const v = cells[i];
      // call_site_hash is a u64: parsing it as a float would round it.
      row[c] = c === 'call_site_hash' || c === 'allocation_policy' ? v : Number(v);
    });
    rows.set(row.call_site_hash, row);
  }
  return rows;
}

/**
 * The load point the table was trained at: the LOAD row whose holds match what
 * the characterization run recorded. Null when none matches -- worth showing,
 * since the quotas would then describe a workload the demo cannot reproduce.
 */
function characterizedK(manifest) {
  if (!manifest || !manifest.parameters) return null;
  const hold = Number(manifest.parameters.process_hold_ms);
  const scale = Number(manifest.parameters.hold_scale);
  const hit = Object.entries(LOAD).find(([, L]) =>
    L.PROCESS_HOLD_MS === hold && Math.abs(L.HOLD_SCALE - scale) < 1e-3);
  return hit ? hit[0] : null;
}

const mb = (bytes) => (bytes === null || bytes === undefined ? null : +(bytes / 1048576).toFixed(1));

/**
 * One row per call-site the ML classified, joined with the arena the table
 * compiler actually built for it.
 */
function readTable() {
  const src = fs.readFileSync(WEIGHTS, 'utf8');
  const bumps = records(src, 'bump_arenas');
  const slabs = records(src, 'slab_classes');
  const routes = records(src, 'table').filter((s) => s.policy && s.policy !== 'none');
  const stats = readPolicyCsv();

  const arenaOf = new Map(bumps.map((a, i) => [a.call_site_hash, { ...a, index: i }]));
  const sites = [];
  for (const [hash, row] of stats) {
    const arena = arenaOf.get(hash);
    const route = routes.find((r) => r.hash === hash);
    sites.push({
      hash,
      call_site: NAME_OF.get(hash) || null,
      name: shortName(NAME_OF.get(hash)) || `hash ${hash.slice(0, 8)}`,
      policy: row.allocation_policy,                     // Bump | Slab | System
      routed: route ? route.policy : 'none',             // what the table actually holds
      arena_index: arena ? arena.index : null,
      cluster: row.temporal_cluster,
      objects: row.n_objects,
      mean_lifespan_ms: row.mu_lifespan == null ? null : +row.mu_lifespan.toFixed(1),
      variance: row.sigma2 == null ? null : +row.sigma2.toFixed(1),
      size_cv: row.size_cv == null ? null : +row.size_cv.toFixed(3),
      mean_size_kb: row.mu_size_bytes == null ? null : +(row.mu_size_bytes / 1024).toFixed(1),
      median_overhang_ms: row.median_overhang_ms ?? null,
      peak_live_mb: mb(row.peak_live_bytes),
      // The decision itself: whichever arena wastes fewer bytes wins.
      bump_extra_mb: mb(row.bump_extra_bytes),
      slab_extra_mb: mb(row.slab_extra_bytes),
      floor_mb: arena ? mb(arena.floor_bytes) : null,
      span_mb: arena ? mb(arena.span_bytes) : null,
      segment_mb: arena ? mb(arena.segment_bytes) : null,
      floor_segments: arena ? arena.floor_segments : null,
      max_segments: arena ? arena.max_segments : null,
      huge_pages: arena ? arena.use_huge_pages : null,
    });
  }
  sites.sort((a, b) => (b.objects || 0) - (a.objects || 0));

  const clusters = {};
  for (const s of sites) clusters[s.cluster] = (clusters[s.cluster] || 0) + 1;

  let manifest = null;
  try { manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8')); } catch { /* absent is allowed */ }

  return {
    generated_at: fs.statSync(WEIGHTS).mtime.toISOString(),
    manifest,
    characterized_k: characterizedK(manifest),
    sites,
    cluster_count: Object.keys(clusters).length,
    clusters,
    // Which cluster the escape detector sent to System, read back from the
    // assignment rather than assumed.
    system_cluster: (sites.find((s) => s.policy === 'System') || {}).cluster ?? null,
    // Only the classes the quotas actually provisioned. The rest exist so an
    // unexpected size still lands somewhere, and showing 14 empty rows for
    // them would bury the one class that carries traffic.
    slab_classes: slabs
      .filter((c) => c.floor_slots > 0)
      .map((c) => ({
        class_kb: +(c.class_size / 1024).toFixed(1),
        floor_slots: c.floor_slots,
        max_slots: c.max_slots,
        floor_mb: mb(c.floor_slots * c.class_size),
        max_mb: mb(c.max_slots * c.class_size),
        huge_pages: c.use_huge_pages,
      })),
    budget: {
      ceiling_mb: mb(constant(src, 'm_available_bytes')),
      reserved_floor_mb: mb(constant(src, 'reserved_floor_bytes')),
      region_mb: mb(constant(src, 'region_bytes')),
      page_size: constant(src, 'page_size'),
      huge_page_size: constant(src, 'huge_page_size'),
    },
  };
}

module.exports = { readTable };
