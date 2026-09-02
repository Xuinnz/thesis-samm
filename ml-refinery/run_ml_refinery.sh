#!/bin/bash

# Abort the script instantly if any underlying script fails
set -e

# Resolve the absolute path of the directory containing this master script
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== [ML Refinery] Starting ML Refinery ==="

# ---------------------------------------------------------------------
# Step 1: K-means Clustering
# ---------------------------------------------------------------------
echo -e "\n---> Running Step 1: K-means Clustering"
cd "$BASE_DIR/clustering"

python3 01_kmeans_strata_discovery.py

# ---------------------------------------------------------------------
# Step 2: Policy Assignment
# ---------------------------------------------------------------------
echo -e "\n---> Running Step 2: Variance Threshold Policy"
cd "$BASE_DIR/policy-assignment"
python3 01_variance_threshold_policy.py

# ---------------------------------------------------------------------
# Step 3: Quota Calculation
# ---------------------------------------------------------------------
echo -e "\n---> Running Step 3: Quota Calculation"
cd "$BASE_DIR/quota-calculation"
python3 01_calculate_spatial_quotas.py

echo -e "\n=== ML Refinery Complete ==="