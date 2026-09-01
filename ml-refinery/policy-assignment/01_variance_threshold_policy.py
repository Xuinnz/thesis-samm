# Variance Threshold Policy
# This function decides whether to put the clusters into bump, slab, system
# Currently, the highest lifespan is automatically put into the system. The remaining will be classified as bump or slab
# To determine if a cluster is bump or slab, it will use median sigma^2 of all sites as a threshold
# If it's lower than the median, classify as bump, else classify as slab

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
    cluster_means = df.groupby("temporal_cluster")["mu_lifespan_log"].mean()

    # Identify the cluster with the highest average lifespan
    # It will be designated as System heap
    # TODO: Flagging this because we only flag out the highest lifespan
    # In cases where there's multiple persistent or no persistent at all. This would be bad
    system_cluster_id = cluster_means.idxmax()

    print(
        f"System-heap temporal cluster identified: cluster {system_cluster_id} "
        f"(highest mean mu_lifespan_log = {cluster_means[system_cluster_id]:.4f})"
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
    print(
        df[
            [
                "call_site_hash",
                "mu_lifespan",
                "sigma2",
                "n_objects",
                "temporal_cluster",
                "allocation_policy",
            ]
        ].to_string(index=False)
    )

    # Output 
    output_csv = os.path.join(OUTPUT_DIR, "call_site_policy_assignment.csv")
    df.to_csv(output_csv, index=False)

    metadata_out = os.path.join(OUTPUT_DIR, "policy_assignment_metadata.json")
    with open(metadata_out, "w") as f:
        json.dump(
            {
                "system_cluster_id": int(system_cluster_id),
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
