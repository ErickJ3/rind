//! Thread-safe `(realm, service, scope)` → token map. The blob pool
//! hits this from N concurrent layer-download threads sharing a
//! single `Client`; the mutex serialises all accesses. The
//! `inflight` set + `cond` add single-flight semantics so a
//! prefetch worker (`registry/prefetch.zig`) and the orchestrator
//! thread cannot both fire the same token GET when their schedules
//! race.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const TokenCache = struct {
    mutex: Io.Mutex = .init,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    /// Set of `(realm, service, scope)` keys that have an in-progress
    /// `acquireToken` somewhere. Second caller for the same key
    /// `cond`-waits instead of duplicating the network round-trip.
    inflight: std.StringHashMapUnmanaged(void) = .empty,
    /// Broadcast by `clearInflight` after either a successful
    /// `tokens.put` or a failed acquire.
    cond: Io.Condition = .init,

    const Entry = struct {
        token: []u8,
        /// Absolute unix-second deadline, or null for "never expires".
        expires_at: ?i64 = null,
    };

    /// Outcome of `acquireOrWait`. The two variants encode the two
    /// roles of an `acquireToken` caller: it either gets a cached
    /// token back (no network needed) or it claims the in-flight
    /// slot and must follow up with `clearInflight`.
    pub const AcquireOutcome = union(enum) {
        /// Cache hit (possibly populated by another thread we waited
        /// on). Owned dup; caller frees with `gpa`.
        have_token: []u8,
        /// Caller owns the in-flight slot for this key. Must call
        /// `clearInflight` exactly once before returning, whether the
        /// network call succeeded or not.
        acquire: void,
    };

    pub fn deinit(self: *TokenCache, io: Io, gpa: Allocator) void {
        // No locking: deinit by definition has exclusive access. The
        // mutex may have been left in any state (locked or unlocked)
        // and we mark `self` undefined at the end either way.
        _ = io;
        var it = self.entries.iterator();
        while (it.next()) |e| {
            gpa.free(e.key_ptr.*);
            gpa.free(e.value_ptr.token);
        }
        self.entries.deinit(gpa);
        var it2 = self.inflight.iterator();
        while (it2.next()) |e| gpa.free(e.key_ptr.*);
        self.inflight.deinit(gpa);
        self.* = undefined;
    }

    pub fn get(
        self: *TokenCache,
        io: Io,
        gpa: Allocator,
        realm: []const u8,
        service: []const u8,
        scope: []const u8,
        now_unix: i64,
    ) Allocator.Error!?[]u8 {
        var key_buf: [768]u8 = undefined;
        const key = makeStackKey(&key_buf, realm, service, scope) orelse {
            // Key too long; fall back to heap.
            const heap_key = try makeKey(gpa, realm, service, scope);
            defer gpa.free(heap_key);
            return self.lookupAndDup(io, gpa, heap_key, now_unix);
        };
        return self.lookupAndDup(io, gpa, key, now_unix);
    }

    fn lookupAndDup(self: *TokenCache, io: Io, gpa: Allocator, key: []const u8, now_unix: i64) Allocator.Error!?[]u8 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const entry = self.entries.get(key) orelse return null;
        if (entry.expires_at) |exp| {
            if (now_unix >= exp) return null;
        }
        return try gpa.dupe(u8, entry.token);
    }

    pub fn put(
        self: *TokenCache,
        io: Io,
        gpa: Allocator,
        realm: []const u8,
        service: []const u8,
        scope: []const u8,
        token: []const u8,
        expires_at: ?i64,
    ) Allocator.Error!void {
        const key = try makeKey(gpa, realm, service, scope);
        errdefer gpa.free(key);
        const tok_dup = try gpa.dupe(u8, token);
        errdefer gpa.free(tok_dup);

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const gop = try self.entries.getOrPut(gpa, key);
        if (gop.found_existing) {
            gpa.free(key);
            gpa.free(gop.value_ptr.token);
        } else {
            gop.key_ptr.* = key;
        }
        gop.value_ptr.* = .{ .token = tok_dup, .expires_at = expires_at };
    }

    pub fn invalidate(
        self: *TokenCache,
        io: Io,
        gpa: Allocator,
        realm: []const u8,
        service: []const u8,
        scope: []const u8,
    ) void {
        var key_buf: [768]u8 = undefined;
        const key = makeStackKey(&key_buf, realm, service, scope) orelse return;
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.entries.fetchRemove(key)) |kv| {
            gpa.free(kv.key);
            gpa.free(kv.value.token);
        }
    }

    /// Single-flight claim. Returns `.have_token` on a fresh cache hit
    /// (possibly after waking from a peer's broadcast), `.acquire`
    /// when the caller has won the slot and must do the network
    /// round-trip before calling `clearInflight`.
    pub fn acquireOrWait(
        self: *TokenCache,
        io: Io,
        gpa: Allocator,
        realm: []const u8,
        service: []const u8,
        scope: []const u8,
        now_unix: i64,
    ) Allocator.Error!AcquireOutcome {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        while (true) {
            // Cache hit overrides everything — even if there's an
            // in-flight acquire for this key, a fresh entry is the
            // best answer we can give.
            var key_buf: [768]u8 = undefined;
            var heap_lookup_key: ?[]u8 = null;
            defer if (heap_lookup_key) |h| gpa.free(h);
            const lookup_key: []const u8 = makeStackKey(&key_buf, realm, service, scope) orelse blk: {
                const heap = try makeKey(gpa, realm, service, scope);
                heap_lookup_key = heap;
                break :blk heap;
            };

            if (self.entries.get(lookup_key)) |entry| {
                const fresh = if (entry.expires_at) |e| now_unix < e else true;
                if (fresh) {
                    return .{ .have_token = try gpa.dupe(u8, entry.token) };
                }
            }

            if (self.inflight.contains(lookup_key)) {
                self.cond.waitUncancelable(io, &self.mutex);
                continue;
            }

            // Claim. Owned key handed to the inflight map.
            const owned_key = try makeKey(gpa, realm, service, scope);
            errdefer gpa.free(owned_key);
            try self.inflight.put(gpa, owned_key, {});
            return .acquire;
        }
    }

    /// Counterpart to a successful `.acquire` outcome. Removes the
    /// in-flight marker and broadcasts so any waiters re-check the
    /// cache. Safe to call on a key that was never claimed (no-op).
    pub fn clearInflight(
        self: *TokenCache,
        io: Io,
        gpa: Allocator,
        realm: []const u8,
        service: []const u8,
        scope: []const u8,
    ) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

        var key_buf: [768]u8 = undefined;
        if (makeStackKey(&key_buf, realm, service, scope)) |k| {
            if (self.inflight.fetchRemove(k)) |kv| gpa.free(kv.key);
        } else if (makeKey(gpa, realm, service, scope)) |heap| {
            defer gpa.free(heap);
            if (self.inflight.fetchRemove(heap)) |kv| gpa.free(kv.key);
        } else |_| {
            // OOM building the key — broadcast anyway so waiters can
            // recover by claiming the slot themselves.
        }
        self.cond.broadcast(io);
    }

    fn keyLen(realm: []const u8, service: []const u8, scope: []const u8) usize {
        return realm.len + 1 + service.len + 1 + scope.len;
    }

    fn writeKey(buf: []u8, realm: []const u8, service: []const u8, scope: []const u8) void {
        @memcpy(buf[0..realm.len], realm);
        buf[realm.len] = 0;
        @memcpy(buf[realm.len + 1 ..][0..service.len], service);
        buf[realm.len + 1 + service.len] = 0;
        @memcpy(buf[realm.len + 2 + service.len ..][0..scope.len], scope);
    }

    fn makeKey(gpa: Allocator, realm: []const u8, service: []const u8, scope: []const u8) Allocator.Error![]u8 {
        const total = keyLen(realm, service, scope);
        const buf = try gpa.alloc(u8, total);
        writeKey(buf, realm, service, scope);
        return buf;
    }

    fn makeStackKey(buf: []u8, realm: []const u8, service: []const u8, scope: []const u8) ?[]u8 {
        const total = keyLen(realm, service, scope);
        if (total > buf.len) return null;
        writeKey(buf[0..total], realm, service, scope);
        return buf[0..total];
    }
};

const testing = std.testing;

test "TokenCache put/get roundtrip" {
    const gpa = testing.allocator;
    var cache: TokenCache = .{};
    const io = testing.io;
    defer cache.deinit(io, gpa);

    try cache.put(io, gpa, "realm", "svc", "scope", "tok-1", null);

    const got = (try cache.get(io, gpa, "realm", "svc", "scope", 0)).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("tok-1", got);
}

test "TokenCache returns null after expiry" {
    const gpa = testing.allocator;
    var cache: TokenCache = .{};
    const io = testing.io;
    defer cache.deinit(io, gpa);

    try cache.put(io, gpa, "realm", "svc", "scope", "tok", 100);
    try testing.expectEqual(@as(?[]u8, null), try cache.get(io, gpa, "realm", "svc", "scope", 100));
    try testing.expectEqual(@as(?[]u8, null), try cache.get(io, gpa, "realm", "svc", "scope", 999));
}

test "TokenCache replace existing entry frees old token" {
    const gpa = testing.allocator;
    var cache: TokenCache = .{};
    const io = testing.io;
    defer cache.deinit(io, gpa);

    try cache.put(io, gpa, "realm", "svc", "scope", "tok-old", null);
    try cache.put(io, gpa, "realm", "svc", "scope", "tok-new", null);

    const got = (try cache.get(io, gpa, "realm", "svc", "scope", 0)).?;
    defer gpa.free(got);
    try testing.expectEqualStrings("tok-new", got);
}

test "TokenCache distinguishes scopes" {
    const gpa = testing.allocator;
    var cache: TokenCache = .{};
    const io = testing.io;
    defer cache.deinit(io, gpa);

    try cache.put(io, gpa, "realm", "svc", "rep:a:pull", "tok-a", null);
    try cache.put(io, gpa, "realm", "svc", "rep:b:pull", "tok-b", null);

    const a = (try cache.get(io, gpa, "realm", "svc", "rep:a:pull", 0)).?;
    defer gpa.free(a);
    const b = (try cache.get(io, gpa, "realm", "svc", "rep:b:pull", 0)).?;
    defer gpa.free(b);
    try testing.expectEqualStrings("tok-a", a);
    try testing.expectEqualStrings("tok-b", b);
}

test "TokenCache invalidate removes entry" {
    const gpa = testing.allocator;
    var cache: TokenCache = .{};
    const io = testing.io;
    defer cache.deinit(io, gpa);

    try cache.put(io, gpa, "realm", "svc", "scope", "tok", null);
    cache.invalidate(io, gpa, "realm", "svc", "scope");
    try testing.expectEqual(@as(?[]u8, null), try cache.get(io, gpa, "realm", "svc", "scope", 0));
}

test "TokenCache.acquireOrWait — first caller claims .acquire" {
    const gpa = testing.allocator;
    var cache: TokenCache = .{};
    const io = testing.io;
    defer cache.deinit(io, gpa);

    const out = try cache.acquireOrWait(io, gpa, "realm", "svc", "scope", 0);
    try testing.expect(out == .acquire);
    cache.clearInflight(io, gpa, "realm", "svc", "scope");
}

test "TokenCache.acquireOrWait — cache hit returns have_token" {
    const gpa = testing.allocator;
    var cache: TokenCache = .{};
    const io = testing.io;
    defer cache.deinit(io, gpa);

    try cache.put(io, gpa, "realm", "svc", "scope", "tok-1", null);
    const out = try cache.acquireOrWait(io, gpa, "realm", "svc", "scope", 0);
    switch (out) {
        .have_token => |tok| {
            defer gpa.free(tok);
            try testing.expectEqualStrings("tok-1", tok);
        },
        .acquire => {
            cache.clearInflight(io, gpa, "realm", "svc", "scope");
            try testing.expect(false);
        },
    }
}

test "TokenCache.acquireOrWait — clearInflight without put lets next caller claim" {
    const gpa = testing.allocator;
    var cache: TokenCache = .{};
    const io = testing.io;
    defer cache.deinit(io, gpa);

    const first = try cache.acquireOrWait(io, gpa, "realm", "svc", "scope", 0);
    try testing.expect(first == .acquire);
    cache.clearInflight(io, gpa, "realm", "svc", "scope");

    const second = try cache.acquireOrWait(io, gpa, "realm", "svc", "scope", 0);
    try testing.expect(second == .acquire);
    cache.clearInflight(io, gpa, "realm", "svc", "scope");
}

test "TokenCache.acquireOrWait — put after acquire makes second caller see have_token" {
    const gpa = testing.allocator;
    var cache: TokenCache = .{};
    const io = testing.io;
    defer cache.deinit(io, gpa);

    const first = try cache.acquireOrWait(io, gpa, "realm", "svc", "scope", 0);
    try testing.expect(first == .acquire);
    try cache.put(io, gpa, "realm", "svc", "scope", "tok-shared", null);
    cache.clearInflight(io, gpa, "realm", "svc", "scope");

    const second = try cache.acquireOrWait(io, gpa, "realm", "svc", "scope", 0);
    switch (second) {
        .have_token => |tok| {
            defer gpa.free(tok);
            try testing.expectEqualStrings("tok-shared", tok);
        },
        .acquire => {
            cache.clearInflight(io, gpa, "realm", "svc", "scope");
            try testing.expect(false);
        },
    }
}
