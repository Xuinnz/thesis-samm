'use strict';
/**
 * Decodes a real k6 v0.55 dashboard stream (test/fixtures, captured from a
 * 12-second probe run) and checks the positional arrays land on the right
 * metrics -- including that a stream which no longer lines up is REFUSED.
 *
 * Usage: node demo/test/k6dash_test.js
 */
const fs = require('fs');
const path = require('path');
const assert = require('assert');
const { parseFrames, decodeSnapshot, trendStats } = require('../k6dash');

const raw = fs.readFileSync(path.join(__dirname, 'fixtures', 'k6-dashboard-events.txt'), 'utf8');
const { frames } = parseFrames(raw);
assert.ok(frames.length > 10, 'the capture should split into frames');

const state = { metrics: {}, aggregates: null };
const snapshots = [];
for (const { event, data } of frames) {
  const body = JSON.parse(data);
  if (event === 'param') state.aggregates = body.aggregates;
  if (event === 'metric') Object.assign(state.metrics, body);
  if (event === 'snapshot') snapshots.push(body);
}
assert.ok(state.aggregates && state.aggregates.trend.includes('p(95)'), 'param must declare p(95)');
assert.ok(snapshots.length >= 3, 'the probe produced several windows');

// Every snapshot must decode, and each metric must have its type's width.
for (const snap of snapshots) {
  const d = decodeSnapshot(state, snap);
  assert.ok(d, 'a well-formed snapshot must decode');
  assert.strictEqual(d.http_req_duration.length, state.aggregates.trend.length);
  assert.strictEqual(d.http_reqs.length, state.aggregates.counter.length);
  assert.strictEqual(d.http_req_failed.length, state.aggregates.rate.length);
}

// Latency is latency: p95 <= p99 <= max, all positive, and the probe's
// /health calls are fast (sub-50 ms) -- a mis-indexed counter would be huge.
const d = decodeSnapshot(state, snapshots[1]);
const e2e = trendStats(state, d, 'http_req_duration');
const maxIdx = state.aggregates.trend.indexOf('max');
assert.ok(e2e.p95 > 0 && e2e.p95 <= e2e.p99, `p95 ${e2e.p95} should be <= p99 ${e2e.p99}`);
assert.ok(e2e.p99 <= d.http_req_duration[maxIdx] + 1e-9, 'p99 cannot exceed max');
assert.ok(e2e.p99 < 50, `probe latency should be tiny, got ${e2e.p99} ms`);
const alloc = trendStats(state, d, 'processing_time');
assert.ok(alloc.p95 !== null, 'the custom processing_time trend must be found by name');

// A stream that no longer lines up must be rejected, never guessed at.
assert.strictEqual(decodeSnapshot(state, snapshots[1].slice(1)), null, 'a missing array must be refused');
const shifted = snapshots[1].map((a) => a.slice());
shifted[0] = [1, 2, 3];                                  // a counter with a trend's shape
assert.strictEqual(decodeSnapshot(state, shifted), null, 'a wrong-width array must be refused');

// A metric with no samples in a window arrives as [] and must NOT sink the
// window. Captured from a probe whose counter only fired in its first 3 s.
{
  const sraw = fs.readFileSync(path.join(__dirname, 'fixtures', 'k6-dashboard-sporadic.txt'), 'utf8');
  const st = { metrics: {}, aggregates: null };
  let decoded = 0, empty = 0, total = 0;
  for (const { event, data } of parseFrames(sraw).frames) {
    const body = JSON.parse(data);
    if (event === 'param') st.aggregates = body.aggregates;
    if (event === 'metric') Object.assign(st.metrics, body);
    if (event === 'snapshot') {
      total++;
      const dd = decodeSnapshot(st, body);
      if (dd) decoded++;
      if (dd && dd.sporadic_events === null) empty++;
      if (dd) assert.ok(trendStats(st, dd, 'http_req_duration').p95 > 0, 'latency survives an empty sibling');
    }
  }
  assert.strictEqual(decoded, total, 'every window must decode, empty metrics included');
  assert.ok(empty >= 3, 'the quiet windows should report the sporadic counter as no-samples');
  console.log(`k6dash_test: sporadic capture -- ${decoded}/${total} windows decoded, ${empty} with an empty metric`);
}

console.log(`k6dash_test: ${snapshots.length} windows decoded; window p95 ${e2e.p95} ms, p99 ${e2e.p99} ms`);
