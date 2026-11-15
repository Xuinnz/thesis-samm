#!/usr/bin/env python3
"""
Checks verify_campaign.py, and the gate and the host-health sensitivity check it
feeds in main_study_stats.py, against generated campaigns with one known defect
each.

Run:  venv/bin/python stats-eval/hypothesis-testing/test_verify_campaign.py
"""

import csv
import json
import os
import subprocess
import sys
import tempfile

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import verify_campaign  # noqa: E402

failures = []
BASE_SEED, TABLE = 20250911, "b" * 64
CONDS = ["jemalloc", "samm"]


def check(name, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'} {name}" + (f"\n       {detail}" if not ok and detail else ""))
    if not ok:
        failures.append(name)


def campaign(folder, n, rng=None, planned=None, health=None, effect=0.0, slow=()):
    """A coherent campaign of n replicates. slow: replicates where both conditions are 30 % slower."""
    rng = rng or np.random.default_rng(1)
    locked = {"k": "2.0", "conditions": " ".join(CONDS), "rotate": "1", "base_seed": str(BASE_SEED), "vary_seed": "1",
              "simulation_minutes": "10", "mem_limit": "1024m", "max_rps": "1000", "hold_scale": "2",
              "process_hold_ms": "300", "traffic_batch": "all days", "cpuset_cpus": "1", "k6_taskset": "2,3",
              "samm_buffer_mode": "chunk", "samm_segment_reuse": None, "telemetry": False,
              "routing_table_sha256": TABLE, "workload_fingerprint": "0ab9", "measured_system_sha256": "c" * 64}
    with open(os.path.join(folder, "campaign.json"), "w") as f:
        json.dump({"locked": locked, "starts": [{"at": "2026-11-16T00:00:00Z", "n_planned": planned or n,
                                                  "probe_every": 10 if health else 0}]}, f)
    for i in range(1, n + 1):
        order = CONDS if i % 2 == 1 else CONDS[::-1]
        factor = 0.7 if i in slow else 1.0
        for cond in CONDS:
            rps = (760 + (effect if cond == "samm" else 0) + rng.normal(0, 8)) * factor
            run = {"condition": f"r{i:02d}-{cond}", "peak_rss_mb": 850 + rng.normal(0, 30),
                   "processing_p99_ms": (160 + rng.normal(0, 20)) / factor, "processing_p95_ms": 80.0,
                   "latency_p99_ms": 2200.0, "throughput_rps": rps, "requests": int(rps * 600), "failed_rate": 0.0,
                   "window_secs": 690, "cpu_utilisation_pct": 90.0, "oom_kills": 0, "timing_suspect": False,
                   "page_faults_per_request": 10.0, "dropped_iterations": 0, "max_rps": 1000.0, "mem_limit_mb": 1024.0,
                   "schedule_seed": BASE_SEED + i, "image_id": f"sha256:{cond}{i}", "image_layers_sha256": "L" + cond,
                   "routing_table_sha256": TABLE,
                   "run_order": " ".join(order), "order_position": order.index(cond) + 1, "cpuset_cpus": "1",
                   "k6_taskset": "2,3", "traffic_batch": "all days", "telemetry_enabled": False,
                   "samm_buffer_mode_requested": "chunk", "samm_shared_buffers": 900000 if cond == "samm" else None,
                   "git_commit": "abc", "git_dirty_files": 0, "host_steal_pct": 0.0,
                   "container_end_state": {"status": "running", "oom_killed": False, "exit_code": 0}}
            with open(os.path.join(folder, f"r{i:02d}-{cond}.json"), "w") as f:
                json.dump(run, f)
            with open(os.path.join(folder, f"r{i:02d}-{cond}-k6.json"), "w") as f:   # a side file: must be ignored
                json.dump({"metrics": {}}, f)
    if health:
        with open(os.path.join(folder, "host-health.tsv"), "w") as f:
            f.write("time_utc\tbefore_replicate\tattempt\tverdict\tprobe_dir\n")
            for before, attempt, verdict in health:
                f.write(f"2026-11-16T00:00:00Z\t{before}\t{attempt}\t{verdict}\t-\n")


def edit(folder, name, **changes):
    path = os.path.join(folder, name)
    run = json.load(open(path))
    run.update(changes)
    json.dump(run, open(path, "w"))


def errors_of(folder, **kw):
    return verify_campaign.verify(folder, **kw)


print("verify_campaign.py against generated campaigns\n")

with tempfile.TemporaryDirectory() as d:
    campaign(d, 20)
    r = errors_of(d)
    check("A a coherent campaign has no errors and no warnings", not r["errors"] and not r["warnings"], str(r))

with tempfile.TemporaryDirectory() as d:
    campaign(d, 20)
    os.remove(os.path.join(d, "r07-samm.json"))
    r = errors_of(d)
    check("B a replicate with one condition missing is an error", any("r07" in e and "samm" in e for e in r["errors"]), str(r["errors"]))

with tempfile.TemporaryDirectory() as d:
    campaign(d, 20)
    edit(d, "r05-samm.json", schedule_seed=BASE_SEED + 6)
    r = errors_of(d)
    check("C a run on the wrong seed is an error", any("r05-samm" in e and "schedule_seed" in e for e in r["errors"]))
    check("C and the replicate is reported as not paired", any("r05" in e and "different seeds" in e for e in r["errors"]))

with tempfile.TemporaryDirectory() as d:
    campaign(d, 20)
    edit(d, "r09-samm.json", routing_table_sha256="d" * 64)
    r = errors_of(d)
    check("D a run under another routing table is an error", any("r09-samm" in e and "routing_table" in e for e in r["errors"]))

with tempfile.TemporaryDirectory() as d:
    campaign(d, 20)
    edit(d, "r03-jemalloc.json", telemetry_enabled=True)
    r = errors_of(d)
    check("E a run with the GC observer on is an error", any("r03-jemalloc" in e and "telemetry" in e.lower() for e in r["errors"]))

with tempfile.TemporaryDirectory() as d:
    campaign(d, 20)
    edit(d, "r04-samm.json", samm_buffer_mode_requested=None, samm_shared_buffers=0)
    edit(d, "r06-samm.json", samm_shared_buffers=0)
    r = errors_of(d)
    check("F SAMM started without the campaign's buffer mode is an error",
          any("r04-samm" in e and "buffer mode" in e for e in r["errors"]))
    check("F SAMM asked for chunk mode but handing out no shared Buffers is an error",
          any("r06-samm" in e and "did not run in that mode" in e for e in r["errors"]))

with tempfile.TemporaryDirectory() as d:
    campaign(d, 20)
    edit(d, "r02-samm.json", run_order="jemalloc samm", order_position=2)
    r = errors_of(d)
    check("G a run out of the planned order is an error", any("r02-samm" in e and "run_order" in e for e in r["errors"]))

with tempfile.TemporaryDirectory() as d:
    campaign(d, 18, planned=20)
    r = errors_of(d)
    check("H an unfinished campaign is an error that says it resumes",
          any("18 replicates" in e and "resumes" in e for e in r["errors"]), str(r["errors"]))
    check("H --expect-n overrides the plan", not errors_of(d, expect_n=18)["errors"])

with tempfile.TemporaryDirectory() as d:
    campaign(d, 20)
    edit(d, "r10-samm.json", image_layers_sha256="rebuilt", git_dirty_files=2)
    r = errors_of(d)
    check("I an image rebuilt from scratch and dirty files are warnings, not errors",
          not r["errors"] and any("image_layers" in w for w in r["warnings"]) and any("uncommitted" in w for w in r["warnings"]))

with tempfile.TemporaryDirectory() as d:
    campaign(d, 20)
    os.remove(os.path.join(d, "campaign.json"))
    r = errors_of(d)
    check("J a folder from before the campaign lock is tested, with a warning",
          not r["errors"] and any("predates" in w for w in r["warnings"]), str(r))

with tempfile.TemporaryDirectory() as d:
    c = json.load(open(os.path.join(d, "campaign.json"))) if os.path.exists(os.path.join(d, "campaign.json")) else None
    campaign(d, 20)
    c = json.load(open(os.path.join(d, "campaign.json")))
    c["changes"] = [{"at": "x", "changed": {"k": {"was": "2.0", "now": "2.5"}}}]
    json.dump(c, open(os.path.join(d, "campaign.json"), "w"))
    check("K settings changed mid-campaign are an error", any("mid-campaign" in e for e in errors_of(d)["errors"]))

# Host health: pass before r1, pass before r11, FAIL before r21 (then a retry passes), pass before r31,
# a new start (a failed first probe there implicates nothing), and a fail at the end.
health = [("-", 0, "start"), (1, 1, "pass"), (11, 1, "pass"), (21, 1, "fail"), (21, 2, "pass"), (31, 1, "pass"),
          ("-", 0, "start"), (36, 1, "fail"), (36, 2, "pass"), ("end", 1, "fail")]
with tempfile.TemporaryDirectory() as d:
    campaign(d, 40, health=health)
    r = errors_of(d)
    want = set(range(11, 21)) | set(range(36, 41))
    check("L host-suspect = the replicates between a passed probe and the next failed one",
          r["host_suspect"] == want, f"got {sorted(r['host_suspect'])}")
    check("L a failed probe is a warning, not an error", not r["errors"] and any("host probe" in w for w in r["warnings"]))

# The gate and the sensitivity check in main_study_stats.py.
STATS = os.path.join(HERE, "main_study_stats.py")
run_stats = lambda folder, *extra: subprocess.run([sys.executable, STATS, folder, *extra], capture_output=True, text=True)

with tempfile.TemporaryDirectory() as d:
    campaign(d, 30)
    os.remove(os.path.join(d, "r07-samm.json"))
    out = run_stats(d)
    check("M the statistics refuse a folder with integrity errors",
          out.returncode != 0 and not os.path.exists(os.path.join(d, "stats", "tests.csv")), out.stdout[-300:])
    out = run_stats(d, "--allow-integrity-errors")
    check("M --allow-integrity-errors tests it and keeps the errors in the report",
          out.returncode == 0 and "ERRORS:" in out.stdout and "r07" in out.stdout)

with tempfile.TemporaryDirectory() as d:
    # A real throughput difference, and ten replicates on a slow host that hit both conditions alike.
    campaign(d, 40, rng=np.random.default_rng(7), effect=60.0, slow=range(11, 21),
             health=[("-", 0, "start"), (1, 1, "pass"), (11, 1, "pass"), (21, 1, "fail"), (21, 2, "pass"),
                     (31, 1, "pass"), ("end", 1, "pass")])
    out = run_stats(d)
    rows = list(csv.DictReader(open(os.path.join(d, "stats", "host_sensitivity.csv")))) if out.returncode == 0 else []
    thr = next((r for r in rows if r["metric"] == "throughput_rps"), {})
    check("N the sensitivity check re-tests without the host-suspect replicates",
          out.returncode == 0 and thr.get("n_baseline") == "30" and thr.get("n_treatment") == "30", out.stdout[-400:] + out.stderr[-300:])
    check("N and says whether the decision changed", "decision unchanged" in out.stdout or "DECISION CHANGES" in out.stdout)
    fig = subprocess.run([sys.executable, os.path.join(HERE, "main_study_figures.py"), d], capture_output=True, text=True)
    check("O the figures are written", fig.returncode == 0
          and os.path.exists(os.path.join(d, "stats", "figures", "primary_distributions.png"))
          and os.path.exists(os.path.join(d, "stats", "figures", "campaign_order.png")), fig.stderr[-400:])
    keep = os.environ.get("KEEP_FIGURES")
    if keep and fig.returncode == 0:
        import shutil
        shutil.copytree(os.path.join(d, "stats", "figures"), keep, dirs_exist_ok=True)

print()
if failures:
    print(f"{len(failures)} check(s) FAILED: " + "; ".join(failures))
    sys.exit(1)
print("all checks passed")
