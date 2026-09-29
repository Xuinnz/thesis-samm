'use strict';

// Experimental group: identical to baseline-v8/server.js in every respect
// except that the Zig sidecar allocator is switched on. Both conditions
// register the same routes from ../routes, so the only independent variable
// between them is which branch allocateBuffer() takes.

const express = require('express');
const registerRoutes = require('../routes/index');
const profiler = require('../../profiler');
const samm = require('../../zig-allocator');
const telemetry = require('../routes/_telemetry');
const { workloadFingerprint } = require('../routes/_workload');
const { verifyWorkload } = require('../../zig-allocator/workload_check');

// Before anything allocates: the compiled routing table is only valid for the
// workload it was characterized against. A mismatch yields quotas that are
// wrong while still producing plausible numbers, so it fails closed.
{
  const current = workloadFingerprint();
  const strict = process.env.SAMM_ALLOW_WORKLOAD_MISMATCH !== 'true';
  const result = verifyWorkload(current, { strict });
  if (!result.ok) process.exit(1);
  if (result.verified) {
    console.log(`[samm-enabled] workload verified: ${result.fingerprint}`);
  }
}

const PORT = process.env.PORT || 3000;

// adding a body limit higher than 1 GB so the express server will not
// instantly reject it.
const BODY_LIMIT = process.env.BODY_LIMIT || '1200mb';

// Fail fast rather than silently benchmarking the baseline while calling it
// SAMM. The wrapper throws on a missing addon; this catches the subtler case of
// the flag simply not being set.
if (!samm.enabled) {
    console.error(
        '[samm-enabled] SAMM_ALLOCATOR_ENABLED is not "true".\n' +
        '               This server exists to measure the SAMM allocator; running it\n' +
        '               unrouted would produce baseline numbers under the wrong label.\n' +
        '               Start it with: SAMM_ALLOCATOR_ENABLED=true node server.js'
    );
    process.exit(1);
}

profiler.start();

// Optional: fault in the predicted working set before traffic arrives, so
// first-touch page faults land here instead of inside measured request latency.
//
// OFF by default, and that default is deliberate. Warmup commits every
// stratum's guaranteed floor -- the full characterized peak demand -- whether or
// not the current traffic mix ever touches it. Measured here, that put RSS at
// ~410MB before the first request, against a baseline that peaked at 179MB
// under the same load. For a study whose headline metric is Peak RSS, warming
// unconditionally would report the allocator's reservation rather than its
// demand. Turn it on only when trading RSS for tail latency is the intent.
const warmedBytes = process.env.SAMM_WARMUP === 'true' ? samm.warmup() : 0;

const app = express();

//apply the body limimt to the JSON parser
app.use(express.json({limit: BODY_LIMIT}));

// ---------------------------------------------------------------------
// OBSERVATION ENDPOINTS -- registered BEFORE registerRoutes(), deliberately.
//
// registerRoutes() installs regionMiddleware, which opens a SAMM region for
// every request it sees. If these sat after it, each poll from the metrics
// collector would open and close a real region -- measured directly: with the
// container idle and no traffic at all, regionsOpened climbed 6 -> 7 between
// two consecutive 1 Hz polls.
//
// That is small (~600 regions against 228,000 in a ten-minute run) but it is
// the wrong shape: the baseline has no regions, so the same polling costs the
// two conditions different amounts. This project has already been burned once
// by an instrument that was present in both conditions and still skewed the
// comparison -- a GC PerformanceObserver, symmetric by presence, asymmetric by
// effect, worth 17,669 capacity fallbacks against 1,703.
//
// Registered here, a poll costs one JSON serialization on either image and
// touches nothing else.
// ---------------------------------------------------------------------

// GC pauses and heap fragmentation, when SAMM_TELEMETRY=true. Off by
// default: the GC observer perturbs the run it measures.
const telemetryOn = telemetry.start();
app.get('/telemetry', (req, res) => {
    res.status(200).json(telemetry.snapshot());
});

// Allocator telemetry, so a run can be checked for the failure modes that would
// otherwise be invisible: requests that fell back to System, arenas that could
// not recycle, and how much of the shared elastic budget was drawn down.
app.get('/samm/stats', (req, res) => {
    res.status(200).json(samm.stats());
});

registerRoutes(app);

// global error handler
app.use((err, req, res, next) => {
    console.error(`[error] ${req.method} ${req.path}`, err.message);
    res.status(500).json({ error: 'internal_error', message: err.message});
});

//server boot
const server = app.listen(PORT, () => {
    const s = samm.stats();
    const mb = (bytes) => (bytes / (1024 * 1024)).toFixed(1);

    console.log(`[samm-enabled] listening on port ${PORT}`);
    console.log(`[samm-enabled] body limit: ${BODY_LIMIT}`);
    console.log(`[samm-enabled] allocator: ENABLED (${samm.ADDON_PATH})`);
    console.log(`[samm-enabled] reclaim policy: ${process.env.SAMM_RECLAIM_POLICY || 'none'}`);
    console.log(
        `[samm-enabled] budget: ${mb(s.reservedFloorBytes)} MB guaranteed, ` +
        `${mb(s.ceilingBytes - s.reservedFloorBytes)} MB shared, ` +
        `${mb(s.ceilingBytes)} MB ceiling`
    );
    console.log(
        warmedBytes > 0
            ? `[samm-enabled] warmup: ${mb(warmedBytes)} MB faulted in`
            : '[samm-enabled] warmup: off (set SAMM_WARMUP=true to pre-fault the floors)'
    );

    const isProfilerOn = process.env.SHADOW_PROFILER_ENABLED === 'true';
    console.log(`[samm-enabled] shadow profiler: ${isProfilerOn ? 'ENABLED' : 'DISABLED'}`);
    console.log(`[samm-enabled] gc/heap telemetry: ${telemetryOn ? 'ENABLED (observer effect in play)' : 'DISABLED'}`);
});

//graceful shutdown
function shutdown(signal){
    console.log(`\n[samm-enabled] received ${signal}, shutting down...`);

    const s = samm.stats();
    console.log(
        `[samm-enabled] allocator: ${s.bumpResets} resets, ${s.grows} grows, ` +
        `${s.capacityFallbacks} capacity fallbacks, ${s.unmanaged} unmanaged`
    );

    server.close(() => {
        console.log('[samm-enabled] server closed');
        process.exit(0);
    });
}

// sigterm from docker
process.on('SIGTERM', () => shutdown('SIGTERM'));
//sigint from ctrl + c
process.on('SIGINT', () => shutdown('SIGINT'));

module.exports = server;
