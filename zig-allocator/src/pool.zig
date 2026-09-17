const std = @import("std");
const posix = std.posix;
const weights = @import("routing-table/model_weights.zig");

// check at compile time, arena offsets are multiples of weights.page_size. the routing table's page size
// must be divisible by the heap page size to align
comptime {
    if (weights.page_size % std.heap.page_size_max != 0) {
        @compileError("model_weights.page_size is not a multiple of the target's page size!");
    }
}

pub const ReclaimPolicy = enum {
    // No reclamation. less page faults. High RSS
    none,
    // Immediate reclamation. more page faults. lower RSS
    dontneed,
    // Reclamation if under memory pressure. Non-deterministic.
    free,

    pub fn fromString(name: []const u8) ?ReclaimPolicy {
        if (std.mem.eql(u8, name, "none")) return .none;
        if (std.mem.eql(u8, name, "dontneed")) return .dontneed;
        if (std.mem.eql(u8, name, "free")) return .free;
        return null;
    }
};

// Pool. consist of Region (start of the POOL requested using mmap) and policy (Reclamation Policy)
pub const Pool = struct {
    region: []align(std.heap.page_size_min) u8,
    policy: ReclaimPolicy,

    pub fn init(policy: ReclaimPolicy) !Pool {
        const region = try posix.mmap(
            null,
            weights.region_bytes,
            posix.PROT.READ | posix.PROT.WRITE,
            // NORESERVE means pages become resident only when traffic touches them.
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true },
            -1,
            0,
        );

        return .{ .region = region, .policy = policy };
    }

    //delete region
    pub fn deinit(self: *Pool) void {
        posix.munmap(self.region);
        self.region = &.{};
    }

    pub fn slice(self: *Pool, offset: usize, len: usize) []u8 {
        //[offset..] slices the region to make the offset be the first index [0]
        //[0..len] slices the region from 0 to len and returns it
        return self.region[offset..][0..len];
    }

    // applies whether to use huge pages or not per arena.
    // huge pages cut TLB pressure since it uses bigger sizes (2MB) compared to standard pages (4KB)
    pub fn applyHugePages(self: *Pool, offset: usize, len: usize, enable: bool) void {
        if (len == 0) return;
        const advice: u32 = if (enable) posix.MADV.HUGEPAGE else posix.MADV.NOHUGEPAGE;
        posix.madvise(self.alignedPtr(offset), alignDown(len), advice) catch {};
    }

    // trigger page fault on every page of the arena at start up.
    // to lower page faults on the actual runtime
    pub fn warmup(self: *Pool, offset: usize, len: usize) usize {
        var touched: usize = 0;
        var i: usize = 0;
        while (i < len) : (i += weights.page_size) {
            const cell: *volatile u8 = @ptrCast(&self.region[offset + i]);
            cell.* = 0;
            touched += weights.page_size;
        }
        return touched;
    }

    //returns the physical pages depending on the reclaim policy
    pub fn reclaim(self: *Pool, offset: usize, len: usize) void {
        const advice: u32 = switch (self.policy) {
            .none => return,
            .dontneed => posix.MADV.DONTNEED,
            .free => posix.MADV.FREE,
        };

        const aligned_len = alignDown(len);
        if (aligned_len == 0) return;
        posix.madvise(self.alignedPtr(offset), aligned_len, advice) catch {};
    }

    fn alignedPtr(self: *Pool, offset: usize) [*]align(std.heap.page_size_min) u8 {
        return @alignCast(self.region.ptr + offset);
    }

    fn alignDown(len: usize) usize {
        return (len / weights.page_size) * weights.page_size;
    }
};

// memory ceiling
pub const Budget = struct {
    committed: usize = 0,
    ceiling: usize = weights.m_available_bytes,
    grants: u64 = 0,
    refusals: u64 = 0,

    pub fn tryCommit(self: *Budget, bytes: usize) bool {
        if (self.committed + bytes > self.ceiling) {
            @branchHint(.cold);
            self.refusals += 1;
            return false;
        }
        self.committed += bytes;
        self.grants += 1;
        return true;
    }

    pub fn available(self: *const Budget) usize {
        return self.ceiling - self.committed;
    }
};
