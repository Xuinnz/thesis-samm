const std = @import("std");

// Ported verbatim from Fnv1aHash() in profiler/src/profiler.cc.
//
// The offset basis below is NOT the canonical FNV-1a 64-bit basis
// (14695981039346656037) — it is one digit shorter. That is deliberate: it is
// the value the Shadow Profiler actually used when it hashed every call-site
// into training_trace.csv, and the routing table is keyed by those exact
// hashes. Changing either constant to the textbook value would make every
// lookup miss and silently route all traffic to System.
const offset_basis: u64 = 1469598103934665603;
const prime: u64 = 1099511628211;

/// Hashes a call-site identifier (e.g. "process.js:processRoute") to the same
/// u64 the profiler wrote for it.
pub fn fnv1a(input: []const u8) u64 {
    var hash: u64 = offset_basis;
    for (input) |byte| {
        hash ^= @as(u64, byte);
        hash *%= prime;
    }
    return hash;
}
