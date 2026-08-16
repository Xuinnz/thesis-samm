# normalized the payload to fit the 1GB Container
import pandas as pd
import numpy as np
import os
import time
import json

INPUT_PATH = "../../../datasets/azure-trace-2019/intermediate/step4-memory-profile/memory_percentiles_representative.csv"
OUTPUT_DIR = "../../../datasets/azure-trace-2019/processed/memory-models"

# Target container heap ceiling in megabytes (1 GB = 1024 MB)
CONTAINER_HEAP_CEILING_MB = 1024.0
PCT_COLS_MAP = {
    'p1'  : 'AverageAllocatedMb_pct1',
    'p25' : 'AverageAllocatedMb_pct25',
    'p50' : 'AverageAllocatedMb_pct50',
    'p75' : 'AverageAllocatedMb_pct75',
    'p99' : 'AverageAllocatedMb_pct99',
    'p100': 'AverageAllocatedMb_pct100',
}


def normalize_memory_profiles():
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    
    if not os.path.exists(INPUT_PATH):
        print(f"Error: Representative memory file not found at {INPUT_PATH}")
        print("Please ensure Step 1.4 has been run successfully.")
        return

    print("Starting Step 3.1: Memory Normalization & Container Scaling")
    start_time = time.time()
    
    # 1. Load the representative memory profiles from Step 1.4
    df = pd.read_csv(INPUT_PATH)
    print(f"Loaded {len(df):,} representative app memory profiles.")
    
    # Identify percentile columns dynamically
    percentile_cols = [c for c in df.columns if 'AverageAllocatedMb_pct' in c]
    
    if not percentile_cols:
        print("Error: Could not find percentile columns (AverageAllocatedMb_pct*) in the dataset.")
        return

    # 2. Determine the Global P99 Anchor
    # We find the 99th percentile across the combined distribution of all apps' P99 values.
    # This acts as our normalization divisor.
    p99_column = [c for c in percentile_cols if '99' in c]
    if not p99_column:
        print("Error: P99 percentile column not found.")
        return
        
    p99_anchor_val = df[PCT_COLS_MAP['p99']].quantile(0.99)
    print(f"Global P99 Normalization Anchor established at: {p99_anchor_val:.2f} MB")
    
    # Safety guard against division by zero
    if p99_anchor_val <= 0:
        print("Error: P99 anchor value is zero or negative. Aborting normalization.")
        return

    # 3. Normalize to [0, 1] scale relative to the P99 anchor
    # We clip values at 1.0 so that extreme outliers above P99 cap out at the maximum container limit
    normalized_df = df.copy()
    for col in percentile_cols:
        normalized_df[f"norm_{col}"] = (df[col] / p99_anchor_val).clip(upper=1.0)
        
    # 4. Scale to the Container's 1GB Heap Ceiling
    # This translates the relative scale directly into absolute megabyte payloads for k6 / Node.js
    scaled_df = df[['HashOwner', 'HashApp']].copy()
    scaled_df['Container_Ceiling_MB'] = CONTAINER_HEAP_CEILING_MB
    
    for col in percentile_cols:
        scaled_df[f"payload_{col}_mb"] = normalized_df[f"norm_{col}"] * CONTAINER_HEAP_CEILING_MB

    print(f"\n[Results Summary]")
    print(f"  Container Ceiling     : {CONTAINER_HEAP_CEILING_MB} MB (1 GB)")
    print(f"  Global P99 Anchor     : {p99_anchor_val:.2f} MB (Azure raw)")
    print(f"  Apps Processed    : {len(scaled_df):,}")
    # 6. Save Outputs
    output_csv = os.path.join(OUTPUT_DIR, "memory_payload_allocations.csv")
    scaled_df.to_csv(output_csv, index=False)
    
    metadata_out = os.path.join(OUTPUT_DIR, "normalization_metadata.json")
    with open(metadata_out, 'w') as f:
        json.dump({
            "container_ceiling_mb": CONTAINER_HEAP_CEILING_MB,
            "global_p99_azure_anchor_mb": p99_anchor_val,
            "apps_processed": len(scaled_df)
        }, f, indent=4)

    elapsed = time.time() - start_time
    print("\n" + "="*50)
    print("Step 3.1 Complete.")
    print(f"Scaled allocations saved to: {output_csv}")
    print(f"Metadata saved to          : {metadata_out}")
    print(f"Execution time             : {elapsed:.2f} seconds")
    print("="*50)

if __name__ == "__main__":
    normalize_memory_profiles()