const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const node_headers = b.option(
        []const u8,
        "node-headers",
        "Directory containing node_api.h (default: node-gyp's cache for the local Node version)",
    ) orelse defaultNodeHeaders(b);

    const samm_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const addon_mod = b.createModule(.{
        .root_source_file = b.path("src/node-api-interface/addon.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    addon_mod.addIncludePath(.{ .cwd_relative = node_headers });
    addon_mod.addImport("samm", samm_mod);

    const addon = b.addLibrary(.{
        .name = "samm_allocator",
        .root_module = addon_mod,
        .linkage = .dynamic,
    });
    // Every napi_* symbol is resolved against the node executable at load time,
    // so the shared object is expected to have them undefined.
    addon.linker_allow_shlib_undefined = true;

    // Node only loads addons named *.node.
    b.getInstallStep().dependOn(&b.addInstallFileWithDir(
        addon.getEmittedBin(),
        .lib,
        "samm_allocator.node",
    ).step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests/all_tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("samm", samm_mod);

    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const test_step = b.step("test", "Run the allocator unit tests");
    test_step.dependOn(&b.addRunArtifact(unit_tests).step);
}

/// node-gyp caches headers per Node version under $HOME/.cache/node-gyp, so
/// there is no fixed path to hardcode. Ask the local Node which version it is
/// and build the path from that; override with -Dnode-headers= or
/// SAMM_NODE_HEADERS when the headers live elsewhere.
fn defaultNodeHeaders(b: *std.Build) []const u8 {
    if (std.process.getEnvVarOwned(b.allocator, "SAMM_NODE_HEADERS")) |path| {
        return path;
    } else |_| {}

    const home = std.process.getEnvVarOwned(b.allocator, "HOME") catch {
        std.debug.print("HOME is unset; pass -Dnode-headers=<dir containing node_api.h>\n", .{});
        std.process.exit(1);
    };

    // `node -v` prints e.g. "v24.18.0"; the cache directory drops the leading v.
    const version = std.mem.trim(u8, b.run(&.{ "node", "-v" }), " \t\r\n");
    if (version.len < 2 or version[0] != 'v') {
        std.debug.print("unexpected `node -v` output: '{s}'\n", .{version});
        std.process.exit(1);
    }

    return b.pathJoin(&.{ home, ".cache", "node-gyp", version[1..], "include", "node" });
}
