const std = @import("std");
const samm = @import("samm");

const router = samm.router;
const weights = samm.weights;

// These assert properties of the lookup rather than specific policies, so a
// fresh ML Refinery run that reclassifies call-sites does not break them.

test "every route the compiler placed is findable" {
    for (weights.table) |slot| {
        if (slot.policy == .none) continue;

        const decision = router.lookup(slot.hash);
        try std.testing.expectEqual(slot.policy, decision.policy);
        try std.testing.expectEqual(slot.arena_index, decision.arena_index);
    }
}

test "a hash that is not in the table falls through to System" {
    var candidate: u64 = 0xDEAD_BEEF_CAFE_F00D;
    while (inTable(candidate)) : (candidate += 1) {}

    try std.testing.expectEqual(router.Policy.none, router.lookup(candidate).policy);
}

test "bump routes point at a real arena" {
    for (weights.table) |slot| {
        if (slot.policy != .bump) continue;

        try std.testing.expect(slot.arena_index < weights.bump_arenas.len);
        // The arena the route points at must belong to the call-site that
        // routed there, or the two halves of the generated file disagree.
        try std.testing.expectEqual(
            slot.hash,
            weights.bump_arenas[slot.arena_index].call_site_hash,
        );
    }
}

test "arenas carved from the region never overlap" {
    const Span = struct { offset: usize, size: usize };

    var spans: [weights.bump_arenas.len + weights.slab_classes.len]Span = undefined;
    var count: usize = 0;
    for (weights.bump_arenas) |arena| {
        if (arena.span_bytes == 0) continue;
        spans[count] = .{ .offset = arena.offset, .size = arena.span_bytes };
        count += 1;
    }
    for (weights.slab_classes) |class| {
        if (class.max_slots == 0) continue;
        spans[count] = .{ .offset = class.offset, .size = @as(usize, class.max_slots) * class.class_size };
        count += 1;
    }

    for (spans[0..count], 0..) |a, i| {
        try std.testing.expect(a.offset + a.size <= weights.region_bytes);
        try std.testing.expectEqual(@as(usize, 0), a.offset % weights.page_size);

        for (spans[0..count], 0..) |b, j| {
            if (i == j) continue;
            const disjoint = a.offset + a.size <= b.offset or b.offset + b.size <= a.offset;
            try std.testing.expect(disjoint);
        }
    }
}

fn inTable(hash: u64) bool {
    for (weights.table) |slot| {
        if (slot.policy != .none and slot.hash == hash) return true;
    }
    return false;
}
