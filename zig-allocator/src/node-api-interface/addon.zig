const std = @import("std");

const c = @import("napi.zig").c;
const samm = @import("samm");
const engine_mod = samm.engine;

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
// buffer's ArrayBuffer, so an escaped reference sees a zero-length detached
// buffer and throws, instead of silently reading recycled bytes. Detach
// failures are counted rather than ignored -- if that number is ever non-zero
// the safety net is not working and the run should not be trusted.
const max_regions = 8192;

const RegionEntry = struct {
    handle: engine_mod.Handle,
    ref: c.napi_ref,
};

const Region = struct {
    open: bool = false,
    entries: std.ArrayList(RegionEntry) = .{},
};

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
    region_stats.opened += 1;
    return id;
}

/// Detaches the buffer so any surviving reference fails loudly, then returns
/// its space to the allocator.
fn reclaimEntry(env: c.napi_env, entry: RegionEntry) void {
    var value: c.napi_value = undefined;
    if (c.napi_get_reference_value(env, entry.ref, &value) == c.napi_ok and value != null) {
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

fn regionClose(env: c.napi_env, id: u32) u32 {
    if (id >= regions.len or !regions[id].open) return 0;

    const region = &regions[id];
    for (region.entries.items) |entry| reclaimEntry(env, entry);

    const reclaimed: u32 = @intCast(region.entries.items.len);
    region.entries.clearRetainingCapacity();
    region.open = false;

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
    const scoped = region_id >= 0 and
        region_id < @as(i64, @intCast(regions.len)) and
        regions[@intCast(region_id)].open;

    const allocation = engine.allocate(token, @intCast(size_bytes)) orelse
        return jsNull(env);

    // Zero-copy either way: the Buffer is a window onto the mmap'd region
    // itself, not a copy of it.
    var result: c.napi_value = undefined;

    if (scoped) {
        // No finalizer. The region reclaims this deterministically at
        // response end, and a strong reference keeps the Buffer alive until
        // then so the detach on close has something to detach.
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

        regions[@intCast(region_id)].entries.append(gpa, .{
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

/// samm_region_open() -> regionId | -1 when no slot is free
fn regionOpenFn(env: c.napi_env, info: c.napi_callback_info) callconv(.c) c.napi_value {
    _ = info;
    if (!engine_ready) return throw(env, "samm allocator failed to initialize");

    var result: c.napi_value = undefined;
    const id = regionOpen();
    _ = c.napi_create_int64(env, if (id) |v| @intCast(v) else -1, &result);
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
    _ = c.napi_create_uint32(env, regionClose(env, @intCast(id)), &result);
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
/// Faults in every stratum's guaranteed floor. Call before the measurement
/// window opens so that unavoidable first-touch faults are not attributed to
/// request latency.
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
    engine_ready = true;

    exportFunction(env, exports, "samm_intern", intern);
    exportFunction(env, exports, "samm_allocate", allocate);
    exportFunction(env, exports, "samm_region_open", regionOpenFn);
    exportFunction(env, exports, "samm_region_close", regionCloseFn);
    exportFunction(env, exports, "samm_warmup", warmup);
    exportFunction(env, exports, "samm_stats", stats);

    return exports;
}
