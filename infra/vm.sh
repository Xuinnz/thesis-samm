#!/usr/bin/env bash
#
# vm.sh -- the benchmark VM, from the laptop (needs the gcloud CLI, logged in).
#
#   infra/vm.sh create     one on-demand t2d-standard-4, Ubuntu 24.04, 100 GB disk
#   infra/vm.sh start      start it again after a stop
#   infra/vm.sh stop       stop it (compute billing ends; the disk is still billed)
#   infra/vm.sh status     RUNNING / TERMINATED, and its external address
#   infra/vm.sh ssh        open a shell on it
#   infra/vm.sh fetch DIR  copy ~/samm-final/DIR from the VM into ./vm-results/
#   infra/vm.sh update     git pull on the VM (refuses while anything is running there)
#   infra/vm.sh study CMD  start server/scripts/study.sh CMD on the VM, detached; the VM
#                          powers off when it ends (CMD: pilot, main, gc, extra-mem 2048m,
#                          extra-mem 4096m, extra-weeks, extra-sat 2048m). Prints the first lines of its log.
#   infra/vm.sh wait       block until the VM is off (at most WAIT_MINUTES, default 25)
#   infra/vm.sh delete     delete the VM AND ITS DISK (asks first)
#
# Settings (environment): GCP_PROJECT (required), GCP_ZONE (default
# us-central1-a), VM_NAME (default samm-bench).
#
# On-demand, not spot: a preempted 10-minute run is a wasted run. A stopped VM
# may come back on different hardware, so the host probe runs after every start.
set -euo pipefail

PROJECT="${GCP_PROJECT:?set GCP_PROJECT to your Google Cloud project id}"
ZONE="${GCP_ZONE:-us-central1-a}"
NAME="${VM_NAME:-samm-bench}"
G=(gcloud compute --project "$PROJECT")

case "${1:-}" in
  create)
    # MIGRATE: Google live-migrates the VM during host maintenance instead of
    # stopping it. A migration stalls the VM briefly; the runbook says to note
    # such events and discard the run they land in.
    "${G[@]}" instances create "$NAME" --zone "$ZONE" \
      --machine-type t2d-standard-4 \
      --image-family ubuntu-2404-lts-amd64 --image-project ubuntu-os-cloud \
      --boot-disk-size 100GB --boot-disk-type pd-balanced \
      --provisioning-model STANDARD --maintenance-policy MIGRATE
    echo "Created. Next: infra/vm.sh ssh, then run infra/provision.sh on the VM."
    ;;
  start)  "${G[@]}" instances start "$NAME" --zone "$ZONE" ;;
  stop)   "${G[@]}" instances stop "$NAME" --zone "$ZONE" ;;
  status) "${G[@]}" instances describe "$NAME" --zone "$ZONE" \
            --format 'value(status,machineType.basename(),networkInterfaces[0].accessConfigs[0].natIP)' ;;
  ssh)    shift; "${G[@]}" ssh "$NAME" --zone "$ZONE" "$@" ;;
  fetch)
    dir="${2:?usage: infra/vm.sh fetch <directory under ~/samm-final on the VM>}"
    mkdir -p vm-results
    "${G[@]}" scp --recurse --zone "$ZONE" "$NAME:~/samm-final/$dir" vm-results/
    ;;
  update)
    # Never while a run is in progress: the run's scripts would change under it.
    "${G[@]}" ssh "$NAME" --zone "$ZONE" --command 'cd ~/samm-final &&
      if [ -n "$(docker ps -q)" ] || ! flock -n results/.study.lock true || pgrep -f "[r]un_replicates.sh|[i]nternal-validation/run.sh|[h]ost-probe.sh" >/dev/null; then
        echo "REFUSED: something is running on the VM. Wait for it (infra/vm.sh wait)."; exit 1; fi
      git status -sb | head -5 && git pull --ff-only && git log -1 --format="now at %h %s"'
    ;;
  study)
    shift
    case "${1:-}" in
      pilot|gc)    deadman=240 ;;
      main)        deadman=3600 ;;
      extra-mem)   deadman=900 ;;
      extra-weeks) deadman=1500 ;;
      extra-sat)   deadman=900 ;;
      extra-mem-k) deadman=900 ;;
      *) echo "usage: infra/vm.sh study <pilot | main | gc | extra-mem 2048m | extra-mem 4096m | extra-mem-k 4096m 3.0 | extra-weeks | extra-sat 2048m>"; exit 2 ;;
    esac
    log="results/study-$(echo "$*" | tr ' ' '-')-$(date -u +%Y%m%d-%H%M).log"
    # The shutdown timer is a backstop for a hang; then-poweroff.sh powers the
    # VM off itself when the job ends, whatever its outcome.
    # Checked here, before then-poweroff.sh is started: a second launch that
    # was refused later would still power the VM off under the first one.
    # (study.sh holds results/.study.lock for as long as it runs.)
    "${G[@]}" ssh "$NAME" --zone "$ZONE" --command "cd ~/samm-final && mkdir -p results &&
      if ! flock -n results/.study.lock true || pgrep -f '[r]un_replicates.sh|[i]nternal-validation/run.sh' >/dev/null; then
        echo 'REFUSED: a run is already in progress on the VM.'; exit 1; fi
      sudo shutdown -h +$deadman >/dev/null 2>&1
      (setsid nohup infra/then-poweroff.sh $log server/scripts/study.sh $* > /dev/null 2>&1 < /dev/null &)
      sleep 25; echo \"log: ~/samm-final/$log\"; tail -n 30 $log"
    ;;
  wait)
    # Only asks Google for the VM's state: nothing runs on the VM itself.
    end=$((SECONDS + ${WAIT_MINUTES:-25} * 60))
    until [ "$("${G[@]}" instances describe "$NAME" --zone "$ZONE" --format 'value(status)')" = "TERMINATED" ]; do
      [ "$SECONDS" -lt "$end" ] || { echo "still running at $(date -u +%H:%M) UTC"; exit 1; }
      sleep 60
    done
    echo "VM is off ($(date -u +%H:%M) UTC)"
    ;;
  delete)
    read -r -p "Delete $NAME and its disk, with everything on it? Type the VM name to confirm: " answer
    [ "$answer" = "$NAME" ] || { echo "not deleted"; exit 1; }
    "${G[@]}" instances delete "$NAME" --zone "$ZONE" --quiet
    ;;
  *) sed -n '3,23p' "$0"; exit 2 ;;
esac
