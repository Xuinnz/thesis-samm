#!/bin/bash
# Exit immediately if any command fails
set -e

# Dynamically find the directory where this script lives, regardless of where it was called from
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Change into that directory so the relative paths in the Python scripts work perfectly
cd "$DIR"

echo "==========================================================="
echo "  [SAMM Pipeline] Phase 2 - Step 5: Feature Engineering"
echo "==========================================================="

# Activate the virtual environment located at the repository root
source ../../../venv/bin/activate

echo "-> Executing 5.1: Per-Object Lifespan Derivation..."
python3 01_derive_lifespan.py

echo "-> Executing 4.1: Call-Site Aggregation..."
python3 02_aggregate_call_sites.py

echo "==========================================================="
echo "  [SAMM Pipeline] Phase 2 - Step 5: Feature Engineering Done!"
echo "==========================================================="