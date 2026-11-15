#!/usr/bin/env bash
#
# study.sh -- the thesis's remaining runs, one command each (runbook Phases
# 9-11). Every command checks the machine first, takes its settings from
# infra/study.env and nowhere else, and is resumable: run the same command
# again after an interruption and it continues.
#
#   study.sh preflight            check the machine and the repository, run nothing
#   study.sh pilot                Phase 9.1: 2 replicates, end to end (about 1 h)
#   study.sh main                 Phase 9.2: the main study, n = 100 (about 42 h)
#   study.sh gc                   Phase 9.3: 3 replicates with the GC observer on (about 1.3 h)
#   study.sh extra-mem 2048m      Phase 10a: retrain for a 2 GB container, beta, 15 replicates (about 8 h)
#   study.sh extra-mem 4096m      the same for 4 GB
#   study.sh extra-weeks          Phase 10b: train on days 1-7, test on days 1-7 and 8-14 (about 14 h)
#   study.sh stats                Phase 11: integrity, statistics, figures for everything that exists
#   study.sh status               what has been run so far
#
# On the VM, start a run from the laptop with `infra/vm.sh study <command>`: it
# runs detached and the VM powers off when it ends.
#
# What a run does: preflight -> run_replicates.sh (campaign lock, host probe
# before the first replicate, every PROBE_EVERY-th and at the end) ->
# verify_campaign.py -> main_study_stats.py -> main_study_figures.py.
#
# What it refuses to do, on purpose:
#   - run with uncommitted changes to anything the measured system is built from;
#   - run the main study anywhere but on branch main;
#   - add runs to a folder whose settings differ from the ones it was started with;
#   - apply a beta from a run that died, or go on when the confirming run asks
#     for a SMALLER pool than the one applied (the method iterates once; a
#     second iteration is a decision for a person, not for a script).
# When it refuses it says why and exits non-zero. Do not work around a refusal:
# read it.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=../../infra/study.env
source "${STUDY_ENV_FILE:-$REPO_ROOT/infra/study.env}"
export CPUSET_CPUS K6_TASKSET PROBE_CPU PROBE_REFERENCE K6_STARTUP_LIMIT_S PROBE_EVERY SAMM_BUFFER_MODE
# Left over in a shell, any of these would quietly change what is measured.
unset MEM_LIMIT TRAFFIC_BATCH SAMM_TELEMETRY SAMM_SEGMENT_REUSE SAMM_BETA_UTILIZATION SAMM_CONTAINER_BYTES \
      ROTATE VARY_SEED CONDITIONS SCHEDULE_SEED RESULTS_DIR K N DRY_RUN SUMMARY_ONLY CAMPAIGN_ALLOW_CHANGE \
      POLL_SAMM_STATS SAMM_ALLOW_CONTAINER_MISMATCH 2>/dev/null || true
# STUDY_MINUTES shortens every run. It exists for rehearsing this script on a
# laptop; a folder made with it is locked to it and cannot be mixed with real runs.
[ -n "${STUDY_MINUTES:-}" ] && export SIMULATION_MINUTES="$STUDY_MINUTES" || unset SIMULATION_MINUTES

PY="$REPO_ROOT/venv/bin/python3"
STATS="$REPO_ROOT/stats-eval/hypothesis-testing"
RESULTS="$REPO_ROOT/benchmark-results"
MAIN_DIR="$RESULTS/main-study"
CONDS="jemalloc samm"

say()  { echo; echo "=== $* ==="; }
fail() { echo "REFUSED: $*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
# preflight <branch the command must be on, or "any"> [dirty-ok]
# dirty-ok: an extra's table is being built on its branch and is not committed yet.
preflight() {
  local want_branch="$1" dirty_ok="${2:-}" problems=0 branch
  note() { echo "  PROBLEM: $*"; problems=$((problems + 1)); }
  say "Preflight"
  for tool in docker k6 node git numfmt curl; do
    command -v "$tool" >/dev/null 2>&1 || note "$tool is not installed"
  done
  [ -x "$PY" ] && "$PY" -c 'import scipy, numpy, matplotlib' 2>/dev/null \
    || note "venv/bin/python3 with scipy, numpy and matplotlib is missing (python3 -m venv venv && venv/bin/pip install -r requirements.txt)"
  docker info >/dev/null 2>&1 || note "the Docker daemon is not reachable"
  [ -z "$(docker ps -q 2>/dev/null)" ] || note "containers are running: $(docker ps --format '{{.Names}}' | tr '\n' ' ')(one experiment at a time)"
  if ss -ltn 2>/dev/null | grep -q ":${HOST_PORT:-3000} "; then note "port ${HOST_PORT:-3000} is in use"; fi
  if pgrep -f "[r]un_replicates.sh|[i]nternal-validation/run.sh|[h]ost-probe.sh" >/dev/null 2>&1; then
    note "another benchmark or probe is running on this machine"
  fi
  [ -d "$PROBE_REFERENCE" ] || note "no host-probe reference at $PROBE_REFERENCE (runbook Phase 3)"
  local free_gb; free_gb=$(df -BG --output=avail "$REPO_ROOT" | tail -1 | tr -dc '0-9')
  [ "${free_gb:-0}" -ge 5 ] || note "only ${free_gb:-?} GB of disk free"
  branch=$(git rev-parse --abbrev-ref HEAD)
  if [ "$want_branch" != "any" ] && [ "$branch" != "$want_branch" ]; then
    note "on branch '$branch'; this command runs on '$want_branch' (git switch $want_branch)"
  fi
  if [ "$dirty_ok" != "dirty-ok" ] && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    note "tracked files have uncommitted changes:"; git status --porcelain --untracked-files=no | sed 's/^/      /'
  fi
  local cores; cores=$(nproc)
  [ "${CPUSET_CPUS##*[,-]}" -lt "$cores" ] && [ "${K6_TASKSET##*[,-]}" -lt "$cores" ] \
    || note "pinning (server $CPUSET_CPUS, k6 $K6_TASKSET) does not fit this machine's $cores cores"
  echo "  branch $branch at $(git rev-parse --short HEAD); table $(sha256sum zig-allocator/src/routing-table/model_weights.zig | cut -c1-12);" \
       "k = $STUDY_K; buffer mode $SAMM_BUFFER_MODE; server on core $CPUSET_CPUS, k6 on $K6_TASKSET; probe every $PROBE_EVERY replicates"
  [ "$problems" -eq 0 ] || fail "$problems problem(s) above. Nothing was run."
  echo "  ok"
}

# The main study's table is whatever campaign.json says it ran with; once the
# main study has started, nothing on branch main may run with another.
check_main_table() {
  [ -f "$MAIN_DIR/campaign.json" ] || return 0
  local want have
  want=$("$PY" -c "import json,sys; print(json.load(open(sys.argv[1]))['locked']['routing_table_sha256'])" "$MAIN_DIR/campaign.json")
  have=$(sha256sum zig-allocator/src/routing-table/model_weights.zig | cut -d' ' -f1)
  [ "$want" = "$have" ] || fail "branch main's routing table (${have:0:12}) is not the one the main study started with (${want:0:12})."
}

# ------------------------------------------------------------ run + analyse
# campaign <results dir> <n> <base seed> [NAME=value ...]: the runs, then integrity, statistics, figures.
campaign() {
  local dir="$1" n="$2" seed="$3"; shift 3
  say "Runs: $(basename "$dir") (n = $n, seeds $((seed + 1))..$((seed + n)))"
  env "$@" K="$STUDY_K" N="$n" CONDITIONS="$CONDS" SCHEDULE_SEED="$seed" RESULTS_DIR="$dir" REQUIRE_CLEAN=1 \
    "$SCRIPT_DIR/run_replicates.sh"
  analyse "$dir" "$n" || exit 1
}

# analyse <results dir> [n the campaign must have]
analyse() {
  local dir="$1" n="${2:-}"
  say "Statistics: $(basename "$dir")"
  "$PY" "$STATS/main_study_stats.py" "$dir" --with-paired ${n:+--expect-n "$n"} \
       --duration-s "$(( ${SIMULATION_MINUTES:-10} * 60 ))" \
    || { echo "The statistics did not run for $dir (see above). The runs themselves are kept." >&2; return 1; }
  "$PY" "$STATS/main_study_figures.py" "$dir" || echo "  (figures failed; the statistics above stand)"
}

# ------------------------------------------------------------------ extras
# One beta pass: beta_pass <results dir> [NAME=value ...]. Prints the beta the run gives.
beta_pass() {
  local dir="$1"; shift
  if [ ! -f "$dir/r01-samm.json" ]; then
    env "$@" K="$STUDY_K" N=1 CONDITIONS=samm POLL_SAMM_STATS=1 SCHEDULE_SEED="$BETA_SEED" RESULTS_DIR="$dir" \
      "$SCRIPT_DIR/run_replicates.sh" >&2
  fi
  "$PY" - "$dir/r01-samm.json" >&2 <<'PY' || fail "the beta pass in $dir did not survive: its memory is not a sound basis for beta."
import json, sys
r = json.load(open(sys.argv[1]))
ended = (r.get("container_end_state") or {}).get("status")
dead = r["cpu_utilisation_pct"] == 0.0 or r["oom_kills"] > 0 or r["failed_rate"] > 0.05 or ended not in (None, "running", "unknown")
print(f"  beta pass: peak {r['peak_rss_mb']} MB of {r['mem_limit_mb']} MB, failed {100 * r['failed_rate']:.2f} %, "
      f"container {ended}" + (" -- DIED" if dead else ""))
sys.exit(1 if dead else 0)
PY
  "$PY" "$SCRIPT_DIR/derive_beta.py" "$dir/r01-samm-samm-stats.jsonl" >&2
  "$PY" "$SCRIPT_DIR/derive_beta.py" "$dir/r01-samm-samm-stats.jsonl" --json
}

# extra_table <branch> <label> <commit message> [NAME=value ...]
# On its own branch: profile and retrain under the variant's settings, derive
# beta as in Phase 6 (measure, recompile, confirm), commit the table there.
extra_table() {
  local branch="$1" label="$2" message="$3"; shift 3
  local state="$RESULTS/extras-state/$label" current beta beta2 json
  mkdir -p "$state"
  current=$(git rev-parse --abbrev-ref HEAD)
  if [ "$current" = "main" ]; then
    check_main_table
    if git show-ref --verify --quiet "refs/heads/$branch"; then git switch "$branch"; else git switch -c "$branch"; fi
  elif [ "$current" != "$branch" ]; then
    fail "on branch '$current'. Start this from main (or from $branch, to resume)."
  fi
  git config user.name >/dev/null && git config user.email >/dev/null \
    || fail "git has no user.name / user.email here, so the table cannot be committed on $branch."
  if [ -f "$state/table.committed" ]; then
    echo "  the table for $label is already committed on $branch (beta $(cat "$state/beta.txt"))"
    return 0
  fi

  if [ ! -f "$state/pipeline.done" ]; then
    say "$label: profile, retrain, compile, test (about 16 min)"
    env "$@" SKIP_BENCHMARK=1 "$SCRIPT_DIR/run_full_pipeline.sh"
    touch "$state/pipeline.done"
  fi
  if [ ! -f "$state/beta.txt" ]; then
    say "$label: beta pass 1"
    json=$(beta_pass "$RESULTS/beta-$label-pass1" "$@")
    beta=$("$PY" -c "import json,sys; b=json.loads(sys.argv[1])['beta_to_apply']; print('' if b is None else b)" "$json")
    [ -n "$beta" ] || fail "pass 1 gives a beta of zero or less: the pool cannot be sized from this run."
    say "$label: recompile with beta = $beta"
    SAMM_BETA_UTILIZATION="$beta" bash "$REPO_ROOT/ml-refinery/run_ml_refinery.sh"
    (cd "$REPO_ROOT/zig-allocator" && zig build test --summary all)
    echo "$beta" > "$state/beta.txt"
  fi
  beta=$(cat "$state/beta.txt")
  say "$label: beta pass 2 (confirm beta = $beta)"
  json=$(beta_pass "$RESULTS/beta-$label-pass2" "$@")
  beta2=$("$PY" -c "import json,sys; print(json.loads(sys.argv[1])['beta'])" "$json")
  "$PY" -c "import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)" "$beta2" "$beta" \
    || fail "the confirming run gives beta = $beta2, below the $beta applied: the pool is too large for this variant. The method iterates once; decide by hand (runbook Phase 6) before any run of $label."
  echo "  confirmed: the run with beta = $beta gives $beta2, not lower. $beta stands."
  git commit -qam "$message" -m "beta = $beta (pass 1), confirmed by pass 2 ($beta2). Made by server/scripts/study.sh."
  touch "$state/table.committed"
  echo "  committed on $branch: $(git log -1 --format='%h %s')"
}

# building <branch> <label>: "dirty-ok" while that extra's table is being built on its branch.
building() {
  [ "$(git rev-parse --abbrev-ref HEAD)" = "$1" ] && [ ! -f "$RESULTS/extras-state/$2/table.committed" ] && echo dirty-ok || true
}

back_to_main() {
  [ -z "$(git status --porcelain --untracked-files=no)" ] || fail "uncommitted changes on $(git rev-parse --abbrev-ref HEAD); not switching back to main."
  git switch main
  check_main_table
  echo "  back on main; its table is untouched."
}

# -------------------------------------------------------------------- main
case "${1:-}" in
  preflight)
    preflight any ;;

  pilot)
    preflight main; check_main_table
    campaign "$RESULTS/main-study-pilot" "$PILOT_N" "$PILOT_SEED" ;;

  main)
    preflight main; check_main_table
    campaign "$MAIN_DIR" "$MAIN_N" "$MAIN_SEED" ;;

  gc)
    preflight main; check_main_table
    say "GC pass: $GC_N replicates with the GC observer on (never compared on speed)"
    env K="$STUDY_K" N="$GC_N" CONDITIONS="$CONDS" SCHEDULE_SEED="$MAIN_SEED" SAMM_TELEMETRY=true REQUIRE_CLEAN=1 \
      RESULTS_DIR="$RESULTS/main-study-gc" "$SCRIPT_DIR/run_replicates.sh"
    "$PY" "$STATS/gc_pass_summary.py" "$RESULTS/main-study-gc" --clean "$MAIN_DIR" ;;

  extra-mem)
    limit="${2:-}"
    case "$limit" in 2048m|4096m) ;; *) fail "usage: study.sh extra-mem 2048m | 4096m" ;; esac
    preflight any "$(building "extras/mem-$limit" "mem$limit")"
    command -v zig >/dev/null 2>&1 || fail "zig is not installed (the table is recompiled here)"
    extra_table "extras/mem-$limit" "mem$limit" "data(vm): routing table for a $limit container" MEM_LIMIT="$limit"
    campaign "$RESULTS/replicates-k$STUDY_K-mem$limit" "$EXTRA_N" "$EXTRA_SEED" MEM_LIMIT="$limit"
    back_to_main ;;

  extra-weeks)
    preflight any "$(building extras/week1 d01-d07)"
    command -v zig >/dev/null 2>&1 || fail "zig is not installed (the table is recompiled here)"
    extra_table "extras/week1" "d01-d07" "data(vm): routing table trained on days 1-7" TRAFFIC_BATCH=d01-d07
    campaign "$RESULTS/replicates-k$STUDY_K-d01-d07" "$EXTRA_N" "$EXTRA_SEED" TRAFFIC_BATCH=d01-d07
    campaign "$RESULTS/replicates-k$STUDY_K-d08-d14" "$EXTRA_N" "$EXTRA_SEED" TRAFFIC_BATCH=d08-d14
    back_to_main ;;

  stats)
    [ -x "$PY" ] || fail "no venv/bin/python3"
    for dir in "$RESULTS/main-study-pilot" "$MAIN_DIR" "$RESULTS"/replicates-k"$STUDY_K"-mem* "$RESULTS"/replicates-k"$STUDY_K"-d0*; do
      [ -f "$dir/campaign.json" ] || continue
      analyse "$dir" || true
    done
    [ -d "$RESULTS/main-study-gc" ] && "$PY" "$STATS/gc_pass_summary.py" "$RESULTS/main-study-gc" --clean "$MAIN_DIR" || true
    "$PY" "$STATS/extras_summary.py" "$RESULTS" || true ;;

  status)
    echo "branch $(git rev-parse --abbrev-ref HEAD) at $(git rev-parse --short HEAD)"
    for dir in "$RESULTS"/main-study* "$RESULTS"/replicates-k"$STUDY_K"-* "$RESULTS"/beta-*; do
      [ -d "$dir" ] || continue
      done_runs=$(find "$dir" -maxdepth 1 -name 'r[0-9]*-*.json' ! -name '*-k6.json' ! -name '*-allocator.json' ! -name '*-telemetry.json' | wc -l)
      planned=$([ -f "$dir/campaign.json" ] && "$PY" -c "import json,sys; c=json.load(open(sys.argv[1])); print(c['starts'][-1]['n_planned'] * len(c['locked']['conditions'].split()))" "$dir/campaign.json" || echo "?")
      printf '  %-34s %4s of %-4s runs%s\n' "$(basename "$dir")" "$done_runs" "$planned" "$([ -f "$dir/stats/report.txt" ] && echo ', statistics written')"
    done ;;

  *) sed -n '3,18p' "$0"; exit 2 ;;
esac
