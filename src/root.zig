//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

/// Image-layer modules: reference parsing, digest helpers, layer
/// extraction, image-config decoding.
pub const image = struct {
    pub const ref = @import("image/ref.zig");
    pub const digest = @import("image/digest.zig");
    pub const extract = @import("image/extract.zig");
    pub const extract_pool = @import("image/extract_pool.zig");
    pub const config = @import("image/config.zig");
};

/// On-disk store modules: OCI image layout, blob ingestion, indexing.
pub const store = struct {
    pub const layout = @import("store/layout.zig");
};

/// Registry client modules: HTTP transport with Bearer auth, manifest
/// fetch (T05), blob fetch (T06).
pub const registry = struct {
    pub const auth = @import("registry/auth.zig");
    pub const client = @import("registry/client.zig");
    pub const manifest = @import("registry/manifest.zig");
    pub const blob_pool = @import("registry/blob_pool.zig");
};

/// Pull orchestrator (T09): glue that wires ref → manifest → blob
/// pool → extract → tag.
pub const pull = @import("pull.zig");

/// OCI runtime modules: typed Zig surface over libcrun (T18) and
/// downstream container lifecycle helpers (T19+).
pub const runtime = struct {
    pub const libcrun = @import("runtime/libcrun.zig");
};

/// This is a documentation comment to explain the `printAnotherMessage` function below.
///
/// Accepting an `Io.Writer` instance is a handy way to write reusable code.
pub fn printAnotherMessage(writer: *Io.Writer) Io.Writer.Error!void {
    try writer.print("Run `zig build test` to run the tests.\n", .{});
}

pub fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    try std.testing.expect(add(3, 7) == 10);
}

test {
    _ = image.ref;
    _ = image.digest;
    _ = image.extract;
    _ = image.extract_pool;
    _ = image.config;
    _ = store.layout;
    _ = registry.auth;
    _ = registry.client;
    _ = registry.manifest;
    _ = registry.blob_pool;
    _ = pull;
    _ = runtime.libcrun;
}
