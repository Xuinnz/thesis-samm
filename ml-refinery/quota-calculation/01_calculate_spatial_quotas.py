# This function determines how much container memory (from 1 GB budget) to allocate
# in each arena after reserving overhead for NodeJS V8 engine (System)

# it does this by:
# 1. Loading execution traces and allocation policies and measures Effective Release Time.
# 2. Measuring peak memory usage (High-Water Mark) of each cluster and policy
# 3. Reserving baseline, safety, and System overhead to find the leftover pool
# 4. Proportionally distributing the remaining pool among the arenas
# 5. Exporting the calculated quotas to a JSON configuration file.

# NOTE: Bump allocators have dedicated. So each call sites that are considered bump
# will get their own arena
# Slab allocators have shared arena.

import os
import time
import json
import pandas as pd
import numpy as np


# Step 5's output rather than step 4's: it carries the scope join, which is what
# lets peak demand be computed from when SAMM actually releases memory instead of
# when V8 happens to collect it.
TRACE_PATH = "../../datasets/shadow-telemetry/intermediate/step5-feature-engineering/training_trace_with_lifespan.csv"
POLICY_PATH = "../../datasets/shadow-telemetry/intermediate/ml-refinery/call_site_policy_assignment.csv"
OUTPUT_DIR = "../../datasets/shadow-telemetry/intermediate/ml-refinery"

# Container limit 1GB
# Container memory limit the quotas are sized against. Every downstream number
# -- pool_hard_limit, M_available, every floor -- is derived from it, so a table
# compiled for one container size is invalid in any other. Overridable because
# it was hardcoded, and a limit sweep silently ran a 1024MB-derived table inside
# 600-850MB containers: the pool believed it owned 495.7MB of a 600MB box and
# every run failed within seconds while the workload fingerprint still reported
# "verified". The fingerprint now carries the container size for this reason.
CONTAINER_HEAP_CEILING_BYTES = int(os.environ.get(
    "SAMM_CONTAINER_BYTES", 1024 * 1024 * 1024))

# Base memory required by the V8 runtime engine
# TODO: Flagging because it's hardcoded. currently no backup that supports this
NODE_V8_BASELINE_BYTES = 80 * 1024 * 1024

# Reserved buffer kept unallocated for unexpected allocations to avoid OOM
# TODO: Also flagging because no back up.
GENERAL_SAFETY_MARGIN_BYTES = 32 * 1024 * 1024

# Quantile of concurrent demand that each stratum gets as a non-revocable floor.
# 1.0 reproduces the old behaviour (floor = peak, no elastic headroom).
FLOOR_QUANTILE = float(os.environ.get("SAMM_FLOOR_QUANTILE", 0.90))

# 15% multiplier for system peak concurrency.
# TODO: Also hard coded. good for now
SAFETY_MULTIPLIER = 1.15

# Fraction of the remaining pool to distribute across arenas.
#
# WHY THIS MUST BE BELOW 1.0
#
# pool_hard_limit already subtracts the V8 baseline, the System-stratum
# high-water and a safety margin -- but NOT the capacity fallback path. Every
# allocation the pool refuses goes to malloc, and those bytes live outside the
# pool's accounting entirely. At beta = 1.0 the arena claims every byte not
# otherwise reserved, so the fallback path has nowhere to live.
#
# That was survivable only while the benchmark wrote a fraction of each buffer:
# a 755.6 MB committed pool cost roughly 190 MB resident at a 25% touch cap, so
# the overrun was hidden. Once every route writes what it claims to use,
# committed and resident converge -- measured 712 MB committed and 821 MB RSS at
# only 30 concurrent requests -- and the container is OOM-killed within seconds
# of real load (exit 137, OOMKilled=true).
#
# Beta is the pool's counterpart to SAFETY_MULTIPLIER on the System stratum:
# headroom for demand the characterization did not see.
BETA_UTILIZATION_FRACTION = float(os.environ.get("SAMM_BETA_UTILIZATION", 0.75))

# Minimum bucket size for slab allocation
MIN_SLAB_CLASS_BYTES = 64


# For bitwise buckets
def next_pow2_at_least(n):
    """
    Computes the smallest power of 2 greater than or equal to n.
    Used to set the upper boundary of slab classes so memory requests are binned
    into predictable, power-of-two size classes (64B, 128B, 256B, etc.).
    
    Bitwise trick: (n - 1).bit_length() gives ceil(log2(n)).
    """
    if n <= 1:
        return 1
    return 1 << (int(n - 1).bit_length())


# Building the slab classes, from 64 to max observed bytes (normally 32MB)
def build_slab_classes(max_observed_bytes):
    """
    Generate a geometric progression of slab buffer sizes [64, 128, 256, ..., ceiling]
    Slab allocators avoid external fragmentation by allocating fixed-size slots.
    Any request is rounded up to the nearest power-of-two bucket.
    """
    classes = []
    c = MIN_SLAB_CLASS_BYTES
    ceiling = next_pow2_at_least(max_observed_bytes)
    while c < ceiling:
        classes.append(c)
        c *= 2
    classes.append(ceiling)
    return classes


# Helper function to find the minimum bucket that object size can fit into
def round_up_to_class(size, classes):
    """
    Find the smallest slab class that can accommodate an allocation of `size`.
    Represents the internal fragmentation incurred (e.g., a 70-byte allocation
    consumes a 128-byte slab slot).
    """
    for c in classes:
        if size <= c:
            return c
    return classes[-1]


# this function calculates the maximum memory simultaneously in use at any single moment in time
# basically, to check the highest concurrency, we make every allocations +peak and every free -peak.
# we pass through the 1d array once. then we get the peak allocations done
def peak_concurrent(events_df, group_col, value_col, tie_break_col):
    """
    Calculates the High-Water Mark (maximum concurrent in-flight memory or slots)
    using an event-based sweep-line algorithm:

    1. Splits allocations and frees into discrete time events:
        - Allocation starts: add +delta
        - Free/finalization: subtracts -delta
    2. Sorts events chronologically by timestamp.
    3. Tie-breaking rule: if an allocation and a free occur at the EXACT same millisecond,
       `tie_break_col` ensures allocation (+delta, is_start=1) are processed BEFORE
       frees (-delta, is_start=0). This guarantees we slightly over-estimate the peak
       rather than under-estimating and causing OOM crashes.
    4. Computes a running cumulative sum per group and extracts the max.
    """
    sorted_events = events_df.sort_values(['time', tie_break_col], ascending=[True, False])
    sorted_events['running'] = sorted_events.groupby(group_col)[value_col].cumsum()
    return sorted_events.groupby(group_col)['running'].max()


# Quantile of concurrent demand, used for the GUARANTEED FLOOR.
#
# WHY THE FLOOR SHOULD NOT BE THE PEAK
#
# A floor is reserved at startup and is never revocable, so every byte of floor
# is a byte the shared elastic pool cannot lend to whichever stratum is busy
# right now. Setting floors at each stratum's PEAK reserves for a worst case
# that the strata do not reach simultaneously, and the arithmetic is brutal:
# measured, guaranteed floors came to 408.6 MB of a 435.9 MB pool -- 93.7% --
# leaving 27 MB of elastic headroom. The elastic-quota design was present but
# had nothing to work with, so any demand above the characterized peak went
# straight to malloc.
#
# Sizing floors at a high quantile instead keeps the guarantee meaningful for
# the common case and lets the tail draw on shared capacity, which is what the
# shared pool is for. The span (P_j, below) still covers the peak, so nothing
# is capped lower than before -- only the non-revocable portion shrinks.
#
# Caveat worth stating: this quantile is over EVENTS, not time-weighted, so
# moments with many allocations carry more weight than quiet ones. At steady
# arrival rates the two are close, and the bias is toward busy periods, which
# is the conservative direction for a floor.
def concurrent_quantile(events_df, group_col, value_col, tie_break_col, q):
    sorted_events = events_df.sort_values(['time', tie_break_col], ascending=[True, False])
    sorted_events['running'] = sorted_events.groupby(group_col)[value_col].cumsum()
    return sorted_events.groupby(group_col)['running'].quantile(q)


def calculate_quotas():
    os.makedirs(OUTPUT_DIR, exist_ok=True)

    if not os.path.exists(TRACE_PATH) or not os.path.exists(POLICY_PATH):
        print("Required dataset files missing.")
        return

    print("Starting Spatial Optimization and Proportional Weighting")
    start_time = time.time()

    # Load memory traces: each row has start time, end/free time, size, and call_site_hash.
    trace = pd.read_csv(TRACE_PATH)
    # Load policy decisions: maps call_site_hash -> ['System', 'Bump', or 'Slab'].
    policy = pd.read_csv(POLICY_PATH)[['call_site_hash', 'allocation_policy']]
    
    # Merge on call_site_hash to tag each recorded allocation with its assigned strategy.
    df = trace.merge(policy, on='call_site_hash', how='inner')

    # ------------------------------------------------------------------
    # Effective release time for MANAGED strata.
    #
    # P_j drives the guaranteed floors, and computing it from
    # finalization_time_ms measures "allocated but not yet collected" -- V8's
    # garbage backlog, not simultaneously-live memory. That over-stated demand by
    # roughly 12x in practice: floors summed to 763MB while SAMM's actual peak
    # residency was 60MB, which consumed the entire pool on paper and left 17MB
    # of elastic headroom.
    #
    # A region-reclaimed object is released when its REQUEST ends, so that is the
    # moment its space returns. Objects that escaped their request keep their
    # finalization time, because for those the GC really is the release event.
    #
    # System stays on finalization throughout: those objects live on the V8 heap
    # and are genuinely freed by the collector.
    # ------------------------------------------------------------------
    if 'scope_end_ms' in df.columns:
        # Whether an object is region-reclaimed is decided by POLICY, not by a
        # measured escape flag: managed (Bump/Slab) call-sites allocate against
        # the request's region, System ones do not. That mirrors exactly what
        # _alloc-utils.js does at runtime, so the quota reflects the allocator
        # that will actually run.
        region_reclaimed = (
            df['scope_end_ms'].notna() & (df['allocation_policy'] != 'System'))
        df['release_time_ms'] = np.where(
            region_reclaimed, df['scope_end_ms'], df['finalization_time_ms'])
        # A request cannot release an object before it allocated it.
        df['release_time_ms'] = np.maximum(
            df['release_time_ms'], df['allocation_time_ms'])

        shortened = (df['release_time_ms'] < df['finalization_time_ms']).sum()
        print(f"\nRegion-reclaimed records: {region_reclaimed.sum():,} of {len(df):,}")
        print(f"Records whose release precedes GC finalization: {shortened:,} "
              f"({100 * shortened / max(len(df), 1):.2f}%)")
    else:
        print("\nWARNING: no scope data in the trace; peak demand will be computed")
        print("from GC finalization and will over-state simultaneously-live memory.")
        df['release_time_ms'] = df['finalization_time_ms']

    print(f"Loaded {len(df):,} finalized allocation records "
          f"across {df['call_site_hash'].nunique()} policy-assigned call-sites.\n")
    print("Records per policy:")
    print(df['allocation_policy'].value_counts().to_string())    
    
    # System heap allocation
    # must be safely provisioned first before dividing the remainder into the managed arenas
    system_df = df[df['allocation_policy'] == 'System'].copy()
    system_hwm_bytes = 0

    if len(system_df) > 0:
        # At allocation_time_ms: add memory (+delta)
        starts = system_df[['allocation_time_ms', 'allocation_size_bytes']].rename(
            columns={'allocation_time_ms': 'time', 'allocation_size_bytes': 'delta'})
        # At finalization_time_ms: free memory (-delta)
        ends = system_df[['finalization_time_ms', 'allocation_size_bytes']].rename(
            columns={'finalization_time_ms': 'time', 'allocation_size_bytes': 'delta'})
        ends['delta'] = -ends['delta']

        # Tie-breaker flag: 1 for start, 0 for end.
        # If an allocation and free happen at the exact same millisecond, the allocation
        # processes first, intentionally biasing peak estimation conservatively upward.
        starts['is_start'] = 1
        ends['is_start'] = 0
        starts['group'] = 'system'
        ends['group'] = 'system'

        # Combine and run sweep-line cumulative sum to find maximum peak concurrent bytes.
        system_events = pd.concat([starts, ends], ignore_index=True)
        system_hwm_series = peak_concurrent(system_events, 'group', 'delta', 'is_start')
        system_hwm_bytes = int(system_hwm_series.get('system', 0))
    
    # Apply safety buffer +15% 
    system_reservation_bytes = int(system_hwm_bytes * SAFETY_MULTIPLIER)

    print(f"\nSystem-heap high-watermark: {system_hwm_bytes:,} bytes "
          f"({system_hwm_bytes/(1024*1024):.1f} MB)")
    print(f"Reserved (x{SAFETY_MULTIPLIER}): {system_reservation_bytes:,} bytes "
          f"({system_reservation_bytes/(1024*1024):.1f} MB)")
    
    # Deduct all fixed/unmanaged reservations from the total 1 GB container ceiling:
    # 1. NODE_V8_BASELINE_BYTES: ~80 MB core engine baseline.
    # 2. system_reservation_bytes: Peak system heap + 15% buffer.
    # 3. GENERAL_SAFETY_MARGIN_BYTES: 32 MB container buffer against OOM kills.
    pool_hard_limit_bytes = (
        CONTAINER_HEAP_CEILING_BYTES
        - NODE_V8_BASELINE_BYTES
        - system_reservation_bytes
        - GENERAL_SAFETY_MARGIN_BYTES
    )

    print(f"\nPOOL_HARD_LIMIT:")
    print(f"  Container ceiling            : {CONTAINER_HEAP_CEILING_BYTES:,} bytes")
    print(f"  - Node/V8 baseline           : {NODE_V8_BASELINE_BYTES:,} bytes")
    print(f"  - System-heap reservation    : {system_reservation_bytes:,} bytes")
    print(f"  - General safety margin      : {GENERAL_SAFETY_MARGIN_BYTES:,} bytes")
    print(f"  = POOL_HARD_LIMIT            : {pool_hard_limit_bytes:,} bytes "
          f"({pool_hard_limit_bytes/(1024*1024):.1f} MB)")

    # If the computation is negative, something is wrong.
    if pool_hard_limit_bytes <= 0:
        print("\nERROR: POOL_HARD_LIMIT is zero or negative. System-heap retention "
              "alone leaves no room for managed arenas.")
        return
    
    # Fraction distributed to Bump + Slab arenas (BETA_UTILIZATION_FRACTION = 1.0 -> 100%).
    m_available_bytes = pool_hard_limit_bytes * BETA_UTILIZATION_FRACTION
    print(f"\nM_available = POOL_HARD_LIMIT * beta ({BETA_UTILIZATION_FRACTION}): "
          f"{m_available_bytes:,.0f} bytes ({m_available_bytes/(1024*1024):.1f} MB)")

    # strata dict maps: stratum_identifier -> peak_observed_demand_in_bytes (P_j)
    strata = {}
    floors = {}   # F_j: non-revocable guarantee, a quantile of concurrent demand
    max_allocs = {}  # largest single allocation per stratum

    # Computation for Bump allocator
    # Bump allocators serve specific call sites with lifecycles tied to linear scopes.
    # Each call site is treated as its own stratum: "bump:<hash>".
    bump_df = df[df['allocation_policy'] == 'Bump'].copy()
    if len(bump_df) > 0:
        starts = bump_df[['call_site_hash', 'allocation_time_ms', 'allocation_size_bytes']].rename(
            columns={'allocation_time_ms': 'time', 'allocation_size_bytes': 'delta'})
        ends = bump_df[['call_site_hash', 'release_time_ms', 'allocation_size_bytes']].rename(
            columns={'release_time_ms': 'time', 'allocation_size_bytes': 'delta'})
        ends['delta'] = -ends['delta']
        starts['is_start'] = 1
        ends['is_start'] = 0
        bump_events = pd.concat([starts, ends], ignore_index=True)
        
        # Calculate peak concurrent byte occupancy per call_site_hash.
        bump_hwm = peak_concurrent(bump_events, 'call_site_hash', 'delta', 'is_start')
        bump_floor = concurrent_quantile(bump_events, 'call_site_hash', 'delta',
                                         'is_start', FLOOR_QUANTILE)
        bump_max = bump_df.groupby('call_site_hash')['allocation_size_bytes'].max()
        for call_site, hwm_bytes in bump_hwm.items():
            strata[f"bump:{call_site}"] = int(hwm_bytes)
            floors[f"bump:{call_site}"] = max(0, int(bump_floor.get(call_site, 0)))
            # Largest single allocation. A bump segment smaller than this can
            # never serve it -- alloc() refuses anything above segment_bytes and
            # counts it as an oversize fallback -- so the compiler needs this to
            # keep segment sizing safe when it is tuned.
            max_allocs[f"bump:{call_site}"] = int(bump_max.get(call_site, 0))
    
    # Computation for Slab Allocator
    # Each size class is treated as a stratum: "slab:<size_class>".
    slab_df = df[df['allocation_policy'] == 'Slab'].copy()
    slab_classes = []
    if len(slab_df) > 0:
        max_observed = slab_df['allocation_size_bytes'].max()
        slab_classes = build_slab_classes(max_observed)
        
        # Assign every slab allocation to the nearest power-of-two bucket that can fit it.
        slab_df['size_class'] = slab_df['allocation_size_bytes'].apply(
            lambda s: round_up_to_class(s, slab_classes))

        # For slabs, track concurrency by SLOTS (count of 1) instead of raw bytes,
        # because a 70-byte object still ties up an entire 128-byte slot.
        starts = slab_df[['size_class', 'allocation_time_ms']].rename(
            columns={'allocation_time_ms': 'time'})
        starts['delta'] = 1
        ends = slab_df[['size_class', 'release_time_ms']].rename(
            columns={'release_time_ms': 'time'})
        ends['delta'] = -1
        starts['is_start'] = 1
        ends['is_start'] = 0
        slab_events = pd.concat([starts, ends], ignore_index=True)
        
        # Peak concurrent slots needed per size class.
        slot_hwm = peak_concurrent(slab_events, 'size_class', 'delta', 'is_start')
        slot_floor = concurrent_quantile(slab_events, 'size_class', 'delta',
                                         'is_start', FLOOR_QUANTILE)

        # Convert peak concurrent slots into total byte demand: slots * class_size.
        for size_class in slab_classes:
            peak_slots = int(slot_hwm.get(size_class, 0))
            floors[f"slab:{size_class}"] = max(0, int(slot_floor.get(size_class, 0))) * size_class
            strata[f"slab:{size_class}"] = peak_slots * size_class

    print(f"\nUnified stratum high-watermarks (P_j), {len(strata)} strata:")
    for stratum_id, p_j in strata.items():
        print(f"  {stratum_id:>30}: P_j = {p_j:>14,} bytes")

    # Sum of all demands across all bump arenas and slab classes.
    total_p = sum(strata.values())
    print(f"\nSum of all P_j: {total_p:,} bytes ({total_p/(1024*1024):.1f} MB)")

    # Distribute the unclaimed memory proportionally to each stratum's relative peak demand
    # Q_j = (P_j / total_P) * M_available
    # If the pool is larger than total_P, every arena gets extra headroom.
    # If smaller, every arena shrinks proportionally.
    quotas = {}
    if total_p > 0:
        for stratum_id, p_j in strata.items():
            q_j = (p_j / total_p) * m_available_bytes
            quotas[stratum_id] = {"P_j_bytes": p_j, "Q_j_bytes": int(q_j),
                                  "F_j_bytes": int(floors.get(stratum_id, p_j)),
                                  "max_alloc_bytes": int(max_allocs.get(stratum_id, 0))}
    else:
        print("\nWARNING: no Bump or Slab allocations observed.")

    print(f"\nFinal quotas Q_j = (P_j / sum P_k) * M_available:")
    for stratum_id, q in quotas.items():
        print(f"  {stratum_id:>30}: P_j={q['P_j_bytes']:>14,}  ->  "
              f"Q_j={q['Q_j_bytes']:>14,} bytes ({q['Q_j_bytes']/(1024*1024):.2f} MB)")

    total_q = sum(q['Q_j_bytes'] for q in quotas.values())
    print(f"\nSum of all Q_j: {total_q:,} bytes ({total_q/(1024*1024):.2f} MB) "
          f"(should equal M_available: {m_available_bytes:,.0f} bytes)")

    # Export
    output = {
        "container_ceiling_bytes": CONTAINER_HEAP_CEILING_BYTES,
        "node_v8_baseline_bytes": NODE_V8_BASELINE_BYTES,
        "floor_quantile": FLOOR_QUANTILE,
        "system_high_watermark_bytes": system_hwm_bytes,
        "system_reservation_bytes": system_reservation_bytes,
        "general_safety_margin_bytes": GENERAL_SAFETY_MARGIN_BYTES,
        "pool_hard_limit_bytes": pool_hard_limit_bytes,
        "beta_utilization_fraction": BETA_UTILIZATION_FRACTION,
        "m_available_bytes": m_available_bytes,
        "slab_classes": slab_classes,
        "strata_quotas": quotas,
    }

    output_json = os.path.join(OUTPUT_DIR, "spatial_quotas.json")
    with open(output_json, 'w') as f:
        json.dump(output, f, indent=4)

    elapsed = time.time() - start_time
    print("\n" + "=" * 50)
    print("Quota Calculation Complete.")
    print(f"Output saved to : {output_json}")
    print(f"Execution time  : {elapsed:.2f} seconds")
    print("=" * 50)


if __name__ == "__main__":
    calculate_quotas()