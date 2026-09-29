//! Raw N-API bindings.
//!
//! The Shadow Profiler uses node-addon-api, but that is a C++ template library
//! and cannot be reached from Zig. This addon therefore calls the C entry
//! points in node_api.h directly. Same N-API version, same runtime guarantees —
//! only the calling style differs.
//!
//! The include path is supplied by build.zig (see the `node-headers` option),
//! because the headers live in node-gyp's per-version cache rather than at any
//! fixed system path.
pub const c = @cImport({
    @cInclude("node_api.h");
});
