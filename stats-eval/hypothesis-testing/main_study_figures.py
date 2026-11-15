#!/usr/bin/env python3
"""
Figures for a run_replicates.sh results folder (the main study, or an extra).

  primary_distributions.png  the three primary metrics, every contributing run
                             as a point, with the median and the middle half
                             (one panel per metric: each has its own unit)
  campaign_order.png         the same metrics against the replicate number, in
                             the order the campaign ran them: drift, a slow
                             stretch of the host or a killed run shows here

Runs that do not enter the tests (killed, timing-suspect) are left out of the
first figure, exactly as main_study_stats.py leaves them out, and are drawn as
crosses at the bottom edge of the second.

Usage: main_study_figures.py RESULTS_DIR [--baseline jemalloc] [--treatment samm] [--out DIR]
Writes RESULTS_DIR/stats/figures/ (or --out).
"""

import argparse
import os
import sys

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import main_study_stats as mss  # noqa: E402
import verify_campaign  # noqa: E402

# Two series, fixed: the baseline is always blue circles, SAMM always orange
# triangles (colour and shape, so the figure survives a greyscale print).
# Checked with the palette validator: colour-blind separation 24.7, contrast >= 3:1.
SERIES = {"baseline": ("#2a78d6", "o"), "treatment": ("#eb6834", "^")}
INK, INK_2, GRID, SURFACE = "#0b0b0b", "#52514e", "#e4e3df", "#ffffff"


def style(ax):
    ax.set_facecolor(SURFACE)
    for side in ("top", "right"):
        ax.spines[side].set_visible(False)
    for side in ("left", "bottom"):
        ax.spines[side].set_color(GRID)
    ax.tick_params(colors=INK_2, labelsize=9, length=0)
    ax.grid(axis="y", color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)


def distributions(base_runs, treat_runs, names, out):
    fig, axes = plt.subplots(1, 3, figsize=(10.5, 4.2), facecolor=SURFACE)
    rng = np.random.default_rng(1)
    for ax, (key, name, unit) in zip(axes, mss.PRIMARY):
        style(ax)
        for x, (role, runs) in enumerate((("baseline", base_runs), ("treatment", treat_runs))):
            vals = mss.values(runs, key)
            if not vals:
                continue
            color, marker = SERIES[role]
            ax.scatter(x + rng.uniform(-0.16, 0.16, len(vals)), vals, s=22, color=color, marker=marker,
                       alpha=0.55, linewidths=0, zorder=2)
            q1, med, q3 = np.percentile(vals, [25, 50, 75])
            ax.plot([x + 0.27, x + 0.27], [q1, q3], color=INK, linewidth=2, solid_capstyle="round", zorder=3)
            ax.plot([x + 0.22, x + 0.32], [med, med], color=INK, linewidth=2, zorder=3)
            ax.annotate(f"{med:,.1f}", (x + 0.34, med), va="center", fontsize=9, color=INK)
        ax.set_xticks([0, 1], [f"{names[0]}\n(n = {len(mss.values(base_runs, key))})",
                               f"{names[1]}\n(n = {len(mss.values(treat_runs, key))})"])
        ax.set_xlim(-0.5, 1.75)
        ax.set_title(f"{name}, {unit}", fontsize=10.5, color=INK, loc="left")
    fig.text(0.008, 0.012, "Each point is one ten-minute run. Bar: the middle half of the runs; tick and number: the median.",
             fontsize=8.5, color=INK_2)
    fig.tight_layout(rect=(0, 0.04, 1, 1))
    fig.savefig(out, dpi=200)
    plt.close(fig)


def campaign_order(base_runs, treat_runs, names, suspects, out):
    fig, axes = plt.subplots(3, 1, figsize=(10.5, 7.6), sharex=True, facecolor=SURFACE)
    last = max(int(r["replicate"][1:]) for r in base_runs + treat_runs)
    for ax, (key, name, unit) in zip(axes, mss.PRIMARY):
        style(ax)
        for i in sorted(suspects):
            ax.axvspan(i - 0.5, i + 0.5, color=GRID, alpha=0.7, linewidth=0, zorder=0)
        for role, runs, label in (("baseline", base_runs, names[0]), ("treatment", treat_runs, names[1])):
            color, marker = SERIES[role]
            ok = [(int(r["replicate"][1:]), float(r[key])) for r in runs if r["included"] and r.get(key) is not None]
            out_of_test = [int(r["replicate"][1:]) for r in runs if not r["included"]]
            if ok:
                ax.plot(*zip(*ok), color=color, linewidth=0.8, alpha=0.5, zorder=1)
                ax.scatter(*zip(*ok), s=20, color=color, marker=marker, linewidths=0, zorder=2, label=label)
            if out_of_test:
                ax.scatter(out_of_test, [ax.get_ylim()[0]] * len(out_of_test), s=34, color=color, marker="x",
                           linewidths=1.4, zorder=3, clip_on=False)
        ax.set_title(f"{name}, {unit}", fontsize=10.5, color=INK, loc="left")
    if axes[0].get_legend_handles_labels()[0]:
        axes[0].legend(loc="upper right", ncols=2, frameon=False, fontsize=9, labelcolor=INK, handletextpad=0.3,
                       bbox_to_anchor=(1.0, 1.22))
    axes[-1].set_xlabel("Replicate, in the order the campaign ran them", fontsize=9.5, color=INK_2)
    axes[-1].set_xlim(0.5, last + 0.5)
    note = "Crosses at the bottom edge: runs that were killed or timing-suspect, left out of the tests."
    if suspects:
        note += " Grey bands: replicates before a failed host probe."
    fig.text(0.008, 0.008, note, fontsize=8.5, color=INK_2)
    fig.tight_layout(rect=(0, 0.03, 1, 1))
    fig.savefig(out, dpi=200)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("results_dir")
    ap.add_argument("--baseline", default="jemalloc")
    ap.add_argument("--treatment", default="samm")
    ap.add_argument("--out")
    args = ap.parse_args()
    base_runs, treat_runs = mss.load(args.results_dir, args.baseline), mss.load(args.results_dir, args.treatment)
    if not base_runs or not treat_runs:
        sys.exit(f"no results for both conditions in {args.results_dir}")
    out_dir = args.out or os.path.join(args.results_dir, "stats", "figures")
    os.makedirs(out_dir, exist_ok=True)
    names = ("Baseline V8 Engine", "SAMM Engine")
    last = max(int(r["replicate"][1:]) for r in base_runs + treat_runs)
    suspects, _, _ = verify_campaign.host_suspects(args.results_dir, last)
    distributions(base_runs, treat_runs, names, os.path.join(out_dir, "primary_distributions.png"))
    campaign_order(base_runs, treat_runs, names, suspects, os.path.join(out_dir, "campaign_order.png"))
    print(f"-> {out_dir}/primary_distributions.png, campaign_order.png")


if __name__ == "__main__":
    main()
