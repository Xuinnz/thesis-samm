#!/bin/bash

# Abort the script instantly if any underlying script fails
set -e

# Resolve the absolute path of the directory containing this master script
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== [Phase 1] Starting Azure Simulation Preprocessing ==="

# ---------------------------------------------------------------------
# Step 1: Data Cleaning
# ---------------------------------------------------------------------
echo -e "\n---> Running Step 1: Data Cleaning"
cd "$BASE_DIR/01-data-cleaning"

bash run_data_cleaning.sh

# ---------------------------------------------------------------------
# Step 2: Data Transformation
# ---------------------------------------------------------------------
echo -e "\n---> Running Step 2: Data Transformation"
cd "$BASE_DIR/02-data-transformation"
bash run_data_transformation.sh

# ---------------------------------------------------------------------
# Step 3: Normalization
# ---------------------------------------------------------------------
echo -e "\n---> Running Step 3: Normalization"
cd "$BASE_DIR/03-normalization"
bash run_normalization.sh

echo -e "\n=== [Phase 1] Preprocessing Complete ==="