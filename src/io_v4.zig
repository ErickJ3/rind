//! `Io` wrapper that forces IPv4-only DNS lookups.
//!
//! `std.http.Client` does not expose any IPv4/IPv6 preference. On a
//! v4-only host every AAAA result costs ~50–100ms before falling back
//! to A (Happy Eyeballs, RFC 8305). For a cold pull with several DNS
//! lookups that adds up to ~400–800ms of pure waste.
//!
//! Strategy: copy the platform's `Io.VTable`, swap `netLookup` for one
//! that sets `LookupOptions.family = .ip4` before delegating to the
//! inner implementation. Linux's `lookupDnsSearch` already honors the
//! field — it just isn't reachable through `HostName.connect`'s public
//! API. Userdata is forwarded unchanged: every other vtable call uses
//! the inner's pointer, so the wrapper is a thin shim.
//!
//! `wrap()` is one-shot. Storage is module-level static; the returned
//! `Io` value can be copied freely (workers do this) since the vtable
//! is read-only after initialisation.

const std = @import("std");
const Io = std.Io;

var inner_io: Io = undefined;
var v4_vtable: Io.VTable = undefined;
var initialized: bool = false;

pub fn wrap(inner: Io) Io {
    std.debug.assert(!initialized); // wrap() is one-shot.
    inner_io = inner;
    v4_vtable = inner.vtable.*;
    v4_vtable.netLookup = ipv4Lookup;
    initialized = true;
    return .{
        .userdata = inner.userdata,
        .vtable = &v4_vtable,
    };
}

fn ipv4Lookup(
    userdata: ?*anyopaque,
    host_name: Io.net.HostName,
    resolved: *Io.Queue(Io.net.HostName.LookupResult),
    options: Io.net.HostName.LookupOptions,
) Io.net.HostName.LookupError!void {
    var v4_options = options;
    v4_options.family = .ip4;
    return inner_io.vtable.netLookup(userdata, host_name, resolved, v4_options);
}
