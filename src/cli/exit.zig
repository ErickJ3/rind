//! Process exit-code mapping for the `rind` CLI.
//!
//! `main.zig` is the only place that calls `std.process.exit`. Every
//! other layer returns a typed error and lets `mapErrorToExitCode`
//! assign it to the documented code:
//!
//! - 0 — success
//! - 1 — generic / storage / config / unhandled
//! - 2 — usage (bad flags, bad ref, unsupported platform)
//! - 3 — network (registry transport, DNS, TLS)
//! - 4 — verification (digest / media-type mismatch)
//!
//! The mapping is intentionally forgiving: any error not classified
//! here falls through to exit 1 rather than crashing the binary.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const pull_mod = @import("../pull.zig");
const run_mod = @import("../run.zig");

/// CLI-specific error names not produced by the pull orchestrator.
pub const CliExtras = error{
    /// Argparse rejected the flag combination, the subcommand, or
    /// the positional. Surfaced from `cli/pull.zig` and `cli/root.zig`.
    Usage,
    /// `--platform` was provided and did not match the host. Single
    /// platform per MVP — see `docs/rind.md`.
    UnsupportedPlatform,
    /// Storage root could not be resolved: neither `RIND_ROOT` nor
    /// `HOME` was set in the environment.
    HomeNotFound,
    /// `rind inspect` did not find a descriptor in `index.json`
    /// matching the supplied tag or digest.
    RefNotFound,
};

/// Closed superset returned by CLI entry points. Composes the
/// orchestrator's `PullError` with CLI-specific extras so `main.zig`
/// can `try` everything and map at the edge.
pub const CliError =
    CliExtras ||
    pull_mod.PullError ||
    run_mod.RunError ||
    Io.Writer.Error;

/// Exit codes the CLI uses. `u8` keeps it in the POSIX range.
pub const Code = enum(u8) {
    success = 0,
    generic = 1,
    usage = 2,
    network = 3,
    verification = 4,
};

/// Map any error value to an exit code. Accepts `anyerror` so callers
/// can hand it the result of `catch` without re-spelling the error
/// set; classification is by name.
pub fn mapErrorToExitCode(err: anyerror) Code {
    return switch (err) {
        error.Usage,
        error.UnsupportedPlatform,
        error.Empty,
        error.InvalidRegistry,
        error.InvalidRepository,
        error.InvalidTag,
        error.InvalidDigest,
        error.UnsupportedDigestAlgorithm,
        error.ImageNotPresent,
        error.EmptyArgs,
        error.UnsupportedUserFormat,
        error.InvalidEnv,
        error.InvalidVolumeSpec,
        error.VolumeSourceNotAbsolute,
        error.VolumeSourceUnreadable,
        error.ContainerRunning,
        error.AmbiguousId,
        error.ContainerNotFound,
        error.PrefixTooShort,
        => .usage,
        error.DigestMismatch,
        error.MediaTypeMismatch,
        error.UnsupportedManifestMediaType,
        => .verification,
        error.Unauthorized,
        error.Forbidden,
        error.NotFound,
        error.ChallengeMissing,
        error.TokenEndpointFailed,
        error.BadTokenResponse,
        error.UnexpectedStatus,
        error.ServerError,
        error.NoCredentials,
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.HostUnreachable,
        error.TemporaryNameServerFailure,
        error.NameServerFailure,
        error.UnknownHostName,
        error.TlsInitializationFailed,
        error.TlsAlert,
        error.UnsupportedUriScheme,
        error.UriMissingHost,
        => .network,
        else => .generic,
    };
}

const testing = std.testing;

test "mapErrorToExitCode classifies common cases" {
    try testing.expectEqual(Code.usage, mapErrorToExitCode(error.Usage));
    try testing.expectEqual(Code.usage, mapErrorToExitCode(error.InvalidRepository));
    try testing.expectEqual(Code.usage, mapErrorToExitCode(error.UnsupportedPlatform));
    try testing.expectEqual(Code.usage, mapErrorToExitCode(error.ContainerRunning));
    try testing.expectEqual(Code.usage, mapErrorToExitCode(error.AmbiguousId));
    try testing.expectEqual(Code.usage, mapErrorToExitCode(error.ContainerNotFound));
    try testing.expectEqual(Code.usage, mapErrorToExitCode(error.PrefixTooShort));
    try testing.expectEqual(Code.generic, mapErrorToExitCode(error.KillTimeout));
    try testing.expectEqual(Code.generic, mapErrorToExitCode(error.RmAggregate));
    try testing.expectEqual(Code.verification, mapErrorToExitCode(error.DigestMismatch));
    try testing.expectEqual(Code.verification, mapErrorToExitCode(error.MediaTypeMismatch));
    try testing.expectEqual(Code.network, mapErrorToExitCode(error.ConnectionRefused));
    try testing.expectEqual(Code.network, mapErrorToExitCode(error.Unauthorized));
    try testing.expectEqual(Code.network, mapErrorToExitCode(error.ServerError));
    try testing.expectEqual(Code.generic, mapErrorToExitCode(error.OutOfMemory));
    try testing.expectEqual(Code.generic, mapErrorToExitCode(error.HomeNotFound));
    try testing.expectEqual(Code.generic, mapErrorToExitCode(error.RefNotFound));
}

test "mapErrorToExitCode classifies run-side errors" {
    try testing.expectEqual(Code.usage, mapErrorToExitCode(error.ImageNotPresent));
    try testing.expectEqual(Code.usage, mapErrorToExitCode(error.InvalidEnv));
    try testing.expectEqual(Code.usage, mapErrorToExitCode(error.EmptyArgs));
    try testing.expectEqual(Code.usage, mapErrorToExitCode(error.UnsupportedUserFormat));
    try testing.expectEqual(Code.usage, mapErrorToExitCode(error.InvalidVolumeSpec));
    try testing.expectEqual(Code.usage, mapErrorToExitCode(error.VolumeSourceUnreadable));
    try testing.expectEqual(Code.usage, mapErrorToExitCode(error.VolumeSourceNotAbsolute));
    try testing.expectEqual(Code.verification, mapErrorToExitCode(error.UnsupportedManifestMediaType));
    try testing.expectEqual(Code.generic, mapErrorToExitCode(error.LibcrunFailure));
    try testing.expectEqual(Code.generic, mapErrorToExitCode(error.BundleNotFound));
    try testing.expectEqual(Code.generic, mapErrorToExitCode(error.PermissionDenied));
    try testing.expectEqual(Code.generic, mapErrorToExitCode(error.InvalidConfig));
    try testing.expectEqual(Code.generic, mapErrorToExitCode(error.AlreadyRunning));
    try testing.expectEqual(Code.generic, mapErrorToExitCode(error.PtySetupFailed));
    try testing.expectEqual(Code.generic, mapErrorToExitCode(error.ConsoleSocketFailed));
}
