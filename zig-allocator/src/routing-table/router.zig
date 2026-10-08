const weights = @import("model_weights.zig");
pub const Policy = weights.Policy;

pub const Decision = struct {
    policy: Policy,
    arena_index: u32, // index into weights.bump_arena
};

const miss = Decision{
    .policy = .none,
    .arena_index = 0,
};

pub fn lookup(hash: u64) Decision {
    if (weights.table.len == 0) return miss;

    // to get the index of the hash.
    // uses AND operation instead of % to execute in 1 cpu cycle. (table_mask must be a power of two)
    var index: usize = @intCast(hash & weights.table_mask);

    // starts loop to check for collisions
    var probe: u32 = 0;
    while (probe <= weights.max_probe) : (probe += 1) {
        const slot = weights.table[index];

        if (slot.policy == .none) return miss;
        // if hash is found, return
        if (slot.hash == hash) {
            return .{ .policy = slot.policy, .arena_index = slot.arena_index };
        }
        // if not, a collision is detected and we try the next slot.
        // it has AND operation to not go beyond the boundary and cycle back to zero.
        index = (index + 1) & @as(usize, @intCast(weights.table_mask));
    }
    return miss;
}
