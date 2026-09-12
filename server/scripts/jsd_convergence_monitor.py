"""
jsd_convergence_monitor.py

Implements the Convergence-Based Termination Criterion from the
methodology's Machine Learning Telemetry section. Runs OUTSIDE Docker,
on the host, tailing training_trace.csv as the characterization
container writes to it. Sends a graceful shutdown signal to the
container the moment successive lifespan-distribution windows are
statistically indistinguishable (D_JS <= EPSILON_JSD), or once the
hard cycle ceiling is reached — whichever comes first.

Memory model: only ever holds TWO windows of WINDOW_SIZE lifespan
values at once (prev_window, curr_window). Once curr_window fills and
a comparison is made, prev_window is discarded and curr_window becomes
the new prev_window — memory usage stays flat regardless of how long
the run continues, rather than growing with total collected rows.

=======================================================================
CONFIGURATION CONSTANTS — the paper's formulas require concrete values
for B, p_min, and eps_bias that were not numerically specified in the
original write-up. Chosen values and their justification:

  B_BINS = 30
    Histogram bin count used ONLY for JSD distributional comparison.
    This is unrelated to K (the eventual K-means cluster count, which
    is not known yet at collection time) — a separate, earlier
    analysis choice, and should be described as such in the paper.

  P_MIN = 0.005
    Matches the paper's own cited figure: long-lived objects represent
    0.5-1% of allocations (Maas et al., 2020; Mansi & Swift, 2024).
    Conservative (smaller) end of that range used.

  EPS_BIAS = 0.05
    Standard Paninski-style bias-control value.

Given these, n_min = max(ceil(B/(2*eps_bias)), ceil(5*B/p_min)) = 30,000
and the operational threshold (n_min * 2.5) = 75,000.

WINDOW_SIZE = 100,000 was chosen to exceed this computed minimum with
margin, while remaining a clean, citable, round number — NOT set
arbitrarily. This relationship is checked programmatically at startup;
if B_BINS/P_MIN/EPS_BIAS are ever changed, WINDOW_SIZE is validated
against the new computed minimum, not silently trusted.
=======================================================================
"""

import argparse
import math
import subprocess
import sys
import time

import numpy as np

# ---------------------------------------------------------------------
# Tunable constants — see module docstring for justification of values.
# ---------------------------------------------------------------------
B_BINS = 30
P_MIN = 0.005
EPS_BIAS = 0.05
SAFETY_MULTIPLIER = 2.5
WINDOW_SIZE = 100_000       # P and Q window size, in finalized-row count
EPSILON_JSD = 0.01          # convergence threshold, base-2 JSD in [0, 1]
MAX_CYCLES = 10             # hard ceiling, per the methodology's non-stationary-workload safeguard

POLL_INTERVAL_SECONDS = 5   # how often to check the CSV for new rows


def compute_n_min(b_bins=B_BINS, p_min=P_MIN, eps_bias=EPS_BIAS, safety=SAFETY_MULTIPLIER):
    """Returns (raw_n_min, operational_threshold) per the methodology's formula."""
    n_min_paninski = math.ceil(b_bins / (2 * eps_bias))
    n_min_cochran = math.ceil((5 * b_bins) / p_min)
    n_min = max(n_min_paninski, n_min_cochran)
    operational = n_min * safety
    return n_min, operational


def validate_window_size(window_size=WINDOW_SIZE):
    n_min, operational = compute_n_min()
    if window_size < operational:
        raise ValueError(
            f"WINDOW_SIZE ({window_size:,}) is below the computed operational "
            f"threshold ({operational:,.0f}) derived from B_BINS/P_MIN/EPS_BIAS. "
            f"Either raise WINDOW_SIZE or adjust those constants — do not proceed "
            f"with an unvalidated window size."
        )
    return n_min, operational


# ---------------------------------------------------------------------
# Jensen-Shannon Divergence — implemented directly rather than via
# scipy.spatial.distance.jensenshannon, which returns the JS DISTANCE
# (the square root of the divergence), not the divergence itself. Using
# that distance directly against EPSILON_JSD would silently trigger
# convergence far earlier than the paper's formula intends (since
# sqrt(x) > x for x < 1). Implemented explicitly here to avoid that
# entire class of mistake.
# ---------------------------------------------------------------------

def jensen_shannon_divergence(p_hist, q_hist):
    """
    Computes D_JS(P||Q) = 0.5*D_KL(P||M) + 0.5*D_KL(Q||M), M = 0.5*(P+Q),
    using base-2 logarithms so the result is bounded in [0, 1] as the
    methodology specifies.

    p_hist, q_hist: normalized probability arrays (sum to 1) over the
    SAME fixed bin edges.
    """
    p = np.asarray(p_hist, dtype=np.float64)
    q = np.asarray(q_hist, dtype=np.float64)
    m = 0.5 * (p + q)

    def kl_divergence(a, b):
        # D_KL(A||B) = sum_i A_i * log2(A_i / B_i), summed only where
        # A_i > 0 (the standard convention: 0 * log(0/x) = 0).
        mask = a > 0
        return np.sum(a[mask] * np.log2(a[mask] / b[mask]))

    return 0.5 * kl_divergence(p, m) + 0.5 * kl_divergence(q, m)


def lifespans_to_histogram(lifespan_values, bin_edges):
    """Log-transforms lifespans (consistent with Step 6.1) and bins
    them against FIXED, pre-established edges — using fixed edges
    across every comparison is what makes successive windows
    comparable; recomputing edges per window would let shifting bin
    boundaries masquerade as distributional change."""
    log_vals = np.log(np.asarray(lifespan_values, dtype=np.float64) + 1)
    counts, _ = np.histogram(log_vals, bins=bin_edges)
    total = counts.sum()
    if total == 0:
        return np.zeros(len(bin_edges) - 1)
    return counts / total


# ---------------------------------------------------------------------
# Incremental CSV tailing — reads only NEW lines since the last check,
# tracks a byte offset rather than re-reading the whole file, and
# extracts only FINALIZED rows (non-empty finalization_time_ms) since
# right-censored rows have no valid lifespan yet.
# ---------------------------------------------------------------------

class TraceTailer:
    def __init__(self, path):
        self.path = path
        self._offset = 0
        self._header_skipped = False

    def read_new_lifespans(self):
        """Returns a list of newly-available lifespan_ms values since
        the last call. Blocks on nothing — returns an empty list if no
        new complete lines are available yet."""
        lifespans = []
        try:
            with open(self.path, 'r') as f:
                f.seek(self._offset)
                lines = f.readlines()
                if not lines:
                    return lifespans

                # Only commit the offset past FULLY-written lines — a
                # partially-flushed final line (writer thread mid-write)
                # should be re-read next poll, not consumed as garbage.
                if not lines[-1].endswith('\n'):
                    lines = lines[:-1]

                consumed_bytes = sum(len(l.encode('utf-8')) for l in lines)

                for line in lines:
                    line = line.strip()
                    if not line:
                        continue
                    if not self._header_skipped:
                        self._header_skipped = True
                        continue  # skip the CSV header row exactly once

                    parts = line.split(',')
                    if len(parts) != 4:
                        continue  # defensive: skip malformed lines rather than crash
                    _, _, alloc_ms, final_ms = parts
                    if final_ms == '':
                        continue  # right-censored / not yet finalized — skip for JSD
                    try:
                        lifespan = float(final_ms) - float(alloc_ms)
                        if lifespan >= 0:
                            lifespans.append(lifespan)
                    except ValueError:
                        continue

                self._offset += consumed_bytes
        except FileNotFoundError:
            pass
        return lifespans


# ---------------------------------------------------------------------
# Shutdown trigger — stops the characterization container gracefully,
# which lets the profiler's stop() flush any still-pending objects as
# right-censored records before exit.
# ---------------------------------------------------------------------

def trigger_shutdown(compose_file):
    print(f"[jsd-monitor] Triggering graceful shutdown: docker compose -f {compose_file} down")
    subprocess.run(["docker", "compose", "-f", compose_file, "down"], check=False)


def main():
    parser = argparse.ArgumentParser(description="JSD convergence monitor for SAMM characterization")
    parser.add_argument("--trace-path", required=True, help="Path to training_trace.csv")
    parser.add_argument("--compose-file", required=True, help="Path to docker-compose.yml to shut down on convergence")
    parser.add_argument("--window-size", type=int, default=WINDOW_SIZE)
    parser.add_argument("--epsilon", type=float, default=EPSILON_JSD)
    parser.add_argument("--max-cycles", type=int, default=MAX_CYCLES)
    parser.add_argument("--poll-interval", type=float, default=POLL_INTERVAL_SECONDS)
    args = parser.parse_args()

    n_min, operational = validate_window_size(args.window_size)
    print(f"[jsd-monitor] n_min={n_min:,}  operational_threshold={operational:,.0f}  "
          f"WINDOW_SIZE={args.window_size:,} (OK, exceeds threshold)")
    print(f"[jsd-monitor] epsilon={args.epsilon}  max_cycles={args.max_cycles}  "
          f"B_BINS={B_BINS}  poll_interval={args.poll_interval}s")

    tailer = TraceTailer(args.trace_path)

    prev_window = []
    curr_window = []
    bin_edges = None
    cycle_count = 0

    print("[jsd-monitor] Waiting for training_trace.csv to appear and fill the first window...")

    while True:
        new_vals = tailer.read_new_lifespans()
        curr_window.extend(new_vals)

        if len(curr_window) >= args.window_size:
            window_to_use = curr_window[:args.window_size]
            leftover = curr_window[args.window_size:]  # carry any excess into the next window

            if not prev_window:
                # First window fill — nothing to compare against yet.
                prev_window = window_to_use
                curr_window = leftover
                print(f"[jsd-monitor] First window filled ({len(prev_window):,} rows). "
                      f"Waiting for second window before first comparison.")
                continue

            # Fix bin edges once, from the first comparable pair's
            # combined range — reused for every subsequent comparison
            # so shifting edges never masquerade as distributional
            # change.
            if bin_edges is None:
                combined = np.log(np.array(prev_window + window_to_use) + 1)
                lo, hi = combined.min(), combined.max()
                margin = (hi - lo) * 0.05 if hi > lo else 1.0
                bin_edges = np.linspace(lo - margin, hi + margin, B_BINS + 1)
                print(f"[jsd-monitor] Bin edges fixed for the remainder of this run "
                      f"(log-lifespan range [{lo:.3f}, {hi:.3f}] with margin).")

            p_hist = lifespans_to_histogram(window_to_use, bin_edges)
            q_hist = lifespans_to_histogram(prev_window, bin_edges)
            d_js = jensen_shannon_divergence(p_hist, q_hist)
            cycle_count += 1

            print(f"[jsd-monitor] Cycle {cycle_count}: D_JS(P||Q) = {d_js:.6f} "
                  f"(threshold {args.epsilon})")

            if d_js <= args.epsilon:
                print(f"[jsd-monitor] CONVERGED at cycle {cycle_count} "
                      f"(D_JS={d_js:.6f} <= {args.epsilon}).")
                trigger_shutdown(args.compose_file)
                sys.exit(0)

            if cycle_count >= args.max_cycles:
                print(f"[jsd-monitor] Hard ceiling reached ({args.max_cycles} cycles) "
                      f"without convergence (final D_JS={d_js:.6f}). Proceeding with "
                      f"the most recent window pair as the best available estimate, "
                      f"per the methodology's non-stationary-workload safeguard.")
                trigger_shutdown(args.compose_file)
                sys.exit(0)

            # Slide: discard old prev_window, promote curr_window.
            prev_window = window_to_use
            curr_window = leftover

        time.sleep(args.poll_interval)


if __name__ == "__main__":
    main()