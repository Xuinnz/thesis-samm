'use strict';

const express = require('express');
const registerRoutes = require('../routes/index');
const profiler = require('../../profiler');
const telemetry = require('../routes/_telemetry');

const PORT = process.env.PORT || 3000;


// adding a body limit higher than 1 GB so the express server will not
// instantly reject it.
const BODY_LIMIT = process.env.BODY_LIMIT || '1200mb';

profiler.start();
const app = express();

//apply the body limimt to the JSON parser
app.use(express.json({limit: BODY_LIMIT}));

// ---------------------------------------------------------------------
// OBSERVATION ENDPOINTS -- registered BEFORE registerRoutes(), matching the
// SAMM image exactly. registerRoutes() installs regionMiddleware; anything
// after it is seen by that middleware, and on the SAMM side that means a real
// region opened and closed per poll. Keeping both images' observation
// endpoints ahead of it is what makes polling cost the same on either side.
// ---------------------------------------------------------------------

// GC pauses and heap fragmentation, when SAMM_TELEMETRY=true. Off by
// default: the GC observer perturbs the run it measures.
const telemetryOn = telemetry.start();
app.get('/telemetry', (req, res) => {
    res.status(200).json(telemetry.snapshot());
});

// Present ONLY so the metrics collector can poll both images identically.
//
// There is no allocator here -- this is the control condition -- so it answers
// with a null and the collector renders an empty allocator panel. What matters
// is that both containers receive the same request at the same rate, parse the
// same amount, and spend the same event-loop turn answering it. Polling only
// the SAMM container would hand the condition under test a cost its control
// never pays, which is how instrumentation ends up inside the measurement.
app.get('/samm/stats', (req, res) => {
    res.status(200).json({ allocator: null });
});

registerRoutes(app);

// global error handler
app.use((err, req, res, next) => {
    console.error(`[error] ${req.method} ${req.path}`, err.message);
    res.status(500).json({ error: 'internal_error', message: err.message});
}); 

//server boot
const server = app.listen(PORT, () => {
    console.log(`[samm-baseline] listening on port ${PORT}`);
    console.log(`[samm-baseline] body limit: ${BODY_LIMIT}`);

    const isProfilerOn = process.env.SHADOW_PROFILER_ENABLED === 'true';
    console.log(`[samm-baseline] shadow profiler: ${isProfilerOn ? 'ENABLED' : "DISABLED"}`);
    console.log(`[samm-baseline] gc/heap telemetry: ${telemetryOn ? 'ENABLED (observer effect in play)' : 'DISABLED'}`);
});

//graceful shutdown
function shutdown(signal){
    console.log(`\n[samm-baseline] received ${signal}, shutting down...`);
    server.close(() => {
        console.log('[samm-baseline] server closed');
        process.exit(0);
    });
}

// sigterm from docker 
process.on('SIGTERM', () => shutdown('SIGTERM'));
//sigint from ctrl + c
process.on('SIGINT', () => shutdown('SIGINT'));

module.exports = server;