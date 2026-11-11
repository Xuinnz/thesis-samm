const std = @import("std");
const pool_mod = @import("../../pool.zig");
const weights = @import("../../routing-table/model_weights.zig");

const Pool = pool_mod.Pool;
const Budget = pool_mod.Budget;

// alignment is 64b so it fits the cache line
// it makes sure an object will get the least cache lines needed possible
pub const alignment = 64;

// Which drained segment (one whose objects have all died) the cursor moves to
// when the current segment is full.
pub const SegmentReuse = enum {
    // Only the next one in the ring. If it is still pinned by a single live
    // object the arena grows, or refuses when the budget is spent, even while
    // other segments sit empty. The original behaviour, kept for ablation.
    next,
    // The next one in the ring if it has drained, otherwise the lowest drained
    // one anywhere (the current segment included), and only then growth.
    // Measured on the replayed traces against `next`: fallbacks 16,536 -> 4,337
    // on mix and 29,150 -> 0 on ingest, with fewer segments ever touched.
    // (Always taking the lowest drained segment first was tried too: same
    // fallbacks and footprint as this, for many more segment switches.)
    any,

    pub fn fromString(name: []const u8) ?SegmentReuse {
        return std.meta.stringToEnum(SegmentReuse, name);
    }
};

pub const Arena = struct {
    pool: *Pool,
    budget: *Budget,
    offset: usize,
    floor: usize,
    span: usize,
    segment_bytes: usize,
    max_segments: u32,

    // Segments granted so far. Starts at the floor's worth. Granting is free;
    // what costs is entering a segment for the first time.
    granted_segments: u32,
    // Highest segment index the cursor has ever entered, plus one -- the
    // extent actually touched, which is what the budget charges for.
    high_water_segments: u32 = 0,
    // Segment the cursor is currently filling.
    segment: u32 = 0,
    // Offset within the current segment.
    cursor: usize = 0,
    // Live objects per segment. Indexed by segment, length `max_segments`.
    live: []u32,
    // How many times the cursor has started each segment from the top. A
    // segment's bytes can only be handed out again after this changes, which
    // is what lets the addon's `view` mode know when to cut old views off.
    epochs: []u32,

    reuse: SegmentReuse = .any,

    resets: u64 = 0,
    grows: u64 = 0,
    // Times the cursor moved onto a drained segment out of ring order.
    reuses: u64 = 0,
    // Requests refused because the next segment was still live and the budget
    // could not grant another. Non-zero means this arena is under-provisioned
    // for the live workload.
    reset_blocked: u64 = 0,
    // Requests larger than a single segment, which no cycle can serve.
    oversize_fallbacks: u64 = 0,

    pub fn init(
        gpa: std.mem.Allocator,
        p: *Pool,
        b: *Budget,
        spec: weights.BumpArena,
    ) !Arena {
        const live = try gpa.alloc(u32, spec.max_segments);
        errdefer gpa.free(live);
        @memset(live, 0);
        const epochs = try gpa.alloc(u32, spec.max_segments);
        @memset(epochs, 0);
        return .{
            .pool = p,
            .budget = b,
            .offset = spec.offset,
            .floor = spec.floor_bytes,
            .span = spec.span_bytes,
            .segment_bytes = spec.segment_bytes,
            .max_segments = spec.max_segments,
            .granted_segments = spec.floor_segments,
            .live = live,
            .epochs = epochs,
        };
    }

    pub fn deinit(self: *Arena, gpa: std.mem.Allocator) void {
        gpa.free(self.live);
        gpa.free(self.epochs);
    }

    // alloc memory
    pub fn alloc(self: *Arena, size: usize) ?[]u8 {
        // if no size, return null
        if (size == 0) return null;

        // if size exceeds a single segment's capacity.
        if (size > self.segment_bytes) {
            @branchHint(.cold);

            // since a single segment's capacity is fixed, it wont fit anywhere
            self.oversize_fallbacks += 1;
            // therefore, return to V8 malloc
            return null;
        }

        // calculates next valid address aligned
        var start = std.mem.alignForward(usize, self.cursor, alignment);
        // checks if the start of the valid address plus the size fits the current segment
        if (start + size > self.segment_bytes) {
            @branchHint(.cold);
            // if it does not, we try the next segment
            if (!self.advance()) {
                // if the next segment is still full, reset is blocked and
                // fallback to malloc
                self.reset_blocked += 1;
                return null;
            }
            // if the segment advances, start will reset to 0
            start = 0;
        }

        // if the segment advances to an elastic memory, trigger chargeSegment to
        // try and commit the pages. if it returns false, the ceiling is reached and cannot allocated anymore
        if (!self.chargeSegment(self.segment)) {
            @branchHint(.cold);
            self.reset_blocked += 1;
            return null;
        }

        // allocator has confirmed there is enough space and budget is approved.
        // start of the arena + (segment index * segment _bytes) + start (aligned)
        const at = self.offset + @as(usize, self.segment) * self.segment_bytes + start;
        // slice the pool starting at up to size
        const bytes = self.pool.slice(at, size);
        // cursor to know where is the bump
        self.cursor = start + size;
        // update live count
        self.live[self.segment] += 1;
        return bytes;
    }

    // called by finalizer. it decrements the live counter of the segment.
    // if live counter is zero, reclaim it.
    pub fn release(self: *Arena, segment: u32) void {
        if (segment < self.live.len and self.live[segment] > 0) {
            self.live[segment] -= 1;
            if (self.live[segment] == 0 and segment != self.segment) {
                self.reclaimSegment(segment);
            }
        }
    }

    // reclaims the memory segment depending on the policy.
    fn reclaimSegment(self: *Arena, segment: u32) void {
        self.pool.reclaim(
            self.offset + @as(usize, segment) * self.segment_bytes,
            self.segment_bytes,
        );
    }

    // which segment an allocation belongs to.
    pub fn currentSegment(self: *const Arena) u32 {
        return self.segment;
    }

    // used to advance to the next segment. returns back to segment 0 if it's on the last of the granted segment
    // if next segment is still holding live objects. it tries to expand the pool.
    fn advance(self: *Arena) bool {
        // the next segment. it the last segment is reached, it goes back to zero.
        const next = if (self.segment + 1 < self.granted_segments) self.segment + 1 else 0;

        if (self.live[next] == 0 and self.chargeSegment(next)) {
            // cleans up the segment before leaving if live counter is 0
            self.enter(next);
            if (next == 0) self.resets += 1;
            return true;
        }

        // the next segment is pinned, but another one may have drained: a single
        // straggler must not cost a whole new segment, or a fallback.
        if (self.reuse == .any and self.enterLowestDrained()) return true;

        // the next segment that would be used is still live, that means we cant reuse it yet.
        // this checks if we still have elastic budget and memory to do so
        if (self.granted_segments < self.max_segments and
            self.chargeSegment(self.granted_segments))
        {
            const fresh = self.granted_segments;
            self.granted_segments += 1;
            self.grows += 1;
            self.enter(fresh);
            return true;
        }
        // if no free segments and no more elastic budget. we cannot advance and fallback to system malloc
        return false;
    }

    // moves the cursor to the lowest-indexed granted segment with no live
    // objects. Same safety rule as the ring: a segment is only written again
    // once everything allocated in it has died. Runs once per segment change,
    // over at most max_segments counters.
    fn enterLowestDrained(self: *Arena) bool {
        var i: u32 = 0;
        while (i < self.granted_segments) : (i += 1) {
            if (self.live[i] != 0) continue;
            // i is past the high-water mark and the budget cannot cover it;
            // every later segment would cost more.
            if (!self.chargeSegment(i)) return false;
            if (i < self.segment) self.resets += 1;
            self.reuses += 1;
            self.enter(i);
            return true;
        }
        return false;
    }

    // if advance goes into another segment
    fn chargeSegment(self: *Arena, segment: u32) bool {
        // checks if the page has not yet claimed
        if (segment >= self.high_water_segments) {
            @branchHint(.cold);
            const fresh = segment + 1 - self.high_water_segments;
            // if no more memory budget
            if (!self.budget.tryCommit(fresh * self.segment_bytes)) return false;
            // add it to the claimed segments
            self.high_water_segments = segment + 1;
        }
        return true;
    }

    // cleans up the segment before it leaves and goes to a new segment.
    fn enter(self: *Arena, segment: u32) void {
        const leaving = self.segment;
        if (leaving != segment and leaving < self.live.len and self.live[leaving] == 0) {
            self.reclaimSegment(leaving);
        }
        self.segment = segment;
        self.cursor = 0;
        self.epochs[segment] +%= 1;
    }
};
