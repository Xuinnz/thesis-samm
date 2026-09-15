# Variance Threshold Policy
# This function decides whether to put the clusters into bump, slab, system
# This script assigns the final memory allocation policy (Bump, Slab, or System) 
# to each call-site using a two-phase decision matrix:
#
# 1. Scope Filter (System vs. Managed): 
#    The temporal cluster with the highest structural overhang (escaping memory) 
#    is automatically routed to the System Heap.
#
# 2. Structure Filter (Bump vs. Slab): a TWO-dimensional decision.
#
#    size_cv        -- is a slab AFFORDABLE for this call-site?
#    sigma_occupancy -- is a bump SAFE for it?
#
#    narrow sizes                  -> Slab   (one class, no waste; individual
#                                             slot reuse tolerates interleaving)
#    wide sizes, steady occupancy  -> Bump   (no rounding, no pinning)
#    wide sizes, chaotic occupancy -> Bump, FLAGGED: neither structure fits.
#
# WHY TWO AXES
#
# The previous rule split on the median of sigma^2 (lifespan variance) alone.
# Two problems, both measured:
#
#  a) It chose a SPATIAL structure from a purely TEMPORAL feature. A slab hands
#     out fixed-size slots, so whether one fits depends on the size
#     distribution -- which never entered the decision. It sent the payload
#     call-site (46,155 distinct sizes spanning three orders of magnitude) to
#     the slab, where it paid 47.7% rounding waste and, far worse, spread over
#     twelve classes each provisioned for its own peak: 1,292 MB of slots
#     against 661 MB of live bytes, a 1.95x penalty in a 435.9 MB pool. 58% of
#     its requests then fell back to malloc.
#
#  b) A MEDIAN threshold forces a 50/50 split. With four managed call-sites,
#     exactly two had to become Slab no matter what they looked like -- the
#     pre-existing TODO in this file flagged precisely this. Absolute
#     thresholds let every call-site take the same structure when that is the
#     right answer.
#
# The temporal axis is kept, because the original reasoning behind it is sound:
# a bump arena resets only when every object in a segment is dead, so a
# call-site whose objects linger unpredictably pins segments. It is now
# measured on slot OCCUPANCY (allocation -> scope end) rather than on
# GC-observed lifespan, since region-per-request releases the slot at scope
# end and collector lag is noise on top of that.

import json
import os
import time
import pandas as pd

INPUT_PATH = "../../datasets/shadow-telemetry/intermediate/ml-refinery/call_site_temporal_clusters.csv"
OUTPUT_DIR = "../../datasets/shadow-telemetry/intermediate/ml-refinery"

def assign_policies():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    if not os.path.exists(INPUT_PATH):
        print(f"Error: temporal cluster assignments not found at {INPUT_PATH}")
        print("Please run ml-refinery/clustering (Strata Discovery) first.") 
        return
    
    print("Starting ML Refinery: Variance-Threshold Policy Assignment")
    start_time = time.time()
    
    # Load csv
    df = pd.read_csv(INPUT_PATH)
    print(
        f"Loaded {len(df)} call-sites across {df['temporal_cluster'].nunique()} temporal strata.\n"
    )

    # Compute mean log-lifespan for each cluster
    # Rank clusters by the same feature the clustering used, so "highest
    # cluster" means the same thing in both steps. With scope-relative lifetime
    # the highest cluster is the one whose objects outlive their request, which
    # is a structural property rather than a load-dependent one.
    rank_feature = ("overhang_log"
                    if "overhang_log" in df.columns
                    else "mu_lifespan_log")
    cluster_means = df.groupby("temporal_cluster")[rank_feature].mean()

    # Identify the cluster with the highest average lifespan
    # It will be designated as System heap
    # TODO: Flagging this because we only flag out the highest lifespan
    # In cases where there's multiple persistent or no persistent at all. This would be bad
    system_cluster_id = cluster_means.idxmax()

    print(
        f"System-heap temporal cluster identified: cluster {system_cluster_id} "
        f"(highest mean {rank_feature} = {cluster_means[system_cluster_id]:.4f})"
    )

    # Filter it out
    non_system_df = df[df["temporal_cluster"] != system_cluster_id]

    # Pick whichever structure wastes fewer BYTES on this call-site.
    #
    # Both costs are computed in feature engineering from the trace itself
    # (see bump_extra_bytes / slab_extra_bytes there), so there is nothing to
    # tune here. That replaces three constants this step used to carry: a
    # median split on lifespan variance, which forced half the call-sites into
    # each policy no matter what they looked like, and two absolute thresholds
    # bolted on afterwards to correct it.
    #
    # The only judgement left is the tie-break. Below one huge page the choice
    # cannot matter for memory, so it is decided on allocation-path cost
    # instead: a bump is a bounds check and a cursor add, a slab is a
    # three-level bitmap scan. HUGE_PAGE is a real unit, not a tuned number.
    HUGE_PAGE = 2 * 1024 * 1024

    has_costs = {"bump_extra_bytes", "slab_extra_bytes"} <= set(df.columns)
    if not has_costs:
        print("WARNING: structure-cost features absent -- falling back to the "
              "old median split on sigma2. Re-run feature engineering.")
        theta_v = non_system_df["sigma2"].median()

    def assign_policy(row):
        if row["temporal_cluster"] == system_cluster_id:
            return "System"
        if not has_costs:
            return "Bump" if row["sigma2"] <= theta_v else "Slab"
        bump_cost = float(row["bump_extra_bytes"])
        slab_cost = float(row["slab_extra_bytes"])
        if max(bump_cost, slab_cost) < HUGE_PAGE:
            return "Bump"          # immaterial either way; take the cheaper path
        return "Bump" if bump_cost <= slab_cost else "Slab"

    df["allocation_policy"] = df.apply(assign_policy, axis=1)

    print("\nFinal policy assignment:")
    if has_costs:
        print("\nStructure cost per call-site (MB wasted by each choice):")
        for _, r in df[df["allocation_policy"] != "System"].iterrows():
            b, sl = r["bump_extra_bytes"]/2**20, r["slab_extra_bytes"]/2**20
            note = "  <- both immaterial, chose cheaper path" if max(b, sl) < 2 else ""
            print(f"  {int(r['call_site_hash']):>22}  bump={b:>9,.1f} MB  "
                  f"slab={sl:>9,.1f} MB  -> {r['allocation_policy']}{note}")

    policy_cols = ["call_site_hash", "mu_lifespan", "sigma2", "n_objects"]
    for extra in ("size_cv", "distinct_sizes", "sigma_occupancy_ms",
                  "bump_extra_bytes", "slab_extra_bytes"):
        if extra in df.columns:
            policy_cols.append(extra)
    for extra in ("died_in_request_rate", "median_overhang_ms"):
        if extra in df.columns:
            policy_cols.append(extra)
    policy_cols += ["temporal_cluster", "allocation_policy"]
    print(df[policy_cols].to_string(index=False))

    # Retention check. Overhang cannot prove escape -- collection is lazy, so
    # every call-site shows SOME overhang -- but a managed call-site whose
    # overhang dwarfs the others is holding memory long past its request and is
    # a candidate for System instead. Reported as an observation, not a verdict.
    if "median_overhang_ms" in df.columns and df["median_overhang_ms"].notna().any():
        managed = df[df["allocation_policy"] != "System"]
        if len(managed) > 0:
            worst = managed.loc[managed["median_overhang_ms"].idxmax()]
            print(f"\nLargest overhang among managed call-sites: "
                  f"{worst['call_site_hash']} at {worst['median_overhang_ms']:.1f} ms median.")
            print("Overhang measures GC lag as well as retention, so this bounds")
            print("retention from above rather than proving it.")

    # Output 
    output_csv = os.path.join(OUTPUT_DIR, "call_site_policy_assignment.csv")
    df.to_csv(output_csv, index=False)

    metadata_out = os.path.join(OUTPUT_DIR, "policy_assignment_metadata.json")
    with open(metadata_out, "w") as f:
        json.dump(
            {
                "system_cluster_id": int(system_cluster_id),
                "system_rank_feature": rank_feature,
                "decision_rule": ("minimum-waste" if has_costs else "median-sigma2-fallback"),
                "non_system_call_site_count": len(non_system_df),
                "policy_counts": df["allocation_policy"]
                .value_counts()
                .to_dict(),
            },
            f,
            indent=4,
        )

    elapsed = time.time() - start_time
    print("\n" + "=" * 50)
    print("Policy Assignment Complete.")
    print(f"Output saved to  : {output_csv}")
    print(f"Metadata saved to: {metadata_out}")
    print(f"Execution time   : {elapsed:.2f} seconds")
    print("=" * 50)

if __name__ == "__main__":
    assign_policies()
