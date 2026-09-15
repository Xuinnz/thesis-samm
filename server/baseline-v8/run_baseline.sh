#!/usr/bin/env bash
#
# run_baseline.sh — one benchmark cycle of the CONTROL condition.
#
# Standard Node.js microservice relying on V8's default garbage collector.
#
# Every container limit, traffic parameter and metric-capture step lives in
# _bench-lib.sh and is shared verbatim with run_samm.sh, so the two conditions
# cannot drift apart. Run them together via run_comparison.sh, which exports one
# shared configuration for both; running this script directly uses the same
# defaults and is equally valid for a standalone cycle.
#
# Usage:
#   ./run_baseline.sh
#   SIMULATION_MINUTES=10 MAX_RPS=80 ./run_baseline.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/_bench-lib.sh
source "$SCRIPT_DIR/../scripts/_bench-lib.sh"

run_condition \
    "baseline" \
    "docker/baseline-environment/Dockerfile" \
    "samm-baseline:bench" \
    "samm-bench-baseline"
