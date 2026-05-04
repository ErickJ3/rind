//! `Io` wrapper that forces IPv4-only DNS lookups.
//!
//! `std.http.Client` does not expose any IPv4/IPv6 preference. On a
//! v4-only host every AAAA result costs ~500-100ms before falling back
//! to A (Happy Eyeballs, RFC 8305). For a cold pull with several DNS
//! lookups that adds up to ~400-800ms of pure waste.
//!
//! Strategy: copy the platform's `Io.VTable`, swap `netLookup` for one
//! that sets `LookupOptions.family = .ip4` before delegating to the
//! inner implementation. Linux's `lookupDnsSearch` already honors the
//! field, it just isn't reachable through `HostName.connect`'s public
//! API. The wrapped `Io`'s userdata points at the owning `IoV4`; the
//! lookup callback casts back and forwards to the original `inner`.
//!
//! Caller-owned: store an `IoV4` on the stack (or wherever its lifetime
//! exceeds every copy of `io()`'s return) and call `init` then `io()`.

const std = @import("std");
const Io = std.Io;

const IoV4 = @This();

inner: Io,
vtable: Io.VTable,

pub fn init(inner: Io) IoV4 {
    var vt = inner.vtable.*;
    vt.netLookup = ipv4Lookup;
    return .{ .inner = inner, .vtable = vt };
}

/// Returns an `Io` that delegates every operation to `inner` except
/// DNS lookups, which are forced to IPv4. The returned value borrows
/// `&self.vtable`; `self` must outlive every copy.
pub fn io(self: *IoV4) Io {
    return .{ .userdata = @ptrCast(self), .vtable = &self.vtable };
}

fn ipv4Lookup(
    userdata: ?*anyopaque,
    host_name: Io.net.HostName,
    resolved: *Io.Queue(Io.net.HostName.LookupResult),
    options: Io.net.HostName.LookupOptions,
) Io.net.HostName.LookupError!void {
    const self: *IoV4 = @ptrCast(@alignCast(userdata.?));
    var v4_options = options;
    v4_options.family = .ip4;
    return self.inner.vtable.netLookup(
        self.inner.userdata,
        host_name,
        resolved,
        v4_options,
    );
}
