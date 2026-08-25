//This file is to simulate human and network chaos.
// It uses a unique delay from the Log-Normal curve from Phase 1, Step 2.2: Derive Jitter


'use strict';

const { parse } = require("node:path");

/*
  Parses jitter_parameters.json and validates that the mathematical parameters are present and valid
*/
function parseJitterParams(jsonText){
  const parsed = JSON.parse(jsonText);
  if (typeof parsed.mu !== 'number' || typeof parsed.sigma !== 'number') {
    throw new Error('parseJitterParams: expected numeric "mu" and "sigma" fields');
  }
  if (parsed.sigma <= 0) {
    throw new Error('parsedJitterParams: sigma must be greater than 0 (variance cannot be negative)');
  }

  return { mu: parsed.mu, sigma: parsed.sigma };
}

/**
 * Samples a single think-time value in milliseconds from Log-Normal distribution
 * using Box-Muller Transformation
 * 
 * 
 * @param {number} mu - The mean of the underlying normal distribution
 * @param {number} sigma - The standard deviation
 * @param {Functiom} [rng] - random number generator (defaults to math.random)
 */
function sampleThinkTimeMs(mu, sigma, rng){
  const rand = rng || Math.random;
  let u1 = rand();

  while (u1 === 0) u1 = rand();

  const u2 = rand();

  // box-muller transformation to convert uniform randoms into a Standard Normal (Z-score)
  const z = Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);

  // convert the Z-score back into our Log-Normal millisecond duration
  return Math.exp(mu + sigma * z);
}

module.exports = {
  parseJitterParams,
  sampleThinkTimeMs
};