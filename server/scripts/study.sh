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
#   study.sh extra-rate 2048m 1500  Phase 10e: k = 2.0's holds at a 1,500 req/s peak in 2 GB:
#                                 retrain (profiled at half the rate), beta, 15 replicates (about 9 h)
#   study.sh extra-rate 4096m 2000  the same at a 2,000 req/s peak in 4 GB
#   study.sh extra-mem-k 4096m 3.0  Phase 10d (not used: superseded by extra-rate, 2026-11-18)
#   study.sh extra-sat 2048m      Phase 10c: the 2 GB table at a load that saturates both (about 9 h;
#                                 after extra-mem 2048m): capacities at 2 GB, k = 2.5 or 3.0 by
#                                 rule, beta at that k, 15 replicates
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
      POLL_SAMM_STATS SAMM_ALLOW_CONTAINER_MISMATCH EXTRA_K PEAK_RPS PROFILE_RPS PROFILE_CAPACITY 2>/dev/null || true
# EXTRA_K: the load point of an extra that runs at its own k (extra-sat, extra-mem-k;
# set by that command, never from the environment). Everything else: STUDY_K.
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
       "k = ${EXTRA_K:-$STUDY_K}; buffer mode $SAMM_BUFFER_MODE; server on core $CPUSET_CPUS, k6 on $K6_TASKSET; probe every $PROBE_EVERY replicates"
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
  env "$@" K="${EXTRA_K:-$STUDY_K}" N="$n" CONDITIONS="$CONDS" SCHEDULE_SEED="$seed" RESULTS_DIR="$dir" REQUIRE_CLEAN=1 \
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
    env "$@" K="${EXTRA_K:-$STUDY_K}" N=1 CONDITIONS=samm POLL_SAMM_STATS=1 SCHEDULE_SEED="$BETA_SEED" RESULTS_DIR="$dir" \
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

# profile_check <pipeline log>: a profiling run above the usual 500 req/s must
# have kept up. The profiler is expensive; if k6 had to drop requests, the
# trace describes a server that fell behind, not the workload, and the table
# trained on it would be wrong.
profile_check() {
  "$PY" - "$1" "$PROFILE_RPS" <<'PY' || exit 1
import re, sys
text = open(sys.argv[1], errors="replace").read()
done = re.findall(r"^\s*iterations\.*:\s*([0-9]+)", text, re.M)
dropped = re.findall(r"^\s*dropped_iterations\.*:\s*([0-9]+)", text, re.M)
if not done:
    sys.exit(f"REFUSED: no k6 summary in {sys.argv[1]}, so the profiling run at {sys.argv[2]} req/s cannot be checked.")
d, x = int(done[-1]), int(dropped[-1]) if dropped else 0
share = 100 * x / (d + x)
print(f"  profiling run at {sys.argv[2]} req/s: {d:,} requests, {x:,} dropped ({share:.2f} %)")
if share > 1.0:
    sys.exit(f"REFUSED: the profiling run dropped {share:.2f} % of its requests (over 1 %): the profiled server fell "
             "behind, so its trace is not a sound basis for the table. Ask the user.")
PY
}

# extra_table <branch> <label> <commit message> [NAME=value ...]
# On its own branch: profile and retrain under the variant's settings, derive
# beta as in Phase 6 (measure, recompile, confirm), commit the table there.
extra_table() {
  local branch="$1" label="$2" message="$3"; shift 3
  local state="$RESULTS/extras-state/$label" current beta beta2 json
  mkdir -p "$state"
  # Before the branch is touched: a failure after the switch would leave the
  # machine on the extra's branch.
  git config user.name >/dev/null && git config user.email >/dev/null \
    || fail "git has no user.name / user.email on this machine, so the table could not be committed on $branch. Set them, then run this again."
  current=$(git rev-parse --abbrev-ref HEAD)
  if [ "$current" = "main" ]; then
    check_main_table
    if git show-ref --verify --quiet "refs/heads/$branch"; then git switch "$branch"; else git switch -c "$branch"; fi
  elif [ "$current" != "$branch" ]; then
    fail "on branch '$current'. Start this from main (or from $branch, to resume)."
  fi
  if [ -f "$state/table.committed" ]; then
    echo "  the table for $label is already committed on $branch (beta $(cat "$state/beta.txt"))"
    return 0
  fi

  if [ ! -f "$state/pipeline.done" ]; then
    say "$label: profile, retrain, compile, test (about 16 min)${PROFILE_RPS:+; profiled at $PROFILE_RPS req/s}"
    # PROFILE_RPS / PROFILE_CAPACITY: extra-rate only (the profiling load and
    # the profiler's slots for it); unset, the pipeline's own defaults.
    env "$@" ${PROFILE_RPS:+MAX_RPS="$PROFILE_RPS"} ${PROFILE_CAPACITY:+SHADOW_PROFILER_CAPACITY="$PROFILE_CAPACITY"} \
      SKIP_BENCHMARK=1 "$SCRIPT_DIR/run_full_pipeline.sh" 2>&1 | tee "$state/pipeline.log"
    [ -n "${PROFILE_RPS:-}" ] && profile_check "$state/pipeline.log"
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

# sat_extra <limit>: the extra-mem table for <limit>, at the lowest load whose
# peak rate covers both capacities measured in that container (Phase 5's rule,
# which the 1 GiB study had to step down from because the baseline died).
# Decided by the user 2026-11-17: k = 2.5 if that covers both, else 3.0, and
# no higher. Each step leaves a file in extras-state/sat<limit>/ and is skipped
# on a resume, so the k, once chosen, never changes.
SAT_CAL_VUS="100,200,300,400,500,600,700,800"
sat_extra() {
  local limit="$1" label="sat$1" base="extras/mem-$1" branch="extras/mem-$1-sat"
  local state="$RESULTS/extras-state/sat$1" current beta beta2 json old
  [ -f "$RESULTS/extras-state/mem$limit/table.committed" ] \
    || fail "the $limit table is not committed yet: run study.sh extra-mem $limit first (this extra starts from its table)."
  mkdir -p "$state"
  git config user.name >/dev/null && git config user.email >/dev/null \
    || fail "git has no user.name / user.email on this machine. Set them, then run this again."
  current=$(git rev-parse --abbrev-ref HEAD)
  if [ "$current" = "main" ]; then
    check_main_table
    if git show-ref --verify --quiet "refs/heads/$branch"; then
      git switch "$branch"
    else
      # From main, so every script is main's (a branch made from $base would
      # carry the scripts as they were when $base was made: on 2026-11-18 that
      # ran the calibration in 1 GiB). Only the table's files come from $base.
      local files
      files=$(git diff --name-only "$(git merge-base main "$base")" "$base")
      [ -n "$files" ] || fail "$base has no table commit to take the files from."
      git switch -c "$branch"
      # shellcheck disable=SC2086
      git checkout "$base" -- $files
      git commit -qm "data(vm): the $limit table, taken from $base ($(git rev-parse --short "$base"))" \
        -m "Files: $(echo $files | tr '\n' ' '). Made by server/scripts/study.sh extra-sat."
      echo "  $branch: main plus the $limit table from $base"
    fi
  elif [ "$current" != "$branch" ]; then
    fail "on branch '$current'. Start this from main (or from $branch, to resume)."
  fi
  [ "$(git show "$base:zig-allocator/src/routing-table/model_weights.zig" | sha256sum)" \
    = "$(sha256sum < zig-allocator/src/routing-table/model_weights.zig)" ] || [ -f "$state/beta.txt" ] \
    || fail "the table on $branch is not the one on $base."

  # 1. Both capacities in this container, closed loop (Phase 5 step 1, with k = 2.5 holds as there).
  if [ ! -f "$state/k.txt" ]; then
    if [ ! -f "$state/calibrate/calibration_knees.csv" ]; then
      say "$label: capacities at $limit (host probe, then closed loop, VUs $SAT_CAL_VUS; about 30 min)"
      rm -rf "$state/calibrate"     # a sweep cut off part-way is started again
      # A slow host would understate the capacities and so the k: probe first,
      # with the campaigns' limits, and stop rather than calibrate on a bad host.
      "$REPO_ROOT/internal-validation/host-probe.sh" "$state/probe-$(date -u +%Y%m%dT%H%M%S)" full \
        || fail "the host probe before the calibration failed. Wait a few hours and run this again (it resumes here)."
      MEM_LIMIT="$limit" LOAD_K=2.5 CAL_VUS="$SAT_CAL_VUS" RESULTS_DIR="$state/calibrate" \
        "$REPO_ROOT/internal-validation/run.sh" calibrate jemalloc samm
      "$PY" "$REPO_ROOT/internal-validation/analysis/calibration_report.py" "$state/calibrate" --no-plot \
        || fail "the calibration report did not run for $state/calibrate."
    fi
    "$PY" - "$state/calibrate/calibration_knees.csv" "$state" "$limit" <<'PY' || exit 1
import csv, json, math, os, sys
# The container the sweep actually ran in, as each config's run.json records it.
for cfg in ("jemalloc", "samm"):
    run = json.load(open(os.path.join(os.path.dirname(sys.argv[1]), cfg, "run.json")))
    got = (run.get("container_limits") or {}).get("memory")
    if got != sys.argv[3]:
        sys.exit(f"REFUSED: the {cfg} calibration ran with a {got} limit, not {sys.argv[3]}. Its capacities "
                 f"do not apply. Move {os.path.dirname(sys.argv[1])} aside and find out why.")
rows = {r["config"]: r for r in csv.DictReader(open(sys.argv[1]))}
caps = {}
for cfg in ("jemalloc", "SAMM"):
    if cfg not in rows:
        sys.exit(f"REFUSED: no calibration row for {cfg}")
    caps[cfg] = float(rows[cfg]["capacity req/s"] or "nan")
    if math.isnan(caps[cfg]):
        sys.exit(f"REFUSED: {cfg} has no valid calibration step, so its capacity is unknown. Ask the user.")
need = max(caps.values())
samm_sat = rows["SAMM"]["saturated"] == "yes"
# MAX_RPS = 500 x k
if need <= 1250:
    if not samm_sat:
        sys.exit(f"REFUSED: SAMM never reached 98 % CPU in the sweep, so {caps['SAMM']:.0f} req/s is only a lower "
                 "bound and cannot decide between k = 2.5 and 3.0. Ask the user.")
    k, why = "2.5", f"the peak rate 1,250 req/s covers both capacities"
else:
    k, why = "3.0", f"1,250 req/s does not cover {need:.0f}; 1,500 is the next level"
    if need > 1500:
        why += f" (it does not cover {need:.0f} either: 3.0 is the highest the user allowed)"
line = f"jemalloc {caps['jemalloc']:.1f} req/s, SAMM {caps['SAMM']:.1f} req/s (SAMM saturated: {'yes' if samm_sat else 'no'})"
open(sys.argv[2] + "/capacities.txt", "w").write(line + "\n")
open(sys.argv[2] + "/k.txt", "w").write(k + "\n")
print(f"  capacities: {line}\n  k = {k}: {why}")
PY
  fi
  EXTRA_K=$(cat "$state/k.txt")
  echo "  load point: k = $EXTRA_K ($(cat "$state/capacities.txt"))"

  # 2. beta at that k, on the extra-mem table. If it asks for the beta already
  #    applied (at 2 GB, likely 1.0, the cap), the table stands and the pass
  #    is its own confirmation (the run gave at least that beta on that table).
  old=$(cat "$RESULTS/extras-state/mem$limit/beta.txt")
  if [ ! -f "$state/beta.txt" ]; then
    say "$label: beta pass 1 at k = $EXTRA_K"
    json=$(beta_pass "$RESULTS/beta-$label-pass1" MEM_LIMIT="$limit")
    beta=$("$PY" -c "import json,sys; b=json.loads(sys.argv[1])['beta_to_apply']; print('' if b is None else b)" "$json")
    [ -n "$beta" ] || fail "pass 1 gives a beta of zero or less: the pool cannot be sized from this run."
    if "$PY" -c "import sys; sys.exit(0 if abs(float(sys.argv[1]) - float(sys.argv[2])) < 1e-9 else 1)" "$beta" "$old"; then
      echo "  beta = $beta, the one the $limit table already has: no recompile."
      touch "$state/same-table"
    else
      say "$label: recompile with beta = $beta (the $limit table has $old)"
      SAMM_BETA_UTILIZATION="$beta" bash "$REPO_ROOT/ml-refinery/run_ml_refinery.sh"
      (cd "$REPO_ROOT/zig-allocator" && zig build test --summary all)
    fi
    echo "$beta" > "$state/beta.txt"
  fi
  beta=$(cat "$state/beta.txt")
  if [ ! -f "$state/table.committed" ]; then
    if [ ! -f "$state/same-table" ]; then
      say "$label: beta pass 2 (confirm beta = $beta)"
      json=$(beta_pass "$RESULTS/beta-$label-pass2" MEM_LIMIT="$limit")
      beta2=$("$PY" -c "import json,sys; print(json.loads(sys.argv[1])['beta'])" "$json")
      "$PY" -c "import sys; sys.exit(0 if float(sys.argv[1]) >= float(sys.argv[2]) else 1)" "$beta2" "$beta" \
        || fail "the confirming run gives beta = $beta2, below the $beta applied. The method iterates once; ask the user."
      git commit -qam "data(vm): routing table for a $limit container at k = $EXTRA_K" \
        -m "beta = $beta (pass 1), confirmed by pass 2 ($beta2). Made by server/scripts/study.sh."
      echo "  committed on $branch: $(git log -1 --format='%h %s')"
    fi
    touch "$state/table.committed"
  fi
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
# One study.sh at a time on a machine. infra/vm.sh tests this lock before it
# starts another, and before it pulls.
case "${1:-}" in
  pilot|main|gc|extra-mem|extra-mem-k|extra-rate|extra-weeks|extra-sat)
    mkdir -p "$REPO_ROOT/results"
    exec 9> "$REPO_ROOT/results/.study.lock"
    flock -n 9 || fail "another study.sh is running on this machine." ;;
esac

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

  extra-rate)
    # Decided by the user 2026-11-18 (with the panel: the extras need a higher
    # load): the main study's requests (k = 2.0's holds), more of them per
    # second, 1,500 req/s peak in 2 GB and 2,000 in 4 GB. The table is retrained
    # on a profile at half the rate with k = 1.0's holds, the main study's own
    # relation (1,000 req/s studied, 500 profiled), so it is sized for the
    # demand it serves; beta at the run's load.
    limit="${2:-}" rate="${3:-}"
    case "$limit:$rate" in 2048m:1500|4096m:2000) ;; *) fail "usage: study.sh extra-rate 2048m 1500 | 4096m 2000" ;; esac
    PROFILE_RPS=$((rate / 2)) PROFILE_CAPACITY=$((150000 * rate / 1000))
    preflight any "$(building "extras/mem-$limit-r$rate" "mem$limit-r$rate")"
    command -v zig >/dev/null 2>&1 || fail "zig is not installed (the table is recompiled here)"
    echo "  load: peak $rate req/s with k = $STUDY_K's holds; profiled at $PROFILE_RPS req/s (profiler slots $PROFILE_CAPACITY)"
    extra_table "extras/mem-$limit-r$rate" "mem$limit-r$rate" \
      "data(vm): routing table for a $limit container at a $rate req/s peak (profiled at $PROFILE_RPS)" \
      MEM_LIMIT="$limit" PEAK_RPS="$rate"
    campaign "$RESULTS/replicates-k$STUDY_K-r$rate-mem$limit" "$EXTRA_N" "$EXTRA_SEED" MEM_LIMIT="$limit" PEAK_RPS="$rate"
    back_to_main ;;

  extra-mem-k)
    # Decided by the user 2026-11-18: the 4 GB extra runs at a fixed k = 3.0
    # instead of the main study's 2.0 (at 2 GB and k = 2.0 memory already did
    # not bind, so 4 GB at 2.0 would repeat it). As extra-mem in every other
    # respect: retrain in that container, beta at that k, 15 replicates.
    limit="${2:-}" k="${3:-}"
    case "$limit" in 2048m|4096m) ;; *) fail "usage: study.sh extra-mem-k 2048m|4096m 2.5|3.0" ;; esac
    case "$k" in 2.5|3.0) ;; *) fail "usage: study.sh extra-mem-k 2048m|4096m 2.5|3.0" ;; esac
    EXTRA_K="$k"
    preflight any "$(building "extras/mem-$limit-k$k" "mem$limit-k$k")"
    command -v zig >/dev/null 2>&1 || fail "zig is not installed (the table is recompiled here)"
    extra_table "extras/mem-$limit-k$k" "mem$limit-k$k" "data(vm): routing table for a $limit container, beta at k = $k" MEM_LIMIT="$limit"
    campaign "$RESULTS/replicates-k$k-mem$limit" "$EXTRA_N" "$EXTRA_SEED" MEM_LIMIT="$limit"
    back_to_main ;;

  extra-sat)
    limit="${2:-}"
    case "$limit" in 2048m|4096m) ;; *) fail "usage: study.sh extra-sat 2048m | 4096m" ;; esac
    preflight any "$(building "extras/mem-$limit-sat" "sat$limit")"
    command -v zig >/dev/null 2>&1 || fail "zig is not installed (the table may be recompiled here)"
    sat_extra "$limit"
    campaign "$RESULTS/replicates-k$EXTRA_K-mem$limit" "$EXTRA_N" "$EXTRA_SEED" MEM_LIMIT="$limit"
    back_to_main ;;

  stats)
    [ -x "$PY" ] || fail "no venv/bin/python3"
    for dir in "$RESULTS/main-study-pilot" "$MAIN_DIR" "$RESULTS"/replicates-k*-mem* "$RESULTS"/replicates-k"$STUDY_K"-d0*; do
      [ -f "$dir/campaign.json" ] || continue
      analyse "$dir" || true
    done
    [ -d "$RESULTS/main-study-gc" ] && "$PY" "$STATS/gc_pass_summary.py" "$RESULTS/main-study-gc" --clean "$MAIN_DIR" || true
    "$PY" "$STATS/extras_summary.py" "$RESULTS" || true ;;

  status)
    echo "branch $(git rev-parse --abbrev-ref HEAD) at $(git rev-parse --short HEAD)"
    for dir in "$RESULTS"/main-study* "$RESULTS"/replicates-k* "$RESULTS"/beta-*; do
      [ -d "$dir" ] || continue
      done_runs=$(find "$dir" -maxdepth 1 -name 'r[0-9]*-*.json' ! -name '*-k6.json' ! -name '*-allocator.json' ! -name '*-telemetry.json' | wc -l)
      planned=$([ -f "$dir/campaign.json" ] && "$PY" -c "import json,sys; c=json.load(open(sys.argv[1])); print(c['starts'][-1]['n_planned'] * len(c['locked']['conditions'].split()))" "$dir/campaign.json" || echo "?")
      printf '  %-34s %4s of %-4s runs%s\n' "$(basename "$dir")" "$done_runs" "$planned" "$([ -f "$dir/stats/report.txt" ] && echo ', statistics written')"
    done ;;

  *) sed -n '3,26p' "$0"; exit 2 ;;
esac
