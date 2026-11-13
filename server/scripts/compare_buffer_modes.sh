#!/usr/bin/env bash
#
# compare_buffer_modes.sh -- SAMM with SAMM_BUFFER_MODE=detach against chunk, at
# one load point, on the same seeds (runbook Phase 5, step 4).
#
# Each replicate runs both modes on one seed, and the mode that goes first
# alternates, so drift in the host lands on both alike. It drives
# run_replicates.sh one replicate at a time, which skips finished runs, so an
# interrupted comparison resumes where it stopped.
#
# Usage:
#   K=2.0 N=10 server/scripts/compare_buffer_modes.sh
#   K=2.0 N=10 SUMMARY_ONLY=1 server/scripts/compare_buffer_modes.sh
#
# Seeds come from their own base (default 20261200), apart from the main
# study's, so no main-study seed is seen before the study.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
K="${K:?set K to the locked load factor, e.g. K=2.0}"
N="${N:-10}"
SEED_BASE="${SCHEDULE_SEED:-20261200}"
OUT="$(realpath -m "${RESULTS_DIR:-$REPO_ROOT/benchmark-results/buffer-modes-k$K}")"
PYTHON_BIN="${PYTHON_BIN:-$([ -x "$REPO_ROOT/venv/bin/python3" ] && echo "$REPO_ROOT/venv/bin/python3" || echo python3)}"

if [ "${SUMMARY_ONLY:-0}" != "1" ]; then
  for n in $(seq 1 "$N"); do
    if [ $((n % 2)) -eq 1 ]; then order="detach chunk"; else order="chunk detach"; fi
    for mode in $order; do
      echo "=== replicate $n/$N, mode $mode"
      K="$K" N="$n" CONDITIONS=samm SAMM_BUFFER_MODE="$mode" SCHEDULE_SEED="$SEED_BASE" \
        RESULTS_DIR="$OUT/$mode" "$SCRIPT_DIR/run_replicates.sh" > "$OUT-$mode-last.log" 2>&1 \
        || echo "    run_replicates exited non-zero (see $OUT-$mode-last.log)"
      grep -E "Container ended|r[0-9]+ samm:" "$OUT-$mode-last.log" | tail -2 || true
    done
  done
fi

"$PYTHON_BIN" - "$OUT" <<'PY'
import glob, json, os, statistics as st, sys
out = sys.argv[1]
def load(mode):
    rows = {}
    for p in sorted(glob.glob(os.path.join(out, mode, 'r*-samm.json'))):
        r = json.load(open(p))
        a_path = p.replace('.json', '-allocator.json')
        a = json.load(open(a_path)) if os.path.exists(a_path) else {}
        a = a.get('allocator', a) or {}
        ended = (r.get('container_end_state') or {}).get('status')
        r['_died'] = r['cpu_utilisation_pct'] == 0.0 or r['oom_kills'] > 0 or r['failed_rate'] > 0.05 or ended not in (None, 'running', 'unknown')
        r['_cpu_ms'] = r['cpu_utilisation_pct'] / 100 * r['window_secs'] * 1000 / max(1, r['requests'])
        allocs = a.get('regionReclaimed', 0) + a.get('capacityFallbacks', 0)
        r['_fallback_pct'] = 100 * a.get('capacityFallbacks', 0) / allocs if allocs else None
        rows[os.path.basename(p)[:3]] = r
    return rows
modes = {m: load(m) for m in ('detach', 'chunk')}
if not any(modes.values()):
    sys.exit(f'no results yet in {out}')
metrics = [('throughput, req/s', 'throughput_rps', 1), ('CPU per request, ms', '_cpu_ms', 3), ('processing p99, ms', 'processing_p99_ms', 1),
           ('processing p95, ms', 'processing_p95_ms', 1), ('peak memory, MiB', 'peak_rss_mb', 1), ('fallback share, %', '_fallback_pct', 3),
           ('dropped iterations', 'dropped_iterations', 0)]
def ci(v):
    if len(v) < 2: return f"{v[0]:.3f}" if v else '-'
    return f"{st.mean(v):.3f} ±{1.96 * st.stdev(v) / len(v) ** 0.5:.3f}"
print('=' * 92)
print(f" SAMM buffer modes, {out}")
print('=' * 92)
for m, rows in modes.items():
    alive = [r for r in rows.values() if not r['_died']]
    print(f" {m:7} runs {len(rows):2}, survived {len(alive):2}, timing-suspect {sum(r.get('timing_suspect', False) for r in rows.values())}")
print(f"\n {'metric (mean ±95% CI, surviving runs)':40}{'detach':>20}{'chunk':>20}{'chunk vs detach, same seed':>30}")
for name, key, _ in metrics:
    cols = []
    for m in ('detach', 'chunk'):
        cols.append(ci([r[key] for r in modes[m].values() if not r['_died'] and r.get(key) is not None]))
    both = [k for k in modes['detach'] if k in modes['chunk'] and not modes['detach'][k]['_died'] and not modes['chunk'][k]['_died']
            and modes['detach'][k].get(key) is not None and modes['chunk'][k].get(key) is not None]
    d = [modes['chunk'][k][key] - modes['detach'][k][key] for k in both]
    base = st.mean(modes['detach'][k][key] for k in both) if both else 0
    diff = (f"{st.mean(d):+.3f} ({100 * st.mean(d) / base:+.1f}%), {sum(x > 0 for x in d)}/{len(d)} higher" if d and base else '-')
    print(f" {name:40}{cols[0]:>20}{cols[1]:>20}{diff:>30}")
print("\n The last column pairs the two modes on each seed: the mean difference, and in how many")
print(" of the pairs chunk's value was the higher one.")
PY
