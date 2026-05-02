//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

/// Image-layer modules: reference parsing, digest helpers, layer extraction.
pub const image = struct {
    pub const ref = @import("image/ref.zig");
    pub const digest = @import("image/digest.zig");
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
    _ = store.layout;
    _ = registry.auth;
    _ = registry.client;
}
