# DATASET USED: invocations_per_function
# The invocations_per_function dataset tells the load generator when to attack and how fast to send requests. 

# This file filters the invocations_per_function cvs into http only triggers
# Triggers that is not http means that it is created by the machine such as orchestrator, queue, timer, etc.
# We only use the triggers from an actual network traffic

import pandas as pd
import glob
import os
import time


RAW_DIR = "../../../datasets/azure-trace-2019/raw"
PROCESSED_DIR ="../../../datasets/azure-trace-2019/intermediate/step1-http-only"


def filter_http_triggers():
    os.makedirs(PROCESSED_DIR, exist_ok=True)

    file_pattern = os.path.join(RAW_DIR, "invocations_per_function_md.anon.d*.csv")
    files = sorted(glob.glob(file_pattern))

    if not files:
        print(f"Error: No Files found matching {file_pattern}")
        print("Ensure that the CSV are extracted into the raw directory.")

    print(f"Found {len(files)} invocation files. Starting Step 1.1: HTTP Trigger Filtering...\n")

    total_retained = 0
    total_original = 0

    start_time = time.time()

    for file_path in files:
        filename = os.path.basename(file_path)
        print(f"Processing {filename}")

        #Load the CSV
        df = pd.read_csv(file_path)
        original_count = len(df)
        total_original += original_count

        http_df = df[df['Trigger'] == 'http'].copy()
        retained_count = len(http_df)
        total_retained += retained_count

        out_filename = f"http_only_{filename}"
        out_path = os.path.join(PROCESSED_DIR, out_filename)
        http_df.to_csv(out_path, index=False)

        print(f" -> Retained {retained_count}/{original_count} functions. Saved to {out_filename}")

    elapsed = time.time() - start_time
    print("\n" + "="*50)
    print("Step 1.1 Complete.")
    print(f"Total rows evaluated: {total_original}")
    print(f"Total HTTP rows retained: {total_retained}")
    print(f"Execution time: {elapsed:.2f} seconds")
    print("="*50)

if __name__ == "__main__":
    filter_http_triggers()


