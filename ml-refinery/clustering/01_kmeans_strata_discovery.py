# This file is the K-Means Clustering Algorithm. 
# It clusters the callsites depending on their log-transformed lifespan
# We use the discrete second derivative to check the optimal numbers of cluster
# This is an unsupervised Machine Learning.
# INPUT: call_site_features_log_transformed.csv
# OUTPUT: The callsites as well as their cluster ID.

import pandas as pd
import numpy as np
from sklearn.cluster import KMeans
import os
import time
import json

INPUT_PATH = "../../datasets/shadow-telemetry/intermediate/step6-log-transformation/call_site_features_log_transformed.csv"
OUTPUT_DIR = "../../datasets/shadow-telemetry/intermediate/ml-refinery"

RANDOM_STATE = 42

# When clustering data, normally we have to tell k-means how many clusters to create
# but we can also use the "elbow method" using Within-Cluster Sum of Squares to find the sharpest turn
# This function uses math to do it automatically
def elbow_select_k(inertias, k_values):
    # if fewer than 3 points, we cannot physically calculate a curve
    if len(k_values) < 3:
        return (k_values[-1] if k_values else 1), {}
    
    second_derivatives = {}

    for i in range(1, len(k_values) - 1):
        k = k_values[i]
        wcss_prev = inertias[i - 1] # WCSS(K - 1)
        wcss_curr = inertias[i]     # WCSS(K)
        wcss_next = inertias[i + 1] # WCSS(K + 1)
        # WCSS''(K) = WCSS(K + 1) - 2 * WCSS(K) + WCSS(K - 1)
        # calculates the discrete second derivate. the second derivative measures the
        # rate of change of a curve. The higher the number, the sharper the elbow
        second_derivatives[k] = wcss_next - 2 * wcss_curr + wcss_prev
    
    # returns the highest second derivative (the sharpest elbow)
    best_k = max(second_derivatives, key=second_derivatives.get)
    return best_k, second_derivatives

def discover_strata():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    
    if not os.path.exists(INPUT_PATH):
        print(f"Error: log-transformed call-site features not found at {INPUT_PATH}")
        print("Please ensure Step 6.1 has been run successfully.")
        return
    
    print("Starting ML Refinery: Strata Discovery via K-Means")

    start_time = time.time()
    
    # Load data
    df = pd.read_csv(INPUT_PATH)
    n_sites = len(df)
    print(f"Loaded {n_sites} call-site feature vectors.\n")

    # Extract the lifespan log into 2D Numpy array
    X = df[['mu_lifespan_log']].values 

    # Determine the max number of clusters to test, capped at 10
    # The max number of clusters is equal to how many call sites is there
    max_k = max(1, min(n_sites - 1, 10))
    inertias = []

    print(f"Evaluating K=1..{max_k} (K-means++ seeding, random_state={RANDOM_STATE}, "
          f"10 restarts per K):")
    
    # Test every possible K to find the elbow
    for k in range(1, max_k + 1):
        # init='k-means++': smartly spaces out starting points to avoid random clustering errors.
        # n_init=10: trains 10 models behind the scenes and keeps the best one.
        km = KMeans(n_clusters=k, init='k-means++', n_init=10, random_state=RANDOM_STATE)

        # The model looks at the unlabeled data and groups it
        km.fit(X)

        # Save WCSS score
        inertias.append(km.inertia_)
        print(f" K={k}: WCSS={km.inertia_:.4f}")
    
    # Pass the scores to the math function to find optimal K automatically
    k_values = list(range(1, max_k + 1))
    best_k, second_derivatives = elbow_select_k(inertias, k_values)

    if second_derivatives:
        print(f"\nWCSS''(K) — discrete second derivative (selectable range: K=2..{max_k - 1}):")
        for k, d2 in second_derivatives.items():
            marker = "  <- selected" if k == best_k else ""
            print(f"  K={k}: WCSS''={d2:.4f}{marker}")
    print(f"\nOptimal K (argmax WCSS''): K = {best_k}")

    # Retrain with the final model
    final_km = KMeans(n_clusters=best_k, init='k-means++', n_init=10, random_state=RANDOM_STATE)

    # fit_predict trains the model AND assigns a cluster ID to every row of data
    df['temporal_cluster'] = final_km.fit_predict(X)

    # Since K-Means assign ID randomly, we could sort the cluster centers from smallest the largest and remap the ID
    centroid_order = np.argsort(final_km.cluster_centers_.flatten())

    # create a translation dictionary (if old cluster 2 is the smallest, map 2 -> 0)
    relabel_map = {old: new for new, old in enumerate(centroid_order)}

    # Apply the translation so cluster 0 is always the shortest lifespan
    df['temporal_cluster'] = df['temporal_cluster'].map(relabel_map)

    print("\nCall-sites with assigned temporal cluster:")
    print(df[['call_site_hash', 'mu_lifespan', 'mu_lifespan_log', 'sigma2', 'temporal_cluster']]
          .sort_values('mu_lifespan').to_string(index=False))
    # Save the dataframe back to a CSV. index=False stops pandas from writing row numbers.
    output_csv = os.path.join(OUTPUT_DIR, "call_site_temporal_clusters.csv")
    df.to_csv(output_csv, index=False)

    # Save all the math variables and scores into a cleanly formatted JSON text file.
    metadata_out = os.path.join(OUTPUT_DIR, "clustering_metadata.json")
    with open(metadata_out, 'w') as f:
        json.dump({
            "random_state": RANDOM_STATE,
            "k_evaluated": list(range(1, max_k + 1)),
            "wcss": inertias,
            "second_derivatives": second_derivatives,
            "selected_k": best_k,
        }, f, indent=4)  # indent=4 adds spacing to make it readable for humans

    elapsed = time.time() - start_time
    print("\n" + "=" * 50)
    print("Strata Discovery Complete.")
    print(f"Output saved to  : {output_csv}")
    print(f"Metadata saved to: {metadata_out}")
    print(f"Execution time   : {elapsed:.2f} seconds")
    print("=" * 50)


if __name__ == "__main__":
    discover_strata()

