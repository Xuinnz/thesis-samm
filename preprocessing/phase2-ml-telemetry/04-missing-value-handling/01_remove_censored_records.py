# Step 4: Removing the right censored records
# basically, we want to remove those finalization_time_ms is empty
# input: training_trace.csv from characterization workload
# output: a dataset without any null as finalization_time_ms(death time)
import pandas as pd
import os
import time
import json

INPUT_PATH = "../../../datasets/shadow-telemetry/raw/training_trace.csv"
OUTPUT_DIR = "../../../datasets/shadow-telemetry/intermediate/step4-missing-value-handling"

def remove_right_censored_records():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    if not os.path.exists(INPUT_PATH):
        print(f"Error: training_trace.csv not found at {INPUT_PATH}")
        print("Please ensure the characterization run (Phase 3/4) has completed.")
        return

    print("Starting Step 4.1: Right-Censored Record Identification and Removal")
    start_time = time.time()

    # Load raw telemetry from the Shadow Profiler.
    # finalization_time_ms is empty for records whose finalizer never
    # fired before shutdown (right-censored) — pandas automatically
    # reads an empty CSV field as NaN, so no special parsing is needed.
    df = pd.read_csv(INPUT_PATH)
    total_records = len(df)
    print(f"Loaded {total_records:,} raw allocation records.")

    # 4.1 — Right-Censored Record Identification and Removal
    #
    # A record is right-censored when the Shadow Profiler observed the
    # allocation but the object's finalizer never fired before the
    # characterization run terminated — most commonly objects still
    # referenced at process exit (e.g. long-lived System-heap
    # candidates, or a natural GC cycle simply not having occurred yet
    # for a short-lived object in the final moments of the run).
    #
    # These are DROPPED rather than imputed. Imputing a finalization
    # time for an object whose actual collection time is unknown would
    # introduce systematic bias into the lifespan distribution, which
    # would in turn skew the K-means boundary between the Medium and
    # System-arena clusters in Step 6.
    is_censored = df['finalization_time_ms'].isnull()
    censored_count = int(is_censored.sum())
    censored_pct = (censored_count / total_records) * 100 if total_records > 0 else 0.0

    print(f"\nRight-censored records identified: {censored_count:,} ({censored_pct:.4f}%)")

    # Break down censoring by call-site — useful for spotting whether
    # censoring is concentrated in a specific call-site (which would
    # suggest a design issue, e.g. an object whose retention logic
    # keeps it alive far longer than the run's duration) rather than
    # being spread thinly and randomly across all call-sites, which is
    # the expected, benign pattern.
    if censored_count > 0:
        censored_by_site = (
            df[is_censored]['call_site_hash']
            .value_counts()
            .rename_axis('call_site_hash')
            .reset_index(name='censored_count')
        )
        print("\nCensored records by call-site hash:")
        print(censored_by_site.to_string(index=False))
    else:
        censored_by_site = pd.DataFrame(columns=['call_site_hash', 'censored_count'])

    # Drop the censored rows.
    cleaned_df = df[~is_censored].copy()
    retained_count = len(cleaned_df)

    print(f"\nRetained (finalized) records: {retained_count:,}")

    # Save cleaned dataset for Step 5 (Feature Engineering).
    output_csv = os.path.join(OUTPUT_DIR, "training_trace_censoring_removed.csv")
    cleaned_df.to_csv(output_csv, index=False)

    # Log the count and percentage of censored records as a reported
    # metric, per the methodology's transparency requirement.
    metadata_out = os.path.join(OUTPUT_DIR, "censoring_metadata.json")
    with open(metadata_out, 'w') as f:
        json.dump({
            "total_records": total_records,
            "censored_count": censored_count,
            "censored_pct": censored_pct,
            "retained_count": retained_count,
            "censored_by_call_site": censored_by_site.to_dict(orient='records'),
        }, f, indent=4)

    elapsed = time.time() - start_time
    print("\n" + "=" * 50)
    print("Step 4.1 Complete.")
    print(f"Cleaned dataset saved to : {output_csv}")
    print(f"Metadata saved to        : {metadata_out}")
    print(f"Execution time           : {elapsed:.2f} seconds")
    print("=" * 50)


if __name__ == "__main__":
    remove_right_censored_records()