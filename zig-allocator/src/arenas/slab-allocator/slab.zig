const std = @import("std");
const pool_mod = @import("../../pool.zig");
const weights = @import("../../routing-table/model_weights.zig");

const Pool = pool_mod.Pool;
const Budget = pool_mod.Budget;

// finding the right bucket
pub fn classIndexFor(size: usize) ?u32 {
    if (size == 0) return null;

    // if clz index is true, we use it
    if (comptime weights.use_clz_index) return clzIndex(size);

    // fallback to this
    return scanIndex(size);
}

// this function utilizes Count Leading Zeroes
// it finds a free slot in O(1), without needing any for loop
fn clzIndex(size: usize) ?u32 {
    const classes = weights.slab_classes;
    // if no classes, return null
    if (comptime classes.len == 0) return null;

    // if size can fit the smallest bucket, return 0
    if (size <= classes[0].class_size) return 0;

    const n = size - 1;

    // @clz counts "Leading Zeros" in the binary number. Subtracting it from 63
    // calculates the base-2 logarithm (the "octave" or magnitude of the number).
    const e: usize = @as(usize, 63) - @clz(n);

    // If the size is too small for the math formula to work, default to bucket 0.
    if (e < weights.sub_bits or e < weights.octave_base) return 0;

    // now that we know the octave, we needto know where exactly inside that octave the size falls
    const sub = (n - (@as(usize, 1) << @intCast(e))) >> @intCast(e - weights.sub_bits);

    // Combine the magnitude (e) and the fractional step (sub) to get the exact bucket index.
    const idx = (e - weights.octave_base) * (@as(usize, 1) << weights.sub_bits) + sub;

    // If the calculated index is larger than biggest bucket, the request is too big
    if (idx >= classes.len) {
        @branchHint(.cold);
        return null;
    }
    return @intCast(idx);
}

// fallback
fn scanIndex(size: usize) ?u32 {
    // loop thru every bucket configuration one by one till we find the fit.
    for (weights.slab_classes, 0..) |class, i| {
        if (size <= class.class_size) return @intCast(i);
    }
    return null;
}

// this is what is returned when alloc() succeeds.
pub const Reservation = struct {
    bytes: []u8, // memory slice
    class_index: u32, // which bucket
    slot_index: u32, // slot ID from that bucket
};

const Bitmap = struct {
    words: []u64, // actual slots. (1 = free, 0 = used)
    summary: []u64, // 1 bit here represents 64 slots in words. (1 = has a free slot)
    root: u64 = 0, // 1 bit here represents 64 slots in summary.

    // finds the lowest available slot and marks it as used.
    fn take(self: *Bitmap) ?u32 {
        // if root is 0, that means every bit is zero. the slab is 100% full.
        if (self.root == 0) {
            @branchHint(.cold);
            return null;
        }

        // find the first '1' bit in the root
        const si: usize = @ctz(self.root);

        // find the first '1' bit in the summary level. then find the word index
        const wi: usize = si * 64 + @ctz(self.summary[si]);

        //find the exact bit
        const bit: usize = @ctz(self.words[wi]);

        // flips the lowest '1' bit to '0'
        self.words[wi] &= self.words[wi] - 1;

        // if flipping the lowest '1' made the whole word be 0,
        // we flip the lowest '1' of summary to mark it as full
        if (self.words[wi] == 0) {
            self.summary[si] &= ~(@as(u64, 1) << @intCast(wi & 63));

            // if flipping the lowest '1' made the whole summary be 0
            // we flip the lowest '1' of the root to mark it as full
            if (self.summary[si] == 0) {
                self.root &= ~(@as(u64, 1) << @intCast(si));
            }
        }

        // return the index (Word Index * 64 + Bit index)
        return @intCast(wi * 64 + bit);
    }

    // returns a slot back to the allocator (mark it as free)
    fn give(self: *Bitmap, slot: u32) void {
        // calculate which word this belongs to. divide by 64
        const wi: usize = slot >> 6;
        // calculate which summary this belongs to. divide by 64
        const si: usize = wi >> 6;

        // use bitwise OR to force the specific bit to '1' in the word
        self.words[wi] |= @as(u64, 1) << @intCast(slot & 63);
        // Force the corresponding bit to '1' in the summary.
        self.summary[si] |= @as(u64, 1) << @intCast(wi & 63);
        // Force the corresponding bit to '1' in the root.
        self.root |= @as(u64, 1) << @intCast(si);
    }
};

// The "Hot" struct. Only contains data needed right now to allocate memory.
// Designed to be tiny so the CPU can load it into L1 Cache instantly.
pub const ClassHot = struct {
    bitmap: Bitmap, // to track free/used memory
    class_size: usize, // how many bytes each slot in this bucket holds
    offset: usize, // where this bucket's memory starts in the main pool
    granted_slots: u32, // how many slots we are allowed to use right now
    max_slots: u32, // hard limit of slots for this bucket given by elastic budget
    high_water_slots: u32, // highest slot number we have ever actually used
};

// Holds analytics and telemetry.
// kept separated so it does not slow down the hot struct in the CPU cache
pub const ClassCold = struct {
    floor_slots: u32 = 0, // initial pre-warmed slot count
    live: u32 = 0, // how many objects are currently allocated
    grows: u64 = 0, // how many times we had to expant granted_slots
    exhausted_fallbacks: u64 = 0, // how many times this bucket ran totally out of space
    zero_slot_fallbacks: u64 = 0, // how many times we asked for a bucket that wasnt configured
};

pub const Slab = struct {
    gpa: std.mem.Allocator, // used to create the Hot/Cold structs
    pool: *Pool, // memory
    budget: *Budget, // tracker that approves OS page limits.
    hot: []ClassHot, // Array of hot structs (one per bucket).
    cold: []ClassCold, // Array of cold structs (one per bucket).
    storage: []u64, // One giant array of numbers holding ALL the bits for ALL bitmaps.
    oversize_fallbacks: u64 = 0, // Requests bigger than our biggest bucket.

    pub fn init(gpa: std.mem.Allocator, p: *Pool, b: *Budget) !Slab {
        // total of slab buckets
        const n = weights.slab_classes.len;

        // calculate how many u64 numbers we need to hold all the bits for all the buckets
        var total_words: usize = 0;
        for (weights.slab_classes) |spec| total_words += bitmapWords(spec.max_slots);

        // allocate a array of u64 to act as bit storage
        const storage = try gpa.alloc(u64, total_words);
        errdefer gpa.free(storage);
        @memset(storage, 0);

        // allocate the arrays for hot and cold structs
        const hot = try gpa.alloc(ClassHot, n);
        errdefer gpa.free(hot);
        const cold = try gpa.alloc(ClassCold, n);
        errdefer gpa.free(cold);

        // wire up the hot/cold structs for each bucket
        var cursor: usize = 0;
        for (weights.slab_classes, 0..) |spec, i| {
            const nwords = wordCount(spec.max_slots);
            const nsum = wordCount(@intCast(nwords));

            // Carve out a slice of the giant storage array just for this specific bucket.
            const block = storage[cursor..][0 .. nwords + nsum];
            cursor += nwords + nsum;

            hot[i] = .{
                // Point the bitmap to its designated slice of the storage array.
                .bitmap = .{ .words = block[0..nwords], .summary = block[nwords..] },
                .class_size = spec.class_size,
                .offset = spec.offset,
                .granted_slots = 0,
                .max_slots = spec.max_slots,
                .high_water_slots = 0,
            };
            cold[i] = .{ .floor_slots = spec.floor_slots };

            var slot: u32 = 0;
            // For every floor slot the ML config asked for, turn its bit to '1' (make it free).
            while (slot < spec.floor_slots) : (slot += 1) hot[i].bitmap.give(slot);
            // Update the granted slots to reflect what we just pre-warmed.
            hot[i].granted_slots = spec.floor_slots;
        }

        return .{
            .gpa = gpa,
            .pool = p,
            .budget = b,
            .hot = hot,
            .cold = cold,
            .storage = storage,
        };
    }

    pub fn deinit(self: *Slab) void {
        self.gpa.free(self.cold);
        self.gpa.free(self.hot);
        self.gpa.free(self.storage);
        self.hot = &.{};
        self.cold = &.{};
        self.storage = &.{};
    }

    // request memory
    pub fn alloc(self: *Slab, size: usize) ?Reservation {
        const class_index = classIndexFor(size) orelse {
            @branchHint(.cold);
            // if the size was too big.
            if (size != 0) self.oversize_fallbacks += 1;
            return null;
        };

        // get the hot struct for the bucket
        const hot = &self.hot[class_index];

        // find a slot
        var slot = hot.bitmap.take();

        if (slot == null) {
            @branchHint(.cold);
            // try to unlock a new slot by growing
            if (self.grow(class_index)) {
                slot = hot.bitmap.take();
            }

            if (slot == null) {
                self.recordFallback(class_index);
                return null;
            }
        }

        // unwrap the slot index
        const taken = slot.?;

        // check if this is inside first budget or elastic
        if (taken >= hot.high_water_slots) {
            @branchHint(.cold);

            // calculate exactly how many new slots
            const fresh = taken + 1 - hot.high_water_slots;

            // check if we still have budget
            if (!self.budget.tryCommit(fresh * hot.class_size)) {
                hot.bitmap.give(taken);
                self.recordFallback(class_index);
                return null;
            }

            // if budget is approved, move the high-watermark up
            hot.high_water_slots = taken + 1;
        }

        self.cold[class_index].live += 1; // We have one more live object.

        const slot_offset = hot.offset + @as(usize, taken) * hot.class_size;

        return .{
            .bytes = self.pool.slice(slot_offset, size), // Slice the memory
            .class_index = class_index,
            .slot_index = taken,
        };
    }

    pub fn free(self: *Slab, class_index: u32, slot_index: u32) void {
        // we js need to turn the slot bit back to 1
        self.hot[class_index].bitmap.give(slot_index);
        // decrease live count.
        self.cold[class_index].live -= 1;
    }

    // Logs exactly WHY an allocation failed in the Cold struct.
    fn recordFallback(self: *Slab, class_index: u32) void {
        const cold = &self.cold[class_index];
        if (cold.floor_slots == 0) {
            // We failed because this bucket was configured to have 0 slots.
            cold.zero_slot_fallbacks += 1;
        } else {
            // We failed because the bucket was full and couldn't grow anymore.
            cold.exhausted_fallbacks += 1;
        }
    }

    fn grow(self: *Slab, class_index: u32) bool {
        const hot = &self.hot[class_index];
        // If we have already granted the maximum allowed slots, we can't grow.
        if (hot.granted_slots >= hot.max_slots) return false;

        // Turn the bit for the NEXT available slot to '1'.
        hot.bitmap.give(hot.granted_slots);
        // Increase our granted count.
        hot.granted_slots += 1;
        // Log the growth in the telemetry.
        self.cold[class_index].grows += 1;
        return true;
    }

    // calculates how many 64-bit words are needed to hold 'X' bits
    fn wordCount(bits: u32) usize {
        return (@as(usize, bits) + 63) / 64;
    }

    // calculates total words for both the slot and the summary level
    fn bitmapWords(max_slots: u32) usize {
        const nwords = wordCount(max_slots);
        return nwords + wordCount(@intCast(nwords));
    }
};
