// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// W3C Baggage propagator. The header is `baggage` and entries are
// comma-separated `key=value;metadata` pairs. The serialised form is
// capped at 4096 bytes per spec.

const std = @import("std");
const baggage_api = @import("../api/baggage.zig");
const tc = @import("trace_context.zig");

pub const baggage_header: []const u8 = "baggage";

pub fn inject(arena: std.mem.Allocator, carrier: tc.Carrier, baggage: *const baggage_api.Baggage) !void {
    if (baggage.count() == 0) return;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);

    var first = true;
    for (baggage.iter()) |entry| {
        if (!first) try buf.append(arena, ',');
        first = false;
        try buf.appendSlice(arena, entry.key);
        try buf.append(arena, '=');
        try percentEncode(arena, &buf, entry.value);
        if (entry.metadata) |m| {
            try buf.append(arena, ';');
            try buf.appendSlice(arena, m);
        }
        if (buf.items.len > baggage_api.max_serialized_bytes) return error.BaggageTooLarge;
    }
    const owned = try arena.dupe(u8, buf.items);
    try carrier.set(baggage_header, owned);
}

pub fn extract(allocator: std.mem.Allocator, carrier: tc.Carrier) !?baggage_api.Baggage {
    const raw = carrier.get(baggage_header) orelse return null;
    if (raw.len > baggage_api.max_serialized_bytes) return error.BaggageTooLarge;

    var bag = baggage_api.Baggage.init(allocator);
    errdefer bag.deinit();

    var members = std.mem.splitScalar(u8, raw, ',');
    while (members.next()) |raw_member| {
        const member = std.mem.trim(u8, raw_member, " \t");
        if (member.len == 0) continue;
        const meta_start = std.mem.indexOfScalar(u8, member, ';');
        const kv = if (meta_start) |i| member[0..i] else member;
        const meta = if (meta_start) |i| member[i + 1 ..] else null;
        const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.InvalidBaggageKey;
        const key = std.mem.trim(u8, kv[0..eq], " \t");
        const value_encoded = std.mem.trim(u8, kv[eq + 1 ..], " \t");

        var scratch: std.ArrayList(u8) = .empty;
        defer scratch.deinit(allocator);
        try percentDecode(allocator, &scratch, value_encoded);
        try bag.put(key, scratch.items, meta);
    }

    return bag;
}

fn percentEncode(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |c| {
        if (isUnreserved(c)) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hexUpper(c >> 4));
            try out.append(allocator, hexUpper(c & 0x0f));
        }
    }
}

fn percentDecode(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];
        if (c == '%') {
            if (i + 2 >= value.len) return error.InvalidBaggageValue;
            const hi = nibble(value[i + 1]) catch return error.InvalidBaggageValue;
            const lo = nibble(value[i + 2]) catch return error.InvalidBaggageValue;
            try out.append(allocator, (hi << 4) | lo);
            i += 3;
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

fn nibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

fn hexUpper(n: u8) u8 {
    const alphabet = "0123456789ABCDEF";
    return alphabet[n & 0x0f];
}

test "inject and extract round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = baggage_api.Baggage.init(std.testing.allocator);
    defer bag.deinit();
    try bag.put("user.id", "u-1", null);
    try bag.put("region", "us-east-1", null);

    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: tc.MapCarrier = .{ .map = &map };
    try inject(arena.allocator(), mc.carrier(), &bag);

    var out = (try extract(std.testing.allocator, mc.carrier())).?;
    defer out.deinit();
    try std.testing.expectEqualStrings("u-1", out.get("user.id").?);
    try std.testing.expectEqualStrings("us-east-1", out.get("region").?);
}

test "extract returns null when missing" {
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: tc.MapCarrier = .{ .map = &map };
    try std.testing.expect((try extract(std.testing.allocator, mc.carrier())) == null);
}
