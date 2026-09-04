// process endpoint
// this enpoint is driven by the memory_payload_allocations
// generates high variance in both size and lifespan
// slab allocator target
'use strict';

const { resolvePayloadBytes, allocateBuffer, simulateProcessing} = require('./_alloc-utils');
/**
 * k6 payload sampler draws size_mb from the Azure-derived distribution
 * normalized in Script 3.1 to a ceiling of EFFECTIVE_CEILING_MB (824 MB after reserving room for V8)
 * These constant MUST match for the rescale to be correct
 */
const AZURE_EFFECTIVE_CEILING_MB = 824;

/**
 * A linear rescale. This makes the max payload be 32MB, but still follow the distribution
 * derived from azure
 */
const PROCESS_MAX_BYTES = 32 * 1024 * 1024; // 32MB
const PROCESS_RESCALE_RATIO = PROCESS_MAX_BYTES / (AZURE_EFFECTIVE_CEILING_MB * 1024 * 1024);


/**
 * This function is async so we give the process route an interleaving lifespan
 * by using Promise(). The buffer is now held alive across an async boundary for more variance lifespan.
 * read _duration-sampler on how it works.
 */
async function processRoute(req, res) {
    // payload size is extracted from the payload, then proportionally
    // rescaled into this endpoint's own defensible per-request range.
    const rawBytes = resolvePayloadBytes(req, 5);
    const bytes = Math.max(1, Math.round(rawBytes * PROCESS_RESCALE_RATIO));
 
    const buffer = allocateBuffer(bytes, 'process.js:processRoute');

    // Held alive across async boundary for a data-driven duration
    // this is what drives the call-sites observed lifespan and variance.
    const holdMs = Number(req.body && req.body.hold_ms) || 10;
    await new Promise((resolve) => setTimeout(resolve, holdMs));

    // to actually get the physical ram, we need to directly touch it.
    const checksum = simulateProcessing(buffer);
 
    res.status(200).json({
        route: 'process',
        bytes,
        hold_ms: holdMs,
        checksum,
    });
}

module.exports = processRoute;