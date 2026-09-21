//! Library surface for the SAMM allocator, used by the unit tests and by the
//! N-API addon. The addon's own entry point lives in
//! src/node-api-interface/addon.zig, which is a separate root so that pure-Zig
//! builds and tests never need the Node headers.

pub const hash = @import("hash.zig");
pub const pool = @import("pool.zig");
pub const router = @import("routing-table/router.zig");
pub const weights = @import("routing-table/model_weights.zig");
pub const bump = @import("arenas/bump-allocator/bump.zig");
pub const slab = @import("arenas/slab-allocator/slab.zig");
pub const engine = @import("engine.zig");
