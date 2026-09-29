'use strict';
/**
 * The demo's load points: arrival rate scales by k and every hold by 1/k, so
 * live bytes (lambda x W) stay constant and only CPU pressure rises.
 *
 * Mirrors the k table in server/scripts/run_comparison.sh. Shared by the
 * collector (to start runs) and table.js (to recognise which of these the
 * routing table was characterized at).
 */
const LOAD = {
  '1.0': { MAX_RPS: 500,  PROCESS_HOLD_MS: 600, HOLD_SCALE: 4 },
  '1.5': { MAX_RPS: 750,  PROCESS_HOLD_MS: 400, HOLD_SCALE: 2.667 },
  '2.0': { MAX_RPS: 1000, PROCESS_HOLD_MS: 300, HOLD_SCALE: 2 },
  '2.5': { MAX_RPS: 1250, PROCESS_HOLD_MS: 240, HOLD_SCALE: 1.6 },
};

module.exports = { LOAD };
