#!/usr/bin/env python3
# Validates the table compiler against a hand-computed fixture.
#
# Deliberately NOT run against the real ~200k-row trace: the point is to check
# the layout arithmetic (floors, elastic spans, slot counts, THP decisions,
# probe placement) against numbers a human worked out, which is only possible at
# this scale.
#
# Run:  python3 tests/test_table_compiler.py

import json
import os
import re
import subprocess
import sys
import tempfile

TESTS_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.abspath(os.path.join(TESTS_DIR, "..", ".."))
COMPILER = os.path.join(
    REPO_ROOT, "ml-refinery", "table-compiler", "01_compile_routing_table.py")

PAGE = 4096

# Fixture. Quotas are deliberately not page multiples so the rounding is
# exercised rather than accidentally satisfied.
#
#   sorted strata keys : bump:100, slab:128, slab:64
#   ELASTIC_FACTOR = 4, MIN_ELASTIC_SLOTS = 8
#
#   A floor is page_floor(min(P_j, Q_j)) -- it can only promise what the pool
#   can honour, and rounds DOWN so the sum cannot exceed the budget.
#
#   bump:100  P=5000  -> floor page_floor(5000)  =  4096   offset      0
#                        span  page_ceil(40000)  = 40960 -> 1 floor segment of 10
#   slab:128  P=10000 -> floor page_floor(10000) =  8192   offset  40960
#                        span  page_ceil(80000)  = 81920 -> 640 slots, floor 64
#   slab:64   P=2500  -> floor page_floor(2500)  =     0   offset 122880
#                        span  page_ceil(20000)  = 20480 -> 320 slots, floor 0
#   region = 40960 + 81920 + 20480 = 143360
#   reserved floors = 4096 + (64*128) + 0 = 12288
POLICY_CSV = """call_site_hash,mu_lifespan,sigma2,n_objects,temporal_cluster,allocation_policy
100,10.0,1.0,50,0,Bump
200,20.0,2.0,60,0,Slab
300,30.0,3.0,70,1,System
"""

QUOTAS = {
    "m_available_bytes": 100000,
    "pool_hard_limit_bytes": 100000,
    "slab_classes": [64, 128],
    "strata_quotas": {
        "bump:100": {"P_j_bytes": 5000, "Q_j_bytes": 10000},
        "slab:64": {"P_j_bytes": 2500, "Q_j_bytes": 5000},
        "slab:128": {"P_j_bytes": 10000, "Q_j_bytes": 20000},
    },
}

failures = []


def check(name, actual, expected):
    if actual == expected:
        print(f"  ok   {name}")
    else:
        failures.append(name)
        print(f"  FAIL {name}")
        print(f"       expected: {expected!r}")
        print(f"       actual:   {actual!r}")


def run_compiler(workdir, quotas, expect_failure=False):
    policy_path = os.path.join(workdir, "policy.csv")
    quotas_path = os.path.join(workdir, "quotas.json")
    output_path = os.path.join(workdir, "model_weights.zig")

    with open(policy_path, "w") as f:
        f.write(POLICY_CSV)
    with open(quotas_path, "w") as f:
        json.dump(quotas, f)

    result = subprocess.run(
        [sys.executable, COMPILER,
         "--policy-csv", policy_path,
         "--quotas-json", quotas_path,
         "--output", output_path],
        capture_output=True, text=True)

    if expect_failure:
        return result

    if result.returncode != 0:
        print(result.stdout)
        print(result.stderr)
        raise SystemExit("table compiler failed on the fixture")

    with open(output_path) as f:
        return f.read()


def parse_const(source, name):
    match = re.search(rf"pub const {name}: [\w.]+ = ([\w.]+);", source)
    if not match:
        return None
    value = match.group(1)
    if value in ("true", "false"):
        return value == "true"
    return int(value) if value.isdigit() else value


def parse_structs(source, name):
    """Pulls the `.{ ... }` entries out of a generated array literal."""
    body = re.search(rf"pub const {name} = \[_\]\w+\{{(.*?)\n}};", source, re.S)
    if not body:
        return []

    entries = []
    for line in body.group(1).splitlines():
        line = line.strip()
        if not line.startswith(".{"):
            continue
        fields = {}
        for key, value in re.findall(r"\.(\w+) = ([\w.]+)", line):
            if value in ("true", "false"):
                fields[key] = value == "true"
            else:
                fields[key] = int(value) if value.isdigit() else value
        entries.append(fields)
    return entries


def main():
    print("table compiler — fixture validation\n")

    with tempfile.TemporaryDirectory() as workdir:
        source = run_compiler(workdir, QUOTAS)

        check("region_bytes is the prefix sum of elastic spans",
              parse_const(source, "region_bytes"), 143360)
        check("m_available_bytes is carried through",
              parse_const(source, "m_available_bytes"), 100000)
        check("reserved floors are the honourable part of P_j",
              parse_const(source, "reserved_floor_bytes"), 12288)
        check("page_size is emitted", parse_const(source, "page_size"), PAGE)

        # The whole premise of elastic quotas: spans deliberately over-subscribe
        # the pool, because virtual extent is free and the real limit is the
        # committed-bytes counter.
        check("spans over-subscribe the budget on purpose",
              parse_const(source, "region_bytes") > parse_const(source, "m_available_bytes"),
              True)
        check("floors fit inside the budget",
              parse_const(source, "reserved_floor_bytes") <= parse_const(source, "m_available_bytes"),
              True)

        bump = parse_structs(source, "bump_arenas")
        check("one bump arena is generated", len(bump), 1)
        check("bump arena has a guaranteed floor and a larger elastic span",
              bump[0],
              {"call_site_hash": 100, "offset": 0, "floor_bytes": 4096,
               "span_bytes": 40960, "segment_bytes": 4096, "floor_segments": 1,
               "max_segments": 10, "use_huge_pages": False})
        check("segments tile the floor and the span without exceeding them",
              (bump[0]["floor_segments"] * bump[0]["segment_bytes"] <= bump[0]["floor_bytes"],
               bump[0]["max_segments"] * bump[0]["segment_bytes"] <= bump[0]["span_bytes"]),
              (True, True))

        slabs = parse_structs(source, "slab_classes")
        check("both slab classes are generated", len(slabs), 2)
        check("slab class 64 floor/max slots",
              slabs[0],
              {"class_size": 64, "offset": 122880, "floor_slots": 0,
               "max_slots": 320, "use_huge_pages": False})
        check("slab class 128 floor/max slots",
              slabs[1],
              {"class_size": 128, "offset": 40960, "floor_slots": 64,
               "max_slots": 640, "use_huge_pages": False})
        check("slab classes stay in ascending class_size order",
              [c["class_size"] for c in slabs], [64, 128])

        # THP threshold is a stated policy, applied uniformly. Every fixture
        # arena is far under 32 huge pages, so every one must opt out.
        check("THP threshold is emitted as a policy constant",
              parse_const(source, "thp_min_arena_bytes"), 32 * 2 * 1024 * 1024)
        check("arenas below the THP threshold all opt out",
              [a["use_huge_pages"] for a in bump] + [c["use_huge_pages"] for c in slabs],
              [False, False, False])

        # CLZ index parameters, derived from the ladder and self-verified.
        check("CLZ index is enabled for a power-of-two ladder",
              parse_const(source, "use_clz_index"), True)
        check("sub_bits derived from the ladder", parse_const(source, "sub_bits"), 0)
        check("octave_base derived from the ladder", parse_const(source, "octave_base"), 5)

        # Two routes at load factor 0.5 -> capacity 4. 100 & 3 == 0 and
        # 200 & 3 == 0, so the second collides and probes one slot forward.
        check("table is sized to the next power of two",
              parse_const(source, "table_mask"), 3)
        check("the measured probe distance is emitted",
              parse_const(source, "max_probe"), 1)

        table = parse_structs(source, "table")
        check("table has one slot per capacity entry", len(table), 4)
        check("the bump route lands on its natural index",
              table[0], {"hash": 100, "policy": ".bump", "arena_index": 0})
        check("the colliding slab route probes one slot forward",
              table[1], {"hash": 200, "policy": ".slab", "arena_index": 0})
        check("unused slots are empty",
              [s["policy"] for s in table[2:]], [".none", ".none"])
        check("the System call-site gets no entry",
              [s["hash"] for s in table if s["policy"] != ".none"], [100, 200])

        # A THP-eligible arena must actually flip the flag, or the threshold is
        # decorative.
        big = json.loads(json.dumps(QUOTAS))
        big["m_available_bytes"] = 8 * 1024 ** 3
        big["strata_quotas"]["bump:100"] = {"P_j_bytes": 200 * 1024 ** 2,
                                            "Q_j_bytes": 200 * 1024 ** 2}
        big_src = run_compiler(workdir, big)
        check("an arena above the THP threshold opts in",
              parse_structs(big_src, "bump_arenas")[0]["use_huge_pages"], True)

        # Over-subscription: when characterized peak demand exceeds the pool
        # (which happens as soon as a re-characterization lands more load than
        # the container can hold), floors must clamp to the proportional share
        # and still BUILD. Refusing here would mean a heavier workload cannot be
        # benchmarked at all.
        over = json.loads(json.dumps(QUOTAS))
        over["strata_quotas"]["bump:100"]["P_j_bytes"] = 500000
        over["strata_quotas"]["slab:64"]["P_j_bytes"] = 250000
        over["strata_quotas"]["slab:128"]["P_j_bytes"] = 1000000
        over_src = run_compiler(workdir, over)
        over_floor = parse_const(over_src, "reserved_floor_bytes")
        check("over-subscribed demand clamps floors to the proportional share",
              over_floor, 8192 + 4096 + 16384)
        check("clamped floors still fit the budget",
              over_floor <= parse_const(over_src, "m_available_bytes"), True)

        # The drift guard: floors that cannot fit must fail loudly rather than
        # generate a table promising memory the pool does not have.
        too_small = json.loads(json.dumps(QUOTAS))
        too_small["m_available_bytes"] = 1024
        result = run_compiler(workdir, too_small, expect_failure=True)
        check("floors that exceed the budget are rejected", result.returncode != 0, True)
        check("the rejection names m_available_bytes",
              "m_available_bytes" in (result.stdout + result.stderr), True)

    if failures:
        print(f"\n{len(failures)} check(s) failed")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
