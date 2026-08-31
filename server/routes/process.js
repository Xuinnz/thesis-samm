// process endpoint
// this enpoint is driven by the memory_payload_allocations
// generates high variance in both size and lifespan
// slab allocator target
'use strict';

const { resolvePayloadBytes, allocateBuffer, simulateProcessing} = require('./_alloc-utils');

// The k6 payload sampler draws size_mb against the full Azure-derived
// distribution, normalized in Script 3.1 to a ceiling of
// EFFECTIVE_CEILING_MB (824MB after reserving room for V8/Node — see
// preprocessing/phase1-azure-simulation/03-normalization). This
// constant MUST match that value for the rescale below to be correct.
const AZURE_EFFECTIVE_CEILING_MB = 824;

// A linear rescale (multiply every value by the same constant ratio)
// preserves the FULL relative shape instead: percentile gaps,
// skewness, and critically the dynamic range (max/min ratio) all stay
// identical, just at a smaller absolute scale. Concretely:
//   Before: min=4MB,  max=824MB  -> ratio = 206x
//   After:  min~155KB, max=32MB  -> ratio = 206x  (unchanged)
// The endpoint's size variance — the property that got it correctly
// classified in this study's decision matrix in the first place — is
// therefore preserved, not compressed away.
const PROCESS_MAX_BYTES = 32 * 1024 * 1024; // 32MB
const PROCESS_RESCALE_RATIO = PROCESS_MAX_BYTES / (AZURE_EFFECTIVE_CEILING_MB * 1024 * 1024);


function processRoute(req, res) {
    // payload size is extracted from the payload, then proportionally
    // rescaled into this endpoint's own defensible per-request range.
    const rawBytes = resolvePayloadBytes(req, 5);
    const bytes = Math.max(1, Math.round(rawBytes * PROCESS_RESCALE_RATIO));
 
    const buffer = allocateBuffer(bytes, 'process.js:processRoute');
 
    // the higher the payload, the longer the process.
    // what makes this endpoint have a high variance and lifespan.
    const checksum = simulateProcessing(buffer);
 
    res.status(200).json({
        route: 'process',
        bytes,
        checksum,
    });
}


module.exports = processRoute;