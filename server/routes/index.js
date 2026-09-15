'use strict';

const healthRoute = require('./health');
const cacheRoute = require('./cache');
const fetchRoute = require('./fetch')
const processRoute = require('./process');
const aggregateRoute = require('./aggregate');
const batchRoute = require('./batch');
const { regionMiddleware } = require('./_alloc-utils');
const { workloadFingerprint } = require('./_workload');

function registerRoutes(app){
    // Must precede the routes: they allocate against the region it opens.
    app.use(regionMiddleware);

    app.get('/health', healthRoute);

    // Lets the characterization run record exactly which workload it
    // profiled, so the compiled table can refuse to serve a different one.
    app.get('/workload', (req, res) => res.status(200).json(workloadFingerprint()));

    app.post('/api/cache', cacheRoute);

    app.post('/api/fetch', fetchRoute);

    app.post('/api/process', processRoute);

    app.post('/api/aggregate', aggregateRoute);

    app.post('/api/batch', batchRoute);
}

module.exports = registerRoutes;