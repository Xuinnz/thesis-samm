#!/usr/bin/env python3
# Independent reference implementation of the profiler's call-site hash, used
# to produce the expected values in hash_parity_test.zig.
#
# Deliberately written from profiler/src/profiler.cc's Fnv1aHash() rather than
# from the Zig port, so that agreement between the two means something. Note the
# offset basis is one digit shorter than the canonical FNV-1a 64-bit basis; that
# is what the profiler used, and therefore what the routing table is keyed by.

OFFSET_BASIS = 1469598103934665603
PRIME = 1099511628211
MASK = 0xFFFFFFFFFFFFFFFF

# Every call-site the server currently tracks, from server/routes/.
CALL_SITES = [
    "",
    "a",
    "cache.js:cacheRoute",
    "fetch.js:fetchRoute",
    "process.js:processRoute",
    "aggregate.js:aggregateRoute",
    "batch.js:batchRoute",
]


def fnv1a(text):
    h = OFFSET_BASIS
    for byte in text.encode("utf-8"):
        h ^= byte
        h = (h * PRIME) & MASK
    return h


if __name__ == "__main__":
    for call_site in CALL_SITES:
        print(f"{call_site!r:35} {fnv1a(call_site)}")
