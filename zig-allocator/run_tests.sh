#!/bin/bash

# Abort the script instantly if any underlying step fails
set -e

# Resolve the absolute path of the directory containing this script
BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BASE_DIR"

echo "=== [Zig Allocator] Starting Test Suite ==="

# ---------------------------------------------------------------------
# Step 1: Table compiler validation (Python)
# ---------------------------------------------------------------------
echo -e "\n---> Running Step 1: Table Compiler Fixture Validation"
python3 tests/test_table_compiler.py

# ---------------------------------------------------------------------
# Step 2: Zig unit tests (hash parity, routing, bump, slab)
# ---------------------------------------------------------------------
echo -e "\n---> Running Step 2: Zig Unit Tests"
zig build test --summary all

# ---------------------------------------------------------------------
# Step 3: Build the N-API addon
# ---------------------------------------------------------------------
echo -e "\n---> Running Step 3: Building N-API Addon"
zig build

# ---------------------------------------------------------------------
# Step 4: Zero-copy verification (needs the Node runtime)
# ---------------------------------------------------------------------
echo -e "\n---> Running Step 4: Zero-Copy Verification"
node tests/zero_copy_test.js

# ---------------------------------------------------------------------
# Step 5: Finalizer reclaim (needs a real garbage collection)
# ---------------------------------------------------------------------
echo -e "\n---> Running Step 5: Finalizer Reclaim"
node --expose-gc tests/finalizer_test.js

# ---------------------------------------------------------------------
# Step 6: Steady-state segment reuse under sustained traffic
# ---------------------------------------------------------------------
echo -e "\n---> Running Step 6: Steady-State Segment Reuse"
node tests/steady_state_test.js

# ---------------------------------------------------------------------
# Step 7: Deterministic region reclamation
# ---------------------------------------------------------------------
echo -e "\n---> Running Step 7: Deterministic Region Reclamation"
node tests/region_test.js

echo -e "\n=== Zig Allocator Test Suite Complete ==="
