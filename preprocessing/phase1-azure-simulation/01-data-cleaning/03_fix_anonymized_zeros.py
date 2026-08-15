# DATASET USED: invocations_per_function
# The invocations_per_function dataset tells the load generator when to attack and how fast to send requests. 

# Convert those 0-invocation minutes into NaN if it's less than 5 minutes
# If it's a 5 minute with 0 invocation, it will be considered as a real cooldown
# If not, it will be considered as NaN

import pandas as pd
import numpy as np
import glob
import os
import time


INPUT_DIR = "../../../datasets/azure-trace-2019/intermediate/step2-burst-only"
OUTPUT_DIR = "../../../datasets/azure-trace-2019/intermediate/step3-zero-fixed"

def fix_anonymized_zeros():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    file_pattern = os.path.join(INPUT_DIR, '*.csv')
    files = sorted(glob.glob(file_pattern))

    if not files:
        print(f"Files not found {file_pattern}")
        return
    
    print("Starting Step 1.3: Anonymized Zero Treatment")
    print("Replacing isolated zero-runs under 5 mins with NaN...\n")

    minute_cols =  [str(i) for i in range(1, 1441)]
    start_time = time.time()

    total_replaced = 0

    for file_path in files:
        filename = os.path.basename(file_path)
        df = pd.read_csv(file_path)

        data = df[minute_cols].values.astype(float)

        file_replaced_count = 0

        for i in range(data.shape[0]):
            row = data[i]
            is_zero = (row == 0)

            if not is_zero.any():
                continue
            
            changes = np.diff(is_zero.astype(int), prepend=0, append=0)
            starts = np.where(changes == 1)[0]
            ends = np.where(changes == -1)[0]
            run_lengths = ends - starts

            for s, e, length in zip(starts, ends, run_lengths):
                if length < 5:
                    data[i, s:e] = np.nan
                    file_replaced_count += length

        df[minute_cols] = data
        
        total_replaced += file_replaced_count
        
        out_filename = filename.replace("burst_only_", "zero_fixed_")
        out_path = os.path.join(OUTPUT_DIR, out_filename)
        df.to_csv(out_path, index=False)
        
        print(f"  -> {out_filename}: Converted {file_replaced_count} isolated zeros to NaN.")
    elapsed = time.time() - start_time
    print("\n" + "="*50)
    print("Step 1.3 Complete.")
    print(f"Total isolated zeros converted to NaN globally: {total_replaced}")
    print(f"Execution time: {elapsed:.2f} seconds")
    print("="*50)

if __name__ == "__main__":
    fix_anonymized_zeros()