/**
 * Request generation shared by every scenario in internal-validation/.
 *
 * DELIBERATE DUPLICATION, NOT DRIFT. Everything that builds a request is copied
 * from load-generator/k6-scenarios/samm-load-test.js: the endpoint weight
 * table, the payload sampler setup, the hold model (HOLD_SCALE, ingest's 1/k
 * hold, process's fixed hold with jitter), the six endpoint handlers and the
 * processing_time pattern (http_req_duration minus the artificial hold). It is
 * copied rather than imported or extracted so the realistic-traffic benchmark
 * stays untouched. If samm-load-test.js changes how a request is built, change
 * it here too, or the two benchmarks stop sending comparable requests.
 *
 * Differences from the original:
 *   - processing_time subtracts the hold the server actually waits (Node
 *     truncates fractional setTimeout delays to whole ms), not the fractional
 *     value sent -- see scheduledHoldMs() below. The one change to the metric;
 *   - every request and processing_time sample carries tags (endpoint, plus
 *     whatever the scenario passes: phase, step, second), so analysis can
 *     split them;
 *   - the seed variable is SEED, because there is no schedule here to seed;
 *   - makeRng is copied from load-generator/traffic-models/markov-chain.js,
 *     which this folder does not import;
 *   - meanHoldMs() exposes the expected hold so scenarios can size their VUs.
 *
 * jitter.js and payload-sampler.js are imported unmodified.
 */

import http from 'k6/http';
import exec from 'k6/execution';
import { Counter, Trend } from 'k6/metrics';
import { SharedArray } from 'k6/data';

const { parseJitterParams, sampleHoldMs } = require('../../../load-generator/traffic-models/jitter.js');
const { parsePayloadCsv, buildPayloadSampler } = require('../../../load-generator/traffic-models/payload-sampler.js');

// ---------------------------------------------------------------------
// Configuration. Paths resolve relative to THIS file, so the defaults point
// at the repository's datasets/ from internal-validation/k6-scenarios/lib/.
// ---------------------------------------------------------------------

export const BASE_URL = __ENV.BASE_URL || 'http://localhost:3000';

const JITTER_PARAMS_PATH =
  __ENV.JITTER_PARAMS_PATH ||
  '../../../datasets/azure-trace-2019/processed/traffic-models/jitter_parameters.json';

const PAYLOAD_CSV_PATH =
  __ENV.PAYLOAD_CSV_PATH ||
  '../../../datasets/azure-trace-2019/processed/memory-models/memory_payload_allocations.csv';

const SEED = __ENV.SEED !== undefined && __ENV.SEED !== '' ? Number(__ENV.SEED) : undefined;

// Copied from samm-load-test.js (see the original for why each weight is what
// it is). Overridable as a JSON string via __ENV.ENDPOINT_WEIGHTS.
const DEFAULT_ENDPOINT_WEIGHTS = {
  cache: 0.25,
  fetch: 0.25,
  process: 0.25,
  ingest: 0.10,
  aggregate: 0.05,
  batch: 0.10,
};
const ENDPOINT_WEIGHTS = __ENV.ENDPOINT_WEIGHTS
  ? JSON.parse(__ENV.ENDPOINT_WEIGHTS)
  : DEFAULT_ENDPOINT_WEIGHTS;

// ---------------------------------------------------------------------
// Hold model -- copied from samm-load-test.js.
// ---------------------------------------------------------------------

const { mu, sigma } = parseJitterParams(open(JITTER_PARAMS_PATH));

// Multiplier on hold time, applied as a shift of mu (scales every draw, keeps
// the fitted shape). Live bytes = rate x hold x size, so this is the memory knob.
const HOLD_SCALE = Number(__ENV.HOLD_SCALE) || 1;
const muHold = mu + Math.log(HOLD_SCALE);

// ingest holds on the BASE Azure distribution at k = 1 (HOLD_SCALE / 4 = 1/k).
const INGEST_SCALE = HOLD_SCALE / 4;
const muIngest = mu + Math.log(INGEST_SCALE);

// process holds for a FIXED duration with a small jitter, as a fraction of it.
const PROCESS_HOLD_MS = Number(__ENV.PROCESS_HOLD_MS) || 600;
const PROCESS_HOLD_JITTER_FRAC = Number(__ENV.PROCESS_HOLD_JITTER_FRAC || 0.0333);
const PROCESS_HOLD_JITTER_MS = __ENV.PROCESS_HOLD_JITTER_MS !== undefined
  ? Number(__ENV.PROCESS_HOLD_JITTER_MS)
  : PROCESS_HOLD_MS * PROCESS_HOLD_JITTER_FRAC;

// ---------------------------------------------------------------------
// Payload sampler -- copied from samm-load-test.js. The CSV is parsed once,
// inside the SharedArray callback, and never copied into each VU.
// ---------------------------------------------------------------------

const sharedRows = new SharedArray('azure rows', function () {
  return parsePayloadCsv(open(PAYLOAD_CSV_PATH)).rows;
});

const headers = Object.keys(sharedRows[0]);
const percentileColumns = [];
for (const header of headers) {
  const match = header.match(/^payload_.*_pct(\d+)_mb$/);
  if (match) percentileColumns.push({ column: header, pct: Number(match[1]) });
}
percentileColumns.sort((a, b) => a.pct - b.pct);

const samplePayloadMb = buildPayloadSampler({
  rows: sharedRows,
  percentileColumns,
  hasSampleCount: headers.includes('SampleCount'),
});

// ---------------------------------------------------------------------
// Endpoint choice and per-iteration RNG -- copied from samm-load-test.js.
// ---------------------------------------------------------------------

const endpointNames = Object.keys(ENDPOINT_WEIGHTS);
const endpointCumulative = [];
{
  let running = 0;
  for (const name of endpointNames) {
    running += ENDPOINT_WEIGHTS[name];
    endpointCumulative.push({ name, cumulative: running });
  }
}

// Copied from load-generator/traffic-models/markov-chain.js (makeRng).
function makeRng(seed) {
  if (seed === undefined || seed === null) return Math.random;
  let state = seed >>> 0;
  return function rng() {
    state |= 0;
    state = (state + 0x6d2b79f5) | 0;
    let t = Math.imul(state ^ (state >>> 15), 1 | state);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function seedFor(rng) { return Math.floor(rng() * 2147483647); }

// Keyed on the iteration index within the scenario, not on __VU: iteration N
// draws the same endpoint, payload and hold on every run and under every
// allocator, so the comparison between configs is paired.
function iterationRng() {
  if (SEED === undefined) return Math.random;
  const idx = exec.scenario.iterationInTest;
  return makeRng((SEED ^ Math.imul(idx + 1, 0x9e3779b1)) >>> 0);
}

function pickEndpoint(rng) {
  const r = (rng || Math.random)() * endpointCumulative[endpointCumulative.length - 1].cumulative;
  for (const entry of endpointCumulative) {
    if (r <= entry.cumulative) return entry.name;
  }
  return endpointCumulative[endpointCumulative.length - 1].name;
}

// ---------------------------------------------------------------------
// processing_time -- copied from samm-load-test.js. http_req_duration minus
// the artificial hold: what the allocator and the server spend, not the
// simulated downstream wait.
// ---------------------------------------------------------------------

export const processingTime = new Trend('processing_time', true);

// Requests whose duration came out SHORTER than the hold that was subtracted,
// clamped to 0 in processing_time. Counted so their share is visible.
export const processingClamped = new Counter('processing_clamped');

// What the server actually waits. The held routes (fetch, ingest, process) hold
// with setTimeout(resolve, hold_ms), and Node truncates a non-integer delay to
// whole milliseconds (and waits 1 ms for anything below 1). k6 sends fractional
// hold_ms values, so subtracting the value that was SENT -- as samm-load-test.js
// does -- undercounts processing by up to 1 ms and clamps fast requests to 0:
// 13-25 % of held requests at 160-320 req/s in the 2026-10-03 run.
//
// DELIBERATE DEPARTURE from samm-load-test.js: subtract the delay Node actually
// schedules. That removes the systematic part. What remains is random and cannot
// be corrected from the client: libuv keeps time in whole milliseconds, so a
// wait can start up to 1 ms before setTimeout is called, and the event loop can
// fire it late. Residual negatives are still clamped, and counted above.
function scheduledHoldMs(holdMs) {
  const ms = Math.trunc(Number(holdMs));
  return ms >= 1 && ms <= 2147483647 ? ms : 1;
}

function recordProcessing(res, holdMs, tags) {
  const value = res.timings.duration - (holdMs ? scheduledHoldMs(holdMs) : 0);
  if (value < 0) processingClamped.add(1, tags);
  processingTime.add(Math.max(0, value), tags);
  return res;
}

const JSON_HEADERS = { 'Content-Type': 'application/json' };

function post(path, body, tags) {
  return http.post(`${BASE_URL}${path}`, body, { headers: JSON_HEADERS, tags });
}

// The six handlers, copied from samm-load-test.js. Request bodies and draw
// order are unchanged; the only addition is the tags argument.
function doCache(rng, tags) {
  return recordProcessing(post('/api/cache', null, tags), 0, tags);
}

function doFetch(rng, tags) {
  const holdMs = sampleHoldMs(muHold, sigma, rng);
  const payload = JSON.stringify({ hold_ms: holdMs });
  return recordProcessing(post('/api/fetch', payload, tags), holdMs, tags);
}

function doProcess(rng, tags) {
  const sizeMb = samplePayloadMb(rng);
  const holdMs = PROCESS_HOLD_MS + (rng() * 2 - 1) * PROCESS_HOLD_JITTER_MS;
  const payload = JSON.stringify({ size_mb: sizeMb, hold_ms: holdMs, rng_seed: seedFor(rng) });
  return recordProcessing(post('/api/process', payload, tags), holdMs, tags);
}

function doAggregate(rng, tags) {
  const sizeMb = samplePayloadMb(rng);
  const payload = JSON.stringify({ size_mb: sizeMb, rng_seed: seedFor(rng) });
  return recordProcessing(post('/api/aggregate', payload, tags), 0, tags);
}

function doIngest(rng, tags) {
  const holdMs = sampleHoldMs(muIngest, sigma, rng);
  const payload = JSON.stringify({ hold_ms: holdMs, rng_seed: seedFor(rng) });
  return recordProcessing(post('/api/ingest', payload, tags), holdMs, tags);
}

function doBatch(rng, tags) {
  const itemCount = Math.max(10, Math.min(2000, Math.round(samplePayloadMb(rng) * 2)));
  const payload = JSON.stringify({ item_count: itemCount, rng_seed: seedFor(rng) });
  return recordProcessing(post('/api/batch', payload, tags), 0, tags);
}

const ENDPOINT_HANDLERS = {
  cache: doCache,
  fetch: doFetch,
  process: doProcess,
  aggregate: doAggregate,
  batch: doBatch,
  ingest: doIngest,
};

/**
 * One iteration of the same request mix samm-load-test.js sends. `tags` are
 * added to the request's http_req_* metrics and to its processing_time sample.
 * Returns the endpoint and the response.
 */
export function runOneRequest(tags) {
  const rng = iterationRng();
  const endpoint = pickEndpoint(rng);
  const res = ENDPOINT_HANDLERS[endpoint](rng, Object.assign({}, tags, { endpoint }));
  return { endpoint, res };
}

/**
 * Expected hold per request, in ms, under the hold model above: log-normal
 * means for fetch and ingest, the fixed process hold, zero for the rest.
 * Little's law turns it into the concurrency a rate needs (rate x hold).
 */
export function meanHoldMs() {
  const total = endpointNames.reduce((sum, n) => sum + ENDPOINT_WEIGHTS[n], 0);
  const share = (n) => (ENDPOINT_WEIGHTS[n] || 0) / total;
  const lognormalMean = (m) => Math.exp(m + (sigma * sigma) / 2);
  return share('fetch') * lognormalMean(muHold)
    + share('ingest') * lognormalMean(muIngest)
    + share('process') * PROCESS_HOLD_MS;
}

/** The workload parameters this run used, for the summary file. */
export const WORKLOAD = {
  base_url: BASE_URL,
  seed: SEED === undefined ? null : SEED,
  hold_scale: HOLD_SCALE,
  process_hold_ms: PROCESS_HOLD_MS,
  endpoint_weights: ENDPOINT_WEIGHTS,
  mean_hold_ms: null, // filled in below, once meanHoldMs can run
};
WORKLOAD.mean_hold_ms = Math.round(meanHoldMs());
