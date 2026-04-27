// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// W3C Baggage entries. Owned, validated, and serialised per the spec
// (max 180 entries, 256-byte keys, 4096-byte total serialised form).

const std = @import("std");

pub const max_entries: usize = 180;
pub const max_key_bytes: usize = 256;
pub const max_serialized_bytes: usize = 4096;

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
    /// Optional metadata after the ';' separator. Per spec, metadata is
    /// preserved verbatim and not interpreted by this implementation.
    metadata: ?[]const u8 = null,
};

pub const Baggage = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry),

    pub fn init(allocator: std.mem.Allocator) Baggage {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .entries = .empty,
        };
    }

    pub fn deinit(self: *Baggage) void {
        const child = self.arena.child_allocator;
        self.entries.deinit(child);
        self.arena.deinit();
    }

    pub fn clone(self: *const Baggage, allocator: std.mem.Allocator) !Baggage {
        var out = Baggage.init(allocator);
        errdefer out.deinit();
        for (self.entries.items) |e| try out.put(e.key, e.value, e.metadata);
        return out;
    }

    pub fn count(self: *const Baggage) usize {
        return self.entries.items.len;
    }

    pub fn get(self: *const Baggage, key: []const u8) ?[]const u8 {
        for (self.entries.items) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.value;
        }
        return null;
    }

    pub fn put(self: *Baggage, key: []const u8, value: []const u8, metadata: ?[]const u8) !void {
        try validateKey(key);
        try validateValue(value);
        const arena_alloc = self.arena.allocator();

        // PR-6 / #139: search FIRST so the hit path doesn't dupe the key
        // (and only dupes value + metadata). Pre-fix this method dupe'd
        // key + value + metadata before the dedup loop, so N consecutive
        // puts of the same key bled key_len bytes per call into arena
        // waste. On miss we still dupe key + value + metadata as before.
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.key, key)) {
                const owned_value = try arena_alloc.dupe(u8, value);
                const owned_meta = if (metadata) |m| try arena_alloc.dupe(u8, m) else null;
                self.entries.items[i].value = owned_value;
                self.entries.items[i].metadata = owned_meta;
                return;
            }
        }
        if (self.entries.items.len >= max_entries) return error.BaggageFull;
        const owned_key = try arena_alloc.dupe(u8, key);
        const owned_value = try arena_alloc.dupe(u8, value);
        const owned_meta = if (metadata) |m| try arena_alloc.dupe(u8, m) else null;
        try self.entries.append(self.arena.child_allocator, .{ .key = owned_key, .value = owned_value, .metadata = owned_meta });
    }

    pub fn remove(self: *Baggage, key: []const u8) bool {
        for (self.entries.items, 0..) |e, i| {
            if (std.mem.eql(u8, e.key, key)) {
                _ = self.entries.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn iter(self: *const Baggage) []const Entry {
        return self.entries.items;
    }
};

pub fn validateKey(key: []const u8) !void {
    if (key.len == 0 or key.len > max_key_bytes) return error.InvalidBaggageKey;
    for (key) |c| {
        // RFC 7230 token = 1*tchar
        const is_tchar = switch (c) {
            '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
            '0'...'9', 'a'...'z', 'A'...'Z' => true,
            else => false,
        };
        if (!is_tchar) return error.InvalidBaggageKey;
    }
}

pub fn validateValue(value: []const u8) !void {
    // Baggage value is %-encoded; we accept the decoded byte sequence as-is
    // but reject control characters and the comma/equals that separate entries.
    for (value) |c| {
        if (c < 0x20 or c == 0x7f) return error.InvalidBaggageValue;
        if (c == ',' or c == ';' or c == '=') return error.InvalidBaggageValue;
    }
}

test "validate key rejects empties and bad chars" {
    try std.testing.expectError(error.InvalidBaggageKey, validateKey(""));
    try std.testing.expectError(error.InvalidBaggageKey, validateKey("bad key"));
    try std.testing.expectError(error.InvalidBaggageKey, validateKey("bad,key"));
    try validateKey("good.key-1");
}

test "validate value rejects separators" {
    try std.testing.expectError(error.InvalidBaggageValue, validateValue("a,b"));
    try std.testing.expectError(error.InvalidBaggageValue, validateValue("a;b"));
    try std.testing.expectError(error.InvalidBaggageValue, validateValue("a=b"));
    try validateValue("plain-text");
}

test "put then get returns the same value" {
    var b = Baggage.init(std.testing.allocator);
    defer b.deinit();
    try b.put("user.id", "u-42", null);
    try std.testing.expectEqualStrings("u-42", b.get("user.id").?);
}

test "max entries enforced" {
    var b = Baggage.init(std.testing.allocator);
    defer b.deinit();
    var key_buf: [16]u8 = undefined;
    var i: usize = 0;
    while (i < max_entries) : (i += 1) {
        const key = try std.fmt.bufPrint(key_buf[0..], "k{d}", .{i});
        try b.put(key, "v", null);
    }
    try std.testing.expectError(error.BaggageFull, b.put("overflow", "v", null));
}

test "clone preserves entries" {
    var a = Baggage.init(std.testing.allocator);
    defer a.deinit();
    try a.put("k1", "v1", null);
    try a.put("k2", "v2", "meta");
    var b = try a.clone(std.testing.allocator);
    defer b.deinit();
    try std.testing.expectEqualStrings("v1", b.get("k1").?);
    try std.testing.expectEqualStrings("v2", b.get("k2").?);
}
