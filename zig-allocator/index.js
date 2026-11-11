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
// SAMM_BUFFER_MODE (see BUFFER MODES in addon.zig). In chunk and view mode a
// bump call-site's object is a view into an ArrayBuffer it shares: the addon
// returns an offset and says, through sharedOut, which buffer it is relative to.
const BUFFER_MODE = native === null ? 'detach' : native.samm_buffer_mode();
const sharedOut = BUFFER_MODE === 'detach' ? null : native.samm_shared_out();
const tokenShares = []; // token -> can samm_allocate_shared ever serve it
const sharedBuffers = []; // key -> ArrayBuffer
const sharedSerials = []; // key -> the serial that buffer was fetched under

function allocate(callSiteId, sizeBytes, regionId) {
  if (native === null) return null;
  const token = tokenFor(callSiteId);

  if (sharedOut !== null && regionId !== undefined && regionId >= 0) {
    let shares = tokenShares[token];
    if (shares === undefined) shares = tokenShares[token] = native.samm_token_shares(token);
    if (shares) {
      const offset = native.samm_allocate_shared(token, sizeBytes, regionId);
      if (offset >= 0) {
        // chunk: one buffer per region and arena. view: one per arena and segment.
        const key = BUFFER_MODE === 'view' ? sharedOut[1] * 4096 + sharedOut[2] : regionId * 16 + sharedOut[1];
        if (sharedSerials[key] !== sharedOut[0]) {
          sharedBuffers[key] = native.samm_shared_buffer(regionId);
          sharedSerials[key] = sharedOut[0];
        }
        return Buffer.from(sharedBuffers[key], offset, sizeBytes);
      }
      if (offset === -1) return null; // no arena could serve it
      // -2: this one takes the ordinary path
    }
  }

  return native.samm_allocate(
    token,
    sizeBytes,
    regionId === undefined ? -1 : regionId,
  );
}

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
  bufferMode: BUFFER_MODE,
  allocate,
  openRegion,
  closeRegion,
  warmup,
  stats,
  ADDON_PATH,
};
