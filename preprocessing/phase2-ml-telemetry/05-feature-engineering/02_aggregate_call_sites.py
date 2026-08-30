# Step 5.2: Aggregate Call sites
# all endpoints have their own hashes. They will now be called callsites.
# We calculate for the mean lifespan of each callsites
# Then we will calculate the variance, or how chaotic their lifespan is.
# Output: Callsite Lifespan, Callsite Lifespan Variance
import pandas as pd
import os
import time
import json

INPUT_PATH = "../../../datasets/shadow-telemetry/intermediate/step5-feature-engineering/training_trace_with_lifespan.csv"
OUTPUT_DIR = "../../../datasets/shadow-telemetry/intermediate/step5-feature-engineering"

# Minimum observed objects per call-site for its mu/sigma2 estimates
# to be considered reliable. Matches the Cochran-based n_min threshold
# established in the methodology's convergence-criterion section
# (five-observation minimum for the rarest class, with a 2.5x safety
# multiplier applied during characterization). A call-site with fewer
# samples than this would produce unstable centroid placement in the
# Step 6 K-means clustering.
MIN_OBJECTS_PER_CALL_SITE = 30

def aggregate_call_sites():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    if not os.path.exists(INPUT_PATH):
        print(f"Error: lifespan-annotated telemetry not found at {INPUT_PATH}")
        print("Please ensure Step 5.1 has been run successfully.")
        return

    print("Starting Step 5.2: Call-Site Aggregation")
    start_time = time.time()

    df = pd.read_csv(INPUT_PATH)
    print(f"Loaded {len(df):,} object-level records across "
          f"{df['call_site_hash'].nunique()} unique call-sites.")

    # The K-means refinery operates on call-site-level feature vectors,
    # not individual object records. Aggregate per call-site:
    #   mu_lifespan : mean lifespan_ms      -> central tendency
    #   sigma2      : variance of lifespan_ms -> behavioral consistency
    #   n_objects   : count of records       -> confidence weight
    agg = (
        df.groupby('call_site_hash')['lifespan_ms']
        .agg(mu_lifespan='mean', sigma2='var', n_objects='count')
        .reset_index()
    )

    # ddof=1 (pandas default for .var()) is used above, i.e. sample
    # variance rather than population variance — appropriate since
    # each call-site's tracked objects are a sample of that call-site's
    # true (unobservable in full) lifespan distribution, not the
    # complete population of every allocation that call-site will ever
    # produce across the system's lifetime.

    # A call-site with exactly 1 observation produces NaN variance
    # (division by ddof=1 zero) — these will always fail the
    # MIN_OBJECTS_PER_CALL_SITE filter below regardless, but guard
    # explicitly so downstream steps never see a NaN sigma2.
    agg['sigma2'] = agg['sigma2'].fillna(0.0)

    print(f"\nPer-call-site aggregates (before minimum-sample filtering):")
    print(agg.to_string(index=False))

    # Discard call-sites with insufficient samples — insufficient
    # samples produce unreliable mu/sigma2 estimates that would
    # destabilize K-means centroid convergence in Step 6.
    below_threshold = agg[agg['n_objects'] < MIN_OBJECTS_PER_CALL_SITE]
    dropped_count = len(below_threshold)

    if dropped_count > 0:
        print(f"\nDropping {dropped_count} call-site(s) below the "
              f"minimum sample threshold (n_objects < {MIN_OBJECTS_PER_CALL_SITE}):")
        print(below_threshold.to_string(index=False))
    else:
        print(f"\nAll call-sites meet the minimum sample threshold "
              f"(n_objects >= {MIN_OBJECTS_PER_CALL_SITE}). None dropped.")

    filtered = agg[agg['n_objects'] >= MIN_OBJECTS_PER_CALL_SITE].copy()

    output_csv = os.path.join(OUTPUT_DIR, "call_site_features.csv")
    filtered.to_csv(output_csv, index=False)

    metadata_out = os.path.join(OUTPUT_DIR, "call_site_aggregation_metadata.json")
    with open(metadata_out, 'w') as f:
        json.dump({
            "min_objects_per_call_site_threshold": MIN_OBJECTS_PER_CALL_SITE,
            "call_sites_before_filtering": len(agg),
            "call_sites_after_filtering": len(filtered),
            "call_sites_dropped": dropped_count,
            "dropped_call_sites": below_threshold.to_dict(orient='records'),
        }, f, indent=4)

    elapsed = time.time() - start_time
    print("\n" + "=" * 50)
    print("Step 5.2 Complete.")
    print(f"Call-site features saved to : {output_csv}")
    print(f"Metadata saved to           : {metadata_out}")
    print(f"Execution time              : {elapsed:.2f} seconds")
    print("=" * 50)


if __name__ == "__main__":
    aggregate_call_sites()