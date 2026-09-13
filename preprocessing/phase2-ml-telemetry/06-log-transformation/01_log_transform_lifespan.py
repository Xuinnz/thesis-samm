# Phase 6: Log Transformation
# The purpose of this preprocessing is to have visible boundaries that k-means will act on
# Example:
#  Raw 1ms -> Log 0.69
#  Raw 40ms -> Log 3.71
#  Raw 60,000ms -> Log 11.00
# By compressing the data, k-means can easily draw clean, mathematically sound boundaries
import pandas as pd
import numpy as np
import os
import time

INPUT_PATH = "../../../datasets/shadow-telemetry/intermediate/step5-feature-engineering/call_site_features.csv"
OUTPUT_DIR = "../../../datasets/shadow-telemetry/intermediate/step6-log-transformation"

def log_transform_lifespan():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    if not os.path.exists(INPUT_PATH):
        print(f"Error: call-site features not found at {INPUT_PATH}")
        print("Please ensure Step 5.2 has been run successfully.")
        return

    print("Starting Step 6.1: Log Transformation of Lifespan Values")
    start_time = time.time()

    df = pd.read_csv(INPUT_PATH)
    print(f"Loaded {len(df)} call-site feature vectors.")

    # Object lifespan distributions are characteristically right-skewed:
    # most call-sites produce short-lived objects clustered together,
    # while a small number of call-sites (e.g. System-heap candidates)
    # produce objects surviving orders of magnitude longer. Fed
    # directly into 1D K-means, this skew would let the long tail
    # dominate centroid placement, compressing the short-lived cluster
    # into an unstable, poorly-separated region.
    #
    # mu_lifespan_log = log(mu_lifespan_ms + 1)
    # The +1 offset handles zero-valued or sub-millisecond lifespans
    # without producing negative or undefined log values.
    if (df['mu_lifespan'] < 0).any():
        print("\nERROR: negative mu_lifespan values found — this should be "
              "impossible given Step 5.1's timestamp integrity check. "
              "Investigate before proceeding.")
        return

    df['mu_lifespan_log'] = np.log(df['mu_lifespan'] + 1)

    # Same log(x+1) treatment for the scope-relative feature, which is what the
    # clustering consumes when it is available. Ratios are heavily right-skewed
    # -- a call-site that escapes its request sits orders of magnitude above one
    # that does not -- and without the transform the centroids collapse onto the
    # escaping site exactly as they do for raw lifespans.
    if 'mu_scope_relative' in df.columns:
        df['mu_scope_relative_log'] = np.log(df['mu_scope_relative'].fillna(0.0) + 1)

    # OVERHANG is the clustering feature: how long an object outlived the
    # request that created it.
    #
    # Neither alternative works. Absolute lifespan includes the legitimate
    # in-request time, so fetch/process (which await ~500ms by design) look
    # long-lived and cluster next to genuinely-retained objects -- that is what
    # merged the strata at 500 RPS. And lifespan-over-request-duration inverts
    # the ordering instead: cache requests finish in under a millisecond, so the
    # ratio hits 278 purely from a tiny denominator.
    #
    # Overhang subtracts the in-request portion and leaves GC lag plus
    # retention. GC lag is a property of the runtime and lands in a tight band
    # shared by every call-site; retention is per-call-site and sits far above
    # it. That gap is what K-means separates. Clamped at zero because an object
    # collected before its request closed has no overhang.
    if 'median_overhang_ms' in df.columns:
        df['overhang_log'] = np.log(
            df['median_overhang_ms'].fillna(0.0).clip(lower=0.0) + 1)

    print(f"\nBefore/after log transform (ms -> log-ms scale):")
    display_cols = ['call_site_hash', 'mu_lifespan', 'mu_lifespan_log', 'sigma2', 'n_objects']
    for extra in ('median_overhang_ms', 'overhang_log', 'mu_scope_relative'):
        if extra in df.columns:
            display_cols.append(extra)
    print(df[display_cols].sort_values('mu_lifespan').to_string(index=False))

    # sigma2 and n_objects are carried through unchanged — they are
    # NOT part of the K-means clustering input (which uses only
    # mu_lifespan_log to discover temporal strata). sigma2 is consumed
    # later, within each discovered stratum, by the variance-threshold
    # step that assigns the Bump vs. Slab policy; n_objects continues
    # to serve as the confidence weight for that assignment.
    output_csv = os.path.join(OUTPUT_DIR, "call_site_features_log_transformed.csv")
    df.to_csv(output_csv, index=False)

    elapsed = time.time() - start_time
    print("\n" + "=" * 50)
    print("Step 6.1 Complete.")
    print(f"Output saved to : {output_csv}")
    print(f"Execution time  : {elapsed:.2f} seconds")
    print("=" * 50)
    print("\nThis file is ready for K-means clustering (K-means++ seeding,")
    print("Elbow-Method K-selection) on the mu_lifespan_log column.")


if __name__ == "__main__":
    log_transform_lifespan()