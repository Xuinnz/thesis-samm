#!/usr/bin/env python3
"""
Checks main_study_stats.py against generated studies whose answers are known.

No real result exists when this is written, which is the point: the analysis is
tested on data built to exercise each branch of the approved decision rule.

Run:  venv/bin/python stats-eval/hypothesis-testing/test_main_study_stats.py
"""

import csv
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
from scipy import stats

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "main_study_stats.py")
failures = []


def check(name, ok, detail=""):
    print(f"  {'ok  ' if ok else 'FAIL'} {name}" + (f"\n       {detail}" if not ok and detail else ""))
    if not ok:
        failures.append(name)


def write_run(folder, replicate, condition, peak, p99, rps, killed=False, suspect=False):
    served_fraction = 0.4 if killed else 1.0
    run = {
        "condition": f"r{replicate:02d}-{condition}", "peak_rss_mb": float(peak), "processing_p99_ms": float(p99),
        "processing_p95_ms": float(p99) / 2, "latency_p99_ms": float(p99) + 2000, "throughput_rps": float(rps),
        "requests": int(rps * 600), "failed_rate": 0.0 if not killed else 1 - served_fraction, "window_secs": 840,
        "cpu_utilisation_pct": 0.0 if killed else 90.0, "oom_kills": 1 if killed else 0, "timing_suspect": suspect,
        "page_faults_per_request": 10.0, "dropped_iterations": 100, "schedule_seed": 1000 + replicate,
        "container_end_state": {"status": "exited" if killed else "running", "oom_killed": killed, "exit_code": 137 if killed else 0},
    }
    with open(os.path.join(folder, f"r{replicate:02d}-{condition}.json"), "w") as f:
        json.dump(run, f)


def study(folder, base, samm, killed=(), suspect=()):
    """base/samm: dicts of metric -> array. killed/suspect: sets of (condition, replicate)."""
    for cond, data in (("jemalloc", base), ("samm", samm)):
        for i in range(len(data["peak"])):
            write_run(folder, i + 1, cond, data["peak"][i], data["p99"][i], data["rps"][i],
                      killed=(cond, i + 1) in killed, suspect=(cond, i + 1) in suspect)


def run(folder, *extra):
    out = subprocess.run([sys.executable, SCRIPT, folder, *extra], capture_output=True, text=True)
    if out.returncode != 0:
        print(out.stdout, out.stderr)
        raise SystemExit("main_study_stats.py failed")
    read = lambda name: list(csv.DictReader(open(os.path.join(folder, "stats", name))))
    return {r["metric"]: r for r in read("tests.csv")}, {r["condition"]: r for r in read("survival.csv")}, out.stdout


rng = np.random.default_rng(20261113)
N = 100
normal = lambda mean, sd: rng.normal(mean, sd, N)

print("main_study_stats.py against generated studies\n")

# A. Normal, equal variances, a real difference on every metric -> t-test, reject.
with tempfile.TemporaryDirectory() as d:
    base = {"peak": normal(850, 30), "p99": normal(160, 20), "rps": normal(760, 8)}
    samm = {"peak": normal(900, 30), "p99": normal(120, 20), "rps": normal(800, 8)}
    study(d, base, samm)
    tests, survival, _ = run(d)
    for key, col in (("peak_rss_mb", "peak"), ("processing_p99_ms", "p99"), ("throughput_rps", "rps")):
        t = tests[key]
        direct = stats.ttest_ind(samm[col], base[col], equal_var=True)
        check(f"A {key}: t-test chosen for normal, equal-variance samples", t["test"] == "independent-samples t-test", t["test"])
        check(f"A {key}: statistic and p match scipy directly",
              abs(float(t["statistic"]) - direct.statistic) < 1e-9 and abs(float(t["p"]) - direct.pvalue) < 1e-12)
        check(f"A {key}: df = n1 + n2 - 2", t["df"] == str(2 * N - 2), t["df"])
        check(f"A {key}: H0 rejected at 0.05/3", t["reject_h0"] == "True")
        expected = 100 * (np.mean(samm[col]) - np.mean(base[col])) / np.mean(base[col])
        check(f"A {key}: relative change = (SAMM - baseline) / baseline", abs(float(t["relative_pct"]) - expected) < 1e-9)
    check("A all 100 runs per condition contribute", survival["jemalloc"]["contributing"] == "100" and survival["samm"]["contributing"] == "100")

# B. Skewed samples -> Shapiro-Wilk rejects normality -> Mann-Whitney.
with tempfile.TemporaryDirectory() as d:
    skew = lambda scale: rng.lognormal(0, 1.0, N) * scale
    base = {"peak": normal(850, 30), "p99": skew(160), "rps": normal(760, 8)}
    samm = {"peak": normal(850, 30), "p99": skew(60), "rps": normal(760, 8)}
    study(d, base, samm)
    tests, _, _ = run(d)
    t = tests["processing_p99_ms"]
    direct = stats.mannwhitneyu(samm["p99"], base["p99"], alternative="two-sided")
    check("B skewed latency: Mann-Whitney chosen", t["test"] == "Mann-Whitney U", t["test"])
    check("B U and p match scipy directly", abs(float(t["statistic"]) - direct.statistic) < 1e-9 and abs(float(t["p"]) - direct.pvalue) < 1e-12)
    check("B the reason is recorded", "normality rejected" in t["why"], t["why"])
    check("B metrics with no real difference are not rejected",
          tests["peak_rss_mb"]["reject_h0"] == "False" and tests["throughput_rps"]["reject_h0"] == "False")

# C. Normal but unequal variances -> Levene rejects -> Mann-Whitney, as the approved text says.
with tempfile.TemporaryDirectory() as d:
    base = {"peak": normal(850, 5), "p99": normal(160, 20), "rps": normal(760, 8)}
    samm = {"peak": normal(850, 60), "p99": normal(160, 20), "rps": normal(760, 8)}
    study(d, base, samm)
    tests, _, _ = run(d)
    t = tests["peak_rss_mb"]
    check("C unequal variances: Mann-Whitney chosen", t["test"] == "Mann-Whitney U", t["test"])
    check("C the reason is recorded", "homogeneity of variance rejected" in t["why"], t["why"])
    check("C Levene's p matches scipy with center='mean'",
          abs(float(t["levene_p"]) - stats.levene(base["peak"], samm["peak"], center="mean").pvalue) < 1e-12)

# D. Killed and timing-suspect runs are left out of the tests and counted separately.
with tempfile.TemporaryDirectory() as d:
    base = {"peak": normal(850, 30), "p99": normal(160, 20), "rps": normal(760, 8)}
    samm = {"peak": normal(900, 30), "p99": normal(120, 20), "rps": normal(800, 8)}
    killed = {("jemalloc", i) for i in range(1, 16)}            # 15 baseline runs die
    suspect = {("samm", 20), ("samm", 21)}
    study(d, base, samm, killed=killed, suspect=suspect)
    tests, survival, report = run(d)
    b, s = survival["jemalloc"], survival["samm"]
    check("D 15 baseline runs counted as killed, all OOM", b["killed"] == "15" and b["oom_killed"] == "15", str(b))
    check("D 85 baseline runs contribute", b["contributing"] == "85" and tests["peak_rss_mb"]["n_baseline"] == "85")
    check("D 2 suspect SAMM runs excluded, none killed", s["timing_suspect"] == "2" and s["contributing"] == "98" and s["killed"] == "0")
    kept = np.array([base["peak"][i] for i in range(N) if ("jemalloc", i + 1) not in killed])
    sk = np.array([samm["peak"][i] for i in range(N) if ("samm", i + 1) not in suspect])
    direct = stats.ttest_ind(sk, kept, equal_var=True)
    if tests["peak_rss_mb"]["test"] == "independent-samples t-test":
        check("D the test uses exactly the surviving runs", abs(float(tests["peak_rss_mb"]["statistic"]) - direct.statistic) < 1e-9)
    full = np.mean([base["rps"][i] * 600 * (0.4 if ("jemalloc", i + 1) in killed else 1.0) / 600 for i in range(N)])
    check("D full-window throughput counts every run, killed ones at what they served",
          abs(float(b["full_window_rps"]) - np.mean([int(base["rps"][i] * 600) * (0.4 if ("jemalloc", i + 1) in killed else 1.0) / 600 for i in range(N)])) < 0.01,
          f"{b['full_window_rps']} vs about {full:.2f}")
    check("D more than 10 % killed is called out as the principal result", "MORE THAN 10 %" in report)

# E. No difference anywhere -> nothing rejected; the paired supplement runs when asked.
with tempfile.TemporaryDirectory() as d:
    base = {"peak": normal(850, 30), "p99": normal(160, 20), "rps": normal(760, 8)}
    samm = {"peak": normal(850, 30), "p99": normal(160, 20), "rps": normal(760, 8)}
    study(d, base, samm)
    tests, _, report = run(d, "--with-paired")
    check("E no difference: no H0 rejected", all(t["reject_h0"] == "False" for t in tests.values()),
          str({k: t["p"] for k, t in tests.items()}))
    check("E paired supplement is labelled as outside the approved method", "SUPPLEMENTARY paired analysis" in report)
    check("E tables.md is written with the three tables",
          sum(line.startswith("| :---: |") for line in open(os.path.join(d, "stats", "tables.md"))) == 3)

print(f"\n{len(failures)} check(s) failed" if failures else "\nall checks passed")
sys.exit(1 if failures else 0)
