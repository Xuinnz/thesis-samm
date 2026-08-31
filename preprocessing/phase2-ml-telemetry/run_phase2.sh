#!/bin/bash

# Abort the script instantly if any underlying script fails
set -e

# Resolve the absolute path of the directory containing this master script
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== [Phase 1] Starting Azure Simulation Preprocessing ==="

# ---------------------------------------------------------------------
# Step 4: Missing Value Handling
# ---------------------------------------------------------------------
echo -e "\n---> Running Step 4: Missing Value Handling"
cd "$BASE_DIR/04-missing-value-handling"

bash run_missing_value_handling.sh

# ---------------------------------------------------------------------
# Step 5: Feature Engineering
# ---------------------------------------------------------------------
echo -e "\n---> Running Step 5: Feature Engineering"
cd "$BASE_DIR/05-feature-engineering"
bash run_feature_engineering.sh

# ---------------------------------------------------------------------
# Step 6: Log Transformation
# ---------------------------------------------------------------------
echo -e "\n---> Running Step 6: Log Transformation"
cd "$BASE_DIR/06-log-transformation"
bash run_log_transformation.sh

echo -e "\n=== [Phase 2] Preprocessing Complete ==="