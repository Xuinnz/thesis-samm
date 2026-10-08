# Step 5.2: Aggregate Call sites
# all endpoints have their own hashes. They will now be called callsites.
# We calculate for the mean lifespan of each callsites.
# also calculates the scope-relative mean (mu_scope_relative) and variance.

# extracts structural telemetry (overhang_ms, died_in_request_rate) to prove 
# the escape rate. Call-sites with insufficient samples are dropped to ensure ML stability.

# Then we will calculate the variance, or how chaotic their lifespan is.
# Output: Callsite Lifespan, Callsite Lifespan Variance
import pandas as pd
import numpy as np
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

    # ------------------------------------------------------------------
    # SPATIAL features: how uniform are this call-site's allocation SIZES?
    #
    # Bump-vs-Slab is a question about size, and nothing upstream was
    # measuring it. A slab hands out fixed-size slots, so a call-site whose
    # sizes cluster tightly fits one slot with no waste, while a wide
    # distribution pays twice: rounding up to a class (measured at 47.7% for
    # the payload-processing call-site on a power-of-two ladder) and, worse,
    # spreading across many classes -- each of which must be provisioned for
    # its OWN peak concurrency. Summed per-class peaks are far larger than the
    # peak of the sum: measured 1,292 MB of slots against 661 MB of live bytes
    # for the same objects, a 1.95x penalty that no class ladder removes.
    #
    # size_cv (std/mean) is scale-free, so one threshold works whether a
    # call-site allocates kilobytes or megabytes. distinct_sizes is carried
    # alongside it because a call-site with a handful of exact sizes is
    # slab-shaped even if those sizes are spread out.
    size_agg = (
        df.groupby('call_site_hash')['allocation_size_bytes']
        .agg(mu_size_bytes='mean', sigma_size_bytes='std',
             max_size_bytes='max', distinct_sizes='nunique')
        .reset_index()
    )
    size_agg['sigma_size_bytes'] = size_agg['sigma_size_bytes'].fillna(0.0)
    size_agg['size_cv'] = (size_agg['sigma_size_bytes'] /
                           size_agg['mu_size_bytes'].replace(0, pd.NA)).fillna(0.0)
    agg = agg.merge(size_agg, on='call_site_hash', how='left')

    # ------------------------------------------------------------------
    # STRUCTURE COSTS: what each allocator would waste on this call-site.
    #
    # Both are in BYTES and both come straight from how the two structures
    # work, so the policy step can simply take the cheaper one instead of
    # comparing features against tuned thresholds.
    #
    #   bump_extra = lambda * sigma_occupancy * mean_size
    #       A bump segment frees only when its LAST object dies, so beyond the
    #       live set the arena must also absorb whatever arrives during the
    #       spread in lifetimes. Zero spread costs nothing extra; a long tail
    #       costs the bytes that arrive while waiting for it.
    #
    #   slab_extra = sum over classes(peak_slots * class_size) - peak_live
    #       Every size class is provisioned for its OWN peak, and those peaks
    #       do not coincide, so a wide size distribution pays twice: rounding
    #       each object up to a slot, and reserving each class separately.
    #
    # This replaces a median split on lifespan variance (which forced half the
    # call-sites into each policy regardless of fit) and the two absolute
    # thresholds that followed it.
    span_s = (df['allocation_time_ms'].max() - df['allocation_time_ms'].min()) / 1000.0
    if span_s <= 0:
        span_s = 1.0

    def _peak_bytes(sub, fixed=None):
        """Sweep-line maximum of concurrently-live bytes."""
        size = (sub['allocation_size_bytes'].values.astype(float)
                if fixed is None else np.full(len(sub), float(fixed)))
        rel = sub['release_ms'].values
        ev = np.concatenate([
            np.stack([sub['allocation_time_ms'].values, size]),
            np.stack([rel, -size])], axis=1)
        ev = ev[:, np.argsort(ev[0], kind='stable')]
        return float(np.max(np.cumsum(ev[1]))) if len(sub) else 0.0

    def _pow2(x):
        c = 64
        while c < x:
            c *= 2
        return c

    # A managed object's slot is released at scope end; an escaping one not
    # until collection. Take whichever comes first.
    if 'scope_end_ms' in df.columns:
        df['release_ms'] = df[['scope_end_ms', 'finalization_time_ms']].min(axis=1)
    else:
        df['release_ms'] = df['finalization_time_ms']

    rows = []
    for h, g in df.groupby('call_site_hash'):
        peak_live = _peak_bytes(g)
        lam = len(g) / span_s
        sigma_occ_s = ((g['scope_end_ms'] - g['allocation_time_ms']).clip(lower=0).std()
                       if 'scope_end_ms' in g.columns else g['lifespan_ms'].std()) / 1000.0
        if sigma_occ_s != sigma_occ_s:
            sigma_occ_s = 0.0
        bump_extra = lam * sigma_occ_s * g['allocation_size_bytes'].mean()
        classed = g.assign(_cls=[_pow2(int(v)) for v in g['allocation_size_bytes']])
        slab_reserved = sum(_peak_bytes(sub, cls) for cls, sub in classed.groupby('_cls'))
        rows.append({'call_site_hash': h,
                     'peak_live_bytes': peak_live,
                     'bump_extra_bytes': max(0.0, bump_extra),
                     'slab_extra_bytes': max(0.0, slab_reserved - peak_live)})
    agg = agg.merge(pd.DataFrame(rows), on='call_site_hash', how='left')

    # ------------------------------------------------------------------
    # TEMPORAL feature, corrected: how long an object holds its ARENA SLOT.
    #
    # sigma2 above is the variance of GC-observed lifespan (allocation ->
    # finalization). Under region-per-request reclamation that is the wrong
    # clock: a managed object's slot is released at scope end by the region,
    # not by the garbage collector, so finalization lag is noise on top of the
    # quantity that actually decides arena pinning.
    #
    # The two agree closely wherever a route awaits -- hold time dominates, and
    # sigma2 matched sigma2_occupancy to four significant figures for both
    # holding call-sites. They diverge exactly where it matters: for routes
    # that never await, sigma2 reported 200-280 (pure collector jitter) while
    # the true slot occupancy variance is 0-2. Pinning risk is a property of
    # the request, not of when V8 got around to noticing.
    if 'scope_end_ms' in df.columns:
        occ = df['scope_end_ms'] - df['allocation_time_ms']
        occ_agg = (
            df.assign(occupancy_ms=occ.clip(lower=0))
            .groupby('call_site_hash')['occupancy_ms']
            .agg(mu_occupancy='mean', sigma2_occupancy='var')
            .reset_index()
        )
        occ_agg['sigma2_occupancy'] = occ_agg['sigma2_occupancy'].fillna(0.0)
        agg = agg.merge(occ_agg, on='call_site_hash', how='left')
    else:
        print("WARNING: no scope_end_ms; falling back to GC lifespan variance "
              "for the pinning feature.")
        agg['mu_occupancy'] = agg['mu_lifespan']
        agg['sigma2_occupancy'] = agg['sigma2']

    # Scope-relative features, carried through to the clustering step.
    #
    # mu_scope_relative is the load-invariant replacement for mu_lifespan as the
    # clustering feature; escape_rate is the structural fact that decides
    # whether a call-site can be reclaimed deterministically at the request
    # boundary or must remain GC-driven.
    if 'scope_relative_lifetime' in df.columns:
        scope_agg = df.groupby('call_site_hash').agg(
            mu_scope_relative=('scope_relative_lifetime', 'mean'),
            sigma2_scope_relative=('scope_relative_lifetime', 'var'),
            died_in_request_rate=('died_in_request', 'mean'),
            median_overhang_ms=('overhang_ms', 'median'),
            mean_overhang_ms=('overhang_ms', 'mean'),
            max_overhang_ms=('overhang_ms', 'max'),
        )
        scope_agg['sigma2_scope_relative'] = scope_agg['sigma2_scope_relative'].fillna(0.0)
        agg = agg.merge(scope_agg, on='call_site_hash', how='left')

        print("\nScope-relative features:")
        print(agg[['call_site_hash', 'mu_lifespan', 'mu_scope_relative',
                   'died_in_request_rate', 'median_overhang_ms',
                   'max_overhang_ms']].to_string(index=False))

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