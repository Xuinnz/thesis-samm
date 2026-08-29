'use strict';

/**
 * This file controls how much memory is allocated using memory_payload_allocations.csv from data preprocessing
 * It picks a percentile bucket, then pick a random number in between using linear interpolation.
 * This ensures that we can send request of highly varied, uneven sizes
 */


const { parseCsv, rowsToObjects } = require('./csv-utils.js');

const PERCENTILE_COLUMN_RE = /^payload_.*_pct(\d+)_mb$/;

/**
 * Parses memory_payload_allocations.csv (output of Script 3.1) and
 * detects whichever payload_*_pctN_mb columns are actually present,
 * so the sampler adapts automatically if the upstream script's
 * percentile set changes.
 */
function parsePayloadCsv(csvText) {
  const { headers, rows } = parseCsv(csvText);
  const objects = rowsToObjects(headers, rows);

  const percentileColumns = [];
  for (const header of headers) {
    const match = header.match(PERCENTILE_COLUMN_RE);
    if (match) {
      percentileColumns.push({ column: header, pct: Number(match[1]) });
    }
  }
  percentileColumns.sort((a, b) => a.pct - b.pct);

  if (percentileColumns.length === 0) {
    throw new Error(
      'parsePayloadCsv: no payload_*_pctN_mb columns found — check memory_payload_allocations.csv schema'
    );
  }

  const hasSampleCount = headers.includes('SampleCount');

  return { rows: objects, percentileColumns, hasSampleCount };
}

/**
 * Builds the bucket-probability table shared by all rows: the
 * cumulative probability of each detected percentile anchor, plus an
 * implicit (p=0, value=0) anchor to allow interpolation below the
 * lowest available percentile column.
 *
 * Returns [{ p: 0, column: null }, { p: 0.01, column: 'payload_..._pct1_mb' }, ...]
 */
function buildAnchorTable(percentileColumns) {
  const anchors = [{ p: 0, column: null }];
  for (const { column, pct } of percentileColumns) {
    anchors.push({ p: pct / 100, column });
  }
  return anchors;
}

/**
 * Builds a weighted cumulative-distribution index over rows for O(log n)
 * weighted selection. If `hasSampleCount` is false, falls back to a
 * uniform weight per row (documented explicitly — see README note
 * in the k6 scenario file about SampleCount not currently being
 * carried through Script 3.1's output).
 */
function buildRowSelector(rows, hasSampleCount) {
  const weights = rows.map((row) => {
    if (hasSampleCount) {
      const w = Number(row.SampleCount);
      return Number.isFinite(w) && w > 0 ? w : 0;
    }
    return 1;
  });

  const totalWeight = weights.reduce((a, b) => a + b, 0);
  const cumulative = [];
  let running = 0;
  for (const w of weights) {
    running += w;
    cumulative.push(running);
  }

  return function selectRowIndex(rng) {
    if (cumulative.length === 0) {
      throw new Error('selectRowIndex: cumulative weight table is empty — no rows to select from.');
    }
    if (totalWeight <= 0) {
      // All weights were zero/invalid (e.g. every SampleCount was 0 or
      // missing). Fall back to a uniform pick across all rows rather
      // than dividing by a zero totalWeight.
      return Math.floor(rng() * cumulative.length);
    }

    const rand = rng() * totalWeight;
    // Binary search for the first cumulative value >= rand
    let lo = 0;
    let hi = cumulative.length - 1;
    while (lo < hi) {
      const mid = (lo + hi) >> 1;
      if (cumulative[mid] < rand) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  };
}

/**
 * Builds a payload-size sampler function from parsed CSV data.
 *
 * Sampling procedure per call:
 *   1. Select an app row (weighted by SampleCount if available,
 *      otherwise uniform across all rows).
 *   2. Select a percentile bucket uniformly at random by cumulative
 *      probability mass (e.g. the P75-P95 bucket has 20% mass).
 *   3. Linearly interpolate a value within that bucket's [lower,
 *      upper] anchor values for the selected row.
 *
 * Returns a function sampleSizeMb(rng) -> number.
 */
function buildPayloadSampler(parsed) {
  const { rows, percentileColumns, hasSampleCount } = parsed;

  if (!rows || rows.length === 0) {
    throw new Error(
      'buildPayloadSampler: no app rows were parsed from the payload CSV. ' +
      'Check that the file has data rows beyond the header, and that ' +
      'parseCsv/rowsToObjects successfully split them.'
    );
  }

  const anchors = buildAnchorTable(percentileColumns);
  const selectRowIndex = buildRowSelector(rows, hasSampleCount);

  return function sampleSizeMb(rng) {
    const randomFn = rng || Math.random;
    const rowIdx = selectRowIndex(randomFn);
    const row = rows[rowIdx];

    if (!row) {
      console.log('CRASH DEBUG -> rowIdx:', rowIdx, 'rows.length:', rows.length, 'typeof rows:', typeof rows, 'Array.isArray(rows):', Array.isArray(rows));
    }

    // Pick a bucket boundary pair (anchors[i-1], anchors[i]) by
    // cumulative probability mass.
    const r = randomFn();
    let i = 1;
    while (i < anchors.length && anchors[i].p < r) {
      i += 1;
    }
    if (i >= anchors.length) i = anchors.length - 1;

    const lowerAnchor = anchors[i - 1];
    const upperAnchor = anchors[i];

    const lowerValue = lowerAnchor.column === null ? 0 : Number(row[lowerAnchor.column]);
    const upperValue = Number(row[upperAnchor.column]);

    if (!Number.isFinite(lowerValue) || !Number.isFinite(upperValue) || upperValue <= lowerValue) {
      // Degenerate row (e.g. missing/zero payload data) — fall back
      // to the upper anchor value rather than interpolating garbage.
      return Number.isFinite(upperValue) ? upperValue : 1;
    }

    const fraction = randomFn();
    return lowerValue + fraction * (upperValue - lowerValue);
  };
}

module.exports = {
  parsePayloadCsv,
  buildAnchorTable,
  buildRowSelector,
  buildPayloadSampler,
};