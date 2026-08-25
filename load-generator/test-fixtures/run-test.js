
/**
 * 
 */

'use strict';

const fs = require('fs');
const path = require('path');

const {
  parseTransitionMatrix,
  deriveStateIntensityProfile,
  scaleToRpsRange,
  simulateSchedule,
  buildK6Stages,
  makeRng,
  STATE_ORDER,
} = require('../traffic-models/markov-chain');

const { parseJitterParams, sampleThinkTimeMs } = require('../traffic-models/jitter');

const {
  parsePayloadCsv,
  buildPayloadSampler,
} = require('../traffic-models/payload-sampler');

const FIXTURES = path.join(__dirname, '..', 'test-fixtures');
const read = (f) => fs.readFileSync(path.join(FIXTURES, f), 'utf8');

let failures = 0;
function assert(cond, msg) {
  if (!cond) {
    failures += 1;
    console.error(`  [FAIL] ${msg}`);
  } else {
    console.log(`  [ OK ] ${msg}`);
  }
}

// -----------------------------------------------------------------
console.log('\n=== markov-chain.js ===');

const matrixCsv = read('../../datasets/azure-trace-2019/processed/traffic-models/markov_transition_matrix.csv');
const matrix = parseTransitionMatrix(matrixCsv);

assert(Object.keys(matrix).length === 4, 'parsed 4 states from transition matrix');
assert(
  Math.abs(matrix.Idle.Idle - 0.8233) < 1e-6,
  `Idle->Idle probability parsed correctly (got ${matrix.Idle.Idle})`
);
assert(
  Math.abs(matrix.Cooldown.Burst - 0.2706) < 1e-6,
  `Cooldown->Burst probability parsed correctly (got ${matrix.Cooldown.Burst})`
);

// Row-stochastic check: every row should sum to ~1.0
for (const state of STATE_ORDER) {
  const rowSum = STATE_ORDER.reduce((acc, s) => acc + matrix[state][s], 0);
  assert(
    Math.abs(rowSum - 1.0) < 1e-3,
    `row "${state}" sums to ~1.0 (got ${rowSum.toFixed(4)})`
  );
}

const seriesCsv = read('../../datasets/azure-trace-2019/processed/traffic-models/traffic_state_series.csv');
const intensityProfile = deriveStateIntensityProfile(seriesCsv);
console.log('  intensity profile:', intensityProfile);
assert(
  intensityProfile.Burst === 1.0 || intensityProfile.Burst >= intensityProfile.Idle,
  'Burst intensity >= Idle intensity (busiest state normalizes near 1.0)'
);
assert(
  Object.values(intensityProfile).every((v) => v >= 0 && v <= 1),
  'all intensity values within [0,1]'
);

const rpsProfile = scaleToRpsRange(intensityProfile, 5, 200);
console.log('  scaled RPS profile (5-200 range):', rpsProfile);
assert(
  Math.min(...Object.values(rpsProfile)) >= 5 - 1e-9,
  'scaled RPS respects the configured minimum'
);
assert(
  Math.max(...Object.values(rpsProfile)) <= 200 + 1e-9,
  'scaled RPS respects the configured maximum'
);

// Deterministic simulation with a fixed seed
const scheduleA = simulateSchedule(matrix, rpsProfile, 120, 'Idle', 12345);
const scheduleB = simulateSchedule(matrix, rpsProfile, 120, 'Idle', 12345);
assert(
  JSON.stringify(scheduleA) === JSON.stringify(scheduleB),
  'same seed produces identical schedule (reproducibility)'
);
assert(scheduleA.length === 120, 'schedule length matches requested minutes');

const stages = buildK6Stages(scheduleA, 1);
const totalStageDuration = stages.reduce((acc, s) => acc + parseInt(s.duration, 10), 0);
console.log(`  ${stages.length} merged stages from ${scheduleA.length} minutes`);
assert(
  totalStageDuration === scheduleA.length,
  `merged stage durations sum to original minute count (${totalStageDuration} == ${scheduleA.length})`
);

// -----------------------------------------------------------------
console.log('\n=== jitter.js ===');

const jitterJson = read('../../datasets/azure-trace-2019/processed/traffic-models/jitter_parameters.json');
const { mu, sigma } = parseJitterParams(jitterJson);
assert(Math.abs(mu - 6.1437) / 6.1437 < 0.01, `mu within 1% of expected (~6.14), got ${mu}`);

const seededRng = makeRng(999);
const samples = [];
for (let i = 0; i < 20000; i += 1) {
  samples.push(sampleThinkTimeMs(mu, sigma, seededRng));
}
samples.sort((a, b) => a - b);
const median = samples[Math.floor(samples.length / 2)];
const p99 = samples[Math.floor(samples.length * 0.99)];
console.log(`  sampled median=${median.toFixed(1)}ms p99=${p99.toFixed(1)}ms over 20000 draws`);
console.log(`  expected (from fixture) median~465.8ms p99~2187.0ms`);
assert(
  Math.abs(median - 465.8) / 465.8 < 0.15,
  `sampled median within 15% of fitted P50 (${median.toFixed(1)} vs 465.8)`
);
assert(
  Math.abs(p99 - 2187.0) / 2187.0 < 0.25,
  `sampled P99 within 25% of fitted P99 (${p99.toFixed(1)} vs 2187.0) — wider tolerance, tail is high-variance`
);
assert(samples.every((s) => s > 0), 'all sampled think-times are strictly positive');

// -----------------------------------------------------------------
console.log('\n=== payload-sampler.js ===');

const payloadCsv = read('../../datasets/azure-trace-2019/processed/memory-models/memory_payload_allocations.csv');
const parsedPayload = parsePayloadCsv(payloadCsv);
assert(parsedPayload.rows.length === 4, 'parsed 4 app rows from payload fixture');
assert(parsedPayload.hasSampleCount === true, 'detected SampleCount column in fixture');
assert(
  parsedPayload.percentileColumns.length === 8,
  `detected all 8 percentile columns (got ${parsedPayload.percentileColumns.length})`
);
assert(
  parsedPayload.percentileColumns[0].pct === 1 &&
    parsedPayload.percentileColumns[7].pct === 100,
  'percentile columns sorted ascending, 1 -> 100'
);

const sampleSizeMb = buildPayloadSampler(parsedPayload);
const payloadSamples = [];
const payloadRng = makeRng(777);
for (let i = 0; i < 5000; i += 1) {
  payloadSamples.push(sampleSizeMb(payloadRng));
}
const minMb = Math.min(...payloadSamples);
const maxMb = Math.max(...payloadSamples);
console.log(`  sampled payload range over 5000 draws: ${minMb.toFixed(1)}MB - ${maxMb.toFixed(1)}MB`);
assert(minMb >= 0, 'no negative payload sizes sampled');
assert(maxMb <= 1024, `no payload exceeds container ceiling (max=${maxMb.toFixed(1)}MB)`);
assert(
  payloadSamples.every((v) => Number.isFinite(v)),
  'all sampled payload sizes are finite numbers'
);

// Rough weighting sanity check: the high-SampleCount row (17259)
// should be selected far more often than the low-SampleCount row (89)
// under weighted selection.
const { buildRowSelector } = require('../traffic-models/payload-sampler');
const selector = buildRowSelector(parsedPayload.rows, parsedPayload.hasSampleCount);
const selectionCounts = new Array(parsedPayload.rows.length).fill(0);
const selRng = makeRng(555);
for (let i = 0; i < 10000; i += 1) {
  selectionCounts[selector(selRng)] += 1;
}
console.log('  weighted row selection counts (rows ordered by SampleCount 1350,17259,522,89):', selectionCounts);
assert(
  selectionCounts[1] > selectionCounts[3] * 5,
  'row with SampleCount=17259 selected far more often than row with SampleCount=89'
);

// -----------------------------------------------------------------
console.log(`\n${failures === 0 ? 'ALL TESTS PASSED' : `${failures} TEST(S) FAILED`}`);
process.exit(failures === 0 ? 0 : 1);