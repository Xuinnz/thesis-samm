'use strict';

/**
 * GET /health
 *
 * Decision-matrix role: baseline noise.
 * No meaningful heap allocation — used by Docker healthchecks and to
 * verify the server is responsive without contributing to memory
 * pressure. Not tracked by the Shadow Profiler.
 */
function healthRoute(req, res) {
  res.status(200).json({
    status: 'ok',
    uptime_s: process.uptime(),
    timestamp: Date.now(),
  });
}

module.exports = healthRoute;