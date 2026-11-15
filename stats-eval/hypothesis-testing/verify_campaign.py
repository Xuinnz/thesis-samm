#!/usr/bin/env python3
"""
Is a run_replicates.sh results folder one coherent sample?

The statistics assume every run in the folder was made the same way: the same
table, load point, pinning and buffer mode, each replicate's two conditions on
one seed, in the planned order. Nothing in a mean shows when that is not so.
This reads the folder's campaign.json (written by run_replicates.sh at the
first start) and every rNN-<condition>.json, and lists what does not agree.

  ERRORS    the folder is not one sample (a missing run, a different table or
            seed, telemetry on, a buffer mode that was not the one asked for).
            main_study_stats.py refuses to test a folder with errors.
  WARNINGS  worth a sentence in the write-up, not a reason to stop (several
            image IDs for one condition, a host probe that failed, files that
            were uncommitted at run time).

It also reads host-health.tsv: the replicates that ran between a passed host
probe and the next failed one are returned as "host-suspect", for the
statistics' sensitivity check.

Usage: verify_campaign.py RESULTS_DIR [--expect-n N] [--conditions "jemalloc samm"]
Exit status: 0 no errors, 1 errors.
"""

import argparse
import csv
import glob
import json
import os
import re
import sys


def _replicate(path):
    m = re.match(r"r(\d+)-(.+)\.json$", os.path.basename(path))
    return (int(m.group(1)), m.group(2)) if m else None


def host_suspects(results_dir, last_replicate):
    """Replicates between a passed probe and the next failed one, and the failed attempts themselves."""
    path = os.path.join(results_dir, "host-health.tsv")
    suspects, failed = set(), []
    if not os.path.exists(path):
        return suspects, failed, False
    clean_from = None          # first replicate run after the last passed probe of this start
    with open(path) as f:
        for row in csv.DictReader(f, delimiter="\t"):
            verdict, before = row["verdict"], row["before_replicate"]
            if verdict == "start":
                clean_from = None
                continue
            at = last_replicate + 1 if before == "end" else int(before)
            if verdict == "pass":
                clean_from = at
            elif verdict == "fail":
                failed.append(row)
                if row["attempt"] == "1" and clean_from is not None:
                    suspects.update(range(clean_from, at))
    return suspects, failed, True


def verify(results_dir, conditions=None, expect_n=None):
    """Returns {"errors": [...], "warnings": [...], "info": [...], "host_suspect": set, "campaign": dict|None}."""
    errors, warnings, info = [], [], []
    campaign_path = os.path.join(results_dir, "campaign.json")
    campaign = json.load(open(campaign_path)) if os.path.exists(campaign_path) else None
    locked = campaign["locked"] if campaign else {}
    if campaign is None:
        warnings.append("no campaign.json: the folder predates the campaign lock, so its settings cannot be "
                        "checked against what was planned, only against each other")
    elif campaign.get("changes"):
        for change in campaign["changes"]:
            errors.append(f"settings were changed mid-campaign at {change['at']} (CAMPAIGN_ALLOW_CHANGE=1): "
                          + ", ".join(f"{k} {v['was']!r} -> {v['now']!r}" for k, v in change["changed"].items()))
    if conditions is None:
        conditions = locked["conditions"].split() if locked.get("conditions") else None

    runs = {}
    for path in sorted(glob.glob(os.path.join(results_dir, "r*-*.json"))):
        key = _replicate(path)
        # rNN-<condition>-k6.json and friends are the harness's side files.
        if key is None or key[1].endswith(("-k6", "-allocator", "-telemetry")):
            continue
        with open(path) as f:
            runs[key] = json.load(f)
    if conditions is None:
        conditions = sorted({c for _, c in runs})
    runs = {k: v for k, v in runs.items() if k[1] in conditions}
    if not runs:
        return {"errors": [f"no runs for {' / '.join(conditions)} in {results_dir}"], "warnings": warnings,
                "info": info, "host_suspect": set(), "campaign": campaign}
    replicates = sorted({i for i, _ in runs})
    last = replicates[-1]

    # ---- completeness
    for i in range(1, last + 1):
        missing = [c for c in conditions if (i, c) not in runs]
        if missing:
            errors.append(f"replicate r{i:02d} has no run for: {', '.join(missing)}")
    planned = expect_n if expect_n is not None else (campaign["starts"][-1]["n_planned"] if campaign else None)
    if planned is not None and last != planned:
        errors.append(f"{last} replicates in the folder, {planned} planned"
                      + (" (the campaign is not finished: start it again, it resumes)" if last < planned else ""))

    # ---- every run against the plan
    rotate = locked.get("rotate", "1") == "1"
    for (i, cond), r in sorted(runs.items()):
        tag = f"r{i:02d}-{cond}"

        def expect(field, want, got=None, what=None):
            got = r.get(field) if got is None else got
            if want is not None and got != want:
                errors.append(f"{tag}: {what or field} is {got!r}, the campaign's is {want!r}")

        if locked:
            if locked.get("vary_seed") == "1":
                expect("schedule_seed", int(locked["base_seed"]) + i)
            else:
                expect("schedule_seed", int(locked["base_seed"]))
            expect("routing_table_sha256", locked.get("routing_table_sha256"))
            expect("cpuset_cpus", locked.get("cpuset_cpus"))
            expect("k6_taskset", locked.get("k6_taskset"))
            expect("traffic_batch", locked.get("traffic_batch"))
            if locked.get("max_rps"):
                expect("max_rps", float(locked["max_rps"]))
            if "telemetry_enabled" in r:
                expect("telemetry_enabled", bool(locked.get("telemetry")))
            if cond == "samm" and "samm_buffer_mode_requested" in r:
                expect("samm_buffer_mode_requested", locked.get("samm_buffer_mode"), what="buffer mode asked for")
            n = len(conditions)
            shift = (i - 1) % n if rotate else 0
            order = [conditions[(j + shift) % n] for j in range(n)]
            # run_order is recorded in the campaign's own condition order, which
            # is the folder's if the caller did not narrow it.
            if r.get("run_order") and set(r["run_order"].split()) == set(conditions):
                expect("run_order", " ".join(order))
                expect("order_position", order.index(cond) + 1)
        if r.get("telemetry_enabled") and not locked.get("telemetry"):
            errors.append(f"{tag}: GC telemetry was on; its observer perturbs the run")
        if cond == "samm" and r.get("samm_shared_buffers") is not None:
            mode = r.get("samm_buffer_mode_requested") or "detach"
            shared = r["samm_shared_buffers"]
            if (mode in ("chunk", "view")) != (shared > 0) and r.get("requests", 0) > 1000:
                errors.append(f"{tag}: buffer mode asked for was {mode}, but the allocator handed out "
                              f"{shared:,} shared Buffers: it did not run in that mode")
        if r.get("git_dirty_files"):
            warnings.append(f"{tag}: {r['git_dirty_files']} tracked file(s) had uncommitted changes at run time")

    # ---- a replicate's conditions share a seed
    for i in replicates:
        seeds = {runs[(i, c)].get("schedule_seed") for c in conditions if (i, c) in runs}
        if len(seeds) > 1:
            errors.append(f"replicate r{i:02d}: its conditions ran on different seeds {sorted(map(str, seeds))}")

    # ---- things that should be constant per condition
    for cond in conditions:
        mine = [r for (_, c), r in runs.items() if c == cond]
        for field, level in (("routing_table_sha256", errors), ("mem_limit_mb", errors),
                             ("image_id", warnings), ("git_commit", warnings)):
            seen = {r.get(field) for r in mine if r.get(field) is not None}
            if len(seen) > 1:
                level.append(f"{cond}: {len(seen)} different values of {field} across its runs: "
                             + ", ".join(sorted(str(s)[:19] for s in seen)))
    steal = [r["host_steal_pct"] for r in runs.values() if r.get("host_steal_pct") is not None]
    if steal:
        info.append(f"hypervisor steal over the runs: median {sorted(steal)[len(steal) // 2]:.3f} %, max {max(steal):.3f} %")

    # ---- host health
    suspects, failed, has_log = host_suspects(results_dir, last)
    if has_log:
        if failed:
            warnings.append(f"{len(failed)} host probe attempt(s) failed "
                            f"({', '.join(sorted({'before r' + f['before_replicate'] for f in failed}))}); "
                            f"host-suspect replicates: {', '.join(f'r{i:02d}' for i in sorted(suspects)) or 'none'}")
        else:
            info.append("every host probe passed")
    elif campaign and campaign["starts"][-1].get("probe_every"):
        warnings.append("probing was on but there is no host-health.tsv")
    else:
        info.append("no host probes were run during this campaign")
    info.append(f"{len(runs)} runs, {last} replicates, conditions: {' '.join(conditions)}")
    return {"errors": errors, "warnings": warnings, "info": info, "host_suspect": suspects, "campaign": campaign}


def report(result):
    lines = []
    for title, key in (("ERRORS", "errors"), ("WARNINGS", "warnings"), ("", "info")):
        for msg in result[key]:
            lines.append(f" {title + ':' if title else '       '} {msg}" if title else f"   {msg}")
    lines.append(" Integrity: " + ("FAILED" if result["errors"] else "ok"
                                   + (f", {len(result['warnings'])} warning(s)" if result["warnings"] else "")))
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("results_dir")
    ap.add_argument("--expect-n", type=int)
    ap.add_argument("--conditions", help='e.g. "jemalloc samm" (default: the campaign\'s)')
    args = ap.parse_args()
    result = verify(args.results_dir, args.conditions.split() if args.conditions else None, args.expect_n)
    print(report(result))
    sys.exit(1 if result["errors"] else 0)


if __name__ == "__main__":
    main()
