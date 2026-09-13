# Variance Threshold Policy
# This function decides whether to put the clusters into bump, slab, system
# This script assigns the final memory allocation policy (Bump, Slab, or System) 
# to each call-site using a two-phase decision matrix:
#
# 1. Scope Filter (System vs. Managed): 
#    The temporal cluster with the highest structural overhang (escaping memory) 
#    is automatically routed to the System Heap.
#
# 2. Predictability Filter (Bump vs. Slab): 
#    The remaining request-scoped call-sites are split using a global variance 
#    threshold (median sigma^2) to measure behavioral chaos.
#    - Low Variance (<= median): Highly predictable. Routed to Bump (reclaimed at once).
#    - High Variance (> median): Unpredictable. Routed to Slab (reclaimed at request-scope).

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

    # Variance threshold which will be used to determine if we put it into slab or bump
    # # We use the median sigma^2 of all non-system sites for this one
    # TODO: Flagging this as well because this approach forces the system 
    # to classify at least one of both slab and bump
    # This approach would not work if we designed it that everything is supposedly bump, or everything is supposedly slab
    theta_v = non_system_df["sigma2"].median()

    print(
        f"\nGlobal variance threshold theta_v (median sigma2 across all "
        f"{len(non_system_df)} non-System call-sites): {theta_v:.4f}"
    )

    # Classify each call-sites according to the decision matrix
    def assign_policy(row):
        if row["temporal_cluster"] == system_cluster_id:
            return "System"
        # Low variance -> Bump allocation
        # High variance -> Slab allocation
        return "Bump" if row["sigma2"] <= theta_v else "Slab"

    df["allocation_policy"] = df.apply(assign_policy, axis=1)

    print("\nFinal policy assignment:")
    policy_cols = ["call_site_hash", "mu_lifespan", "sigma2", "n_objects"]
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
                "theta_v_global_variance_threshold": theta_v,
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
