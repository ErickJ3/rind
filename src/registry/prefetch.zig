//! Speculative connection + token warm-up for `pull.zig`.
//!
//! After a manifest-cache miss the next operation is a manifest GET
//! that pays three round trips on a cold start (anonymous probe →
//! token endpoint → retry with Bearer) plus two TLS handshakes
//! (registry host and auth realm). The handle below lets pull.zig
//! spawn one OS thread that issues that exact GET in parallel with
//! the disk I/O the orchestrator was going to do anyway (blob-presence
//! checks, slot-table init, atomic-temp creation).
//!
//! When the orchestrator joins the handle, the registry client's
//! `TokenCache` already holds the bearer for our scope and the
//! `std.http.Client` keep-alive pool already has the warm TCP+TLS
//! socket the main path will reuse. Single-flight inside `TokenCache`
//! prevents the prefetch and the main path from issuing the same
//! token GET twice when their schedules race.
//!
//! Worker failures are intentionally swallowed: the orchestrator
//! retries the manifest GET independently. A wasted prefetch costs
//! at most one OS thread; a panicking worker would crash a real pull.

const std = @import("std");
const builtin = @import("builtin");

const client_mod = @import("client.zig");

/// Background warm-up handle. Single-shot — `start` once, `join` once.
/// `join` is idempotent on a never-started or already-joined handle so
/// callers can place it under a `defer` without tracking lifecycle.
pub const Handle = struct {
    thread: ?std.Thread = null,
    /// Worker exit code: 0 = clean, nonzero = warm-up failed. Tests
    /// only need the boolean; the registry client owns its own
    /// diagnostic logging.
    err: std.atomic.Value(u8) = .init(0),

    pub const Args = struct {
        client: *client_mod.Client,
        /// `https://<host>/v2/<repo>/manifests` — caller-owned, must
        /// outlive `join`.
        manifest_base: []const u8,
        /// Tag or sha256 digest to GET. Caller-owned, outlives `join`.
        reference: []const u8,
        /// OCI auth scope, e.g. `repository:lib/alpine:pull`. Caller-
        /// owned, outlives `join`.
        scope: []const u8,
        /// Manifest `Accept` header — same list the main path uses.
        /// Caller-owned, outlives `join`.
        accept: []const u8,
    };

    pub const StartError = error{AlreadyRunning} || std.Thread.SpawnError;

    pub fn start(self: *Handle, args: Args) StartError!void {
        if (self.thread != null) return error.AlreadyRunning;
        // Tests use scripted single-connection mock servers that
        // mis-sequence on parallel GETs; skip prefetch under test.
        if (builtin.is_test) return;
        self.err.store(0, .release);
        self.thread = try std.Thread.spawn(.{}, workerEntry, .{ self, args });
    }

    pub fn join(self: *Handle) void {
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    pub fn failed(self: *const Handle) bool {
        return self.err.load(.acquire) != 0;
    }
};

fn workerEntry(handle: *Handle, args: Handle.Args) void {
    args.client.warmup(args.manifest_base, args.reference, args.scope, args.accept) catch {
        handle.err.store(1, .release);
    };
}

const testing = std.testing;

test "Handle.join is a no-op on never-started" {
    var h: Handle = .{};
    h.join();
    try testing.expect(!h.failed());
}

test "Handle.start twice without join returns AlreadyRunning" {
    var h: Handle = .{};
    // Plant a no-op thread to flip `thread` non-null. Production
    // `start` is gated by `builtin.is_test` so it never spawns under
    // test, but the null-check still fires for the second call.
    h.thread = try std.Thread.spawn(.{}, struct {
        fn run() void {}
    }.run, .{});
    defer h.join();

    const dummy_args: Handle.Args = .{
        .client = undefined,
        .manifest_base = "",
        .reference = "",
        .scope = "",
        .accept = "",
    };
    try testing.expectError(error.AlreadyRunning, h.start(dummy_args));
}
