#!/bin/bash
# Exit immediately if any command fails
set -e

# Dynamically find the directory where this script lives, regardless of where it was called from
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Change into that directory so the relative paths in the Python scripts work perfectly
cd "$DIR"

echo "==========================================================="
echo "  [SAMM Pipeline] Phase 2 - Step 4: Missing Value Handling"
echo "==========================================================="

# Activate the virtual environment located at the repository root
source ../../../venv/bin/activate

echo "-> Executing 4.1: Removing Censored Records..."
python3 01_remove_censored_records.py

echo "==========================================================="
echo "  [SAMM Pipeline] Phase 2 - Step 4: Missing Value Handling Done!"
echo "==========================================================="