#!/usr/bin/env python3
"""
Statistics for the main study, as the approved methodology states them.

Written on 2026-11-13, before any main-study run existed, so that nothing about
the analysis could be chosen after seeing the data.

Input: a run_replicates.sh results folder (rNN-<condition>.json, one per run).

For each of the three primary metrics -- peak container memory, P99 processing
time, mean sustained throughput:

  1. Shapiro-Wilk on each condition's sample (normality) and Levene's test
     across the two (homogeneity of variance), each judged at 0.05.
  2. If both samples are normal AND the variances are homogeneous: an
     independent-samples t-test. Otherwise: a Mann-Whitney U test. Two-sided.
  3. Bonferroni: the result is significant if p < 0.05 / 3 (about 0.017).
  4. The relative percentage difference, (SAMM - baseline) / baseline.

Runs that do not enter the tests (rules fixed 2026-11-13):
  - a run whose container was killed or died (Docker's end state, an OOM kill,
    no CPU counters at teardown, or more than 5 % failed requests): its metrics
    cover only the time it lived;
  - a run the harness flagged timing-suspect (the wall window overshot the
    schedule: the host stalled).
Survival is reported separately, and throughput over the full scheduled window
is reported with killed runs INCLUDED, as a check against survivorship bias.

Both conditions in a replicate share a seed, so the two samples are positively
related. The independent-samples tests do not use that, which makes them
conservative. --with-paired adds a paired analysis as a supplement; it is not
part of the approved method.

Usage:
  main_study_stats.py RESULTS_DIR [--baseline jemalloc] [--treatment samm]
                      [--duration-s 600] [--with-paired] [--out DIR]

Writes, under RESULTS_DIR/stats (or --out): report.txt, descriptives.csv,
tests.csv, survival.csv, and tables.md (Chapter 4's tables, filled in).
"""

import argparse
import csv
import glob
import json
import math
import os
import statistics as st
import sys

from scipy import stats

ALPHA = 0.05
PRIMARY = [
    # key, name in the manuscript, unit
    ("peak_rss_mb", "Peak container memory", "MiB"),
    ("processing_p99_ms", "P99 processing time", "ms"),
    ("throughput_rps", "Mean sustained throughput", "req/s"),
]
ALPHA_ADJUSTED = ALPHA / len(PRIMARY)
SUPPORTING = [
    ("processing_p95_ms", "P95 processing time", "ms"),
    ("latency_p99_ms", "End-to-end P99", "ms"),
    ("cpu_utilisation_pct", "CPU utilisation", "% of the core"),
    ("page_faults_per_request", "Page faults per request", ""),
    ("dropped_iterations", "Dropped iterations", "per run"),
    ("failed_pct", "Failed requests", "%"),
]


def load(results_dir, condition):
    runs = []
    for path in sorted(glob.glob(os.path.join(results_dir, f"r*-{condition}.json"))):
        with open(path) as f:
            r = json.load(f)
        r["replicate"] = os.path.basename(path).split("-")[0]
        ended = (r.get("container_end_state") or {}).get("status")
        r["killed"] = bool(
            r["cpu_utilisation_pct"] == 0.0 or r["oom_kills"] > 0 or r["failed_rate"] > 0.05
            or ended not in (None, "running", "unknown"))
        r["suspect"] = bool(r.get("timing_suspect", False))
        r["included"] = not r["killed"] and not r["suspect"]
        r["failed_pct"] = 100.0 * r["failed_rate"]
        r["served"] = r["requests"] * (1.0 - r["failed_rate"])
        runs.append(r)
    return runs


def values(runs, key):
    return [float(r[key]) for r in runs if r["included"] and r.get(key) is not None]


def describe(x):
    if not x:
        return {"n": 0, "mean": math.nan, "sd": math.nan, "median": math.nan, "min": math.nan, "max": math.nan}
    return {"n": len(x), "mean": st.mean(x), "sd": st.stdev(x) if len(x) > 1 else math.nan,
            "median": st.median(x), "min": min(x), "max": max(x)}


def primary_test(base, treat):
    """The approved decision rule for one metric. Returns a dict of everything reported."""
    out = {"n_baseline": len(base), "n_treatment": len(treat)}
    if len(base) < 3 or len(treat) < 3:
        out.update(test="not enough runs", statistic=math.nan, df=None, p=math.nan,
                   shapiro_baseline_p=math.nan, shapiro_treatment_p=math.nan, levene_p=math.nan)
        return out
    out["shapiro_baseline_p"] = stats.shapiro(base).pvalue
    out["shapiro_treatment_p"] = stats.shapiro(treat).pvalue
    # center='mean' is Levene's test as originally defined (scipy's default,
    # 'median', is the Brown-Forsythe variant).
    out["levene_p"] = stats.levene(base, treat, center="mean").pvalue
    normal = out["shapiro_baseline_p"] > ALPHA and out["shapiro_treatment_p"] > ALPHA
    homogeneous = out["levene_p"] > ALPHA
    if normal and homogeneous:
        res = stats.ttest_ind(treat, base, equal_var=True)
        out.update(test="independent-samples t-test", statistic=res.statistic,
                   df=len(base) + len(treat) - 2, p=res.pvalue)
        pooled = math.sqrt(((len(base) - 1) * st.variance(base) + (len(treat) - 1) * st.variance(treat))
                           / (len(base) + len(treat) - 2))
        out["effect_size"] = ("Cohen's d", (st.mean(treat) - st.mean(base)) / pooled if pooled else math.nan)
    else:
        res = stats.mannwhitneyu(treat, base, alternative="two-sided")
        out.update(test="Mann-Whitney U", statistic=res.statistic, df=None, p=res.pvalue)
        # rank-biserial correlation: +1 means every SAMM run exceeded every baseline run
        out["effect_size"] = ("rank-biserial r", 2 * res.statistic / (len(base) * len(treat)) - 1)
    out["why"] = ("both samples normal, variances homogeneous" if normal and homogeneous else
                  "; ".join(filter(None, [None if normal else "normality rejected",
                                          None if homogeneous else "homogeneity of variance rejected"])))
    out["reject_h0"] = bool(out["p"] < ALPHA_ADJUSTED)
    return out


def fmt_p(p):
    if p is None or math.isnan(p):
        return "n/a"
    return "< .001" if p < 0.001 else f"{p:.3f}"


def fmt(v, digits=1):
    return "n/a" if v is None or (isinstance(v, float) and math.isnan(v)) else f"{v:,.{digits}f}"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("results_dir")
    ap.add_argument("--baseline", default="jemalloc")
    ap.add_argument("--treatment", default="samm")
    ap.add_argument("--duration-s", type=float, default=600.0, help="scheduled length of one run")
    ap.add_argument("--with-paired", action="store_true", help="add the supplementary paired analysis")
    ap.add_argument("--out")
    args = ap.parse_args()

    base_runs = load(args.results_dir, args.baseline)
    treat_runs = load(args.results_dir, args.treatment)
    if not base_runs or not treat_runs:
        sys.exit(f"no results for both conditions in {args.results_dir} "
                 f"({len(base_runs)} {args.baseline}, {len(treat_runs)} {args.treatment})")
    out_dir = args.out or os.path.join(args.results_dir, "stats")
    os.makedirs(out_dir, exist_ok=True)
    names = {args.baseline: "Baseline V8 Engine", args.treatment: "SAMM Engine"}
    lines = []
    p = lines.append

    # ------------------------------------------------------------ survival
    survival = {}
    for cond, runs in ((args.baseline, base_runs), (args.treatment, treat_runs)):
        killed = [r for r in runs if r["killed"]]
        oom = [r for r in killed if r["oom_kills"] > 0 or (r.get("container_end_state") or {}).get("oom_killed")]
        suspect = [r for r in runs if r["suspect"] and not r["killed"]]
        survival[cond] = {
            "attempted": len(runs), "completed": len(runs) - len(killed), "killed": len(killed),
            "oom_killed": len(oom), "timing_suspect": len(suspect),
            "contributing": sum(r["included"] for r in runs),
            # requests actually served, spread over the whole scheduled window, EVERY run counted
            "full_window_rps": st.mean(r["served"] / args.duration_s for r in runs),
            "killed_replicates": " ".join(r["replicate"] for r in killed),
        }
    b, t = survival[args.baseline], survival[args.treatment]
    fisher = stats.fisher_exact([[b["completed"], b["killed"]], [t["completed"], t["killed"]]]).pvalue
    worst_loss = max(b["killed"] / b["attempted"], t["killed"] / t["attempted"])

    p("=" * 96)
    p(f" Main study statistics: {os.path.abspath(args.results_dir)}")
    p(f" baseline = {args.baseline}, treatment = {args.treatment}; "
      f"Bonferroni alpha = {ALPHA}/{len(PRIMARY)} = {ALPHA_ADJUSTED:.4f}")
    p("=" * 96)
    p("\n 1. Run completion")
    p(f" {'':44}{names[args.baseline]:>22}{names[args.treatment]:>22}")
    for label, key in (("Runs attempted", "attempted"), ("Runs completing the workload", "completed"),
                       ("Runs killed or died", "killed"), ("  of which OOM-killed", "oom_killed"),
                       ("Timing-suspect (host stalled), excluded", "timing_suspect"),
                       ("Runs contributing to the tests", "contributing")):
        p(f" {label:44}{b[key]:>22}{t[key]:>22}")
    p(f" {'Full-window throughput, all runs, req/s':44}{b['full_window_rps']:>22,.1f}{t['full_window_rps']:>22,.1f}")
    p(f" Survival, Fisher's exact test (supplementary): p = {fmt_p(fisher)}")
    if worst_loss > 0.10:
        p(" MORE THAN 10 % of a condition's runs were killed: by the rule fixed in advance, survival is")
        p(" the principal result, and the tests below describe only the runs that completed.")

    # --------------------------------------------------------- primary tests
    p("\n 2. Primary metrics (runs contributing to the tests)")
    p(f" {'metric':36}{'baseline mean ± SD':>22}{'SAMM mean ± SD':>22}{'relative change':>18}")
    tests, desc_rows = [], []
    for key, name, unit in PRIMARY:
        x, y = values(base_runs, key), values(treat_runs, key)
        dx, dy = describe(x), describe(y)
        rel = 100.0 * (dy["mean"] - dx["mean"]) / dx["mean"] if x and y and dx["mean"] else math.nan
        res = primary_test(x, y)
        res.update(metric=key, name=name, unit=unit, baseline=dx, treatment=dy, relative_pct=rel)
        tests.append(res)
        p(f" {name + ', ' + unit:36}{fmt(dx['mean']) + ' ± ' + fmt(dx['sd']):>22}"
          f"{fmt(dy['mean']) + ' ± ' + fmt(dy['sd']):>22}{fmt(rel) + ' %':>18}")
        for cond, d in ((args.baseline, dx), (args.treatment, dy)):
            desc_rows.append({"metric": key, "condition": cond, "primary": True, **d})

    p("\n 3. Assumption checks and two-sided tests")
    p(f" {'metric':28}{'Shapiro p (base / SAMM)':>26}{'Levene p':>10}  {'test':28}{'statistic':>12}{'p':>9}  decision on H0")
    for res in tests:
        stat = (f"t({res['df']}) = {res['statistic']:.3f}" if res["test"].startswith("independent")
                else f"U = {res['statistic']:,.1f}" if res["test"].startswith("Mann") else "n/a")
        decision = "n/a" if math.isnan(res["p"]) else ("Reject" if res["reject_h0"] else "Fail to reject")
        p(f" {res['name']:28}{fmt_p(res['shapiro_baseline_p']) + ' / ' + fmt_p(res['shapiro_treatment_p']):>26}"
          f"{fmt_p(res['levene_p']):>10}  {res['test']:28}{stat:>12}{fmt_p(res['p']):>9}  {decision}")
    p(f" Decisions compare the unrounded p with {ALPHA_ADJUSTED:.4f}. A rejected H0 favours whichever")
    p(" condition the relative change in section 2 favours for that metric.")

    # ----------------------------------------------------------- supporting
    p("\n 4. Supporting measures (descriptive, not tested)")
    p(f" {'measure':34}{'baseline mean ± SD':>24}{'SAMM mean ± SD':>24}")
    for key, name, unit in SUPPORTING:
        x, y = values(base_runs, key), values(treat_runs, key)
        if not x and not y:
            continue
        dx, dy = describe(x), describe(y)
        digits = 0 if key == "dropped_iterations" else 2
        p(f" {(name + (', ' + unit if unit else '')):34}{fmt(dx['mean'], digits) + ' ± ' + fmt(dx['sd'], digits):>24}"
          f"{fmt(dy['mean'], digits) + ' ± ' + fmt(dy['sd'], digits):>24}")
        for cond, d in ((args.baseline, dx), (args.treatment, dy)):
            desc_rows.append({"metric": key, "condition": cond, "primary": False, **d})

    # --------------------------------------------------- paired supplement
    paired = []
    if args.with_paired:
        p("\n 5. SUPPLEMENTARY paired analysis (not part of the approved method)")
        by_rep = {r["replicate"]: r for r in base_runs if r["included"]}
        for key, name, unit in PRIMARY:
            pairs = [(by_rep[r["replicate"]][key], r[key]) for r in treat_runs
                     if r["included"] and r["replicate"] in by_rep]
            d = [float(y) - float(x) for x, y in pairs]
            if len(d) < 3:
                continue
            normal = stats.shapiro(d).pvalue > ALPHA
            res = stats.ttest_rel([y for _, y in pairs], [x for x, _ in pairs]) if normal else stats.wilcoxon(d)
            paired.append({"metric": key, "pairs": len(d), "mean_difference": st.mean(d),
                           "test": "paired t-test" if normal else "Wilcoxon signed-rank",
                           "statistic": res.statistic, "p": res.pvalue})
            p(f" {name:28}{len(d):>4} pairs, mean difference {st.mean(d):+,.2f} {unit}, "
              f"{paired[-1]['test']}, p = {fmt_p(res.pvalue)}")

    report = "\n".join(lines)
    print(report)
    with open(os.path.join(out_dir, "report.txt"), "w") as f:
        f.write(report + "\n")

    # ------------------------------------------------------------------ CSV
    with open(os.path.join(out_dir, "descriptives.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=["metric", "condition", "primary", "n", "mean", "sd", "median", "min", "max"])
        w.writeheader()
        w.writerows(desc_rows)
    with open(os.path.join(out_dir, "tests.csv"), "w", newline="") as f:
        cols = ["metric", "n_baseline", "n_treatment", "shapiro_baseline_p", "shapiro_treatment_p", "levene_p",
                "test", "why", "statistic", "df", "p", "alpha_adjusted", "reject_h0", "relative_pct",
                "effect_size_name", "effect_size"]
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for res in tests:
            name, size = res.get("effect_size", ("", math.nan))
            w.writerow({**{k: res.get(k) for k in cols if k in res}, "alpha_adjusted": ALPHA_ADJUSTED,
                        "effect_size_name": name, "effect_size": size})
    with open(os.path.join(out_dir, "survival.csv"), "w", newline="") as f:
        cols = ["condition", "attempted", "completed", "killed", "oom_killed", "timing_suspect", "contributing",
                "full_window_rps", "killed_replicates"]
        w = csv.DictWriter(f, fieldnames=cols)
        w.writeheader()
        for cond in (args.baseline, args.treatment):
            w.writerow({"condition": cond, **survival[cond]})
    if paired:
        with open(os.path.join(out_dir, "paired_supplement.csv"), "w", newline="") as f:
            w = csv.DictWriter(f, fieldnames=list(paired[0]))
            w.writeheader()
            w.writerows(paired)

    # -------------------------------------------- Chapter 4's tables, filled
    md = ["<!-- Generated by stats-eval/hypothesis-testing/main_study_stats.py. Paste into Chapter 4. -->", "",
          "**Main-study run completion and full-window throughput**", "",
          "| Measure | Baseline V8 Engine | SAMM Engine |", "| :---: | :---: | :---: |",
          f"| Runs attempted | {b['attempted']} | {t['attempted']} |",
          f"| Runs completing the ten-minute workload | {b['completed']} | {t['completed']} |",
          f"| Runs terminated by an out-of-memory kill | {b['oom_killed']} | {t['oom_killed']} |",
          f"| Runs contributing to the primary metric tests | {b['contributing']} | {t['contributing']} |",
          f"| Mean throughput over the full {args.duration_s:.0f}-second window, including terminated runs, req/s "
          f"| {b['full_window_rps']:,.1f} | {t['full_window_rps']:,.1f} |", "",
          "**Main-study performance at the locked stress point**", "",
          "| Per-run measure | Baseline, mean ± SD | SAMM, mean ± SD | Relative change with SAMM |",
          "| :---: | :---: | :---: | :---: |"]
    for res in tests:
        md.append(f"| {res['name']}, {res['unit']} | {fmt(res['baseline']['mean'])} ± {fmt(res['baseline']['sd'])} "
                  f"| {fmt(res['treatment']['mean'])} ± {fmt(res['treatment']['sd'])} | {res['relative_pct']:+.1f}% |")
    x, y = describe(values(base_runs, "processing_p95_ms")), describe(values(treat_runs, "processing_p95_ms"))
    if x["n"] and y["n"]:
        md.append(f"| P95 processing time, ms, supporting measure | {fmt(x['mean'])} ± {fmt(x['sd'])} "
                  f"| {fmt(y['mean'])} ± {fmt(y['sd'])} | {100 * (y['mean'] - x['mean']) / x['mean']:+.1f}% |")
    md += ["", "**Assumption checks and two-sided hypothesis tests**", "",
           "| Metric | Shapiro–Wilk *p*, baseline / SAMM | Levene *p* | Selected test and statistic "
           "| Unadjusted two-sided *p* | Decision on H₀ |", "| :---: | :---: | :---: | :---: | :---: | :---: |"]
    for res in tests:
        stat = (f"*t*({res['df']}) = {res['statistic']:.3f}" if res["test"].startswith("independent")
                else f"*U* = {res['statistic']:,.1f}" if res["test"].startswith("Mann") else "n/a")
        decision = "n/a" if math.isnan(res["p"]) else ("Reject" if res["reject_h0"] else "Fail to reject")
        md.append(f"| {res['name']} | {fmt_p(res['shapiro_baseline_p'])} / {fmt_p(res['shapiro_treatment_p'])} "
                  f"| {fmt_p(res['levene_p'])} | {res['test']}, {stat} | {fmt_p(res['p'])} | {decision} |")
    with open(os.path.join(out_dir, "tables.md"), "w") as f:
        f.write("\n".join(md) + "\n")
    print(f"\n-> {out_dir}/report.txt, descriptives.csv, tests.csv, survival.csv, tables.md")


if __name__ == "__main__":
    main()
