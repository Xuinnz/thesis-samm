# DATASET USED: invocations_per_function
# The invocations_per_function dataset tells the load generator when to attack and how fast to send requests. 

# This file removes all dormant functions
# If there's a day that a function has not burst at least once, it will be dropped.
# A function that bursted in day 1, and not on the other days, is still eligible and will be included
import pandas as pd
import glob
import os
import time

INPUT_DIR = "../../../datasets/azure-trace-2019/intermediate/step1-http-only"
OUTPUT_DIR = "../../../datasets/azure-trace-2019/intermediate/step2-burst-only"

def remove_dormant_functions():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    file_pattern = os.path.join(INPUT_DIR, '*.csv')
    files = sorted(glob.glob(file_pattern))

    if not files:
        print(f"Error: No files found matching {file_pattern}")
        return
    
    print("Starting step 1.2: Dormant Function Removal")
    print("Pass 1: Scanning for burst-eligible functions across all 14 days... \n")

    #1440 columns representing minutes of the day
    minute_cols = [str(i) for i in range(1,1441)]

    # array to store the functions that burst at least once
    eligible_keys = set()
    start_time = time.time()

    # first, find the eligible functions
    # basically columns of 5 (5 minute rolling window) that has an average higher than p95
    for file_path in files:
        filename = os.path.basename(file_path)
        print(f"Scanning {filename} for burst")

        df = pd.read_csv(file_path)
        #computing for p95 of this specific row
        p95 = df[minute_cols].quantile(0.95, axis=1)
        #apply the 5 minute rolling window to all columns
        max_rolling_mean = df[minute_cols].T.rolling(window=5, min_periods=5).mean().T.max(axis=1)
        #filter for rolling windows higher than p95
        mask = (max_rolling_mean > p95)

        #extract the composite keys that met the criteria
        burst_df = df[mask]
        burst_key = set(zip(burst_df['HashOwner'], burst_df['HashApp'], burst_df['HashFunction']))
        #update our eligible keys
        eligible_keys.update(burst_key)
    
    print(f"\nPass 1 Complete. Found {len(eligible_keys)} unique burst-eligible functions globally.")
    print("\nPass 2: Filtering the 14-day trace based on eligible keys...\n")

    # for this one, we filter all the eligible functions from the step 1
    # and write it into a file
    for file_path in files:
        filename = os.path.basename(file_path)
        df = pd.read_csv(file_path).reset_index(drop=True) 

        # we create a composite key for each function
        current_keys = pd.Series(list(zip(df['HashOwner'], df['HashApp'], df['HashFunction'])))

        # if the current key is in eligible key, copy 
        filtered_df = df[current_keys.isin(eligible_keys)].copy()

        # replace the name, then put inside the step2-burst-only folder
        out_filename = filename.replace("http_only", "burst_only")
        out_path = os.path.join(OUTPUT_DIR, out_filename)
        filtered_df.to_csv(out_path, index=False)

        print(f" -> {out_filename}: Retained {len(filtered_df)} / {len(df)} rows")
    elapsed = time.time() - start_time
    print("\n" + "="*50)
    print("Step 1.2 Complete.")
    print(f"Execution time: {elapsed:.2f} seconds")
    print("="*50)

if __name__ == "__main__":
    remove_dormant_functions()