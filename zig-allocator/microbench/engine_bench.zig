//! Replays a trace against the allocator with NO Node-API bridge.
//!
//! Two layers, same replay loop, same bookkeeping:
//!   engine  the real SAMM engine (src/, imported read-only), the real routing
//!           table, regions kept and closed exactly as addon.zig does -- minus
//!           every napi_* call. A null from the engine (System call-site, or a
//!           capacity fallback) goes to malloc, as the server's falls to V8.
//!   malloc  every allocation through the C allocator. Run under glibc, or with
//!           LD_PRELOAD=libjemalloc.so.2 for the baseline's allocator.
//!
//! Nothing in src/ is modified; this file only calls its public API.
//!
//! Usage: engine_bench <trace-dir> <engine|malloc> <trials> <touch 0|1> [warmup=1]
//! Prints one JSON object per measured trial on stdout.

const std = @import("std");
const samm = @import("samm");

const Engine = samm.engine.Engine;
const Handle = samm.engine.Handle;

const OPEN = 0;
const ALLOC = 1;
const CLOSE = 2;
const FREE = 3;

const page = 4096;
/// Each trial replays the trace enough times to cover at least this many
/// events, so one-allocation-per-request traces are not timed in milliseconds.
const min_events = 1_000_000;

const Meta = struct {
    sites: []const []const u8,
    escaping: []const bool,
    n_events: usize,
    n_allocs: usize,
    n_scopes: usize,
};

const Trace = struct {
    ops: []const u8,
    arg: []align(1) const u32,
    size: []align(1) const u32,
    site: []const u8,
    meta: Meta,
};

/// One allocation owned by an open request. Mirrors addon.zig's RegionEntry
/// (16 bytes): an engine handle, or a malloc'd fallback pointer.
const Entry = struct {
    handle: Handle,
    fallback: ?[*]u8,
};

const Layer = enum { engine, malloc };

// Initialized in place and never moved -- the arenas point into it.
var engine: Engine = undefined;

var stdout_buf: [4096]u8 = undefined;

pub fn main() !void {
    const gpa = std.heap.c_allocator;
    const argv = try std.process.argsAlloc(gpa);
    if (argv.len < 5) {
        std.debug.print("usage: engine_bench <trace-dir> <engine|malloc> <trials> <touch 0|1> [warmup]\n", .{});
        std.process.exit(2);
    }
    const dir = argv[1];
    const layer = std.meta.stringToEnum(Layer, argv[2]) orelse return error.BadLayer;
    const trials = try std.fmt.parseInt(u32, argv[3], 10);
    const touch = std.mem.eql(u8, argv[4], "1");
    const warmup = if (argv.len > 5) try std.fmt.parseInt(u32, argv[5], 10) else 1;

    const trace = try load(gpa, dir);

    var tokens: [16]u32 = undefined;
    if (layer == .engine) {
        const policy = samm.pool.ReclaimPolicy.fromString(
            std.posix.getenv("SAMM_RECLAIM_POLICY") orelse "none",
        ) orelse .none;
        try engine.init(gpa, policy);
        for (trace.meta.sites, 0..) |name, i| tokens[i] = engine.intern(name) orelse return error.Intern;
    }

    // Per request: which region it holds. Per region: its entries. Region ids
    // are recycled through a free stack, exactly as addon.zig does.
    const region_of = try gpa.alloc(u32, trace.meta.n_scopes);
    const max_regions = 8192;
    const regions = try gpa.alloc(std.ArrayList(Entry), max_regions);
    for (regions) |*r| r.* = .empty;
    const free_ids = try gpa.alloc(u32, max_regions);
    const escaped = try gpa.alloc(?[*]u8, trace.meta.n_allocs);

    var out = std.fs.File.stdout().writer(&stdout_buf);
    const w = &out.interface;

    var t: u32 = 0;
    while (t < warmup + trials) : (t += 1) {
        for (free_ids, 0..) |*id, i| id.* = @intCast(max_regions - 1 - i);
        var free_count: usize = max_regions;
        @memset(escaped, null);

        var fallbacks: u64 = 0;
        var system: u64 = 0;
        var seq: usize = 0;
        var close_ns: u64 = 0;

        // Touch mode costs microseconds per allocation: one pass is enough, and
        // repeating it would touch hundreds of millions of pages.
        const passes = if (touch) 1 else @max(1, (min_events + trace.ops.len - 1) / trace.ops.len);
        var timer = try std.time.Timer.start();
        for (0..passes) |_| for (trace.ops, 0..) |op, e| {
            switch (op) {
                OPEN => {
                    free_count -= 1;
                    const id = free_ids[free_count];
                    regions[id].clearRetainingCapacity();
                    region_of[trace.arg[e]] = id;
                },
                ALLOC => {
                    const size: usize = trace.size[e];
                    const site = trace.site[e];
                    const escapes = trace.meta.escaping[site];
                    var bytes: [*]u8 = undefined;
                    var entry: Entry = .{ .handle = 0, .fallback = null };

                    const managed: ?samm.engine.Allocation =
                        if (layer == .engine) engine.allocate(tokens[site], size) else null;
                    if (managed) |a| {
                        bytes = a.bytes.ptr;
                        entry.handle = a.handle;
                    } else {
                        if (layer == .engine) {
                            if (escapes) system += 1 else fallbacks += 1;
                        }
                        bytes = @ptrCast(std.c.malloc(size) orelse return error.OutOfMemory);
                        entry.fallback = bytes;
                    }

                    if (touch) touchPages(bytes, size);

                    if (escapes and entry.fallback != null) {
                        escaped[seq % trace.meta.n_allocs] = entry.fallback;
                    } else {
                        try regions[region_of[trace.arg[e]]].append(gpa, entry);
                    }
                    seq += 1;
                },
                CLOSE => {
                    const c0 = timer.read();
                    defer close_ns += timer.read() - c0;
                    const id = region_of[trace.arg[e]];
                    for (regions[id].items) |entry| {
                        if (entry.fallback) |p| std.c.free(p) else engine.release(entry.handle);
                    }
                    regions[id].clearRetainingCapacity();
                    free_ids[free_count] = id;
                    free_count += 1;
                },
                FREE => {
                    if (escaped[trace.arg[e]]) |p| std.c.free(p);
                    escaped[trace.arg[e]] = null;
                },
                else => unreachable,
            }
        };
        const ns = timer.read();

        if (t < warmup) continue;
        try w.print(
            "{{\"layer\":\"{s}\",\"trace\":\"{s}\",\"touch\":{},\"trial\":{d},\"allocs\":{d},\"passes\":{d},\"ns\":{d},\"ns_per_alloc\":{d:.1},\"close_ns_per_alloc\":{d:.1},\"fallbacks\":{d},\"system\":{d}}}\n",
            .{
                @tagName(layer),             std.fs.path.basename(dir), touch,
                t - warmup,                  seq,                        passes,
                ns,
                @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(seq)),
                @as(f64, @floatFromInt(close_ns)) / @as(f64, @floatFromInt(seq)),
                fallbacks,                   system,
            },
        );
        try w.flush();
    }
}

/// One byte per page, the same pattern as writePages() in _alloc-utils.js.
fn touchPages(bytes: [*]u8, len: usize) void {
    var i: usize = 0;
    while (i < len) : (i += page) {
        const cell: *volatile u8 = @ptrCast(bytes + i);
        cell.* = @truncate(i);
    }
}

fn load(gpa: std.mem.Allocator, dir: []const u8) !Trace {
    var d = try std.fs.cwd().openDir(dir, .{});
    defer d.close();
    const max = 1 << 30;
    const meta_src = try d.readFileAlloc(gpa, "meta.json", max);
    const parsed = try std.json.parseFromSlice(Meta, gpa, meta_src, .{ .ignore_unknown_fields = true });
    const ops = try d.readFileAlloc(gpa, "ops.u8", max);
    const arg = try d.readFileAlloc(gpa, "arg.u32", max);
    const size = try d.readFileAlloc(gpa, "size.u32", max);
    const site = try d.readFileAlloc(gpa, "site.u8", max);
    return .{
        .ops = ops,
        .arg = std.mem.bytesAsSlice(u32, arg),
        .size = std.mem.bytesAsSlice(u32, size),
        .site = site,
        .meta = parsed.value,
    };
}
