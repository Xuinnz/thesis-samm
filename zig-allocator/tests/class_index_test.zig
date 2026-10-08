const std = @import("std");
const samm = @import("samm");

const classIndexFor = samm.slab.classIndexFor;
const classes = samm.weights.slab_classes;

// Trace replay can only prove the formula on sizes the workload happened to
// produce, and real sizes almost never land exactly on a class boundary. These
// walk every boundary explicitly instead: for each class, the size that exactly
// fills it, one byte under, and one byte over.

test "every class boundary maps to the expected index" {
    if (classes.len == 0) return error.SkipZigTest;

    for (classes, 0..) |class, i| {
        const size = class.class_size;
        const prev: usize = if (i > 0) classes[i - 1].class_size else 0;

        // Exactly the class size fills this class.
        try std.testing.expectEqual(@as(?u32, @intCast(i)), classIndexFor(size));

        // One byte under stays in this class unless it drops into the previous.
        const under = size - 1;
        const expect_under: u32 = if (under > prev) @intCast(i) else @intCast(i - 1);
        try std.testing.expectEqual(@as(?u32, expect_under), classIndexFor(under));

        // One byte over spills into the next class, or off the top of the
        // ladder, where it must miss rather than silently clamp.
        const over = size + 1;
        if (i + 1 < classes.len) {
            try std.testing.expectEqual(@as(?u32, @intCast(i + 1)), classIndexFor(over));
        } else {
            try std.testing.expectEqual(@as(?u32, null), classIndexFor(over));
        }

        // The first size that lands in this class is one past the previous one.
        try std.testing.expectEqual(@as(?u32, @intCast(i)), classIndexFor(prev + 1));
    }
}

test "the chosen class is always large enough to hold the request" {
    if (classes.len == 0) return error.SkipZigTest;

    for (classes, 0..) |class, i| {
        const prev: usize = if (i > 0) classes[i - 1].class_size else 0;
        const midpoint = prev + (class.class_size - prev) / 2;

        for ([_]usize{ prev + 1, midpoint, class.class_size }) |size| {
            const idx = classIndexFor(size) orelse return error.UnexpectedMiss;
            // Handing back a slot smaller than the request would corrupt the
            // neighbouring slot, so this is the invariant that matters most.
            try std.testing.expect(classes[idx].class_size >= size);
            // And it must be the SMALLEST such class, or the ladder wastes space.
            if (idx > 0) try std.testing.expect(classes[idx - 1].class_size < size);
        }
    }
}

test "degenerate and out-of-range sizes" {
    if (classes.len == 0) return error.SkipZigTest;

    try std.testing.expectEqual(@as(?u32, null), classIndexFor(0));
    try std.testing.expectEqual(@as(?u32, 0), classIndexFor(1));
    try std.testing.expectEqual(@as(?u32, null), classIndexFor(classes[classes.len - 1].class_size + 1));
    try std.testing.expectEqual(@as(?u32, null), classIndexFor(std.math.maxInt(usize)));
}

test "the fast index agrees with a linear scan at every boundary" {
    // The CLZ formula is only enabled when the compiler proved it matches the
    // emitted ladder. Re-prove it here against an independent scan, so a bad
    // octave_base/sub_bits pair cannot slip through as a silent misroute.
    if (classes.len == 0) return error.SkipZigTest;

    for (classes, 0..) |class, i| {
        const prev: usize = if (i > 0) classes[i - 1].class_size else 0;
        for ([_]usize{ prev + 1, class.class_size - 1, class.class_size, class.class_size + 1 }) |size| {
            if (size == 0) continue;
            try std.testing.expectEqual(referenceIndex(size), classIndexFor(size));
        }
    }
}

fn referenceIndex(size: usize) ?u32 {
    if (size == 0) return null;
    for (classes, 0..) |class, i| {
        if (size <= class.class_size) return @intCast(i);
    }
    return null;
}
