const std = @import("std");
const samm = @import("samm");

const fnv1a = samm.hash.fnv1a;

// The expected values below were produced independently by
// tests/reference_hashes.py (Python) and cross-checked against a BigInt
// implementation in Node, both using the constants in
// profiler/src/profiler.cc.
//
// Four of the five strings are real call-sites from server/routes/, and their
// hashes appear verbatim in
// datasets/shadow-telemetry/intermediate/ml-refinery/call_site_policy_assignment.csv.
// So this is not just three implementations of the same formula agreeing: it
// ties the Zig port back to the hashes the profiler actually wrote into the
// training trace.

test "empty input returns the offset basis" {
    try std.testing.expectEqual(@as(u64, 1469598103934665603), fnv1a(""));
}

test "single byte matches the reference implementations" {
    try std.testing.expectEqual(@as(u64, 4953267810257967366), fnv1a("a"));
}

test "real call-sites hash to the values in the training trace" {
    try std.testing.expectEqual(
        @as(u64, 8985841585374529601),
        fnv1a("cache.js:cacheRoute"),
    );
    try std.testing.expectEqual(
        @as(u64, 7791549285265555129),
        fnv1a("fetch.js:fetchRoute"),
    );
    try std.testing.expectEqual(
        @as(u64, 6032067261616903543),
        fnv1a("process.js:processRoute"),
    );
    try std.testing.expectEqual(
        @as(u64, 13608350406885744963),
        fnv1a("aggregate.js:aggregateRoute"),
    );
    try std.testing.expectEqual(
        @as(u64, 10594155676959940577),
        fnv1a("batch.js:batchRoute"),
    );
}

test "hashing is byte-wise, so a longer string keeps mixing" {
    // Guards against an accidental early return or a length cap creeping in.
    try std.testing.expect(fnv1a("cache.js:cacheRoute") != fnv1a("cache.js:cacheRoutf"));
    try std.testing.expect(fnv1a("cache.js:cacheRoute") != fnv1a("cache.js:cacheRoute "));
}
