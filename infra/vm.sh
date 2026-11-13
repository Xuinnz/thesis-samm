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
  delete)
    read -r -p "Delete $NAME and its disk, with everything on it? Type the VM name to confirm: " answer
    [ "$answer" = "$NAME" ] || { echo "not deleted"; exit 1; }
    "${G[@]}" instances delete "$NAME" --zone "$ZONE" --quiet
    ;;
  *) sed -n '3,18p' "$0"; exit 2 ;;
esac
