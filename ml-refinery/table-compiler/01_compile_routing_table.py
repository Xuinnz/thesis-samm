#!/usr/bin/env python3
# Table Compiler
#
# Reads the two ML Refinery outputs that fully describe the routing decision:
#
#   1. call_site_policy_assignment.csv  (which policy each call-site gets)
#   2. spatial_quotas.json              (how many bytes each stratum gets)
#
# and emits a Zig source file that the allocator compiles directly into itself.
# This is a manual build step, not a runtime dependency: the server never reads
# these files, it only runs the compiled-in table.
#
# Everything here is derived from the data. The number of bump arenas, the slab
# class list, the slot counts, the byte offsets and the size-class index formula
# are all discovered from the two input files, so a fresh characterization run
# only requires re-running this script and rebuilding the Zig addon.
#
# ---------------------------------------------------------------------------
# ELASTIC QUOTAS
#
# A stratum gets two numbers rather than one:
#
#   floor  = P_j, the peak demand characterization actually observed. This is
#            guaranteed: it is reserved against the global budget at startup and
#            can never be taken away by another stratum.
#   span   = Q_j * ELASTIC_FACTOR, a VIRTUAL extent it may grow into on demand.
#
# Spans deliberately sum to more than the pool. Virtual address space costs
# nothing until touched, so the real ceiling is enforced by a single global
# committed-bytes counter instead of by hard geometry. Under a static partition
# every stratum gets exactly M/sum(P_j) headroom -- 1.92x on the current data,
# and 1.00x for classes that peaked at a single slot -- so any endpoint-weight
# change beyond that starves a stratum while the rest of the pool sits idle.
# ---------------------------------------------------------------------------

import argparse
import json
import math
import os
import sys
import time

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, "..", ".."))

DEFAULT_POLICY_CSV = os.path.join(
    REPO_ROOT, "datasets", "shadow-telemetry", "intermediate", "ml-refinery",
    "call_site_policy_assignment.csv")
DEFAULT_QUOTAS_JSON = os.path.join(
    REPO_ROOT, "datasets", "shadow-telemetry", "intermediate", "ml-refinery",
    "spatial_quotas.json")
DEFAULT_OUTPUT_ZIG = os.path.join(
    REPO_ROOT, "zig-allocator", "src", "routing-table", "model_weights.zig")

# Every stratum starts on a page boundary and occupies a whole number of pages.
# Load-bearing, not cosmetic: reclaim uses madvise, whose start address must be
# page-aligned and whose length the kernel rounds UP to a page. If two strata
# shared a page, reclaiming one would discard the first page of its neighbour.
PAGE_SIZE = 4096
HUGE_PAGE_SIZE = 2 * 1024 * 1024

# --- THP policy -------------------------------------------------------------
# Transparent Huge Pages make RSS report in 2MB steps, so a partially-touched
# arena over-reports by up to one huge page. Expressed as a bound on measurement
# distortion: an arena may use huge pages only if that worst case is under
# 1/THP_MIN_HUGE_PAGES of its own size. At 32 that is <= 3.125%.
#
# This is a stated policy, not a per-arena judgement: every arena is tested
# against the same threshold and the compiler reports which side it fell on.
THP_MIN_HUGE_PAGES = 32
THP_MIN_ARENA_BYTES = THP_MIN_HUGE_PAGES * HUGE_PAGE_SIZE

# How far beyond its proportional share a stratum may grow, budget permitting.
ELASTIC_FACTOR = 4
# Smallest classes peaked at one slot, so a proportional share of one slot times
# any factor is still tiny. Give every class at least this much room to grow.
MIN_ELASTIC_SLOTS = 8
# A bump arena grows in chunks rather than per request, to avoid a syscall-free
# but still pointless walk of tiny increments.
BUMP_GROWTH_CHUNK = 2 * 1024 * 1024

# --- Bump segmentation ------------------------------------------------------
# A bump arena is divided into segments, and the cursor may enter a segment only
# once every object allocated in it has died.
#
# The obvious check -- "is the arena entirely dead?" -- is unreachable under
# sustained traffic. Little's Law puts the busiest call-site at ~195 live
# objects at any instant, so a whole-arena liveness test never passes and the
# arena can only grow, never wrap. Per-segment liveness IS reachable, because by
# the time the cursor comes back around, that segment's objects were allocated a
# full cycle ago and have long since been collected.
#
# A segment is untouched for (S-1)/S of a full cycle, so more segments preserve
# more of the arena's natural safety margin.
#
# WHY EIGHT WAS TOO FEW
#
# A segment resets only when EVERY object in it has died, so one late survivor
# pins the whole segment. The cost of that is set by segment SIZE. At eight
# segments per floor the payload call-site got 41.9 MB segments holding roughly
# ten 4 MB objects each -- so a single surviving buffer held ~37 MB hostage.
#
# Measured: that arena could commit ~483 MB (334.9 MB floor plus the 148.7 MB
# elastic pool), which is only 11.5 segments at that size, against a live set of
# ~357 MB that needs 15-20 of them once pinning is accounted for. The result was
# 9,329 blocked resets and 13.9% of allocations pushed to malloc -- and every
# one of those was a budget refusal, with the pool sitting at 99.998% of its
# ceiling.
#
# Smaller segments cut the pinned remainder proportionally. The trade is more
# frequent advance() calls, which is a bounds check and a cursor reset, against
# tens of megabytes held by a single object.
BUMP_SEGMENTS_PER_FLOOR = int(os.environ.get("SAMM_BUMP_SEGMENTS_PER_FLOOR", 8))

# Largest share of the pool handed out as non-revocable floors. The remainder
# stays shared, so a stratum running above its characterized demand can borrow
# rather than fall back to malloc. 1.0 restores the old behaviour.
FLOOR_BUDGET_FRACTION = float(os.environ.get("SAMM_FLOOR_BUDGET_FRACTION", 0.70))

# Load factor for the open-addressed routing table.
MAX_LOAD = 0.5


def next_pow2_at_least(n):
    if n <= 1:
        return 1
    return 1 << (int(n - 1).bit_length())


def page_floor(n):
    return (int(n) // PAGE_SIZE) * PAGE_SIZE


def page_ceil(n):
    return ((int(n) + PAGE_SIZE - 1) // PAGE_SIZE) * PAGE_SIZE


def load_policies(path):
    """Read the policy CSV by column NAME, so extra columns are harmless."""
    import csv

    rows = []
    with open(path, newline="") as f:
        reader = csv.DictReader(f)
        required = {"call_site_hash", "allocation_policy"}
        missing = required - set(reader.fieldnames or [])
        if missing:
            raise SystemExit(
                f"ERROR: {path} is missing required column(s): {sorted(missing)}")
        for row in reader:
            rows.append({
                "call_site_hash": int(row["call_site_hash"]),
                "allocation_policy": row["allocation_policy"].strip(),
            })
    return rows


# ---------------------------------------------------------------------------
# Size-class index formula
# ---------------------------------------------------------------------------
# For a geometric ladder with 2^sub_bits subdivisions per octave, the class
# index is computable from the request size with shifts and masks alone:
#
#     e   = 63 - clz(size-1)                 # 2^e < size <= 2^(e+1)
#     sub = ((size-1) - (1<<e)) >> (e - sub_bits)
#     idx = (e - octave_base) * 2^sub_bits + sub
#
# No division anywhere, including for a ladder whose class sizes are not powers
# of two. The only multiply in the allocator is slot -> address, and there is no
# address -> slot inversion because the finalizer carries the slot index.
#
# The compiler DERIVES sub_bits and octave_base from the emitted class list and
# then VERIFIES the formula reproduces that list exactly. If the ladder is not a
# clean geometric one, use_clz_index is emitted false and Zig falls back to a
# linear scan -- correctness never depends on the ladder's shape.


def clz_class_index(size, sub_bits, octave_base, num_classes):
    if size <= 0:
        return None
    k = 1 << sub_bits
    first_class = (1 << (octave_base + 1)) if sub_bits == 0 else \
        (1 << octave_base) + (1 << (octave_base - sub_bits))
    if size <= first_class:
        return 0
    e = (size - 1).bit_length() - 1
    if e < sub_bits:
        return 0
    sub = ((size - 1) - (1 << e)) >> (e - sub_bits)
    idx = (e - octave_base) * k + sub
    if idx < 0:
        return 0
    if idx >= num_classes:
        return None
    return idx


def derive_index_params(class_sizes):
    """Infer (sub_bits, octave_base) from the ladder, then prove it reproduces it.

    Returns (True, sub_bits, octave_base) when the formula is exact for every
    class boundary, otherwise (False, 0, 0).
    """
    if len(class_sizes) < 2:
        return False, 0, 0

    # Subdivisions per octave = how many classes fall within one doubling.
    smallest = class_sizes[0]
    if smallest & (smallest - 1) != 0:
        return False, 0, 0
    per_octave = sum(1 for c in class_sizes if smallest < c <= smallest * 2)
    if per_octave < 1 or per_octave & (per_octave - 1) != 0:
        return False, 0, 0

    sub_bits = per_octave.bit_length() - 1
    octave_base = (smallest.bit_length() - 1) - (1 if sub_bits == 0 else 0)

    # Verification: the boundary triples are where an off-by-one hides. Check
    # the class itself, one below, and one above, for every class.
    for i, class_size in enumerate(class_sizes):
        lower = class_sizes[i - 1] if i > 0 else 0
        for probe, expect in (
            (class_size, i),
            (class_size - 1, i if class_size - 1 > lower else max(i - 1, 0)),
            (lower + 1, i),
        ):
            if probe <= 0:
                continue
            got = clz_class_index(probe, sub_bits, octave_base, len(class_sizes))
            if got != expect:
                return False, 0, 0

    # And a request past the top must miss rather than silently clamp.
    if clz_class_index(class_sizes[-1] + 1, sub_bits, octave_base, len(class_sizes)) is not None:
        return False, 0, 0

    return True, sub_bits, octave_base


def build_layout(quotas_json):
    """Assign each stratum a page-aligned offset, a guaranteed floor and a span.

    Offsets are a running prefix sum over the strata in sorted-key order, so the
    same input always produces the same memory layout.
    """
    strata = quotas_json["strata_quotas"]

    # ------------------------------------------------------------------
    # GLOBAL FLOOR BUDGET
    #
    # A per-stratum quantile is not enough on its own. The floor is
    # min(F_j, Q_j), and the quota script distributes exactly M_available across
    # strata, so sum(Q_j) == M_available by construction. Whenever characterized
    # demand exceeds the pool -- the normal case under memory pressure -- every
    # F_j is larger than its Q_j, every floor collapses to Q_j, and the floors
    # total 100% of the pool no matter what quantile was requested. Measured:
    # introducing the quantile alone moved floors from 93.7% to 97.7% of the
    # pool, i.e. the wrong way.
    #
    # So cap the TOTAL. Reserving at most this fraction as non-revocable leaves
    # the rest as genuine shared elastic capacity -- which is the whole point of
    # the elastic-quota design and which it has never actually had (27 MB of a
    # 435.9 MB pool, then 10 MB). Strata scale proportionally, so their relative
    # shares, the part the profile actually informs, are preserved.
    m_available_bytes = int(quotas_json.get("m_available_bytes", 0))
    floor_raw = {
        sid: min(e.get("F_j_bytes", e["P_j_bytes"]), e["Q_j_bytes"])
        for sid, e in strata.items()
    }
    floor_scale = 1.0
    if m_available_bytes:
        budget = FLOOR_BUDGET_FRACTION * m_available_bytes
        total_floor = sum(floor_raw.values())
        if total_floor > budget and total_floor > 0:
            floor_scale = budget / total_floor
            print(f"  floor budget      : {total_floor/2**20:>10,.1f} MB requested -> "
                  f"{budget/2**20:,.1f} MB cap ({FLOOR_BUDGET_FRACTION:.0%} of pool, "
                  f"scale {floor_scale:.3f})")

    layout = {}
    cursor = 0
    for stratum_id in sorted(strata.keys()):
        entry = strata[stratum_id]

        # The floor is a promise, so it can only be as large as the pool can
        # actually honour. Q_j is the proportional share that provably fits
        # (the quota script distributes exactly M_available across strata);
        # P_j is observed peak demand, which can exceed the pool outright when
        # a re-characterization lands more load than the container can hold.
        # Taking the smaller keeps sum(floor) <= sum(Q_j) <= M_available, so an
        # over-subscribed workload degrades to "no elastic headroom" instead of
        # refusing to build at all. page_floor, not page_ceil, because rounding
        # up could push the sum back over the budget it just respected.
        # F_j is a quantile of concurrent demand rather than its peak, so the
        # non-revocable guarantee covers the common case and the tail draws on
        # the shared elastic pool. Falls back to P_j for quota files written
        # before F_j existed.
        floor = page_floor(int(floor_raw[stratum_id] * floor_scale))
        span = page_ceil(max(entry["Q_j_bytes"] * ELASTIC_FACTOR, floor))

        if stratum_id.startswith("slab:"):
            class_size = int(stratum_id.split(":", 1)[1])
            span = max(span, MIN_ELASTIC_SLOTS * class_size)
            # A span that is not a whole number of slots wastes the remainder.
            span = page_ceil((span // class_size) * class_size) if span >= class_size else 0
            floor = min(floor, span)

        layout[stratum_id] = {"offset": cursor, "floor": floor, "span": span}
        cursor += span

    return layout, cursor


def compile_table(policy_csv, quotas_json_path, output_zig):
    print("Starting Table Compiler: static routing table generation")
    start_time = time.time()

    for path in (policy_csv, quotas_json_path):
        if not os.path.exists(path):
            raise SystemExit(f"ERROR: required input not found: {path}")

    policies = load_policies(policy_csv)
    with open(quotas_json_path) as f:
        quotas = json.load(f)

    m_available_bytes = int(quotas["m_available_bytes"])
    slab_class_sizes = list(quotas["slab_classes"])

    print(f"Loaded {len(policies)} policy-assigned call-sites from {policy_csv}")
    print(f"Loaded {len(slab_class_sizes)} slab classes and "
          f"{len(quotas['strata_quotas'])} strata from {quotas_json_path}")

    layout, region_bytes = build_layout(quotas)

    bump_arenas = []
    bump_index_by_hash = {}
    for stratum_id in sorted(layout.keys()):
        if not stratum_id.startswith("bump:"):
            continue
        entry = layout[stratum_id]
        call_site_hash = int(stratum_id.split(":", 1)[1])
        bump_index_by_hash[call_site_hash] = len(bump_arenas)

        # A segment below the call-site's largest allocation can never serve it:
        # alloc() refuses anything above segment_bytes and counts an oversize
        # fallback, so every large request would bypass the arena entirely. That
        # makes BUMP_SEGMENTS_PER_FLOOR unsafe to tune without this clamp -- at
        # 32 segments this arena would drop to 10.5 MB segments against a 16 MB
        # maximum payload, and silently route every big allocation to malloc.
        want = (entry["floor"] // BUMP_SEGMENTS_PER_FLOOR // PAGE_SIZE) * PAGE_SIZE
        need = ((quotas["strata_quotas"][stratum_id].get("max_alloc_bytes", 0)
                 + PAGE_SIZE - 1) // PAGE_SIZE) * PAGE_SIZE
        segment_bytes = max(PAGE_SIZE, want, need)
        if need > want and want > 0:
            print(f"  segment clamp     : {stratum_id} raised {want/2**20:.2f} -> "
                  f"{segment_bytes/2**20:.2f} MB to fit its largest allocation")
        floor_segments = max(1, entry["floor"] // segment_bytes)
        max_segments = max(floor_segments, entry["span"] // segment_bytes)

        bump_arenas.append({
            "call_site_hash": call_site_hash,
            "offset": entry["offset"],
            "floor": entry["floor"],
            "span": entry["span"],
            "segment_bytes": segment_bytes,
            "floor_segments": floor_segments,
            "max_segments": max_segments,
            "huge": entry["span"] >= THP_MIN_ARENA_BYTES,
        })

    slab_classes = []
    for class_size in slab_class_sizes:
        stratum_id = f"slab:{class_size}"
        if stratum_id not in layout:
            raise SystemExit(
                f"ERROR: slab class {class_size} is listed in slab_classes but has "
                f"no '{stratum_id}' entry in strata_quotas. The quota script and "
                f"this compiler have drifted out of sync.")
        entry = layout[stratum_id]
        slab_classes.append({
            "class_size": class_size,
            "offset": entry["offset"],
            "floor_slots": entry["floor"] // class_size,
            "max_slots": entry["span"] // class_size,
            "huge": entry["span"] >= THP_MIN_ARENA_BYTES,
        })

    use_clz, sub_bits, octave_base = derive_index_params(slab_class_sizes)

    routes = []
    skipped_system = 0
    for row in policies:
        policy = row["allocation_policy"]
        call_site_hash = row["call_site_hash"]

        if policy == "System":
            skipped_system += 1
            continue

        if policy == "Bump":
            if call_site_hash not in bump_index_by_hash:
                raise SystemExit(
                    f"ERROR: call-site {call_site_hash} is classified Bump but has "
                    f"no 'bump:{call_site_hash}' stratum in spatial_quotas.json. "
                    f"The policy and quota files have drifted out of sync.")
            routes.append({
                "hash": call_site_hash,
                "policy": "bump",
                "arena_index": bump_index_by_hash[call_site_hash],
            })
        elif policy == "Slab":
            # No class index here on purpose: a Slab call-site can emit objects
            # of any size, so the class is chosen per request from the requested
            # size. The table only fixes the POLICY.
            routes.append({"hash": call_site_hash, "policy": "slab", "arena_index": 0})
        else:
            raise SystemExit(
                f"ERROR: unknown allocation_policy '{policy}' for call-site "
                f"{call_site_hash}. Expected one of: Bump, Slab, System.")

    # Stamp the workload this table was fit against. The server compares its own
    # fingerprint to this at boot and refuses to run on a mismatch -- the only
    # thing standing between a silently-wrong quota set and a benchmark that
    # looks valid but is measuring a model fit to a workload that never ran.
    manifest_path = os.path.normpath(os.path.join(
        os.path.dirname(os.path.abspath(quotas_json_path)),
        "..", "..", "raw", "workload_manifest.json"))
    if os.path.exists(manifest_path):
        with open(manifest_path) as mf:
            manifest = json.load(mf)
        print(f"  workload          : {manifest.get('fingerprint', '?')}")
    else:
        manifest = {"fingerprint": "unknown", "parameters": {}}
        print(f"  WARNING: no workload_manifest.json at {manifest_path}. The table "
              f"will carry fingerprint 'unknown' and the server cannot verify it.")

    slots, max_probe = build_hash_table(routes)

    reserved_floor = sum(a["floor"] for a in bump_arenas) + \
        sum(c["floor_slots"] * c["class_size"] for c in slab_classes)

    # Fail loudly: the guaranteed floors must fit inside the pool, or the
    # guarantee is a fiction and elasticity has nothing left to hand out.
    if reserved_floor > m_available_bytes:
        raise SystemExit(
            f"ERROR: guaranteed floors total {reserved_floor:,} bytes, which exceeds "
            f"m_available_bytes ({m_available_bytes:,}). Characterized peak demand "
            f"does not fit the pool; re-run the quota calculation.")

    max_bitmap_slots = max((c["max_slots"] for c in slab_classes), default=0)
    if max_bitmap_slots > 64 * 64 * 64:
        raise SystemExit(
            f"ERROR: a slab class needs {max_bitmap_slots:,} slots, beyond the "
            f"three-level bitmap's 262,144 ceiling.")

    print(f"\nRouting decisions:")
    print(f"  Bump routes      : {sum(1 for r in routes if r['policy'] == 'bump')}")
    print(f"  Slab routes      : {sum(1 for r in routes if r['policy'] == 'slab')}")
    print(f"  System (no entry): {skipped_system}")
    print(f"  Table slots      : {len(slots)} (max probe distance {max_probe})")

    print(f"\nSize-class index: ", end="")
    if use_clz:
        print(f"CLZ formula verified ({1 << sub_bits} subdivision(s)/octave, "
              f"octave_base={octave_base})")
    else:
        print("ladder is not a clean geometric one; falling back to linear scan")

    print(f"\nBump arenas ({len(bump_arenas)}):")
    for i, a in enumerate(bump_arenas):
        print(f"  [{i}] hash={a['call_site_hash']:>20}  offset={a['offset']:>13,}  "
              f"floor={a['floor']/2**20:>8.2f} MB  span={a['span']/2**20:>9.2f} MB  "
              f"seg={a['segment_bytes']/2**20:>6.2f} MB x{a['floor_segments']:>3}"
              f"(max {a['max_segments']:>3})  thp={'on' if a['huge'] else 'off'}")

    print(f"\nSlab classes ({len(slab_classes)}):")
    for i, c in enumerate(slab_classes):
        print(f"  [{i:>2}] class={c['class_size']:>10,}B  offset={c['offset']:>13,}  "
              f"floor={c['floor_slots']:>6,} slots  max={c['max_slots']:>7,} slots  "
              f"thp={'on' if c['huge'] else 'off'}")

    print(f"\nBudget:")
    print(f"  guaranteed floors : {reserved_floor:>14,} bytes ({reserved_floor/2**20:8.1f} MB)")
    print(f"  global ceiling    : {m_available_bytes:>14,} bytes ({m_available_bytes/2**20:8.1f} MB)")
    print(f"  elastic headroom  : {m_available_bytes-reserved_floor:>14,} bytes "
          f"({(m_available_bytes-reserved_floor)/2**20:8.1f} MB shared)")
    print(f"  virtual reservation: {region_bytes:>13,} bytes ({region_bytes/2**30:8.2f} GB, "
          f"MAP_NORESERVE, untouched pages cost nothing)")

    source = render_zig(
        policy_csv=policy_csv, quotas_json_path=quotas_json_path,
        m_available_bytes=m_available_bytes, reserved_floor=reserved_floor,
        region_bytes=region_bytes, bump_arenas=bump_arenas,
        slab_classes=slab_classes, slots=slots, max_probe=max_probe,
        use_clz=use_clz, sub_bits=sub_bits, octave_base=octave_base,
    )

    os.makedirs(os.path.dirname(output_zig), exist_ok=True)
    with open(output_zig, "w") as f:
        f.write(source)

    # Sidecar the server reads at boot. Kept beside the JS wrapper rather than
    # inside the .node binary so a mismatch is reported by Node with a readable
    # message instead of a comptime failure nobody sees at run time.
    sidecar = os.path.join(REPO_ROOT, "zig-allocator", "workload_fingerprint.json")
    with open(sidecar, "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"  fingerprint file  : {os.path.relpath(sidecar, REPO_ROOT)}")

    elapsed = time.time() - start_time
    print("\n" + "=" * 50)
    print("Table Compilation Complete.")
    print(f"Output saved to : {output_zig}")
    print(f"Execution time  : {elapsed:.2f} seconds")
    print("=" * 50)


def build_hash_table(routes):
    """Open-addressed table with linear probing, built offline.

    Because the table is static and fully known at compile time, the probe
    distance is a measured constant rather than an expected value, which is what
    makes the runtime lookup genuinely O(1).
    """
    if not routes:
        return [], 0

    capacity = next_pow2_at_least(max(1, int(len(routes) / MAX_LOAD)))
    mask = capacity - 1

    slots = [None] * capacity
    max_probe = 0

    for route in sorted(routes, key=lambda r: r["hash"]):
        idx = route["hash"] & mask
        probe = 0
        while slots[idx] is not None:
            if slots[idx]["hash"] == route["hash"]:
                raise SystemExit(
                    f"ERROR: duplicate call_site_hash {route['hash']} in the policy CSV.")
            idx = (idx + 1) & mask
            probe += 1
            if probe > capacity:
                raise SystemExit("ERROR: routing table is full, cannot place route.")
        slots[idx] = route
        max_probe = max(max_probe, probe)

    return slots, max_probe


def render_zig(policy_csv, quotas_json_path, m_available_bytes, reserved_floor,
               region_bytes, bump_arenas, slab_classes, slots, max_probe,
               use_clz, sub_bits, octave_base):
    out = []
    w = out.append

    w("// GENERATED FILE - DO NOT EDIT BY HAND.")
    w("//")
    w("// Produced by ml-refinery/table-compiler/01_compile_routing_table.py from:")
    w(f"//   {os.path.relpath(policy_csv, REPO_ROOT)}")
    w(f"//   {os.path.relpath(quotas_json_path, REPO_ROOT)}")
    w("//")
    w("// Checked into git so the Zig addon builds without a Python step. Re-run")
    w("// the table compiler after any ML Refinery run and commit the result;")
    w("// never edit the numbers here directly.")
    w("")
    w("/// Alignment every offset below respects, so madvise on one stratum can")
    w("/// never touch its neighbour.")
    w(f"pub const page_size: usize = {PAGE_SIZE};")
    w(f"pub const huge_page_size: usize = {HUGE_PAGE_SIZE};")
    w("")
    w("/// THP policy. Huge pages make RSS report in 2MB steps, so a partially")
    w("/// touched arena over-reports by up to one huge page. An arena may use")
    w("/// them only when that worst case is under 1/thp_min_huge_pages of its")
    w("/// own size -- a uniform, stated bound on measurement distortion rather")
    w("/// than a per-arena judgement call.")
    w(f"pub const thp_min_huge_pages: usize = {THP_MIN_HUGE_PAGES};")
    w(f"pub const thp_min_arena_bytes: usize = {THP_MIN_ARENA_BYTES};")
    w(f"pub const thp_max_rss_distortion_pct: f64 = {100.0 / THP_MIN_HUGE_PAGES};")
    w("")
    w("/// Hard ceiling on bytes committed across every stratum at once.")
    w(f"pub const m_available_bytes: usize = {m_available_bytes};")
    w("/// Sum of the guaranteed floors, charged against the ceiling at startup.")
    w(f"pub const reserved_floor_bytes: usize = {reserved_floor};")
    w("/// Total VIRTUAL extent of the mapping. Deliberately larger than the")
    w("/// ceiling: untouched pages cost nothing, and the real limit is the")
    w("/// committed-bytes counter, not the geometry.")
    w(f"pub const region_bytes: usize = {region_bytes};")
    w(f"pub const elastic_factor: usize = {ELASTIC_FACTOR};")
    w(f"pub const bump_growth_chunk: usize = {BUMP_GROWTH_CHUNK};")
    w("")
    w("/// Size-class index by shifts and masks, no division. Derived from the")
    w("/// emitted ladder and verified against every class boundary at generation")
    w("/// time; false means the ladder is not geometric and Zig must scan.")
    w(f"pub const use_clz_index: bool = {'true' if use_clz else 'false'};")
    w(f"pub const sub_bits: u6 = {sub_bits};")
    w(f"pub const octave_base: u6 = {octave_base};")
    w("")
    w("pub const Policy = enum(u8) {")
    w("    /// Not in the table: System-classified, served by a plain V8 allocation.")
    w("    none,")
    w("    bump,")
    w("    slab,")
    w("};")
    w("")
    w("pub const Slot = struct {")
    w("    hash: u64,")
    w("    policy: Policy,")
    w("    /// Index into `bump_arenas` when `policy == .bump`. Meaningless for")
    w("    /// `.slab`: that class is picked per request from the requested size.")
    w("    arena_index: u32,")
    w("};")
    w("")
    w("pub const BumpArena = struct {")
    w("    call_site_hash: u64,")
    w("    offset: usize,")
    w("    /// Guaranteed, reserved at startup, never revocable.")
    w("    floor_bytes: usize,")
    w("    /// Virtual ceiling it may grow into while the global budget allows.")
    w("    span_bytes: usize,")
    w("    /// The cursor may enter a segment only once every object allocated in")
    w("    /// it has died. Testing the whole arena instead is unreachable under")
    w("    /// sustained traffic, where hundreds of objects are live at any instant,")
    w("    /// so the arena could only ever grow and never wrap.")
    w("    segment_bytes: usize,")
    w("    /// Segments covered by the guaranteed floor, usable without borrowing.")
    w("    floor_segments: u32,")
    w("    /// Segments covered by the elastic span.")
    w("    max_segments: u32,")
    w("    use_huge_pages: bool,")
    w("};")
    w("")
    w("pub const SlabClass = struct {")
    w("    class_size: usize,")
    w("    offset: usize,")
    w("    floor_slots: u32,")
    w("    max_slots: u32,")
    w("    use_huge_pages: bool,")
    w("};")
    w("")
    w("/// One dedicated arena per Bump-classified call-site.")
    w("pub const bump_arenas = [_]BumpArena{")
    for a in bump_arenas:
        w(f"    .{{ .call_site_hash = {a['call_site_hash']}, .offset = {a['offset']}, "
          f".floor_bytes = {a['floor']}, .span_bytes = {a['span']}, "
          f".segment_bytes = {a['segment_bytes']}, "
          f".floor_segments = {a['floor_segments']}, "
          f".max_segments = {a['max_segments']}, "
          f".use_huge_pages = {'true' if a['huge'] else 'false'} }},")
    w("};")
    w("")
    w("/// Ascending by class_size, exactly as spatial_quotas.json listed them.")
    w("pub const slab_classes = [_]SlabClass{")
    for c in slab_classes:
        w(f"    .{{ .class_size = {c['class_size']}, .offset = {c['offset']}, "
          f".floor_slots = {c['floor_slots']}, .max_slots = {c['max_slots']}, "
          f".use_huge_pages = {'true' if c['huge'] else 'false'} }},")
    w("};")
    w("")
    w("/// Open-addressed, linear-probed lookup table, power-of-two capacity.")
    w(f"pub const table_mask: u64 = {max(0, len(slots) - 1)};")
    w("/// Longest probe chain measured at generation time, so the lookup can stop")
    w("/// after this many steps instead of scanning the whole table.")
    w(f"pub const max_probe: u32 = {max_probe};")
    w("")
    w("pub const table = [_]Slot{")
    if not slots:
        w("    // no Bump or Slab call-sites: everything falls through to System")
    for slot in slots:
        if slot is None:
            w("    .{ .hash = 0, .policy = .none, .arena_index = 0 },")
        else:
            w(f"    .{{ .hash = {slot['hash']}, .policy = .{slot['policy']}, "
              f".arena_index = {slot['arena_index']} }},")
    w("};")
    w("")
    w("comptime {")
    w("    if (reserved_floor_bytes > m_available_bytes)")
    w("        @compileError(\"guaranteed floors exceed the global budget\");")
    w("    var span_total: usize = 0;")
    w("    for (bump_arenas) |arena| span_total += arena.span_bytes;")
    w("    for (slab_classes) |class| span_total += class.max_slots * class.class_size;")
    w("    if (span_total > region_bytes)")
    w("        @compileError(\"stratum spans overflow the mapped region\");")
    w("}")
    w("")

    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(
        description="Compile ML Refinery output into a static Zig routing table.")
    parser.add_argument(
        "--policy-csv", default=os.environ.get("SAMM_POLICY_CSV", DEFAULT_POLICY_CSV),
        help="call_site_policy_assignment.csv (env: SAMM_POLICY_CSV)")
    parser.add_argument(
        "--quotas-json", default=os.environ.get("SAMM_QUOTAS_JSON", DEFAULT_QUOTAS_JSON),
        help="spatial_quotas.json (env: SAMM_QUOTAS_JSON)")
    parser.add_argument(
        "--output", default=os.environ.get("SAMM_MODEL_WEIGHTS_OUT", DEFAULT_OUTPUT_ZIG),
        help="generated model_weights.zig (env: SAMM_MODEL_WEIGHTS_OUT)")
    args = parser.parse_args()

    compile_table(args.policy_csv, args.quotas_json, args.output)


if __name__ == "__main__":
    sys.exit(main())
