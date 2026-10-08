// GENERATED FILE - DO NOT EDIT BY HAND.
//
// Produced by ml-refinery/table-compiler/01_compile_routing_table.py from:
//   datasets/shadow-telemetry/intermediate/ml-refinery/call_site_policy_assignment.csv
//   datasets/shadow-telemetry/intermediate/ml-refinery/spatial_quotas.json
//
// Checked into git so the Zig addon builds without a Python step. Re-run
// the table compiler after any ML Refinery run and commit the result;
// never edit the numbers here directly.

/// Alignment every offset below respects, so madvise on one stratum can
/// never touch its neighbour.
pub const page_size: usize = 4096;
pub const huge_page_size: usize = 2097152;

/// THP policy. Huge pages make RSS report in 2MB steps, so a partially
/// touched arena over-reports by up to one huge page. An arena may use
/// them only when that worst case is under 1/thp_min_huge_pages of its
/// own size -- a uniform, stated bound on measurement distortion rather
/// than a per-arena judgement call.
pub const thp_min_huge_pages: usize = 32;
pub const thp_min_arena_bytes: usize = 67108864;
pub const thp_max_rss_distortion_pct: f64 = 3.125;

/// Hard ceiling on bytes committed across every stratum at once.
pub const m_available_bytes: usize = 657535795;
/// Sum of the guaranteed floors, charged against the ceiling at startup.
pub const reserved_floor_bytes: usize = 460169216;
/// Total VIRTUAL extent of the mapping. Deliberately larger than the
/// ceiling: untouched pages cost nothing, and the real limit is the
/// committed-bytes counter, not the geometry.
pub const region_bytes: usize = 2638290944;
pub const elastic_factor: usize = 4;
pub const bump_growth_chunk: usize = 2097152;

/// Size-class index by shifts and masks, no division. Derived from the
/// emitted ladder and verified against every class boundary at generation
/// time; false means the ladder is not geometric and Zig must scan.
pub const use_clz_index: bool = true;
pub const sub_bits: u6 = 0;
pub const octave_base: u6 = 5;

pub const Policy = enum(u8) {
    /// Not in the table: System-classified, served by a plain V8 allocation.
    none,
    bump,
    slab,
};

pub const Slot = struct {
    hash: u64,
    policy: Policy,
    /// Index into `bump_arenas` when `policy == .bump`. Meaningless for
    /// `.slab`: that class is picked per request from the requested size.
    arena_index: u32,
};

pub const BumpArena = struct {
    call_site_hash: u64,
    offset: usize,
    /// Guaranteed, reserved at startup, never revocable.
    floor_bytes: usize,
    /// Virtual ceiling it may grow into while the global budget allows.
    span_bytes: usize,
    /// The cursor may enter a segment only once every object allocated in
    /// it has died. Testing the whole arena instead is unreachable under
    /// sustained traffic, where hundreds of objects are live at any instant,
    /// so the arena could only ever grow and never wrap.
    segment_bytes: usize,
    /// Segments covered by the guaranteed floor, usable without borrowing.
    floor_segments: u32,
    /// Segments covered by the elastic span.
    max_segments: u32,
    use_huge_pages: bool,
};

pub const SlabClass = struct {
    class_size: usize,
    offset: usize,
    floor_slots: u32,
    max_slots: u32,
    use_huge_pages: bool,
};

/// One dedicated arena per Bump-classified call-site.
pub const bump_arenas = [_]BumpArena{
    .{ .call_site_hash = 10594155676959940577, .offset = 0, .floor_bytes = 6651904, .span_bytes = 102002688, .segment_bytes = 831488, .floor_segments = 8, .max_segments = 122, .use_huge_pages = true },
    .{ .call_site_hash = 6032067261616903543, .offset = 102002688, .floor_bytes = 235929600, .span_bytes = 1400008704, .segment_bytes = 29491200, .floor_segments = 8, .max_segments = 47, .use_huge_pages = true },
    .{ .call_site_hash = 7788200244258950291, .offset = 1502011392, .floor_bytes = 13115392, .span_bytes = 79237120, .segment_bytes = 1638400, .floor_segments = 8, .max_segments = 48, .use_huge_pages = true },
    .{ .call_site_hash = 8985841585374529601, .offset = 1581248512, .floor_bytes = 0, .span_bytes = 69632, .segment_bytes = 4096, .floor_segments = 1, .max_segments = 17, .use_huge_pages = false },
};

/// Ascending by class_size, exactly as spatial_quotas.json listed them.
pub const slab_classes = [_]SlabClass{
    .{ .class_size = 64, .offset = 2637697024, .floor_slots = 0, .max_slots = 64, .use_huge_pages = false },
    .{ .class_size = 128, .offset = 2629902336, .floor_slots = 0, .max_slots = 32, .use_huge_pages = false },
    .{ .class_size = 256, .offset = 2631102464, .floor_slots = 0, .max_slots = 16, .use_huge_pages = false },
    .{ .class_size = 512, .offset = 2633498624, .floor_slots = 0, .max_slots = 8, .use_huge_pages = false },
    .{ .class_size = 1024, .offset = 1581318144, .floor_slots = 0, .max_slots = 8, .use_huge_pages = false },
    .{ .class_size = 2048, .offset = 2631086080, .floor_slots = 0, .max_slots = 8, .use_huge_pages = false },
    .{ .class_size = 4096, .offset = 2633465856, .floor_slots = 0, .max_slots = 8, .use_huge_pages = false },
    .{ .class_size = 8192, .offset = 2638225408, .floor_slots = 0, .max_slots = 8, .use_huge_pages = false },
    .{ .class_size = 16384, .offset = 2630955008, .floor_slots = 0, .max_slots = 8, .use_huge_pages = false },
    .{ .class_size = 32768, .offset = 2633203712, .floor_slots = 0, .max_slots = 8, .use_huge_pages = false },
    .{ .class_size = 65536, .offset = 2637701120, .floor_slots = 0, .max_slots = 8, .use_huge_pages = false },
    .{ .class_size = 131072, .offset = 2629906432, .floor_slots = 0, .max_slots = 8, .use_huge_pages = false },
    .{ .class_size = 262144, .offset = 2631106560, .floor_slots = 0, .max_slots = 8, .use_huge_pages = false },
    .{ .class_size = 524288, .offset = 2633502720, .floor_slots = 0, .max_slots = 8, .use_huge_pages = false },
    .{ .class_size = 1048576, .offset = 1581326336, .floor_slots = 195, .max_slots = 1000, .use_huge_pages = true },
};

/// Open-addressed, linear-probed lookup table, power-of-two capacity.
pub const table_mask: u64 = 15;
/// Longest probe chain measured at generation time, so the lookup can stop
/// after this many steps instead of scanning the whole table.
pub const max_probe: u32 = 1;

pub const table = [_]Slot{
    .{ .hash = 0, .policy = .none, .arena_index = 0 },
    .{ .hash = 8985841585374529601, .policy = .bump, .arena_index = 3 },
    .{ .hash = 10594155676959940577, .policy = .bump, .arena_index = 0 },
    .{ .hash = 7788200244258950291, .policy = .bump, .arena_index = 2 },
    .{ .hash = 0, .policy = .none, .arena_index = 0 },
    .{ .hash = 0, .policy = .none, .arena_index = 0 },
    .{ .hash = 0, .policy = .none, .arena_index = 0 },
    .{ .hash = 6032067261616903543, .policy = .bump, .arena_index = 1 },
    .{ .hash = 0, .policy = .none, .arena_index = 0 },
    .{ .hash = 7791549285265555129, .policy = .slab, .arena_index = 0 },
    .{ .hash = 0, .policy = .none, .arena_index = 0 },
    .{ .hash = 0, .policy = .none, .arena_index = 0 },
    .{ .hash = 0, .policy = .none, .arena_index = 0 },
    .{ .hash = 0, .policy = .none, .arena_index = 0 },
    .{ .hash = 0, .policy = .none, .arena_index = 0 },
    .{ .hash = 0, .policy = .none, .arena_index = 0 },
};

comptime {
    if (reserved_floor_bytes > m_available_bytes)
        @compileError("guaranteed floors exceed the global budget");
    var span_total: usize = 0;
    for (bump_arenas) |arena| span_total += arena.span_bytes;
    for (slab_classes) |class| span_total += class.max_slots * class.class_size;
    if (span_total > region_bytes)
        @compileError("stratum spans overflow the mapped region");
}
