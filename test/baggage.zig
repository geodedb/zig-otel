// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");

test "baggage rejects empty key" {
    var b = otel.api.baggage.Baggage.init(std.testing.allocator);
    defer b.deinit();
    try std.testing.expectError(error.InvalidBaggageKey, b.put("", "v", null));
}

test "baggage rejects bad value separators" {
    var b = otel.api.baggage.Baggage.init(std.testing.allocator);
    defer b.deinit();
    try std.testing.expectError(error.InvalidBaggageValue, b.put("k", "a,b", null));
}

test "baggage put then get round trips" {
    var b = otel.api.baggage.Baggage.init(std.testing.allocator);
    defer b.deinit();
    try b.put("user.id", "u-7", null);
    try std.testing.expectEqualStrings("u-7", b.get("user.id").?);
}

test "baggage propagator round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = otel.api.baggage.Baggage.init(std.testing.allocator);
    defer bag.deinit();
    try bag.put("k1", "v1", null);
    try bag.put("k2", "value with spaces", null);

    var map = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer map.deinit();
    var mc: otel.propagation.trace_context.MapCarrier = .{ .map = &map };
    try otel.propagation.baggage.inject(arena.allocator(), mc.carrier(), &bag);

    var decoded = (try otel.propagation.baggage.extract(std.testing.allocator, mc.carrier())).?;
    defer decoded.deinit();
    try std.testing.expectEqualStrings("v1", decoded.get("k1").?);
    try std.testing.expectEqualStrings("value with spaces", decoded.get("k2").?);
}
