# DATASET USED: app_memory_percentiles
# The app_memory_percentiles dataset tells the load generator how heavy each of those individual requests should be. 
# It controls the payload size.

# This file takes the 12 daily files and squashing them down into one single profile for each app by averaging the days together.
import pandas as pd
import glob
import os
import time

INPUT_DIR = "../../../datasets/azure-trace-2019/raw"
OUTPUT_DIR = "../../../datasets/azure-trace-2019/intermediate/step4-memory-profile"

def handle_missing_days():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    file_pattern = os.path.join(INPUT_DIR, "app_memory_percentiles.anon.d*.csv")
    files = sorted(glob.glob(file_pattern))

    if not files:
        print(f"Files not found {file_pattern}")
        return
    
    print("Starting Step 1.4: Missing Day Handling")
    print(f"Found {len(files)} memory percentile files.\n")

    start_time = time.time()

    #    Dataset Limitations
    #    app_memory_percentiles files are only available for days d01-d12
    #    Missing: d13 and d14 are absent from the published Microsoft dataset.
    #    Resolution: The mean memory percentile distribution was computed across d01-d12 per app.
    #    This mean distribution acts as the representative profile for the entire 14-day simulation.
    

    # Load all available daily files into a single list
    df_list = []
    for file_path in files:
        filename = os.path.basename(file_path)
        print(f"  Loading {filename}...")
        df_list.append(pd.read_csv(file_path))

    # Concatenate them all into one massive dataframe
    combined_df = pd.concat(df_list, ignore_index=True)

    # Group by Owner and App, then compute the mean.
    # Note: The memory dataset is aggregated at the App level, not the Function level.
    print("\n  Computing representative mean profiles (excluding missing days)...")

    # pandas .mean() automatically ignores NaN/missing values. 
    # If an app only existed on days 1-5, it divides by 5, not 12.
    # numeric_only=True ensures we don't try to average string columns if any exist.
    representative_df = combined_df.groupby(['HashOwner', 'HashApp']).mean(numeric_only=True).reset_index()

    # Save the final representative profile
    out_path = os.path.join(OUTPUT_DIR, "memory_percentiles_representative.csv")
    representative_df.to_csv(out_path, index=False)

    print(f"  -> Saved representative profiles for {len(representative_df)} unique apps to memory_percentiles_representative.csv")

    elapsed = time.time() - start_time
    print("\n" + "="*50)
    print("Step 1.4 Complete.")
    print(f"Execution time: {elapsed:.2f} seconds")
    print("="*50)

if __name__ == "__main__":
    handle_missing_days()