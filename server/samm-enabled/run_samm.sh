#!/usr/bin/env bash
#
# run_samm.sh — one benchmark cycle of the EXPERIMENTAL condition.
#
# Identical microservice, with managed allocations routed through the Zig
# sidecar allocator instead of the V8 heap.
#
# Every container limit, traffic parameter and metric-capture step lives in
# _bench-lib.sh and is shared verbatim with run_baseline.sh, so the two
# conditions cannot drift apart. Run them together via run_comparison.sh, which
# exports one shared configuration for both; running this script directly uses
# the same defaults and is equally valid for a standalone cycle.
#
# SAMM-specific knobs (both default to the values used for the headline metric):
#   SAMM_RECLAIM_POLICY  none | dontneed | free   (default: none)
#   SAMM_WARMUP          true | false             (default: false)
#
# Warmup is off by default on purpose. It faults in every stratum's guaranteed
# floor whether or not the traffic touches it, which reports the allocator's
# reservation rather than its demand — the opposite of what Peak RSS measures.
#
# Usage:
#   ./run_samm.sh
#   SAMM_RECLAIM_POLICY=dontneed ./run_samm.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../scripts/_bench-lib.sh
source "$SCRIPT_DIR/../scripts/_bench-lib.sh"

run_condition \
    "samm" \
    "docker/samm-environment/Dockerfile" \
    "samm-enabled:bench" \
    "samm-bench-samm" \
    -e SAMM_ALLOCATOR_ENABLED=true \
    -e SAMM_RECLAIM_POLICY="${SAMM_RECLAIM_POLICY:-none}" \
    -e SAMM_WARMUP="${SAMM_WARMUP:-false}"
