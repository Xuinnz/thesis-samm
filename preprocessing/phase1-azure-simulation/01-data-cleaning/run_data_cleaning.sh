#!/bin/bash
# Exit immediately if any command fails
set -e

# Dynamically find the directory where this script lives, regardless of where it was called from
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Change into that directory so the relative paths in the Python scripts work perfectly
cd "$DIR"

echo "==========================================================="
echo "  [SAMM Pipeline] Phase 1 - Step 1: Data Cleaning Started"
echo "==========================================================="

# Activate the virtual environment located at the repository root
source ../../../venv/bin/activate

echo "-> Executing 1.1: HTTP Trigger Filtering..."
python3 01_filter_http_triggers.py

echo "-> Executing 1.2: Dormant Function Removal..."
python3 02_remove_dormant.py

echo "-> Executing 1.3: Anonymized Zero Treatment..."
python3 03_fix_anonymized_zeros.py

echo "-> Executing 1.4: Missing Day Handling..."
python3 04_handle_missing_days.py

echo "==========================================================="
echo "  [SAMM Pipeline] Phase 1 - Step 1: Data Cleaning Finished!"
echo "==========================================================="