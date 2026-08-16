# DATASET USED: function_durations_percentile
# This function duration percentile dictates how long the functions stay alive.

import pandas as pd
import numpy as np
import glob
import os
import time
import json

INPUT_DIR = "../../../datasets/azure-trace-2019/raw"
OUTPUT_DIR = "../../../datasets/azure-trace-2019/processed/traffic-models"

# ---------------------------------------------------------------------------
# Log-normal fitting via least-squares across 4 percentile anchors
# 
# Model: log(P_z) = mu + z * sigma
# where z is the standard normal quantile for each percentile anchor.
#
# Using 4 anchors (P25, P50, P75, P99) with least-squares is more stable
# than the 2-anchor interpolation (P50/P99 only) because it constrains both
# the center and spread of the distribution simultaneously, reducing the
# influence of tail noise on sigma.
# ---------------------------------------------------------------------------
Z_SCORES = {
    'percentile_Average_25': -0.6745,
    'percentile_Average_50':  0.0000,
    'percentile_Average_75':  0.6745,
    'percentile_Average_99':  2.3263,
}

PERCENTILE_COLS = list(Z_SCORES.keys())


def fit_lognormal_4anchor(row):
    """
    Fit a log-normal distribution to 4 percentile anchor points using
    ordinary least-squares: log(P_z) = mu + z * sigma.

    Returns (mu, sigma) or (NaN, NaN) if the row is invalid.

    Validity checks:
      - All 4 percentile values must be strictly positive (log is undefined at 0)
      - Fitted sigma must be strictly positive (degenerate distribution otherwise)
      - P99 must be greater than P50 (ensures the tail is to the right)
    """
    values = [row[col] for col in PERCENTILE_COLS]

    # Guard: all anchors must be positive
    if any(v <= 0 for v in values):
        return pd.Series({'mu': np.nan, 'sigma': np.nan})

    # Guard: P99 must exceed P50 — if not, the row is malformed
    if row['percentile_Average_99'] <= row['percentile_Average_50']:
        return pd.Series({'mu': np.nan, 'sigma': np.nan})

    log_vals = np.log([row[col] for col in PERCENTILE_COLS])
    z_scores  = np.array(list(Z_SCORES.values()))

    # Design matrix: [1, z] for each anchor → solves for [mu, sigma]
    A = np.column_stack([np.ones(len(z_scores)), z_scores])
    result = np.linalg.lstsq(A, log_vals, rcond=None)
    mu, sigma = result[0]

    # Guard: sigma must be positive
    if sigma <= 0:
        return pd.Series({'mu': np.nan, 'sigma': np.nan})

    return pd.Series({'mu': mu, 'sigma': sigma})


def derive_gaussian_jitter():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    file_pattern = os.path.join(INPUT_DIR, "function_durations_percentiles.anon.d*.csv")
    files = sorted(glob.glob(file_pattern))

    if not files:
        print(f"Error: No files found matching {file_pattern}")
        return

    print("Starting Step 2.2: Gaussian Jitter Parameter Derivation")
    print(f"Found {len(files)} duration files.\n")

    start_time = time.time()

    # ------------------------------------------------------------------
    # Load all 14 days
    # ------------------------------------------------------------------
    cols_to_use = ['HashOwner', 'HashApp', 'HashFunction'] + PERCENTILE_COLS

    df_list = []
    for file_path in files:
        filename = os.path.basename(file_path)
        print(f"  Loading {filename}...")
        try:
            df = pd.read_csv(file_path, usecols=cols_to_use)
            df_list.append(df)
        except Exception as e:
            print(f"  [Error] Failed to load {filename}: {e}")

    combined_df = pd.concat(df_list, ignore_index=True)
    print(f"\n  Total rows across all days: {len(combined_df):,}")

    # ------------------------------------------------------------------
    # Filter invalid rows before any aggregation
    # A row is invalid if any of the 4 percentile columns is zero or
    # negative. These are either true zero-duration functions (degenerate)
    # or Azure anonymization artifacts.
    # ------------------------------------------------------------------
    valid_mask = combined_df[PERCENTILE_COLS].gt(0).all(axis=1)
    invalid_count = (~valid_mask).sum()
    combined_df = combined_df[valid_mask].copy()

    print(f"  Dropped {invalid_count:,} rows with zero/negative percentile values.")
    print(f"  Remaining rows for fitting: {len(combined_df):,}")

    # ------------------------------------------------------------------
    # Step 1: Average percentile values per function across all days
    #
    # IMPORTANT: We average first, then fit — not fit then average.
    # This ensures each function contributes exactly one data point to
    # the global parameter estimate, regardless of how many days it
    # appears in. A function present in all 14 days should not have
    # 14x the influence of a function present in only 3 days.
    # ------------------------------------------------------------------
    print("\n  Averaging percentile values per function across all days...")

    per_function = (
        combined_df
        .groupby(['HashOwner', 'HashApp', 'HashFunction'])[PERCENTILE_COLS]
        .mean()
        .reset_index()
    )

    print(f"  Unique functions after grouping: {len(per_function):,}")

    # ------------------------------------------------------------------
    # Step 2: Fit log-normal (mu, sigma) per function using 4 anchors
    # ------------------------------------------------------------------
    print("  Fitting log-normal parameters per function (4-anchor least-squares)...")

    fit_params = per_function.apply(fit_lognormal_4anchor, axis=1)
    per_function = pd.concat([per_function, fit_params], axis=1)

    # Report and drop functions where fitting failed
    failed = per_function['mu'].isna().sum()
    per_function = per_function.dropna(subset=['mu', 'sigma'])

    print(f"  Functions with valid fits: {len(per_function):,}")
    print(f"  Functions dropped (degenerate fit): {failed:,}")

    # ------------------------------------------------------------------
    # Step 3: Average mu and sigma across all functions
    #
    # This produces the single global (mu, sigma) pair consumed by k6.
    # We use the mean rather than the median here because mu and sigma
    # are already log-space parameters — the mean is appropriate for
    # aggregating normally-distributed log-space values.
    # ------------------------------------------------------------------
    print("\n  Computing global (mu, sigma) by averaging across all functions...")

    mu    = per_function['mu'].mean()
    sigma = per_function['sigma'].mean()

    mu_std    = per_function['mu'].std()
    sigma_std = per_function['sigma'].std()

    # ------------------------------------------------------------------
    # Back-calculate percentiles for validation
    # If fitting is correct, these should match the empirical global
    # median and P99 of the original data closely.
    # ------------------------------------------------------------------
    back_p25 = np.exp(mu + (-0.6745) * sigma)
    back_p50 = np.exp(mu)
    back_p75 = np.exp(mu + ( 0.6745) * sigma)
    back_p99 = np.exp(mu + ( 2.3263) * sigma)

    print(f"  {'Metric':<30} {'Value':>12}")
    print(f"  {'-'*42}")
    print(f"  {'mu (μ)':<30} {mu:>12.4f} {'N/A':>12}")
    print(f"  {'sigma (σ)':<30} {sigma:>12.4f} {'N/A':>12}")
    print(f"  {'mu std dev':<30} {mu_std:>12.4f} {'N/A':>12}")
    print(f"  {'sigma std dev':<30} {sigma_std:>12.4f} {'N/A':>12}")
    print(f"  {'-'*54}")
    print(f"  {'Back-calc P25 (ms)':<30} {back_p25:>12.1f} {'N/A':>12}")
    print(f"  {'Back-calc P50 (ms)':<30} {back_p50:>12.1f}")
    print(f"  {'Back-calc P75 (ms)':<30} {back_p75:>12.1f} {'N/A':>12}")
    print(f"  {'Back-calc P99 (ms)':<30} {back_p99:>12.1f}")

    # ------------------------------------------------------------------
    # Save output
    # ------------------------------------------------------------------
    output = {
        "mu": mu,
        "sigma": sigma,
        "mu_std": mu_std,
        "sigma_std": sigma_std,
        "back_calc_p25_ms": back_p25,
        "back_calc_p50_ms": back_p50,
        "back_calc_p75_ms": back_p75,
        "back_calc_p99_ms": back_p99,
        "n_functions_fitted": len(per_function),
        "n_functions_dropped": int(failed),
    }

    config_out = os.path.join(OUTPUT_DIR, "jitter_parameters.json")
    with open(config_out, 'w') as f:
        json.dump(output, f, indent=4)

    # Also save the per-function fits for auditability
    per_function_out = os.path.join(OUTPUT_DIR, "jitter_per_function.csv")
    per_function[['HashOwner', 'HashApp', 'HashFunction', 'mu', 'sigma']].to_csv(
        per_function_out, index=False
    )

    elapsed = time.time() - start_time
    print("\n" + "=" * 50)
    print("Step 2.2 Complete.")
    print(f"Jitter parameters saved to : {config_out}")
    print(f"Per-function fits saved to : {per_function_out}")
    print(f"Execution time             : {elapsed:.2f} seconds")
    print("=" * 50)


if __name__ == "__main__":
    derive_gaussian_jitter()