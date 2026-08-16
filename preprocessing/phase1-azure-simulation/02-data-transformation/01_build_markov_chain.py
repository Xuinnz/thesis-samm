# This file creates the marcov chain transition matrix
# We have 4 states, IDLE, RAMP, BURST, COOLDOWN
# Idle -> Below 25th percentile of invocation rate
# Ramp -> 25th to 75th percentile of invocation rate
# Burst -> 75th to 95th percentile of invocation rate
# Cooldown -> Above 95th percentile, followed by a declining window

import pandas as pd
import numpy as np
import glob
import os
import time

INPUT_DIR="../../../datasets/azure-trace-2019/intermediate/step3-zero-fixed"
OUTPUT_DIR="../../../datasets/azure-trace-2019/processed/traffic-models"

def build_markov_chain():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    file_pattern = os.path.join(INPUT_DIR, "*.csv")
    files = sorted(glob.glob(file_pattern))

    if not files:
        print(f"Error: No files found matching {file_pattern}")
        return
    
    print("Starting Step 2.1: Markov-Chain Transition Matrix Construction")

    minute_cols = [str(i) for i in range(1, 1441)]
    start_time = time.time()

    # Aggregate traffic across all functions to build the composite time series
    print("Aggregating 14-day composite time series...")
    daily_sums = []

    for file_path in files:
        df = pd.read_csv(file_path)
        # Sum down the columns (axis=0) to get total invocations per minute across all functions
        # skipna=True ensures the NaNs we created in Step 1.3 are safely ignored
        minute_totals = df[minute_cols].sum(axis=0, skipna=True).values
        daily_sums.append(minute_totals)

    # Concatenate all 14 days chronologically into a single 1D array (20,160 minutes)
    composite_ts = np.concatenate(daily_sums)
    ts_series = pd.Series(composite_ts)

    # Calculate Quantiles
    p25 = np.percentile(composite_ts, 25)
    p75 = np.percentile(composite_ts, 75)
    p95 = np.percentile(composite_ts, 95)

    print(f"Computed Thresholds -> P25: {p25:.2f} | P75: {p75:.2f} | P95: {p95:.2f}")

    # Look-ahead logic for Cooldown (Is the next 3-minute window declining?)
    # We calculate the 3-minute rolling mean and shift it backwards by 3 
    # so that index 't' holds the mean of 't+1', 't+2', and 't+3'.
    next_3_mean = ts_series.rolling(window=3).mean().shift(-3)

    # If the next 3 mins average is strictly less than the current minute, it is declining.
    # We fillna(False) to handle the last 3 minutes of day 14 where look-ahead is impossible.
    is_declining = (next_3_mean < ts_series).fillna(False)

    # State Assignment
    print("Discretizing traffic into Idle, Ramp, Burst, and Cooldown states...")

    states = pd.Series(index=ts_series.index, dtype=str)

    # Condition masks
    cond_idle = ts_series < p25
    cond_ramp = (ts_series >= p25) & (ts_series < p75)
    
    # Cooldown: Captures the entire declining arc from above P75
    cond_cooldown = (ts_series >= p75) & is_declining
    
    # Burst: Sustained high traffic (above P75) that is NOT cooling down
    cond_burst = (ts_series >= p75) & ~is_declining

    # State Assignment — np.select evaluates all conditions simultaneously
    conditions = [cond_cooldown, cond_burst, cond_ramp, cond_idle]
    choices = ['Cooldown', 'Burst', 'Ramp', 'Idle']
    states = pd.Series(
        np.select(conditions, choices, default='Idle'),
        index=ts_series.index
    )

    # Save the labeled time series for the k6 load generator to reference if needed
    labeled_ts_df = pd.DataFrame({
        'Minute': range(1, len(ts_series) + 1),
        'Total_Invocations': ts_series,
        'State': states
    })
    series_out = os.path.join(OUTPUT_DIR, "traffic_state_series.csv")
    labeled_ts_df.to_csv(series_out, index=False)
    
    # Build the Markov Transition Matrix
    print("Computing state-to-state transition probabilities...")

    # Mask out day boundary transitions
    is_boundary = pd.Series(False, index=range(len(ts_series) - 1))
    boundary_indices = [(i * 1440) - 1 for i in range(1, 14)]
    is_boundary.loc[boundary_indices] = True
    valid_mask = ~is_boundary.values

    current_state = states.iloc[:-1].reset_index(drop=True)[valid_mask]
    next_state = states.iloc[1:].reset_index(drop=True)[valid_mask]

    transition_matrix = pd.crosstab(current_state, next_state, normalize='index')    
    # Ensure columns/rows are in a logical order
    state_order = ['Idle', 'Ramp', 'Burst', 'Cooldown']
    transition_matrix = transition_matrix.reindex(index=state_order, columns=state_order, fill_value=0.0)
    
    matrix_out = os.path.join(OUTPUT_DIR, "markov_transition_matrix.csv")
    transition_matrix.to_csv(matrix_out)

    elapsed = time.time() - start_time
    print("\n" + "="*50)
    print("Step 2.1 Complete.")
    print("\nFinal Row-Normalized Transition Matrix:\n")
    print(transition_matrix.round(4))
    print(f"\nExecution time: {elapsed:.2f} seconds")
    print(f"Matrix saved to: {matrix_out}")
    print("="*50)

if __name__ == "__main__":
    build_markov_chain()