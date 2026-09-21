const std = @import("std");
const pool_mod = @import("pool.zig");
const hash = @import("hash.zig");
const router = @import("routing-table/router.zig");
const weights = @import("routing-table/model_weights.zig");
const bump_allocator = @import("arenas/bump-allocator/bump.zig");
const slab_allocator = @import("arenas/slab-allocator/slab.zig");

const Pool = pool_mod.Pool;
const Budget = pool_mod.Budget;

pub const ReclaimPolicy = pool_mod.ReclaimPolicy;

// a callsite hash resolve into an ID at start up.
// this is to avoid using string matching
pub const Token = u32;

// max unique call sites
pub const max_tokens = 256;

// ID of each object, passed to JS, so finding the object to free is O(1)
// Includes a flag (bump / slab)
// if bump, [1] [0] [arena_index] [segment_index]
// if slab, [1] [1] [class_index] [slot_index]
pub const Handle = u64;

// bit 63: always set into 1 so it wont go 0 (null)
const handle_tag: u64 = 1 << 63;

// bit 62: Allocator Flag (0 = Bump,  1 = Slab Allocator)
const handle_slab: u64 = 1 << 62;

// bits 0..31: extract bottom 30
const handle_index_mask: u32 = 0x3fff_ffff;

pub fn packBump(arena_index: u32, segment: u32) Handle {
    // start with tag | shift to 32 for arena_index | segment_index
    return handle_tag | (@as(u64, arena_index) << 32) | segment;
}

pub fn packSlab(class_index: u32, slot_index: u32) Handle {
    // start with tag | add slab indicator | shift to 32 for class_index | slot_index
    return handle_tag | handle_slab | (@as(u64, class_index) << 32) | slot_index;
}

// what we return into JS
pub const Allocation = struct {
    bytes: []u8, //actual payload
    handle: Handle, // the ID
};

// telemetry
pub const Stats = struct {
    unmanaged: u64,
    capacity_fallbacks: u64,
    bump_oversize_fallbacks: u64,
    slab_oversize_fallbacks: u64,
    slab_zero_slot_fallbacks: u64,
    slab_exhausted_fallbacks: u64,
    bump_reset_blocked: u64,
    bump_resets: u64,
    grows: u64,
    committed_bytes: u64,
    ceiling_bytes: u64,
    reserved_floor_bytes: u64,
    budget_refusals: u64,
    warmed_bytes: u64,
};

// main engine, to initialize everything
pub const Engine = struct {
    gpa: std.mem.Allocator,
    pool: Pool,
    budget: Budget,
    bump_arenas: []bump_allocator.Arena,
    slab: slab_allocator.Slab,

    tokens: [max_tokens]router.Decision = undefined,
    token_count: u32 = 0,
    unmanaged: u64 = 0,
    warmed_bytes: u64 = 0,

    pub fn init(self: *Engine, gpa: std.mem.Allocator, policy: ReclaimPolicy) !void {
        // Initialize base structs
        self.* = .{
            .gpa = gpa,
            .pool = try Pool.init(policy),
            .budget = .{},
            .bump_arenas = &.{},
            .slab = undefined,
        };
        errdefer self.pool.deinit();

        // allocate array to hold bump arena structs
        // since we have
        self.bump_arenas = try gpa.alloc(bump_allocator.Arena, weights.bump_arenas.len);
        errdefer gpa.free(self.bump_arenas);

        for (weights.bump_arenas, 0..) |spec, i| {
            self.bump_arenas[i] = try bump_allocator.Arena.init(gpa, &self.pool, &self.budget, spec);
            // apply pages
            self.pool.applyHugePages(spec.offset, spec.span_bytes, spec.use_huge_pages);
        }

        self.slab = try slab_allocator.Slab.init(gpa, &self.pool, &self.budget);

        for (weights.slab_classes) |spec| {
            self.pool.applyHugePages(
                spec.offset,
                @as(usize, spec.max_slots) * spec.class_size,
                spec.use_huge_pages,
            );
        }
    }

    pub fn deinit(self: *Engine) void {
        self.slab.deinit();
        for (self.bump_arenas) |*arena| arena.deinit(self.gpa);
        self.gpa.free(self.bump_arenas);
        self.pool.deinit();
    }

    // called once at start up to register each call sites
    pub fn intern(self: *Engine, call_site_id: []const u8) ?Token {
        if (self.token_count >= max_tokens) return null;

        //get the ID number
        const token = self.token_count;
        //add into hash map
        self.tokens[token] = router.lookup(hash.fnv1a(call_site_id));

        self.token_count += 1;
        return token;
    }

    //helper to look up decision
    pub fn decisionFor(self: *Engine, token: Token) ?router.Decision {
        if (token >= self.token_count) return null;
        return self.tokens[token];
    }

    // asks memory using token
    pub fn allocate(self: *Engine, token: Token, size: usize) ?Allocation {
        if (token >= self.token_count) {
            @branchHint(.cold);
            return null;
        }
        // check the decision of the token (if it's bump / slab)
        const decision = self.tokens[token];

        switch (decision.policy) {
            // not recorded, return null (to system heap)
            .none => {
                @branchHint(.cold);
                self.unmanaged += 1;
                return null;
            },
            // if bump, we can use arena_index to find to arena number
            // use alloc then return to pack it up
            .bump => {
                const arena = &self.bump_arenas[decision.arena_index];
                const bytes = arena.alloc(size) orelse return null;
                return .{
                    .bytes = bytes,
                    .handle = packBump(decision.arena_index, arena.currentSegment),
                };
            },

            //if slab, we just need the class index and slot index.
            .slab => {
                const reservation = self.slab.alloc(size) orelse null;
                return .{
                    .bytes = reservation.bytes,
                    .handle = packSlab(reservation.class_index, reservation.slot_index),
                };
            },
        }
    }

    // release the memory
    // we check the handle if it's slab/bump
    pub fn release(self: *Engine, handle: Handle) void {
        // the index lives on the first 32, truncate makes it to 32b
        const index: u32 = @as(u32, @truncate(handle >> 32)) & handle_index_mask;
        // tail slot index lives on the last 32b,
        const tail: u32 = @truncate(handle);

        // if slab, use the free function of slab
        if (handle & handle_slab != 0) {
            self.slab.free(index, tail);
        } else { // if bump, we use the release function of bump
            self.bump_arena[index].release(tail);
        }
    }

    // trigger a page fault on startup on all bump arenas and slab class
    pub fn warmup(self: *Engine) u64 {
        var touched: usize = 0;

        for (weights.bump_arenas) |spec| {
            touched += self.pool.warmup(spec.offset, spec.floor_bytes);
        }

        for (weights.slab_classes) |spec| {
            touched += self.pool.warmup(
                spec.offset,
                @as(usize, spec.floor_slots) * spec.class_size,
            );
        }

        self.warmed_bytes = touched;
        return touched;
    }

    // update the stats
    pub fn stats(self: *Engine) Stats {
        var bump_resets: u64 = 0;
        var bump_oversize: u64 = 0;
        var bump_blocked: u64 = 0;
        var grows: u64 = 0;

        for (self.bump_arenas) |arena| {
            bump_resets += arena.resets;
            bump_oversize += arena.oversize_fallbacks;
            bump_blocked += arena.reset_blocked;
            grows += arena.grows;
        }

        var slab_exhausted: u64 = 0;
        var slab_zero_slot: u64 = 0;

        for (self.slab.cold) |cold| {
            slab_exhausted += cold.exhausted_fallbacks;
            slab_zero_slot += cold.zero_slot_fallbacks;
            grows += cold.grows;
        }

        return .{
            .unmanaged = self.unmanaged,
            .capacity_fallbacks = bump_oversize + self.slab.oversize_fallbacks +
                slab_zero_slot + slab_exhausted + bump_blocked,
            .bump_oversize_fallbacks = bump_oversize,
            .slab_oversize_fallbacks = self.slab.oversize_fallbacks,
            .slab_zero_slot_fallbacks = slab_zero_slot,
            .slab_exhausted_fallbacks = slab_exhausted,
            .bump_reset_blocked = bump_blocked,
            .bump_resets = bump_resets,
            .grows = grows,
            .committed_bytes = self.budget.committed,
            .ceiling_bytes = self.budget.ceiling,
            .reserved_floor_bytes = weights.reserved_floor_bytes,
            .budget_refusals = self.budget.refusals,
            .warmed_bytes = self.warmed_bytes,
        };
    }
};
