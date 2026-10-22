#!/usr/bin/env python3
"""
Layer 1 against the reachability oracle (server/routes/_oracle.js).

Layer 1 sends each call-site either to an arena (managed: its bytes are
reclaimed when the request's region closes) or to the System heap. The oracle
run recorded, for every Buffer, the last forced GC that found it alive and the
first that found it dead, so each Buffer's death is bracketed relative to the
end of its request. This scores the routing table's decisions against that,
in the style of Blackburn et al.'s pretenuring evaluation:

  truth \\ decision     managed (Bump/Slab)        System
  request-scoped       GOOD                       NEUTRAL: missed gain
  escaped              BAD (brief / long)         NEUTRAL: correct

A Buffer is
  request-scoped  if it was found dead by request end + DELTA,
  escaped         if a forced GC found it alive later than request end + DELTA
                  (direct evidence: something still reached it),
  ambiguous       if its bracket straddles request end + DELTA,
  censored        if it was alive at shutdown before DELTA had passed, or its
                  request never ended.
Escaped Buffers are brief if found dead by request end + LONG, long if alive
past it. DELTA is the slack for references that outlive 'finish' by an event-loop
turn; reachable is not the same as used, so BAD is an upper bound on harm.

Each cell is weighted three ways: Buffers, bytes, and byte-seconds (bytes x
lifetime, Blackburn's space-time).

Usage:
  oracle_matrix.py RUN_DIR [RUN_DIR ...] [--policy CSV] [--delta-ms 50] [--long-ms 1000]

Writes RUN_DIR/analysis/{site_summary,matrix,sensitivity}.csv and report.txt
for each run, and, given several runs, generalization.csv beside the first.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np
import pandas as pd

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_POLICY = (REPO_ROOT / "datasets/shadow-telemetry/intermediate/ml-refinery"
                  / "call_site_policy_assignment.csv")

# The profiler's call-site hash (profiler/src/profiler.cc Fnv1aHash), which the
# routing table is keyed by. The offset basis is one digit shorter than
# canonical FNV-1a; see zig-allocator/src/hash.zig.
OFFSET_BASIS = 1469598103934665603
PRIME = 1099511628211
MASK = 0xFFFFFFFFFFFFFFFF

MANAGED = {"Bump", "Slab"}
SENSITIVITY_DELTAS_MS = [0, 10, 25, 50, 100, 250, 1000]
SENSITIVITY_GC_STRIDES = [1, 2, 5, 10, 50]


def fnv1a(text):
    h = OFFSET_BASIS
    for byte in text.encode("utf-8"):
        h ^= byte
        h = (h * PRIME) & MASK
    return h


def load_run(run_dir):
    objects = pd.read_csv(run_dir / "objects.csv")
    gcs = pd.read_csv(run_dir / "gcs.csv")
    meta_path = run_dir / "meta.json"
    meta = json.loads(meta_path.read_text()) if meta_path.exists() else None
    if meta is None:
        print(f"WARNING: {run_dir}/meta.json is missing -- the server did not exit "
              "cleanly, so Buffers alive at shutdown were never written.", file=sys.stderr)
    return objects, gcs, meta


def brackets(objects, gc_times=None):
    """Death bracket (lo, hi] in ms relative to request end.

    lo: the last time the Buffer was known alive (a forced GC, or its
        allocation). hi: the first forced GC that found it dead (NaN if none).
    With gc_times, the bracket is the one a cadence using only those GCs would
    have seen: reachability is monotone, so a Buffer alive at its last_alive GC
    was alive at every earlier one, and dead at every GC after first_dead.
    """
    alloc = objects["alloc_ms"].to_numpy()
    last_alive = objects["last_alive_ms"].to_numpy()
    first_dead = objects["first_dead_ms"].to_numpy()
    end = objects["request_end_ms"].to_numpy()

    if gc_times is None:
        lo_abs = np.where(np.isnan(last_alive), alloc, last_alive)
        hi_abs = first_dead
    else:
        t = np.sort(gc_times)
        # latest kept GC at or before last_alive
        i = np.searchsorted(t, np.nan_to_num(last_alive, nan=-np.inf), side="right") - 1
        kept_alive = np.where((i >= 0) & ~np.isnan(last_alive), t[np.clip(i, 0, None)], np.nan)
        lo_abs = np.where(np.isnan(kept_alive), alloc, np.maximum(alloc, kept_alive))
        # earliest kept GC at or after first_dead
        j = np.searchsorted(t, np.nan_to_num(first_dead, nan=np.inf), side="left")
        hi_abs = np.where((j < len(t)) & ~np.isnan(first_dead), t[np.clip(j, 0, len(t) - 1)], np.nan)
    return lo_abs - end, hi_abs - end


def label(objects, delta_ms, long_ms, gc_times=None):
    lo, hi = brackets(objects, gc_times)
    no_request = objects["request_id"].isna().to_numpy()
    open_request = ~no_request & objects["request_end_ms"].isna().to_numpy()
    dead = ~np.isnan(hi)

    out = np.full(len(objects), "ambiguous", dtype=object)
    escaped = lo > delta_ms
    out[escaped & dead & (hi <= long_ms)] = "brief"
    out[escaped & (lo > long_ms)] = "long"
    out[escaped & ~(dead & (hi <= long_ms)) & ~(lo > long_ms)] = "escaped_unknown"
    out[~escaped & dead & (hi <= delta_ms)] = "scoped"
    out[~escaped & ~dead] = "censored"
    out[open_request] = "censored"
    out[no_request] = "no_request"
    return out


def grade(truth, policy):
    managed = policy.isin(MANAGED).to_numpy()
    scoped = truth == "scoped"
    escaped = np.isin(truth, ["brief", "long", "escaped_unknown"])
    g = np.full(len(truth), "excluded", dtype=object)
    g[managed & scoped] = "good"
    g[managed & escaped] = "bad"
    g[~managed & scoped] = "neutral_missed"
    g[~managed & escaped] = "neutral_correct"
    return g


def attach_policy(objects, policy_csv):
    table = pd.read_csv(policy_csv)[["call_site_hash", "allocation_policy"]]
    table["call_site_hash"] = table["call_site_hash"].astype("uint64")
    sites = pd.DataFrame({"call_site": objects["call_site"].unique()})
    sites["call_site_hash"] = sites["call_site"].map(fnv1a).astype("uint64")
    sites = sites.merge(table, on="call_site_hash", how="left")
    # The router answers a miss with policy none: unmanaged, i.e. System.
    sites["in_table"] = sites["allocation_policy"].notna()
    sites["allocation_policy"] = sites["allocation_policy"].fillna("System")
    unexercised = sorted(set(table["call_site_hash"]) - set(sites["call_site_hash"]))
    return objects.merge(sites, on="call_site", how="left"), unexercised


def weights(df):
    lo_abs = np.where(df["last_alive_ms"].isna(), df["alloc_ms"], df["last_alive_ms"])
    death = np.where(df["first_dead_ms"].isna(), lo_abs, (lo_abs + df["first_dead_ms"]) / 2)
    return {
        "buffers": np.ones(len(df)),
        "bytes": df["bytes"].to_numpy(dtype=float),
        "byte_seconds": df["bytes"].to_numpy(dtype=float) * (death - df["alloc_ms"].to_numpy()) / 1000.0,
    }


def matrix(df, w):
    rows = []
    for name, weight in w.items():
        total = weight.sum()
        for cell in ["good", "bad", "neutral_missed", "neutral_correct", "excluded"]:
            mask = df["grade"].to_numpy() == cell
            rows.append({"weighting": name, "cell": cell, "value": weight[mask].sum(),
                         "pct": 100 * weight[mask].sum() / total if total else 0.0})
        bad = df["grade"].to_numpy() == "bad"
        for tier in ["brief", "long", "escaped_unknown"]:
            mask = bad & (df["truth"].to_numpy() == tier)
            rows.append({"weighting": name, "cell": f"bad:{tier}", "value": weight[mask].sum(),
                         "pct": 100 * weight[mask].sum() / total if total else 0.0})
    return pd.DataFrame(rows)


def site_summary(df):
    lo, _ = brackets(df)
    df = df.assign(after_end_alive_ms=lo)
    out = []
    for site, g in df.groupby("call_site"):
        b = g["bytes"].sum()
        row = {
            "call_site": site,
            "call_site_hash": int(g["call_site_hash"].iloc[0]),
            "policy": g["allocation_policy"].iloc[0],
            "in_table": bool(g["in_table"].iloc[0]),
            "buffers": len(g),
            "bytes": int(b),
        }
        for t in ["scoped", "brief", "long", "escaped_unknown", "ambiguous", "censored", "no_request"]:
            row[f"{t}_bytes_pct"] = 100 * g.loc[g["truth"] == t, "bytes"].sum() / b if b else 0.0
        esc = g[g["truth"].isin(["brief", "long", "escaped_unknown"])]
        row["escaped_buffers"] = len(esc)
        # How long after its request a Buffer was still seen alive (a lower
        # bound on its overhang), over the ones that escaped.
        row["alive_after_end_p50_ms"] = float(esc["after_end_alive_ms"].median()) if len(esc) else np.nan
        row["alive_after_end_max_ms"] = float(esc["after_end_alive_ms"].max()) if len(esc) else np.nan
        decided = row["scoped_bytes_pct"] + sum(row[f"{t}_bytes_pct"] for t in ["brief", "long", "escaped_unknown"])
        row["site_truth"] = ("" if decided == 0 else
                             "escaping" if row["scoped_bytes_pct"] < decided / 2 else "request-scoped")
        managed = row["policy"] in MANAGED
        row["site_verdict"] = ("" if not row["site_truth"] else
                               "good" if managed and row["site_truth"] == "request-scoped" else
                               "BAD" if managed else
                               "neutral (missed)" if row["site_truth"] == "request-scoped" else
                               "neutral (correct)")
        out.append(row)
    return pd.DataFrame(out).sort_values("bytes", ascending=False)


def sensitivity(df, gcs, long_ms):
    rows = []
    gc_times = gcs["gc_ms"].to_numpy()
    gaps = np.diff(np.sort(gc_times))
    w = weights(df)["bytes"]
    total = w.sum()
    policy = df["allocation_policy"]
    for stride in SENSITIVITY_GC_STRIDES:
        kept = None if stride == 1 else np.sort(gc_times)[::stride]
        eff = float(np.median(gaps)) * stride if len(gaps) else np.nan
        for delta in SENSITIVITY_DELTAS_MS:
            truth = label(df, delta, long_ms, kept)
            g = grade(truth, policy)
            row = {"gc_stride": stride, "gc_interval_p50_ms": eff, "delta_ms": delta}
            for cell in ["good", "bad", "neutral_missed", "neutral_correct", "excluded"]:
                row[f"{cell}_bytes_pct"] = 100 * w[g == cell].sum() / total if total else 0.0
            row["ambiguous_bytes_pct"] = 100 * w[truth == "ambiguous"].sum() / total if total else 0.0
            rows.append(row)
    return pd.DataFrame(rows)


def analyse(run_dir, policy_csv, delta_ms, long_ms):
    objects, gcs, meta = load_run(run_dir)
    df, unexercised = attach_policy(objects, policy_csv)
    df["truth"] = label(df, delta_ms, long_ms)
    df["grade"] = grade(df["truth"].to_numpy(), df["allocation_policy"])

    out_dir = run_dir / "analysis"
    out_dir.mkdir(exist_ok=True)
    sites = site_summary(df)
    mat = matrix(df, weights(df))
    sens = sensitivity(df, gcs, long_ms)
    sites.to_csv(out_dir / "site_summary.csv", index=False)
    mat.to_csv(out_dir / "matrix.csv", index=False)
    sens.to_csv(out_dir / "sensitivity.csv", index=False)

    gaps = np.diff(np.sort(gcs["gc_ms"].to_numpy()))
    lines = []
    p = lines.append
    p("=" * 92)
    p(f" Layer 1 vs reachability oracle -- {run_dir.name}")
    p(f" table: {policy_csv}")
    p(f" DELTA = {delta_ms:g} ms after request end, LONG = {long_ms:g} ms")
    p("=" * 92)
    if meta:
        t = meta["totals"]
        p(f" {t['requests']:,} requests, {t['tracked']:,} Buffers, {t['gcs']:,} forced GCs over "
          f"{meta['durationMs'] / 1000:,.0f} s (requested every {meta['gcIntervalMs']} ms); "
          f"workload {meta['workload']['fingerprint']}")
    if len(gaps):
        p(f" GC gap p50 {np.median(gaps):.1f} ms, p99 {np.percentile(gaps, 99):.1f} ms, max {gaps.max():.1f} ms; "
          f"GC duration p50 {gcs['duration_ms'].median():.1f} ms, max {gcs['duration_ms'].max():.1f} ms")
    if unexercised:
        p(f" table entries never seen in this run: {', '.join(str(h) for h in unexercised)}")

    p("\n Per call-site (bytes-weighted truth):")
    p(f" {'call site':30}{'policy':>8}{'buffers':>10}{'MB':>9}{'scoped%':>9}{'escaped%':>10}"
      f"{'ambig%':>8}{'cens%':>7}{'alive p50/max ms':>19}  verdict")
    for _, r in sites.iterrows():
        esc = r["brief_bytes_pct"] + r["long_bytes_pct"] + r["escaped_unknown_bytes_pct"]
        alive = ("" if np.isnan(r["alive_after_end_p50_ms"]) else
                 f"{r['alive_after_end_p50_ms']:,.0f}/{r['alive_after_end_max_ms']:,.0f}")
        p(f" {r['call_site']:30}{r['policy'] + ('' if r['in_table'] else '*'):>8}{r['buffers']:>10,}"
          f"{r['bytes'] / 1048576:>9,.1f}{r['scoped_bytes_pct']:>9.2f}{esc:>10.2f}"
          f"{r['ambiguous_bytes_pct']:>8.2f}{r['censored_bytes_pct']:>7.2f}{alive:>19}  {r['site_verdict']}")
    if not sites["in_table"].all():
        p(" * not in the routing table: the router's miss path leaves it to the System heap")

    p("\n Matrix (% of all tracked Buffers / bytes / byte-seconds):")
    piv = mat.pivot(index="cell", columns="weighting", values="pct")
    order = ["good", "bad", "bad:brief", "bad:long", "bad:escaped_unknown",
             "neutral_missed", "neutral_correct", "excluded"]
    p(f" {'':24}{'buffers':>10}{'bytes':>10}{'byte-s':>10}")
    for cell in order:
        p(f" {cell:24}{piv.loc[cell, 'buffers']:>9.2f}%{piv.loc[cell, 'bytes']:>9.2f}%{piv.loc[cell, 'byte_seconds']:>9.2f}%")

    p("\n Sensitivity (bytes-weighted %): every Nth forced GC kept, DELTA swept")
    p(f" {'GC every':>9}{'DELTA':>7}{'good':>8}{'bad':>8}{'missed':>8}{'correct':>9}{'excluded':>10}{'(ambig)':>9}")
    for _, r in sens.iterrows():
        p(f" {r['gc_interval_p50_ms']:>7.0f}ms{r['delta_ms']:>7.0f}{r['good_bytes_pct']:>8.2f}{r['bad_bytes_pct']:>8.2f}"
          f"{r['neutral_missed_bytes_pct']:>8.2f}{r['neutral_correct_bytes_pct']:>9.2f}{r['excluded_bytes_pct']:>10.2f}"
          f"{r['ambiguous_bytes_pct']:>9.2f}")
    p(" excluded = ambiguous + censored + no request. A DELTA below the GC interval cannot place")
    p(" a death on either side of request end, so those rows are mostly ambiguous by construction.")
    report = "\n".join(lines)
    (out_dir / "report.txt").write_text(report + "\n")
    print(report)
    return sites


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("runs", nargs="+", type=Path)
    ap.add_argument("--policy", type=Path, default=DEFAULT_POLICY)
    ap.add_argument("--delta-ms", type=float, default=50.0)
    ap.add_argument("--long-ms", type=float, default=1000.0)
    args = ap.parse_args()

    per_run = {}
    for run in args.runs:
        per_run[run.name] = analyse(run.resolve(), args.policy, args.delta_ms, args.long_ms)
        print()

    if len(per_run) > 1:
        # Is a call-site's truth stable across runs (another seed, another day
        # of traffic)? A table trained on one input is only as good as this.
        frames = []
        for name, sites in per_run.items():
            s = sites.set_index("call_site")
            esc = s["brief_bytes_pct"] + s["long_bytes_pct"] + s["escaped_unknown_bytes_pct"]
            frames.append(pd.DataFrame({f"{name}:escaped_bytes_pct": esc, f"{name}:site_truth": s["site_truth"]}))
        gen = pd.concat(frames, axis=1)
        truths = gen[[c for c in gen.columns if c.endswith(":site_truth")]]
        gen["truth_agrees"] = truths.nunique(axis=1) == 1
        out = args.runs[0].resolve() / "analysis" / "generalization.csv"
        gen.to_csv(out)
        print("Generalization across runs (bytes escaped %, site truth):")
        print(gen.to_string())
        print(f"-> {out}")


if __name__ == "__main__":
    main()
