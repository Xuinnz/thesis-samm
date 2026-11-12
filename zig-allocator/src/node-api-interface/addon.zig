const std = @import("std");

const c = @import("napi.zig").c;
const samm = @import("samm");
const engine_mod = samm.engine;
const weights = samm.weights;
const bump_alignment = samm.bump.alignment;

const gpa = std.heap.c_allocator;

/// Initialized once at module load and never moved: the arenas inside it hold
/// pointers to its own pool and budget fields.
var engine: engine_mod.Engine = undefined;
var engine_ready = false;

/// Call-site identifiers are short source locations like
/// "process.js:processRoute". Anything approaching this length is a caller bug,
/// and silently truncating one would hash to the wrong value and route the
/// call-site to System without a trace.
const max_call_site_len = 512;

// ---------------------------------------------------------------------------
// REGIONS
//
// A region is a request's worth of allocations, reclaimed in one deterministic
// batch when the response finishes rather than whenever V8 gets around to
// collecting each Buffer.
//
// This is what makes reclamation deterministic. The finalizer path below is
// still correct, but its timing is the GC's to decide -- measured at 500 RPS
// that produced 49,383 requests where a bump segment could not be recycled
// because finalizers had not run yet. A region closes on `res.finish`, which is
// a structural boundary, not a statistical one.
//
// Safety: a buffer that escapes its request would otherwise read memory that
// has been handed to another request. On close the region DETACHES each
// buffer's ArrayBuffer, so an escaped reference can never reach recycled
// bytes. It does not fail loudly, though: a detached Buffer reads as empty
// (length 0, toString() "", write() returns 0), and only bounds-checked reads
// such as readUInt8 throw. A misrouted escaping call-site therefore loses its
// data silently instead of corrupting another request's, and zero failed
// requests does not show that nothing escaped (the reachability oracle,
// server/routes/_oracle.js, measures that). Detach failures are counted rather
// than ignored -- if that number is ever non-zero, an escaped reference could
// read recycled memory and the run should not be trusted.
const max_regions = 8192;
const region_index_bits = 13;
comptime {
    if (max_regions != 1 << region_index_bits) @compileError("region_index_bits must match max_regions");
}

const RegionEntry = struct {
    handle: engine_mod.Handle,
    /// A Buffer (detach mode), a chunk's ArrayBuffer (chunk mode), or null for
    /// an object that is only a view into its segment (view mode).
    ref: c.napi_ref,
    is_chunk: bool = false,
};

// ---------------------------------------------------------------------------
// BUFFER MODES
//
// Creating an external Buffer costs V8 about a microsecond; the bridge call
// and the engine together cost about 30 ns. A request that allocates hundreds
// of small objects (batch.js) therefore spends nearly all of its allocation
// time on V8 object creation. The two extra modes replace most of those
// Buffers with typed-array views, which cost tens of nanoseconds. They only
// apply to region-scoped allocations from bump arenas; everything else takes
// the detach path whatever the mode.
//
// SAMM_BUFFER_MODE =
//   detach  (default) one external Buffer per object, detached when its
//           region closes. An escaped reference reads as empty from then on.
//   chunk   each region carves private chunks out of the arena and its objects
//           are views into its own chunks; one ArrayBuffer per chunk, detached
//           when the region closes. Same guarantee as detach, and a view's
//           `.buffer` exposes that request's chunk and nothing else.
//   view    one ArrayBuffer per SEGMENT, shared by every request allocating in
//           it and detached only when the segment is recycled. The cheapest,
//           and the weakest: an escaped view stays readable until its segment
//           is recycled, and `.buffer` exposes the whole segment, other
//           requests' bytes included. Kept to measure the upper bound.
const BufferMode = enum { detach, chunk, view };
var buffer_mode: BufferMode = .detach;

const n_bump = weights.bump_arenas.len;
const max_bump_segments = blk: {
    var m: u32 = 1;
    for (weights.bump_arenas) |a| m = @max(m, a.max_segments);
    break :blk m;
};

/// One region's current chunk in one bump arena (chunk mode).
const Chunk = struct {
    ref: c.napi_ref = null,
    base: usize = 0, // offset into the pool
    cap: usize = 0,
    used: usize = 0,
    /// Size of the next chunk this region opens here; doubles up to the cap.
    next_bytes: usize = first_chunk_bytes,
    /// Allocations this region has made from this arena.
    seen: u32 = 0,
    /// Identifies this chunk's ArrayBuffer to the JS wrapper.
    serial: u32 = 0,
};

/// A region's first chunk. Later ones double, up to a quarter of the arena's
/// segment, so a request that allocates a lot converges on a few ArrayBuffers
/// while one that allocates little wastes little.
const first_chunk_bytes = 64 * 1024;
const chunk_segment_fraction = 4;
/// An object larger than 1/this of its chunk (chunk mode) or segment (view
/// mode) gains nothing from sharing an ArrayBuffer and takes the detach path.
const min_objects_per_buffer = 4;

const Region = struct {
    open: bool = false,
    entries: std.ArrayList(RegionEntry) = .{},
    chunks: [n_bump]Chunk = [_]Chunk{.{}} ** n_bump,
    /// Objects served as views (they have no entry of their own).
    viewed: u32 = 0,
    /// Bumped at every close. A region id handed to JS carries the generation
    /// it was opened in, so an id that outlived its region (a handler still
    /// running after its client disconnected) cannot name whichever request
    /// holds the slot now.
    generation: u32 = 0,
};

/// The id samm_region_open() returns: slot index plus the slot's generation.
fn regionToken(index: u32) i64 {
    return (@as(i64, regions[index].generation) << region_index_bits) | index;
}

/// The open region a token names, or null if it has closed since.
fn regionFor(token: i64) ?u32 {
    if (token < 0) return null;
    const index: usize = @intCast(token & (max_regions - 1));
    if (!regions[index].open or regions[index].generation != token >> region_index_bits) return null;
    return @intCast(index);
}

/// view mode: each segment's current ArrayBuffer and the epoch it was made in.
var seg_refs: [n_bump][max_bump_segments]c.napi_ref = [_][max_bump_segments]c.napi_ref{[_]c.napi_ref{null} ** max_bump_segments} ** n_bump;
var seg_epochs: [n_bump][max_bump_segments]u32 = [_][max_bump_segments]u32{[_]u32{0} ** max_bump_segments} ** n_bump;

/// Written by samm_allocate_shared for the JS wrapper, which holds a
/// Uint32Array over it: [0] which ArrayBuffer the offset is relative to (a
/// serial that changes whenever that buffer is replaced), [1] arena index,
/// [2] segment (view mode), [3] the region's slot index.
var shared_out: [4]u32 = .{ 0, 0, 0, 0 };
var buffer_serial: u32 = 0;

const use_exact_path: i32 = -2;
const refused: i32 = -1;

var regions: []Region = &.{};
var free_region_ids: []u32 = &.{};
var free_region_count: usize = 0;

var region_stats = struct {
    opened: u64 = 0,
    closed: u64 = 0,
    reclaimed: u64 = 0,
    /// Allocations that ran without a region and so fell back to the
    /// GC-driven finalizer. Non-zero means reclamation was not fully
    /// deterministic for that fraction of the run.
    unscoped: u64 = 0,
    /// No free region slot was available. The allocation still succeeds, via
    /// the finalizer path.
    exhausted: u64 = 0,
    /// A buffer could not be detached on close, so an escaped reference to it
    /// would read recycled memory. Must stay zero.
    detach_failures: u64 = 0,
    /// Objects handed out as views into a shared ArrayBuffer (chunk and view modes).
    viewed: u64 = 0,
    /// ArrayBuffers created for chunks or segments.
    shared_buffers: u64 = 0,
}{};

fn regionsInit() !void {
    regions = try gpa.alloc(Region, max_regions);
    for (regions) |*r| r.* = .{};

    free_region_ids = try gpa.alloc(u32, max_regions);
    var i: u32 = 0;
    while (i < max_regions) : (i += 1) free_region_ids[i] = max_regions - 1 - i;
    free_region_count = max_regions;
}

fn regionOpen() ?u32 {
    if (free_region_count == 0) {
        @branchHint(.cold);
        region_stats.exhausted += 1;
        return null;
    }
    free_region_count -= 1;
    const id = free_region_ids[free_region_count];
    regions[id].open = true;
    regions[id].entries.clearRetainingCapacity();
    regions[id].chunks = [_]Chunk{.{}} ** n_bump;
    regions[id].viewed = 0;
    region_stats.opened += 1;
    return id;
}

/// Detaches the buffer so a surviving reference sees an empty buffer instead
/// of recycled memory (silently: see REGIONS), then returns its space to the
/// allocator.
fn reclaimEntry(env: c.napi_env, entry: RegionEntry) void {
    if (entry.ref == null) {
        // A view into its segment's ArrayBuffer: nothing of its own to detach.
        engine.release(entry.handle);
        return;
    }
    var value: c.napi_value = undefined;
    if (entry.is_chunk) {
        // One detach empties every view the region made into this chunk.
        if (c.napi_get_reference_value(env, entry.ref, &value) != c.napi_ok or value == null or
            c.napi_detach_arraybuffer(env, value) != c.napi_ok)
        {
            region_stats.detach_failures += 1;
        }
    } else if (c.napi_get_reference_value(env, entry.ref, &value) == c.napi_ok and value != null) {
        var array_buffer: c.napi_value = undefined;
        var kind: c.napi_typedarray_type = undefined;
        var length: usize = 0;
        var data: ?*anyopaque = null;
        var byte_offset: usize = 0;
        if (c.napi_get_typedarray_info(env, value, &kind, &length, &data, &array_buffer, &byte_offset) == c.napi_ok) {
            if (c.napi_detach_arraybuffer(env, array_buffer) != c.napi_ok) {
                region_stats.detach_failures += 1;
            }
        } else {
            region_stats.detach_failures += 1;
        }
    }
    _ = c.napi_delete_reference(env, entry.ref);
    engine.release(entry.handle);
}

fn regionClose(env: c.napi_env, token: i64) u32 {
    const id = regionFor(token) orelse return 0;

    const region = &regions[id];
    for (region.entries.items) |entry| reclaimEntry(env, entry);

    // Objects, not entries: a chunk is one entry however many views it backs.
    var reclaimed: u32 = region.viewed;
    for (region.entries.items) |entry| {
        if (!entry.is_chunk) reclaimed += 1;
    }
    region.entries.clearRetainingCapacity();
    region.open = false;
    region.generation = (region.generation + 1) & 0x1ffff; // keeps the token a small exact integer

    free_region_ids[free_region_count] = id;
    free_region_count += 1;

    region_stats.closed += 1;
    region_stats.reclaimed += reclaimed;
    return reclaimed;
}

fn jsNull(env: c.napi_env) c.napi_value {
    var value: c.napi_value = undefined;
    _ = c.napi_get_null(env, &value);
    return value;
}

fn throw(env: c.napi_env, message: [*:0]const u8) c.napi_value {
    _ = c.napi_throw_error(env, null, message);
    return null;
}

/// Reads up to `out.len` arguments, requiring at least `required` of them.
/// Slots past what the caller supplied are left null, so an optional trailing
/// argument is simply absent rather than an error.
fn args(
    env: c.napi_env,
    info: c.napi_callback_info,
    comptime required: usize,
    out: anytype,
) bool {
    const capacity = @typeInfo(@TypeOf(out.*)).array.len;
    for (out) |*slot| slot.* = null;
    var argc: usize = capacity;
    return c.napi_get_cb_info(env, info, &argc, out, null, null) == c.napi_ok and argc >= required;
}

/// samm_intern(callSiteId: string) -> token: number
///
/// Resolves a call-site to a routing decision once, at startup. The allocation
/// path then takes the token, so no request hashes a string or probes the table.
fn intern(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    if (!engine_ready) return throw(env, "samm allocator failed to initialize");

    var argv: [1]c.napi_value = undefined;
    if (!args(env, info, 1, &argv)) return throw(env, "samm_intern(callSiteId: string) expected");

    var buf: [max_call_site_len]u8 = undefined;
    var len: usize = 0;
    if (c.napi_get_value_string_utf8(env, argv[0], &buf, buf.len, &len) != c.napi_ok) {
        return throw(env, "callSiteId must be a string");
    }
    if (len >= buf.len - 1) {
        return throw(env, "callSiteId is too long and would hash incorrectly");
    }

    const token = engine.intern(buf[0..len]) orelse
        return throw(env, "samm allocator: too many interned call-sites");

    var result: c.napi_value = undefined;
    _ = c.napi_create_uint32(env, token, &result);
    return result;
}

/// samm_allocate(token: number, sizeBytes: number) -> Buffer | null
///
/// A null return means the call-site is not managed by SAMM, or no arena could
/// serve the request. Either way the caller should fall back to
/// Buffer.allocUnsafe(). Deciding which call-sites to route here at all belongs
/// to the server, not to this addon.
fn allocate(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    if (!engine_ready) return throw(env, "samm allocator failed to initialize");

    var argv: [3]c.napi_value = undefined;
    if (!args(env, info, 2, &argv)) {
        return throw(env, "samm_allocate(token: number, sizeBytes: number, regionId?: number) expected");
    }

    var token: u32 = 0;
    if (c.napi_get_value_uint32(env, argv[0], &token) != c.napi_ok) {
        return throw(env, "token must be a number from samm_intern()");
    }

    var size_bytes: i64 = 0;
    if (c.napi_get_value_int64(env, argv[1], &size_bytes) != c.napi_ok) {
        return throw(env, "sizeBytes must be a number");
    }
    if (size_bytes <= 0) return jsNull(env);

    // Third argument is optional: a region id from samm_region_open(), or
    // absent/negative for an unscoped allocation.
    var region_id: i64 = -1;
    if (argv[2] != null) {
        _ = c.napi_get_value_int64(env, argv[2], &region_id);
    }
    const region_index = regionFor(region_id);
    const scoped = region_index != null;

    const allocation = engine.allocate(token, @intCast(size_bytes)) orelse
        return jsNull(env);

    // Zero-copy either way: the Buffer is a window onto the mmap'd region
    // itself, not a copy of it.
    var result: c.napi_value = undefined;

    if (scoped) {
        // No finalizer. The region reclaims this deterministically at
        // response end, and a strong reference keeps the Buffer alive until
        // then so the detach on close has something to detach.
        //
        // V8 counts this Buffer's length as external memory until the detach,
        // which feeds its major-GC trigger although no collection can free
        // these bytes. Do NOT cancel that with napi_adjust_external_memory
        // (tried 2026-11-11): that counter may only give back what the addon
        // itself added, and V8 13 (Node 24) aborts the process with
        // "Check failed: amount_before >= -delta" once it is exceeded.
        if (c.napi_create_external_buffer(
            env,
            allocation.bytes.len,
            allocation.bytes.ptr,
            null,
            null,
            &result,
        ) != c.napi_ok) {
            @branchHint(.cold);
            engine.release(allocation.handle);
            return jsNull(env);
        }

        var ref: c.napi_ref = undefined;
        if (c.napi_create_reference(env, result, 1, &ref) != c.napi_ok) {
            @branchHint(.cold);
            engine.release(allocation.handle);
            return jsNull(env);
        }

        regions[region_index.?].entries.append(gpa, .{
            .handle = allocation.handle,
            .ref = ref,
        }) catch {
            @branchHint(.cold);
            _ = c.napi_delete_reference(env, ref);
            engine.release(allocation.handle);
            return jsNull(env);
        };

        return result;
    }

    // Unscoped: fall back to GC-driven reclamation. The handle rides in
    // `finalize_hint`, which N-API treats as an opaque word and never
    // dereferences, so this needs no side allocation.
    region_stats.unscoped += 1;
    if (c.napi_create_external_buffer(
        env,
        allocation.bytes.len,
        allocation.bytes.ptr,
        finalizeBuffer,
        @ptrFromInt(allocation.handle),
        &result,
    ) != c.napi_ok) {
        // Builds with V8 pointer compression refuse external buffers. Give the
        // space back and let the caller use a plain Buffer.
        @branchHint(.cold);
        engine.release(allocation.handle);
        return jsNull(env);
    }

    return result;
}

fn int32(env: c.napi_env, value: i32) c.napi_value {
    var result: c.napi_value = undefined;
    _ = c.napi_create_int32(env, value, &result);
    return result;
}

/// samm_allocate_shared(token, sizeBytes, regionId) -> offset | -1 | -2
///
/// chunk and view modes. On success the object is `sizeBytes` at the returned
/// offset of the ArrayBuffer `shared_out` identifies, and the JS wrapper makes
/// the view. -1: no arena could serve it (use a plain Buffer). -2: this
/// allocation is not one that shares a buffer; call samm_allocate.
fn allocateShared(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    if (!engine_ready) return throw(env, "samm allocator failed to initialize");

    var argv: [3]c.napi_value = undefined;
    if (!args(env, info, 3, &argv)) return throw(env, "samm_allocate_shared(token, sizeBytes, regionId) expected");
    var token: u32 = 0;
    var size_i: i64 = 0;
    var region_id: i64 = -1;
    if (c.napi_get_value_uint32(env, argv[0], &token) != c.napi_ok or
        c.napi_get_value_int64(env, argv[1], &size_i) != c.napi_ok or
        c.napi_get_value_int64(env, argv[2], &region_id) != c.napi_ok)
    {
        return throw(env, "samm_allocate_shared: arguments must be numbers");
    }
    if (buffer_mode == .detach or size_i <= 0) return int32(env, use_exact_path);
    const region_index = regionFor(region_id) orelse return int32(env, use_exact_path);
    const decision = engine.decisionFor(token) orelse return int32(env, use_exact_path);
    if (decision.policy != .bump) return int32(env, use_exact_path);

    const size: usize = @intCast(size_i);
    const ai = decision.arena_index;
    const arena = &engine.bump_arenas[ai];
    const region = &regions[region_index];
    shared_out[3] = region_index;

    if (buffer_mode == .view) {
        if (size * min_objects_per_buffer > arena.segment_bytes) return int32(env, use_exact_path);
        const allocation = engine.allocate(token, size) orelse return int32(env, refused);
        const seg = arena.currentSegment();
        const seg_start = arena.offset + @as(usize, seg) * arena.segment_bytes;
        if (seg_refs[ai][seg] == null or seg_epochs[ai][seg] != arena.epochs[seg]) {
            // New, or recycled since its ArrayBuffer was made: cut every old
            // view off before any of this memory is handed out again.
            if (seg_refs[ai][seg] != null) {
                var old: c.napi_value = undefined;
                if (c.napi_get_reference_value(env, seg_refs[ai][seg], &old) != c.napi_ok or old == null or
                    c.napi_detach_arraybuffer(env, old) != c.napi_ok)
                {
                    region_stats.detach_failures += 1;
                }
                _ = c.napi_delete_reference(env, seg_refs[ai][seg]);
                seg_refs[ai][seg] = null;
            }
            var ab: c.napi_value = undefined;
            if (c.napi_create_external_arraybuffer(env, engine.pool.region.ptr + seg_start, arena.segment_bytes, null, null, &ab) != c.napi_ok or
                c.napi_create_reference(env, ab, 1, &seg_refs[ai][seg]) != c.napi_ok)
            {
                @branchHint(.cold);
                seg_refs[ai][seg] = null;
                engine.release(allocation.handle);
                return int32(env, refused);
            }
            seg_epochs[ai][seg] = arena.epochs[seg];
            region_stats.shared_buffers += 1;
        }
        region.entries.append(gpa, .{ .handle = allocation.handle, .ref = null }) catch {
            @branchHint(.cold);
            engine.release(allocation.handle);
            return int32(env, refused);
        };
        region_stats.viewed += 1; // counted at close through its entry
        shared_out[0] = seg_epochs[ai][seg];
        shared_out[1] = ai;
        shared_out[2] = seg;
        return int32(env, @intCast(@intFromPtr(allocation.bytes.ptr) - @intFromPtr(engine.pool.region.ptr) - seg_start));
    }

    // chunk mode
    const chunk = &region.chunks[ai];
    chunk.seen += 1;
    // A request's first allocation here stays an ordinary Buffer: most
    // requests make exactly one, and a chunk for it would be pure waste.
    if (chunk.seen == 1) return int32(env, use_exact_path);

    const chunk_cap = std.mem.alignBackward(usize, arena.segment_bytes / chunk_segment_fraction, bump_alignment);
    if (size * min_objects_per_buffer > chunk_cap) return int32(env, use_exact_path);

    var start = std.mem.alignForward(usize, chunk.used, bump_alignment);
    if (chunk.cap == 0 or start + size > chunk.cap) {
        // Open the region's next chunk. If the arena cannot serve a whole
        // chunk the object may still fit on its own, so that attempt must not
        // be counted as a fallback.
        var want = @max(chunk.next_bytes, std.mem.alignForward(usize, size * min_objects_per_buffer, bump_alignment));
        want = @min(want, chunk_cap);
        const blocked = arena.reset_blocked;
        const refusals = engine.budget.refusals;
        const allocation = engine.allocate(token, want) orelse {
            arena.reset_blocked = blocked;
            engine.budget.refusals = refusals;
            return int32(env, use_exact_path);
        };
        var ab: c.napi_value = undefined;
        var ref: c.napi_ref = undefined;
        if (c.napi_create_external_arraybuffer(env, allocation.bytes.ptr, want, null, null, &ab) != c.napi_ok or
            c.napi_create_reference(env, ab, 1, &ref) != c.napi_ok)
        {
            @branchHint(.cold);
            engine.release(allocation.handle);
            return int32(env, use_exact_path);
        }
        region.entries.append(gpa, .{ .handle = allocation.handle, .ref = ref, .is_chunk = true }) catch {
            @branchHint(.cold);
            _ = c.napi_delete_reference(env, ref);
            engine.release(allocation.handle);
            return int32(env, use_exact_path);
        };
        buffer_serial +%= 1;
        chunk.ref = ref;
        chunk.base = @intFromPtr(allocation.bytes.ptr) - @intFromPtr(engine.pool.region.ptr);
        chunk.cap = want;
        chunk.used = 0;
        chunk.next_bytes = @min(want * 2, chunk_cap);
        chunk.serial = buffer_serial;
        region_stats.shared_buffers += 1;
        start = 0;
    }
    chunk.used = start + size;
    region.viewed += 1;
    region_stats.viewed += 1;
    shared_out[0] = chunk.serial;
    shared_out[1] = ai;
    return int32(env, @intCast(start));
}

/// samm_shared_buffer(regionId) -> the ArrayBuffer the last samm_allocate_shared
/// offset refers to (the JS wrapper asks only when `shared_out[0]` changed).
fn sharedBuffer(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    if (!args(env, info, 1, &argv)) return throw(env, "samm_shared_buffer(regionId) expected");
    var region_id: i64 = -1;
    _ = c.napi_get_value_int64(env, argv[0], &region_id);
    const ai = shared_out[1];
    var ref: c.napi_ref = null;
    if (buffer_mode == .view) {
        ref = seg_refs[ai][shared_out[2]];
    } else if (regionFor(region_id)) |index| {
        ref = regions[index].chunks[ai].ref;
    }
    var ab: c.napi_value = undefined;
    if (ref == null or c.napi_get_reference_value(env, ref, &ab) != c.napi_ok) return jsNull(env);
    return ab;
}

/// samm_shared_out() -> Uint32Array over `shared_out`
fn sharedOut(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    _ = info;
    var ab: c.napi_value = undefined;
    var view: c.napi_value = undefined;
    if (c.napi_create_external_arraybuffer(env, &shared_out, @sizeOf(@TypeOf(shared_out)), null, null, &ab) != c.napi_ok or
        c.napi_create_typedarray(env, c.napi_uint32_array, shared_out.len, ab, 0, &view) != c.napi_ok)
    {
        return throw(env, "samm allocator: could not expose shared_out");
    }
    return view;
}

/// samm_token_shares(token) -> whether samm_allocate_shared can ever serve it
/// (a bump call-site, in chunk or view mode), so the wrapper can skip the call.
fn tokenShares(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    var argv: [1]c.napi_value = undefined;
    if (!args(env, info, 1, &argv)) return throw(env, "samm_token_shares(token) expected");
    var token: u32 = 0;
    _ = c.napi_get_value_uint32(env, argv[0], &token);
    const decision = engine.decisionFor(token);
    var result: c.napi_value = undefined;
    _ = c.napi_get_boolean(env, buffer_mode != .detach and decision != null and decision.?.policy == .bump, &result);
    return result;
}

/// samm_buffer_mode() -> "detach" | "chunk" | "view"
fn bufferModeFn(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    _ = info;
    var result: c.napi_value = undefined;
    const name = @tagName(buffer_mode);
    _ = c.napi_create_string_utf8(env, name.ptr, name.len, &result);
    return result;
}

/// samm_region_open() -> regionId | -1 when no slot is free
fn regionOpenFn(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    _ = info;
    if (!engine_ready) return throw(env, "samm allocator failed to initialize");

    var result: c.napi_value = undefined;
    const id = regionOpen();
    _ = c.napi_create_int64(env, if (id) |v| regionToken(v) else -1, &result);
    return result;
}

/// samm_region_close(regionId) -> number of allocations reclaimed
fn regionCloseFn(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    if (!engine_ready) return throw(env, "samm allocator failed to initialize");

    var argv: [1]c.napi_value = undefined;
    if (!args(env, info, 1, &argv)) return throw(env, "samm_region_close(regionId) expected");

    var id: i64 = -1;
    if (c.napi_get_value_int64(env, argv[0], &id) != c.napi_ok or id < 0) {
        var zero: c.napi_value = undefined;
        _ = c.napi_create_uint32(env, 0, &zero);
        return zero;
    }

    var result: c.napi_value = undefined;
    _ = c.napi_create_uint32(env, regionClose(env, id), &result);
    return result;
}

/// Runs on the main JS thread when V8 collects the Buffer, and never
/// concurrently with `allocate`. That is what lets the bitmaps and arena
/// cursors stay lock-free.
fn finalizeBuffer(env: c.napi_env, data: ?*anyopaque, hint: ?*anyopaque) callconv(.c) void {
    _ = env;
    _ = data;
    engine.release(@intFromPtr(hint));
}

/// samm_warmup() -> bytes: number
///
/// Faults in every stratum's floor. Call before the measurement window opens
/// so that unavoidable first-touch faults are not attributed to request
/// latency. It touches pages only: the budget is still charged on first use.
fn warmup(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    _ = info;
    if (!engine_ready) return throw(env, "samm allocator failed to initialize");

    var result: c.napi_value = undefined;
    _ = c.napi_create_double(env, @floatFromInt(engine.warmup()), &result);
    return result;
}

/// samm_stats() -> counters
///
/// capacityFallbacks is the sum of the five attributed causes, each pointing at
/// a different thing to fix:
///   bumpOversizeFallbacks  - object bigger than its call-site's whole span
///   slabOversizeFallbacks  - object bigger than the largest slab class
///   slabZeroSlotFallbacks  - class never provisioned and could not grow
///   slabExhaustedFallbacks - class provisioned but out of slots and capped
///   bumpResetBlocked       - generation still alive and the arena could not grow
fn stats(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    _ = info;
    if (!engine_ready) return throw(env, "samm allocator failed to initialize");

    const s = engine.stats();

    var result: c.napi_value = undefined;
    if (c.napi_create_object(env, &result) != c.napi_ok) {
        return throw(env, "failed to create stats object");
    }

    setNumber(env, result, "unmanaged", s.unmanaged);
    setNumber(env, result, "capacityFallbacks", s.capacity_fallbacks);
    setNumber(env, result, "bumpOversizeFallbacks", s.bump_oversize_fallbacks);
    setNumber(env, result, "slabOversizeFallbacks", s.slab_oversize_fallbacks);
    setNumber(env, result, "slabZeroSlotFallbacks", s.slab_zero_slot_fallbacks);
    setNumber(env, result, "slabExhaustedFallbacks", s.slab_exhausted_fallbacks);
    setNumber(env, result, "bumpResetBlocked", s.bump_reset_blocked);
    setNumber(env, result, "bumpResets", s.bump_resets);
    setNumber(env, result, "bumpReuses", s.bump_reuses);
    setNumber(env, result, "grows", s.grows);
    setNumber(env, result, "committedBytes", s.committed_bytes);
    setNumber(env, result, "ceilingBytes", s.ceiling_bytes);
    setNumber(env, result, "reservedFloorBytes", s.reserved_floor_bytes);
    setNumber(env, result, "budgetRefusals", s.budget_refusals);
    setNumber(env, result, "warmedBytes", s.warmed_bytes);

    setNumber(env, result, "regionsOpened", region_stats.opened);
    setNumber(env, result, "regionsClosed", region_stats.closed);
    setNumber(env, result, "regionReclaimed", region_stats.reclaimed);
    setNumber(env, result, "unscopedAllocations", region_stats.unscoped);
    setNumber(env, result, "regionsExhausted", region_stats.exhausted);
    setNumber(env, result, "detachFailures", region_stats.detach_failures);
    setNumber(env, result, "viewedAllocations", region_stats.viewed);
    setNumber(env, result, "sharedBuffers", region_stats.shared_buffers);

    return result;
}

fn setNumber(env: c.napi_env, object: c.napi_value, name: [*:0]const u8, value: u64) void {
    var number: c.napi_value = undefined;
    if (c.napi_create_double(env, @floatFromInt(value), &number) != c.napi_ok) return;
    _ = c.napi_set_named_property(env, object, name, number);
}

fn exportFunction(
    env: c.napi_env,
    exports: c.napi_value,
    name: [*:0]const u8,
    callback: c.napi_callback,
) void {
    var value: c.napi_value = undefined;
    if (c.napi_create_function(env, name, c.NAPI_AUTO_LENGTH, callback, null, &value) != c.napi_ok) {
        return;
    }
    _ = c.napi_set_named_property(env, exports, name, value);
}

/// SAMM_RECLAIM_POLICY = none | dontneed | free. Default none: the arena owns
/// its pages for the process lifetime, so wrapping writes straight over them.
fn reclaimPolicyFromEnv() engine_mod.ReclaimPolicy {
    const raw = std.posix.getenv("SAMM_RECLAIM_POLICY") orelse return .none;
    return samm.pool.ReclaimPolicy.fromString(raw) orelse .none;
}

/// SAMM_SEGMENT_REUSE = any (default) | next (see bump.zig's SegmentReuse).
/// Unset keeps the arena's default; an unknown value is refused, because a
/// typo would otherwise silently benchmark the default.
fn segmentReuseFromEnv() !?engine_mod.SegmentReuse {
    const raw = std.posix.getenv("SAMM_SEGMENT_REUSE") orelse return null;
    if (raw.len == 0) return null; // docker -e NAME="" passes an empty value
    return engine_mod.SegmentReuse.fromString(raw) orelse error.BadSetting;
}

/// SAMM_BUFFER_MODE = detach (default) | chunk | view (see BUFFER MODES).
fn bufferModeFromEnv() !BufferMode {
    const raw = std.posix.getenv("SAMM_BUFFER_MODE") orelse return .detach;
    if (raw.len == 0) return .detach;
    return std.meta.stringToEnum(BufferMode, raw) orelse error.BadSetting;
}

export fn napi_register_module_v1(env: c.napi_env, exports: c.napi_value) c.napi_value {
    // One anonymous mapping for the whole pool, reserved here at module load.
    engine.init(gpa, reclaimPolicyFromEnv()) catch |err| {
        _ = c.napi_throw_error(env, null, switch (err) {
            error.OutOfMemory => "samm allocator: out of memory reserving the pool",
            else => "samm allocator: failed to reserve the backing mapping",
        });
        return exports;
    };
    regionsInit() catch {
        _ = c.napi_throw_error(env, null, "samm allocator: out of memory reserving regions");
        return exports;
    };
    const reuse = segmentReuseFromEnv() catch {
        _ = c.napi_throw_error(env, null, "samm allocator: SAMM_SEGMENT_REUSE must be any or next");
        return exports;
    };
    if (reuse) |r| engine.setSegmentReuse(r);
    buffer_mode = bufferModeFromEnv() catch {
        _ = c.napi_throw_error(env, null, "samm allocator: SAMM_BUFFER_MODE must be detach, chunk or view");
        return exports;
    };
    engine_ready = true;

    exportFunction(env, exports, "samm_intern", intern);
    exportFunction(env, exports, "samm_allocate", allocate);
    exportFunction(env, exports, "samm_allocate_shared", allocateShared);
    exportFunction(env, exports, "samm_shared_buffer", sharedBuffer);
    exportFunction(env, exports, "samm_shared_out", sharedOut);
    exportFunction(env, exports, "samm_buffer_mode", bufferModeFn);
    exportFunction(env, exports, "samm_token_shares", tokenShares);
    exportFunction(env, exports, "samm_region_open", regionOpenFn);
    exportFunction(env, exports, "samm_region_close", regionCloseFn);
    exportFunction(env, exports, "samm_warmup", warmup);
    exportFunction(env, exports, "samm_stats", stats);

    return exports;
}
