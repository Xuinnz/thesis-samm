const std = @import("std");
const samm = @import("samm");

const Pool = samm.pool.Pool;
const Budget = samm.pool.Budget;
const Arena = samm.bump.Arena;
const weights = samm.weights;
const page_size = weights.page_size;

// A synthetic arena rather than one from the generated table, so these stay
// meaningful whatever the next characterization run produces. One allocation of
// `seg` bytes fills exactly one segment, which makes the cycle easy to reason
// about.
const seg = page_size;
const floor_segments = 4;
const max_segments = 16;

// Exactly the floor's worth of budget: every floor segment can be made
// resident, but there is nothing left to grow into. Under usage-based
// accounting a ceiling of 0 would mean the arena cannot serve even its first
// allocation, which is a different scenario from "no elastic headroom".
const floor_ceiling = floor_segments * seg;

const spec = weights.BumpArena{
    .call_site_hash = 0,
    .offset = 0,
    .floor_bytes = floor_segments * seg,
    .span_bytes = max_segments * seg,
    .segment_bytes = seg,
    .floor_segments = floor_segments,
    .max_segments = max_segments,
    .use_huge_pages = false,
};

fn fixture(p: *Pool, b: *Budget) !Arena {
    return Arena.init(std.testing.allocator, p, b, spec);
}

test "the cursor cycles through segments and wraps once the oldest is dead" {
    var pool = try Pool.init(.none);
    defer pool.deinit();
    var budget = Budget{ .committed = 0, .ceiling = floor_ceiling }; // floor only, no growth
    var arena = try fixture(&pool, &budget);
    defer arena.deinit(std.testing.allocator);

    // Each buffer dies immediately, as a Bump call-site is meant to.
    var i: usize = 0;
    while (i < floor_segments) : (i += 1) {
        const bytes = arena.alloc(seg) orelse return error.AllocationRefused;
        try std.testing.expectEqual(@as(u32, @intCast(i)), arena.currentSegment());
        arena.release(arena.currentSegment());
        _ = bytes;
    }
    try std.testing.expectEqual(@as(u64, 0), arena.resets);

    // Filling past the last granted segment returns to segment 0.
    const wrapped = arena.alloc(seg) orelse return error.AllocationRefused;
    try std.testing.expectEqual(@as(u32, 0), arena.currentSegment());
    try std.testing.expectEqual(@as(u64, 1), arena.resets);
    try std.testing.expectEqual(@as(u64, 0), arena.grows);
    try std.testing.expectEqual(@intFromPtr(pool.region.ptr), @intFromPtr(wrapped.ptr));
}

test "a still-live segment is granted around, never overwritten" {
    var pool = try Pool.init(.none);
    defer pool.deinit();
    var budget = Budget{ .committed = 0, .ceiling = max_segments * seg };
    var arena = try fixture(&pool, &budget);
    defer arena.deinit(std.testing.allocator);

    // Hold every buffer, so no segment ever drains.
    var held: [floor_segments][]u8 = undefined;
    for (&held) |*slot| slot.* = arena.alloc(seg) orelse return error.AllocationRefused;

    const grown = arena.alloc(seg) orelse return error.AllocationRefused;

    // It must NOT have wrapped onto segment 0, which is still live.
    try std.testing.expectEqual(@as(u64, 0), arena.resets);
    try std.testing.expectEqual(@as(u64, 1), arena.grows);
    try std.testing.expectEqual(@as(u32, floor_segments), arena.currentSegment());
    try std.testing.expect(budget.committed > 0);

    // And the new buffer must sit past everything still alive.
    const start = @intFromPtr(grown.ptr) - @intFromPtr(pool.region.ptr);
    try std.testing.expect(start >= floor_segments * seg);
}

test "a live cycle with no budget refuses rather than corrupting" {
    var pool = try Pool.init(.none);
    defer pool.deinit();
    var budget = Budget{ .committed = 0, .ceiling = floor_ceiling }; // nothing left to grant
    var arena = try fixture(&pool, &budget);
    defer arena.deinit(std.testing.allocator);

    var held: [floor_segments][]u8 = undefined;
    for (&held) |*slot| slot.* = arena.alloc(seg) orelse return error.AllocationRefused;

    // Cannot reuse segment 0 (live), cannot grant (no budget). The only safe
    // answer is to refuse and let the caller use a plain Buffer.
    try std.testing.expect(arena.alloc(seg) == null);
    try std.testing.expectEqual(@as(u64, 1), arena.reset_blocked);
    try std.testing.expectEqual(@as(u64, 0), arena.resets);

    // Once segment 0 drains, the arena recovers on its own.
    arena.release(0);
    _ = arena.alloc(seg) orelse return error.AllocationRefused;
    try std.testing.expectEqual(@as(u64, 1), arena.resets);
}

test "liveness is tracked per segment, not for the arena as a whole" {
    var pool = try Pool.init(.none);
    defer pool.deinit();
    var budget = Budget{ .committed = 0, .ceiling = floor_ceiling };
    var arena = try fixture(&pool, &budget);
    defer arena.deinit(std.testing.allocator);

    // Hold the newest segment's object while releasing the older ones. A
    // whole-arena liveness test would refuse to wrap here -- which is exactly
    // the deadlock that made an earlier version fall back to System forever --
    // but segment 0 is dead and therefore safe to reuse.
    var i: usize = 0;
    while (i < floor_segments) : (i += 1) {
        _ = arena.alloc(seg) orelse return error.AllocationRefused;
        if (i + 1 < floor_segments) arena.release(arena.currentSegment());
    }

    const last_segment = arena.currentSegment();
    try std.testing.expect(arena.live[last_segment] > 0); // something IS alive

    _ = arena.alloc(seg) orelse return error.AllocationRefused;
    try std.testing.expectEqual(@as(u32, 0), arena.currentSegment());
    try std.testing.expectEqual(@as(u64, 1), arena.resets);
    try std.testing.expectEqual(@as(u64, 0), arena.grows);
}

test "payloads are cache-line aligned" {
    var pool = try Pool.init(.none);
    defer pool.deinit();
    var budget = Budget{ .committed = 0, .ceiling = floor_ceiling };
    var arena = try fixture(&pool, &budget);
    defer arena.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const bytes = arena.alloc(37) orelse return error.AllocationRefused; // awkward size
        arena.release(arena.currentSegment());
        try std.testing.expectEqual(@as(usize, 0), @intFromPtr(bytes.ptr) % samm.bump.alignment);
    }
}

test "allocations stay inside the arena's own bounds" {
    var pool = try Pool.init(.none);
    defer pool.deinit();
    var budget = Budget{ .committed = 0, .ceiling = floor_ceiling };

    var offset_spec = spec;
    offset_spec.offset = 8 * page_size;
    var arena = try Arena.init(std.testing.allocator, &pool, &budget, offset_spec);
    defer arena.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < 12) : (i += 1) {
        const bytes = arena.alloc(seg) orelse return error.AllocationRefused;
        arena.release(arena.currentSegment());
        const start = @intFromPtr(bytes.ptr) - @intFromPtr(pool.region.ptr);
        try std.testing.expect(start >= offset_spec.offset);
        try std.testing.expect(start + bytes.len <= offset_spec.offset + offset_spec.floor_bytes);
    }
}

test "a request larger than one segment is refused, not cycled forever" {
    var pool = try Pool.init(.none);
    defer pool.deinit();
    var budget = Budget{ .committed = 0, .ceiling = max_segments * seg };
    var arena = try fixture(&pool, &budget);
    defer arena.deinit(std.testing.allocator);

    try std.testing.expect(arena.alloc(seg + 1) == null);
    try std.testing.expectEqual(@as(u64, 1), arena.oversize_fallbacks);
    try std.testing.expectEqual(@as(u64, 0), arena.resets);

    // A zero-byte request is a degenerate input rather than a shortage of space,
    // so it must not be attributed to any capacity cause.
    try std.testing.expect(arena.alloc(0) == null);
    try std.testing.expectEqual(@as(u64, 1), arena.oversize_fallbacks);

    _ = arena.alloc(seg) orelse return error.AllocationRefused;
}

test "granting never runs past max_segments" {
    var pool = try Pool.init(.none);
    defer pool.deinit();
    var budget = Budget{ .committed = 0, .ceiling = 1 << 40 }; // effectively unlimited
    var arena = try fixture(&pool, &budget);
    defer arena.deinit(std.testing.allocator);

    // Hold everything alive so the arena can only ever grant, never reuse.
    var i: usize = 0;
    while (i < max_segments * 4) : (i += 1) {
        const bytes = arena.alloc(seg) orelse break;
        const start = @intFromPtr(bytes.ptr) - @intFromPtr(pool.region.ptr);
        try std.testing.expect(start + bytes.len <= spec.span_bytes);
    }
    try std.testing.expect(arena.granted_segments <= max_segments);
    try std.testing.expectEqual(@as(u64, 0), arena.resets);
    try std.testing.expect(arena.reset_blocked > 0); // it eventually hit the span
}
