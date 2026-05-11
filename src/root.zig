//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const Io = std.Io;

/// Builder modules: Containerfile lexer, parser, build orchestrator.
pub const Builder = struct {
    pub const lex = @import("builder/lex.zig");
    pub const parse = @import("builder/parse.zig");
    pub const context = @import("builder/context.zig");
    pub const cache_key = @import("builder/cache_key.zig");
};

/// Image-layer modules: reference parsing, digest helpers, layer
/// extraction, image-config decoding.
pub const Image = struct {
    pub const ref = @import("image/ref.zig");
    pub const digest = @import("image/digest.zig");
    pub const extract = @import("image/extract.zig");
    pub const extract_pool = @import("image/extract_pool.zig");
    pub const config = @import("image/config.zig");
};

/// On-disk store modules: OCI image layout, blob ingestion, indexing.
pub const Store = struct {
    pub const layout = @import("store/layout.zig");
};

/// Registry client modules: HTTP transport with Bearer auth, manifest
/// fetch, blob fetch.
pub const Registry = struct {
    pub const auth = @import("registry/auth.zig");
    pub const client = @import("registry/client.zig");
    pub const manifest = @import("registry/manifest.zig");
    pub const blob_pool = @import("registry/blob_pool.zig");
    pub const prefetch = @import("registry/prefetch.zig");
};

/// Pull orchestrator: glue that wires ref → manifest → blob pool →
/// extract → tag.
pub const pull = @import("pull.zig");

/// Run orchestrator: glue that wires ref → store lookup → extract →
/// state alloc → overlay mount → bundle compose → libcrun.
pub const run = @import("run.zig");

/// OCI runtime modules: typed Zig surface over libcrun and downstream
/// container lifecycle helpers.
pub const Runtime = struct {
    pub const libcrun = @import("runtime/libcrun.zig");
    pub const state = @import("runtime/state.zig");
    pub const overlay = @import("runtime/overlay.zig");
    pub const bundle = @import("runtime/bundle.zig");
    pub const core = @import("runtime/core.zig");
    pub const subid = @import("runtime/subid.zig");
    pub const teardown = @import("runtime/teardown.zig");
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
    _ = Builder.lex;
    _ = Builder.parse;
    _ = Builder.context;
    _ = Builder.cache_key;
    _ = Image.ref;
    _ = Image.digest;
    _ = Image.extract;
    _ = Image.extract_pool;
    _ = Image.config;
    _ = Store.layout;
    _ = Registry.auth;
    _ = Registry.client;
    _ = Registry.manifest;
    _ = Registry.blob_pool;
    _ = pull;
    _ = run;
    _ = Runtime.libcrun;
    _ = Runtime.state;
    _ = Runtime.overlay;
    _ = Runtime.bundle;
    _ = Runtime.core;
    _ = Runtime.subid;
    _ = Runtime.teardown;
}
