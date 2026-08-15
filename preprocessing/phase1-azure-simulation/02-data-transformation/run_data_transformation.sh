#!/bin/bash
# Exit immediately if any command fails
set -e

# Dynamically find the directory where this script lives, regardless of where it was called from
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# Change into that directory so the relative paths in the Python scripts work perfectly
cd "$DIR"

echo "==========================================================="
echo "  [SAMM Pipeline] Phase 1 - Step 2: Data Transformation Started"
echo "==========================================================="

# Activate the virtual environment located at the repository root
source ../../../venv/bin/activate

echo "-> Executing 1.1: Building Markov Chain..."
python3 01_build_markov_chain.py

echo "-> Executing 1.2: Deriving Gaussian Jitter..."
python3 02_derive_jitter.py

echo "==========================================================="
echo "  [SAMM Pipeline] Phase 1 - Step 2: Data Transformation Finished!"
echo "==========================================================="