#!/usr/bin/env bash
#
# then-poweroff.sh -- run a long job on the VM and power the VM off when it
# ends, whatever the outcome, so an overnight campaign stops costing money the
# minute it finishes. A powered-off VM is "stopped": the disk and everything on
# it stay. Start it again with infra/vm.sh start.
#
#   tmux new -s study
#   infra/then-poweroff.sh logs/main-study.log  env K=2.0 N=100 ... server/scripts/run_replicates.sh
#
# KEEP_ON=1 runs the job without powering off (for a job you will follow with
# another).
set -uo pipefail
log="${1:?usage: then-poweroff.sh <log file> <command...>}"; shift
mkdir -p "$(dirname "$log")"
echo "started $(date -u +%FT%TZ): $*" >> "$log"
"$@" >> "$log" 2>&1
rc=$?
echo "finished $(date -u +%FT%TZ) with exit $rc" >> "$log"
sync
if [ "${KEEP_ON:-0}" = "1" ]; then echo "KEEP_ON=1: not powering off" >> "$log"; exit 0; fi
echo "powering off in 60 s (cancel: sudo shutdown -c)" | tee -a "$log"
sudo shutdown -h +1
