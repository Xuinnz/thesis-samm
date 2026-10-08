const std = @import("std");
const samm = @import("samm");

const Pool = samm.pool.Pool;
const Budget = samm.pool.Budget;
const Slab = samm.slab.Slab;
const weights = samm.weights;

fn openSlab(pool: *Pool, budget: *Budget) !Slab {
    return Slab.init(std.testing.allocator, pool, budget);
}

test "a class hands out every granted slot, then grows from the shared budget" {
    var pool = try Pool.init(.none);
    defer pool.deinit();
    var budget = Budget{ .committed = 0, .ceiling = 1 << 40 };
    var slab = try openSlab(&pool, &budget);
    defer slab.deinit();

    const index = smallestProvisioned(&slab) orelse return error.SkipZigTest;
    const hot = &slab.hot[index];
    const request = hot.class_size;
    const floor_slots = slab.cold[index].floor_slots;

    // Drain the guaranteed floor.
    var taken = std.ArrayList(u32){};
    defer taken.deinit(std.testing.allocator);
    var i: u32 = 0;
    while (i < floor_slots) : (i += 1) {
        const r = slab.alloc(request) orelse return error.AllocationRefused;
        try std.testing.expectEqual(index, r.class_index);
        try taken.append(std.testing.allocator, r.slot_index);
    }
    // Draining the floor charges the budget for what is now resident -- the
    // floor is an entitlement, not a prepayment -- but nothing beyond it.
    const floor_bytes = @as(usize, floor_slots) * hot.class_size;
    try std.testing.expectEqual(floor_bytes, budget.committed);

    // Past the floor the class must borrow, not fail, while budget remains.
    const borrowed = slab.alloc(request) orelse return error.AllocationRefused;
    try std.testing.expect(slab.cold[index].grows > 0);
    try std.testing.expectEqual(floor_bytes + hot.class_size, budget.committed);
    try std.testing.expect(hot.granted_slots > floor_slots);
    try taken.append(std.testing.allocator, borrowed.slot_index);

    for (taken.items) |slot| slab.free(index, slot);
    try std.testing.expectEqual(@as(u32, 0), slab.cold[index].live);
}

test "a class capped at max_slots reports exhaustion instead of overrunning" {
    var pool = try Pool.init(.none);
    defer pool.deinit();
    var budget = Budget{ .committed = 0, .ceiling = 1 << 40 };
    var slab = try openSlab(&pool, &budget);
    defer slab.deinit();

    const index = smallestProvisioned(&slab) orelse return error.SkipZigTest;
    const hot = &slab.hot[index];
    const request = hot.class_size;
    const max_slots = hot.max_slots;

    var count: u32 = 0;
    while (slab.alloc(request) != null) : (count += 1) {
        if (count > max_slots + 8) return error.GrewPastMaxSlots;
    }

    try std.testing.expectEqual(max_slots, count);
    try std.testing.expectEqual(max_slots, hot.granted_slots);
    try std.testing.expectEqual(@as(u64, 1), slab.cold[index].exhausted_fallbacks);
    try std.testing.expectEqual(@as(u64, 0), slab.cold[index].zero_slot_fallbacks);
}

test "a class that was never provisioned and cannot grow is counted apart" {
    var pool = try Pool.init(.none);
    defer pool.deinit();
    var budget = Budget{ .committed = 0, .ceiling = 0 }; // no elastic headroom
    var slab = try openSlab(&pool, &budget);
    defer slab.deinit();

    const index = unprovisioned(&slab) orelse return error.SkipZigTest;
    const hot = &slab.hot[index];

    try std.testing.expect(slab.alloc(hot.class_size) == null);

    // The quota never ran out here, it was never granted. Attributing this to
    // exhaustion would read as an under-sized arena instead of a size the
    // training data never covered.
    try std.testing.expectEqual(@as(u64, 1), slab.cold[index].zero_slot_fallbacks);
    try std.testing.expectEqual(@as(u64, 0), slab.cold[index].exhausted_fallbacks);
}

test "an unprovisioned class becomes usable once budget exists" {
    var pool = try Pool.init(.none);
    defer pool.deinit();
    var budget = Budget{ .committed = 0, .ceiling = 1 << 40 };
    var slab = try openSlab(&pool, &budget);
    defer slab.deinit();

    const index = unprovisioned(&slab) orelse return error.SkipZigTest;
    const hot = &slab.hot[index];
    if (hot.max_slots == 0) return error.SkipZigTest;

    // This is the whole point of elastic quotas: a size characterization never
    // saw is served anyway, rather than being permanently dead.
    const r = slab.alloc(hot.class_size) orelse return error.AllocationRefused;
    try std.testing.expectEqual(index, r.class_index);
    try std.testing.expectEqual(@as(u64, 0), slab.cold[index].zero_slot_fallbacks);
    slab.free(index, r.slot_index);
}

test "a request larger than every class is counted apart from a full class" {
    var pool = try Pool.init(.none);
    defer pool.deinit();
    var budget = Budget{ .committed = 0, .ceiling = 1 << 40 };
    var slab = try openSlab(&pool, &budget);
    defer slab.deinit();

    if (weights.slab_classes.len == 0) return error.SkipZigTest;
    const largest = weights.slab_classes[weights.slab_classes.len - 1].class_size;

    try std.testing.expect(slab.alloc(largest + 1) == null);
    try std.testing.expectEqual(@as(u64, 1), slab.oversize_fallbacks);
    for (slab.cold) |cold| {
        try std.testing.expectEqual(@as(u64, 0), cold.exhausted_fallbacks);
        try std.testing.expectEqual(@as(u64, 0), cold.zero_slot_fallbacks);
    }

    try std.testing.expect(slab.alloc(0) == null);
    try std.testing.expectEqual(@as(u64, 1), slab.oversize_fallbacks);
}

test "the bitmap always yields the lowest free slot" {
    var pool = try Pool.init(.none);
    defer pool.deinit();
    var budget = Budget{ .committed = 0, .ceiling = 1 << 40 };
    var slab = try openSlab(&pool, &budget);
    defer slab.deinit();

    const index = smallestProvisioned(&slab) orelse return error.SkipZigTest;
    const request = slab.hot[index].class_size;

    // Lowest-free-first is what keeps the touched page set equal to the
    // high-water mark of concurrency, so it is a property worth pinning down.
    var slots: [6]u32 = undefined;
    for (&slots) |*s| s.* = (slab.alloc(request) orelse return error.AllocationRefused).slot_index;
    for (slots, 0..) |s, i| try std.testing.expectEqual(@as(u32, @intCast(i)), s);

    slab.free(index, slots[3]);
    slab.free(index, slots[1]);
    // Both 1 and 3 are free; the next allocation must take 1.
    try std.testing.expectEqual(@as(u32, 1), (slab.alloc(request) orelse return error.AllocationRefused).slot_index);
    try std.testing.expectEqual(@as(u32, 3), (slab.alloc(request) orelse return error.AllocationRefused).slot_index);
}

test "every slot lies inside its own class region and is never double-issued" {
    var pool = try Pool.init(.none);
    defer pool.deinit();
    var budget = Budget{ .committed = 0, .ceiling = 1 << 40 };
    var slab = try openSlab(&pool, &budget);
    defer slab.deinit();

    for (slab.hot, 0..) |*hot, index| {
        if (hot.max_slots == 0) continue;

        const take = @min(hot.max_slots, 64);
        var seen = try std.testing.allocator.alloc(bool, hot.max_slots);
        defer std.testing.allocator.free(seen);
        @memset(seen, false);

        var i: u32 = 0;
        while (i < take) : (i += 1) {
            const r = slab.alloc(hot.class_size) orelse return error.AllocationRefused;
            const start = @intFromPtr(r.bytes.ptr) - @intFromPtr(pool.region.ptr);

            try std.testing.expect(start >= hot.offset);
            try std.testing.expect(start + hot.class_size <=
                hot.offset + @as(usize, hot.max_slots) * hot.class_size);
            try std.testing.expect(!seen[r.slot_index]);
            seen[r.slot_index] = true;
        }

        i = 0;
        while (i < take) : (i += 1) slab.free(@intCast(index), i);
    }
}

fn smallestProvisioned(slab: *Slab) ?u32 {
    var best: ?u32 = null;
    for (slab.hot, 0..) |hot, i| {
        if (hot.granted_slots == 0 or hot.max_slots <= hot.granted_slots) continue;
        if (best == null or hot.granted_slots < slab.hot[best.?].granted_slots) best = @intCast(i);
    }
    return best;
}

fn unprovisioned(slab: *Slab) ?u32 {
    for (slab.hot, 0..) |hot, i| {
        if (hot.granted_slots == 0) return @intCast(i);
    }
    return null;
}
