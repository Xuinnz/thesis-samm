'use strict';

const healthRoute = require('./health');
const cacheRoute = require('./cache');
const fetchRoute = require('./fetch')
const processRoute = require('./process');
const aggregateRoute = require('./aggregate');
const batchRoute = require('./batch');

function registerRoutes(app){
    app.get('/health', healthRoute);

    app.post('/api/cache', cacheRoute);

    app.get('/api/fetch', fetchRoute);

    app.post('/api/process', processRoute);

    app.post('/api/aggregate', aggregateRoute);

    app.post('/api/batch', batchRoute);
}

module.exports = registerRoutes;