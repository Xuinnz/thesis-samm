// PROCESS ENDPOINT
// this enpoint is driven by the memory_payload_allocations
// follows azure derived distribution of payloads
// varying size / fixed life

// candidate for bump allocator
'use strict';

const { resolvePayloadBytes, allocateBuffer, writeWholeBuffer } = require('./_alloc-utils');
/**
 * k6 payload sampler draws size_mb from the Azure-derived distribution
 * normalized in Script 3.1 to a ceiling of EFFECTIVE_CEILING_MB (824 MB after reserving room for V8)
 * These constant MUST match for the rescale to be correct
 */
const AZURE_EFFECTIVE_CEILING_MB = 824;

// Caps the maximum allocation to save CPU cycles.
// We scale down the massive Azure sizes to fit within this limit (default 32MB).
const PROCESS_MAX_BYTES = (() => {
  const raw = process.env.PROCESS_MAX_BYTES;
  if (raw === undefined || raw === '') return 32 * 1024 * 1024;
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0) {
    throw new Error(`PROCESS_MAX_BYTES must be a positive byte count; got ${JSON.stringify(raw)}`);
  }
  return n;
})();

// The mathematical ratio used to shrink incoming payload sizes down to our safer limit.
// Linear scaling moves the size but leaves the *distribution shape* untouched.
const PROCESS_RESCALE_RATIO = PROCESS_MAX_BYTES / (AZURE_EFFECTIVE_CEILING_MB * 1024 * 1024);


/**
 * This function is async so we give the process route an interleaving lifespan
 * by using Promise(). The buffer is now held alive across an async boundary for more variance lifespan.
 */
async function processRoute(req, res) {
    // payload size is extracted from the payload, then proportionally
    // rescaled into this endpoint's own defensible per-request range.
    const rawBytes = resolvePayloadBytes(req, 5);
    const bytes = Math.max(1, Math.round(rawBytes * PROCESS_RESCALE_RATIO));
 
    const buffer = allocateBuffer(bytes, 'process.js:processRoute', req);

    // Held alive across async boundary for a data-driven duration
    // this is what drives the call-sites observed lifespan and variance.
    const holdMs = Number(req.body && req.body.hold_ms) || 10;
    await new Promise((resolve) => setTimeout(resolve, holdMs));

    // to actually get the physical ram, we need to directly touch it.
    // Transforming a payload reads and writes all of it.
    const checksum = writeWholeBuffer(buffer);
 
    res.status(200).json({
        route: 'process',
        bytes,
        hold_ms: holdMs,
        checksum,
    });
}

module.exports = processRoute;