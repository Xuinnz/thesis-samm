'use strict';

/**
 * Verifies that the compiled routing table was fit against the workload this
 * process is about to run.
 *
 * The table encodes per-call-site quotas derived from one characterization. Run
 * it against a different workload and every quota is wrong in a way that still
 * produces plausible-looking numbers -- which is how a benchmark ends up
 * measuring a model fit to a workload that never existed. Refusing to boot is
 * the cheaper failure.
 */

const fs = require('fs');
const path = require('path');

const SIDECAR = path.join(__dirname, 'workload_fingerprint.json');

function verifyWorkload(current, { strict = true } = {}) {
  if (!fs.existsSync(SIDECAR)) {
    console.warn('[samm] WARNING: no workload_fingerprint.json beside the table. '
      + 'Cannot verify the table matches this workload.');
    return { ok: true, verified: false };
  }
  const compiled = JSON.parse(fs.readFileSync(SIDECAR, 'utf8'));
  if (compiled.fingerprint === 'unknown') {
    console.warn('[samm] WARNING: table carries fingerprint "unknown" — it was '
      + 'compiled without a workload manifest.');
    return { ok: true, verified: false };
  }
  if (compiled.fingerprint === current.fingerprint) {
    return { ok: true, verified: true, fingerprint: current.fingerprint };
  }

  const diffs = [];
  const keys = new Set([...Object.keys(compiled.parameters || {}),
                        ...Object.keys(current.parameters || {})]);
  for (const k of [...keys].sort()) {
    const a = (compiled.parameters || {})[k];
    const b = (current.parameters || {})[k];
    if (a !== b) diffs.push(`    ${k}: table=${a}  running=${b}`);
  }

  const msg = [
    '',
    '='.repeat(72),
    'WORKLOAD MISMATCH — refusing to start.',
    '',
    `  table was compiled for : ${compiled.fingerprint}`,
    `  this process would run : ${current.fingerprint}`,
    '',
    '  differing parameters:',
    ...(diffs.length ? diffs : ['    (fingerprint differs but no parameter diff — check the hash inputs)']),
    '',
    '  The routing table sizes every arena from concurrency observed during',
    '  characterization. Serving a different workload makes those quotas wrong',
    '  while still producing numbers that look like allocator behaviour.',
    '',
    '  Re-run characterization with these settings, or set the settings to match',
    '  the table. Set SAMM_ALLOW_WORKLOAD_MISMATCH=true to override (the result',
    '  is not a valid measurement of the allocator).',
    '='.repeat(72),
    '',
  ].join('\n');

  if (!strict) { console.warn(msg); return { ok: true, verified: false, mismatch: true }; }
  console.error(msg);
  return { ok: false, verified: false, mismatch: true };
}

module.exports = { verifyWorkload };
