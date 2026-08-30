# Step 5.1: Deriving Lifespan
# calculate for lifespan_ms by subtracting allocation time from finalization time
# if the lifespan_ms is negative, the data is invalid and therefore dropped.

# input: training_trace.csv with right censored data removed (step 4)
# output: training_trace with lifespan
import pandas as pd
import os
import time

INPUT_PATH = "../../../datasets/shadow-telemetry/intermediate/step4-missing-value-handling/training_trace_censoring_removed.csv"
OUTPUT_DIR = "../../../datasets/shadow-telemetry/intermediate/step5-feature-engineering"

def derive_lifespan():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    if not os.path.exists(INPUT_PATH):
        print(f"Error: cleaned telemetry not found at {INPUT_PATH}")
        print("Please ensure Step 4.1 has been run successfully.")
        return

    print("Starting Step 5.1: Per-Object Lifespan Derivation")
    start_time = time.time()

    df = pd.read_csv(INPUT_PATH)
    print(f"Loaded {len(df):,} finalized allocation records.")

    # NOTE ON UNITS: the methodology text describes deriving lifespan
    # from nanosecond timestamps (lifespan_ms = (t_ns_end - t_ns_start)
    # / 1_000_000). The Shadow Profiler's actual native implementation
    # (profiler.cc, NowMs()) uses std::chrono::steady_clock with
    # millisecond-resolution doubles directly, not nanoseconds. Both
    # allocation_time_ms and finalization_time_ms are therefore already
    # in milliseconds, so lifespan is a direct subtraction with no unit
    # conversion. The methodology write-up should be updated to reflect
    # this — millisecond precision was always the stated target
    # granularity (Step 5.1's own rationale: "millisecond precision is
    # sufficient... nanosecond precision is not required"), so this is
    # a units-description correction, not a change in what is measured.
    df['lifespan_ms'] = df['finalization_time_ms'] - df['allocation_time_ms']

    # Sanity guard: a finalization timestamp before its own allocation
    # timestamp would indicate a data integrity problem (clock issue,
    # corrupted record, or a bug in the profiler itself) rather than a
    # normal edge case, since finalization can only happen after
    # allocation by construction. Report and drop any such rows rather
    # than silently keeping negative lifespans.
    negative_mask = df['lifespan_ms'] < 0
    negative_count = int(negative_mask.sum())
    if negative_count > 0:
        print(f"\nWARNING: {negative_count:,} records have negative lifespan_ms "
              f"(finalization before allocation). Dropping these as data integrity "
              f"failures, not normal right-censoring.")
        df = df[~negative_mask].copy()
    else:
        print("\nNo negative lifespans found — timestamp integrity check passed.")

    print(f"\nLifespan summary (ms):")
    print(df['lifespan_ms'].describe().to_string())

    output_csv = os.path.join(OUTPUT_DIR, "training_trace_with_lifespan.csv")
    df.to_csv(output_csv, index=False)

    elapsed = time.time() - start_time
    print("\n" + "=" * 50)
    print("Step 5.1 Complete.")
    print(f"Output saved to : {output_csv}")
    print(f"Execution time  : {elapsed:.2f} seconds")
    print("=" * 50)


if __name__ == "__main__":
    derive_lifespan()