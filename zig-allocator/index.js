'use strict';

/**
 * SAMM allocator — JS-facing wrapper around the Zig N-API addon.
 *
 * Mirrors the shape of profiler/index.js: an env switch so the exact same
 * server code path can run either routed through SAMM or on plain V8, which is
 * what keeps the two benchmark conditions comparable.
 *
 * Call-sites are interned once and cached here, so the hot path never hashes a
 * string natively. The first allocation for a given call-site pays one
 * samm_intern(); every later one is a Map lookup plus a token.
 */

const path = require('path');

const ENABLED = process.env.SAMM_ALLOCATOR_ENABLED === 'true';
const ADDON_PATH =
  process.env.SAMM_ADDON_PATH ||
  path.join(__dirname, 'zig-out', 'lib', 'samm_allocator.node');

let native = null;
const tokens = new Map();

if (ENABLED) {
  try {
    // eslint-disable-next-line global-require, import/no-dynamic-require
    native = require(ADDON_PATH);
  } catch (err) {
    // Deliberately fatal rather than a silent fallback to Buffer.allocUnsafe.
    // A run that quietly degrades to baseline behaviour but is still labelled
    // "SAMM" would invalidate the comparison it exists to produce.
    throw new Error(
      `[samm] SAMM_ALLOCATOR_ENABLED=true but the addon could not be loaded from ` +
        `${ADDON_PATH}\n` +
        `       Build it first:  (cd zig-allocator && zig build -Doptimize=ReleaseFast)\n` +
        `       Underlying error: ${err.message}`,
    );
  }
}

/** Resolves a call-site to its token, interning it the first time it is seen. */
function tokenFor(callSiteId) {
  let token = tokens.get(callSiteId);
  if (token === undefined) {
    token = native.samm_intern(callSiteId);
    tokens.set(callSiteId, token);
  }
  return token;
}

/**
 * Returns a Buffer backed by the SAMM pool, or null when this call-site is not
 * managed (System-classified) or no arena could serve the request. Null is the
 * normal, expected answer for a System call-site -- the caller falls back to a
 * plain V8 allocation, which is exactly the decision matrix's intent.
 *
 * @param {string} callSiteId e.g. "process.js:processRoute"
 * @param {number} sizeBytes
 * @returns {Buffer|null}
 */
function allocate(callSiteId, sizeBytes, regionId) {
  if (native === null) return null;
  return native.samm_allocate(
    tokenFor(callSiteId),
    sizeBytes,
    regionId === undefined ? -1 : regionId,
  );
}

/**
 * Opens a reclamation region. Everything allocated against it is released in
 * one deterministic batch by closeRegion(), instead of whenever V8 happens to
 * collect each Buffer.
 *
 * @returns {number} region id, or -1 if none is available (callers then fall
 *   back to the GC-driven path, which is still correct, just not deterministic)
 */
function openRegion() {
  if (native === null) return -1;
  return native.samm_region_open();
}

/**
 * Reclaims every allocation made against the region and detaches their
 * Buffers, so a reference that escaped its request throws instead of reading
 * memory now owned by someone else.
 *
 * @returns {number} allocations reclaimed
 */
function closeRegion(regionId) {
  if (native === null || regionId === undefined || regionId < 0) return 0;
  return native.samm_region_close(regionId);
}

/**
 * Faults in every stratum's guaranteed floor. Call once at startup, before
 * traffic, so first-touch page faults are not charged to request latency.
 */
function warmup() {
  if (native === null) return 0;
  return native.samm_warmup();
}

function stats() {
  if (native === null) return null;
  return native.samm_stats();
}

module.exports = {
  enabled: ENABLED,
  allocate,
  openRegion,
  closeRegion,
  warmup,
  stats,
  ADDON_PATH,
};
