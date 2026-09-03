/**
 * Loads the Azure-derived execution duration jitter parameters from Preprocessing Phase 1 Script 2.2
 * then samples from that same log-normal distribution to drive hold duration. basically the lifepsan of the objects
 * across async boundaries before responding.
 */
'use strict';

const fs = require('fs');
const path = require('path');

const JITTER_PARAMS_PATH =
  process.env.JITTER_PARAMS_PATH ||
  path.join(__dirname, '..', '..', 'datasets', 'azure-trace-2019',
    'processed', 'traffic-models', 'jitter_parameters.json');

let mu = null;
let sigma = null;

function loadParams() {
  if (mu !== null && sigma !== null) return;
 
  const raw = fs.readFileSync(JITTER_PARAMS_PATH, 'utf8');
  const parsed = JSON.parse(raw);
 
  if (typeof parsed.mu !== 'number' || typeof parsed.sigma !== 'number') {
    throw new Error(
      `_duration-sampler: ${JITTER_PARAMS_PATH} is missing numeric "mu"/"sigma" fields`
    );
  }
  if (parsed.sigma <= 0) {
    throw new Error('_duration-sampler: sigma must be > 0');
  }
 
  mu = parsed.mu;
  sigma = parsed.sigma;
}

// use box muller transformation to generate a hold duration in milliseconds
// from the azure derived log-normal execution-duration distribution
function sampleHoldMs(){
    loadParams();

    let u1 = Math.random();
    while (u1 === 0) u1 = Math.random();
    const u2 = Math.random();

    const z = Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
    return Math.exp(mu + sigma * z);
}

module.exports = {
    sampleHoldMs
};