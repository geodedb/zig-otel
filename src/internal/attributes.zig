// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// AttributeSet — owned key/value storage backing every OpenTelemetry signal.
// Enforces the spec limits (128 entries, 256-byte keys, 4096-byte string
// values) and reports drops via the `dropped` counter so the exporter can
// surface them.

const std = @import("std");

pub const max_attributes: usize = 128;
pub const max_key_bytes: usize = 256;
pub const max_string_value_bytes: usize = 4096;

pub const Value = union(enum) {
    string: []const u8,
    bool: bool,
    int: i64,
    double: f64,
    string_array: []const []const u8,
    bool_array: []const bool,
    int_array: []const i64,
    double_array: []const f64,
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

/// Owned, deterministic-iteration attribute container.
///
/// Strings are duplicated into `arena` so callers can free their inputs.
/// Iteration order matches insertion order; later writes to the same key
/// overwrite the earlier value in place (counted as one slot).
///
/// Lookup uses an O(1) hash index built over the arena-owned keys, so
/// `put`/`getString` cost stays constant even at the 128-entry limit.
/// The index keys alias the entry keys (same arena bytes), so there is
/// only one duplication per inserted key.
pub const AttributeSet = struct {
    arena: std.heap.ArenaAllocator,
    entries: std.ArrayList(Entry),
    index: std.StringHashMapUnmanaged(u32),
    dropped: u32,

    pub fn init(allocator: std.mem.Allocator) AttributeSet {
        return .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .entries = .empty,
            .index = .empty,
            .dropped = 0,
        };
    }

    pub fn deinit(self: *AttributeSet) void {
        const child = self.arena.child_allocator;
        self.entries.deinit(child);
        self.index.deinit(child);
        self.arena.deinit();
    }

    /// Clear all entries and reset the arena while retaining capacity
    /// (entry list, index buckets, first arena page). Used by the
    /// SpanState pool so a recycled span pays no per-span attribute
    /// allocator traffic on the steady-state hot path.
    pub fn reset(self: *AttributeSet) void {
        self.entries.clearRetainingCapacity();
        self.index.clearRetainingCapacity();
        _ = self.arena.reset(.retain_capacity);
        self.dropped = 0;
    }

    pub fn count(self: *const AttributeSet) usize {
        return self.entries.items.len;
    }

    pub fn getString(self: *const AttributeSet, key: []const u8) ?[]const u8 {
        if (self.index.get(key)) |idx| {
            return switch (self.entries.items[idx].value) {
                .string => |s| s,
                else => null,
            };
        }
        return null;
    }

    pub fn putString(self: *AttributeSet, key: []const u8, value: []const u8) !void {
        if (key.len == 0 or key.len > max_key_bytes) {
            self.dropped +%= 1;
            return;
        }
        const v = if (value.len > max_string_value_bytes) value[0..max_string_value_bytes] else value;
        try self.put(key, .{ .string = v });
    }

    pub fn putInt(self: *AttributeSet, key: []const u8, value: i64) !void {
        if (key.len == 0 or key.len > max_key_bytes) {
            self.dropped +%= 1;
            return;
        }
        try self.put(key, .{ .int = value });
    }

    pub fn putBool(self: *AttributeSet, key: []const u8, value: bool) !void {
        if (key.len == 0 or key.len > max_key_bytes) {
            self.dropped +%= 1;
            return;
        }
        try self.put(key, .{ .bool = value });
    }

    pub fn putDouble(self: *AttributeSet, key: []const u8, value: f64) !void {
        if (key.len == 0 or key.len > max_key_bytes) {
            self.dropped +%= 1;
            return;
        }
        try self.put(key, .{ .double = value });
    }

    /// Owns nothing about `value` — copies via the arena. `value`'s slice
    /// memory may be freed by the caller after the call returns.
    ///
    /// GAP-SEC-L-2: array-typed values are refused with
    /// `error.UnsupportedAttributeKind`. The OTLP encoder and the
    /// Prometheus exporter both currently emit arrays as a `<array>`
    /// placeholder string, which (a) hides data loss from the caller
    /// and (b) collides with any literal user value of `<array>`.
    /// Refusing at the API surface forces callers to either flatten
    /// the array client-side or wait for proper array support to
    /// land on every codec.
    pub fn put(self: *AttributeSet, key: []const u8, value: Value) !void {
        if (key.len == 0 or key.len > max_key_bytes) {
            self.dropped +%= 1;
            return;
        }
        switch (value) {
            .string_array, .bool_array, .int_array, .double_array => return error.UnsupportedAttributeKind,
            else => {},
        }
        const arena_alloc = self.arena.allocator();

        // Look up first so the overwrite path never duplicates the key
        // into the arena. Without this the previous implementation
        // dropped a key-dupe per overwrite, eventually saturating the
        // arena for long-lived spans (P0-1 / P1-7).
        if (self.index.get(key)) |idx| {
            self.entries.items[idx].value = try dupValue(arena_alloc, value);
            return;
        }

        if (self.entries.items.len >= max_attributes) {
            self.dropped +%= 1;
            return;
        }

        const owned_key = try arena_alloc.dupe(u8, key);
        const owned_value = try dupValue(arena_alloc, value);
        const child = self.arena.child_allocator;
        try self.entries.append(child, .{ .key = owned_key, .value = owned_value });
        try self.index.put(child, owned_key, @intCast(self.entries.items.len - 1));
    }

    fn dupValue(arena: std.mem.Allocator, value: Value) !Value {
        return switch (value) {
            .string => |s| .{ .string = try arena.dupe(u8, s) },
            .bool => |b| .{ .bool = b },
            .int => |i| .{ .int = i },
            .double => |d| .{ .double = d },
            .string_array => |arr| blk: {
                const owned = try arena.alloc([]const u8, arr.len);
                for (arr, 0..) |s, i| owned[i] = try arena.dupe(u8, s);
                break :blk .{ .string_array = owned };
            },
            .bool_array => |arr| .{ .bool_array = try arena.dupe(bool, arr) },
            .int_array => |arr| .{ .int_array = try arena.dupe(i64, arr) },
            .double_array => |arr| .{ .double_array = try arena.dupe(f64, arr) },
        };
    }

    /// Returns entries sorted by key. The returned slice is owned by `out_alloc`.
    pub fn sortedEntries(self: *const AttributeSet, out_alloc: std.mem.Allocator) ![]Entry {
        const slice = try out_alloc.alloc(Entry, self.entries.items.len);
        @memcpy(slice, self.entries.items);
        std.mem.sort(Entry, slice, {}, lessThan);
        return slice;
    }

    fn lessThan(_: void, a: Entry, b: Entry) bool {
        return std.mem.order(u8, a.key, b.key) == .lt;
    }
};

test "put strings respects spec limits" {
    var as = AttributeSet.init(std.testing.allocator);
    defer as.deinit();

    try as.putString("service.name", "demo");
    try std.testing.expectEqualStrings("demo", as.getString("service.name").?);

    var huge_key: [max_key_bytes + 1]u8 = undefined;
    @memset(huge_key[0..], 'k');
    try as.putString(huge_key[0..], "x");
    try std.testing.expectEqual(@as(u32, 1), as.dropped);

    var huge_value: [max_string_value_bytes + 64]u8 = undefined;
    @memset(huge_value[0..], 'v');
    try as.putString("k", huge_value[0..]);
    try std.testing.expectEqual(@as(usize, max_string_value_bytes), as.getString("k").?.len);
}

test "duplicate keys overwrite in place" {
    var as = AttributeSet.init(std.testing.allocator);
    defer as.deinit();

    try as.putInt("retries", 1);
    try as.putInt("retries", 7);
    try std.testing.expectEqual(@as(usize, 1), as.count());
}

test "max attributes enforced" {
    var as = AttributeSet.init(std.testing.allocator);
    defer as.deinit();
    var i: usize = 0;
    var key_buf: [16]u8 = undefined;
    while (i < max_attributes + 5) : (i += 1) {
        const key = try std.fmt.bufPrint(key_buf[0..], "k{d}", .{i});
        try as.putInt(key, @intCast(i));
    }
    try std.testing.expectEqual(@as(usize, max_attributes), as.count());
    try std.testing.expectEqual(@as(u32, 5), as.dropped);
}

test "sorted entries are key-ordered" {
    var as = AttributeSet.init(std.testing.allocator);
    defer as.deinit();
    try as.putString("c", "1");
    try as.putString("a", "2");
    try as.putString("b", "3");
    const sorted = try as.sortedEntries(std.testing.allocator);
    defer std.testing.allocator.free(sorted);
    try std.testing.expectEqualStrings("a", sorted[0].key);
    try std.testing.expectEqualStrings("b", sorted[1].key);
    try std.testing.expectEqualStrings("c", sorted[2].key);
}
