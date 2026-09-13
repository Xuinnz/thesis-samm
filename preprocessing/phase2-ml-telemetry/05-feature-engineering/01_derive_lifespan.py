# Step 5.1: Deriving Lifespan
# calculate for lifespan_ms by subtracting allocation time from finalization time
# if the lifespan_ms is negative, the data is invalid and therefore dropped.

# joins the data with scope_trace.csv to calculate 
# 'scope_relative_lifetime' (GC lifespan divided by HTTP request duration)
# and 'overhang_ms' (GC lag).

# This translates fuzzy GC timing into a structural, load-invariant ratio 
# to deterministically identify escaping vs. request-scoped memory.

# input 1: training_trace_censoring_removed.csv (from step 4)
# input 2: scope_trace.csv (structural HTTP boundaries from the profiler)
# output:  training_trace_with_lifespan.csv (ready for call-site aggregation)

import pandas as pd
import os
import time

INPUT_PATH = "../../../datasets/shadow-telemetry/intermediate/step4-missing-value-handling/training_trace_censoring_removed.csv"
# Written alongside training_trace.csv by the Shadow Profiler: one row per
# request, with the times its scope opened and closed.
SCOPE_PATH = "../../../datasets/shadow-telemetry/raw/scope_trace.csv"
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

    # ------------------------------------------------------------------
    # Scope-relative lifetime
    #
    # lifespan_ms is time-to-FINALIZATION, which is a property of GC scheduling
    # as much as of the object. Measured at 500 RPS every observed lifespan
    # shrank -- aggregate fell from 25.5s to 2.6s -- purely because collection
    # ran more often, and that compression merged the temporal clusters and
    # collapsed the policy assignment. Dividing by the request's own duration
    # removes the load dependence: a buffer that lives for its request has a
    # ratio near 1 whether the server is doing 50 or 500 RPS.
    #
    # WHAT CAN AND CANNOT BE MEASURED HERE
    #
    # "Did this object escape its request?" is a question about REACHABILITY,
    # and this telemetry cannot answer it. All we observe is finalization, and
    # collection is lazy: on a smoke run, 100% of objects were still uncollected
    # when their request ended, including ones that were unreachable the instant
    # the handler returned. A flag defined as finalization > scope_end therefore
    # reads ~100% for every call-site and means nothing.
    #
    # What IS measurable:
    #   died_in_request  finalization happened before the request closed. A
    #                    definite lower bound on request-scoped behaviour --
    #                    true means safe, false means unknown, never "escaped".
    #   overhang_ms      how far past its request the finalization fell. This
    #                    separates GC lag (tens of ms) from genuine retention
    #                    (aggregate holds buffers across many requests), and it
    #                    is what scope_relative_lifetime encodes as a ratio.
    # ------------------------------------------------------------------
    # Both conditions matter: a scope file left over from a newer run beside an
    # older trace that predates scope tracking would otherwise crash the join
    # on a missing column rather than degrade to the no-scope path.
    if os.path.exists(SCOPE_PATH) and 'scope_id' in df.columns:
        scopes = pd.read_csv(SCOPE_PATH).drop_duplicates(subset='scope_id', keep='last')
        scopes['scope_duration_ms'] = scopes['scope_end_ms'] - scopes['scope_start_ms']

        before = len(df)
        df = df.merge(scopes, on='scope_id', how='left')
        assert len(df) == before, "scope join changed the row count"

        df['died_in_request'] = (
            df['finalization_time_ms'] <= df['scope_end_ms']).fillna(False)
        df['overhang_ms'] = df['finalization_time_ms'] - df['scope_end_ms']
        # Guard the divide: a sub-millisecond request would otherwise produce a
        # meaningless ratio rather than a large one.
        safe_duration = df['scope_duration_ms'].where(df['scope_duration_ms'] > 0.001)
        df['scope_relative_lifetime'] = df['lifespan_ms'] / safe_duration

        matched = df['scope_end_ms'].notna()
        print(f"\nScope join: {matched.sum():,} of {len(df):,} records matched a request "
              f"({100 * matched.mean():.2f}%)")
        print(f"Finalized before their request closed: {df['died_in_request'].sum():,} "
              f"({100 * df['died_in_request'].mean():.2f}%)")
        print("\nOverhang past request close, per call-site")
        print("(small = GC lag; large = genuine retention beyond the request):")
        over = df.groupby('call_site_hash')['overhang_ms'].agg(
            ['median', 'mean', 'max', 'count'])
        over.columns = ['median_ms', 'mean_ms', 'max_ms', 'objects']
        print(over.round(1).to_string())
    else:
        if 'scope_id' not in df.columns:
            print("\nWARNING: this trace predates scope tracking (no scope_id column).")
        else:
            print(f"\nWARNING: no scope trace at {SCOPE_PATH}.")
        print("Falling back to GC-observed lifespan only; escape rate cannot be")
        print("measured and the clustering will inherit its load dependence.")
        df['died_in_request'] = False
        df['overhang_ms'] = pd.NA
        df['scope_duration_ms'] = pd.NA
        df['scope_relative_lifetime'] = pd.NA

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