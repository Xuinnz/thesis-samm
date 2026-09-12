#!/bin/bash

# Abort the script instantly if any underlying script fails
set -e

# Resolve the absolute path of the directory containing this master script
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Activate the repo-root virtualenv, matching what every preprocessing
# stage does. Without this the scripts run against the system python3,
# which has no pandas/scikit-learn, and the refinery dies on import
# AFTER the expensive characterization pass has already completed.
source "$BASE_DIR/../venv/bin/activate"

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

# ---------------------------------------------------------------------
# Step 4: Table Compilation
# ---------------------------------------------------------------------
# Bakes the decisions above into zig-allocator/src/routing-table/model_weights.zig.
# The Zig addon must be rebuilt afterwards for the new table to take effect.
echo -e "\n---> Running Step 4: Table Compilation"
cd "$BASE_DIR/table-compiler"
python3 01_compile_routing_table.py

echo -e "\n=== ML Refinery Complete ==="
echo "Rebuild the allocator to pick up the new table: (cd zig-allocator && zig build)"