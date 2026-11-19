#!/usr/bin/env bash
#
# record-reference.sh -- runbook Phase 3 on a new benchmark VM, the way
# samm-bench's reference was made on 2026-11-13: six reference probe runs
# before any benchmark, pooled (every run's microbenchmark rows together, the
# median k6 start-up), and the k6 limit set to 1.10x that median.
#
#   infra/record-reference.sh          (on the VM, from anywhere; about 30 min)
#
# Writes results/probe-reference-pooled/ (where infra/study.env's
# PROBE_REFERENCE points on every VM) and infra/study.local.env (untracked),
# which sources infra/study.env and overrides only K6_STARTUP_LIMIT_S;
# infra/vm.sh study uses it when present. Prints this VM's reference beside
# samm-bench's, so the machines can be compared.
set -euo pipefail
cd "${REPO_DIR:-$(dirname "$0")/..}"
N="${N:-6}"
export PROBE_CPU="${PROBE_CPU:-1}"
[ -e results/probe-reference-pooled ] && { echo "results/probe-reference-pooled exists already; not recording over it." >&2; exit 1; }

for i in $(seq 1 "$N"); do
  echo "== reference run $i of $N"
  internal-validation/host-probe.sh "results/probe-reference-$i" reference
done

mkdir -p results/probe-reference-pooled
cat results/probe-reference-[0-9]*/native.jsonl > results/probe-reference-pooled/native.jsonl
cat results/probe-reference-[0-9]*/v8.jsonl > results/probe-reference-pooled/v8.jsonl
python3 - "$N" <<'PY'
import glob, json, statistics as st, subprocess, sys, datetime
runs = sorted(glob.glob('results/probe-reference-[0-9]*'))
k6 = [float(open(f'{r}/k6_startup.txt').read().split()[1]) for r in runs]
med = st.median(k6)
open('results/probe-reference-pooled/k6_startup.txt', 'w').write(f'k6_startup_s {med:.1f}\n')
rows = [json.loads(l) for l in open('results/probe-reference-pooled/v8.jsonl') if l.strip().startswith('{')]
cell = lambda touch, f=lambda r: r['ns_per_alloc']: st.median(
    f(r) for r in rows if r['layer'] == 'v8' and r['trace'] == 'mix' and bool(r['touch']) == touch)
gc = cell(False, lambda r: r['gc_ms'] / r['gc_count'])
limit = round(1.10 * med)
bench = {'k6': 125.4, 'no touch': 7289.7, 'page writes': 12323.2, 'gc': 1.79}   # samm-bench, runbook Phase 3
mine = {'k6': med, 'no touch': cell(False), 'page writes': cell(True), 'gc': gc}
print(f"\nThis VM's reference ({len(runs)} runs pooled), beside samm-bench's:")
for k, unit in (('k6', 's'), ('no touch', 'ns'), ('page writes', 'ns'), ('gc', 'ms')):
    print(f"  {k:12s} {mine[k]:10.1f} {unit:2s}   samm-bench {bench[k]:10.1f}   ratio {mine[k] / bench[k]:.2f}")
print(f"  k6 start-up per run: {', '.join(f'{x:.1f}' for x in k6)} s; limit = 1.10 x {med:.1f} = {limit} s")
host = subprocess.run(['hostname'], capture_output=True, text=True).stdout.strip()
open('infra/study.local.env', 'w').write(
    f"# {host}: its own host-probe limit (runbook Phase 3), recorded "
    f"{datetime.datetime.utcnow():%Y-%m-%d %H:%M} UTC from {len(runs)} reference runs by infra/record-reference.sh.\n"
    f"# PROBE_REFERENCE is the same path as on samm-bench: results/probe-reference-pooled, this VM's own.\n"
    'source "$REPO_ROOT/infra/study.env"\n'
    f"K6_STARTUP_LIMIT_S={limit}\n")
print("-> results/probe-reference-pooled/, infra/study.local.env")
PY
