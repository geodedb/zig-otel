// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Composite propagator — runs trace-context and baggage in one pass.
// Order matches the spec: traceparent first, baggage second on inject.

const std = @import("std");
const tc = @import("trace_context.zig");
const bp = @import("baggage.zig");
const ctx_mod = @import("../api/context.zig");
const baggage_api = @import("../api/baggage.zig");

pub const ExtractResult = struct {
    span_context: ?ctx_mod.SpanContext = null,
    baggage: ?baggage_api.Baggage = null,

    pub fn deinit(self: *ExtractResult) void {
        if (self.baggage) |*b| b.deinit();
    }
};

pub fn inject(arena: std.mem.Allocator, carrier: tc.Carrier, sc: ctx_mod.SpanContext, baggage: ?*const baggage_api.Baggage) !void {
    try tc.inject(arena, carrier, sc);
    if (baggage) |b| try bp.inject(arena, carrier, b);
}

pub fn extract(allocator: std.mem.Allocator, arena: std.mem.Allocator, carrier: tc.Carrier) !ExtractResult {
    var out: ExtractResult = .{};
    out.span_context = tc.extract(arena, carrier) catch |err| switch (err) {
        // The spec says malformed traceparent must not poison baggage extraction.
        error.InvalidTraceParent, error.InvalidTraceState => null,
        else => return err,
    };
    out.baggage = bp.extract(allocator, carrier) catch |err| switch (err) {
        error.InvalidBaggageKey, error.InvalidBaggageValue, error.BaggageTooLarge => null,
        else => return err,
    };
    return out;
}

test "composite inject handles both signals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = baggage_api.Baggage.init(std.testing.allocator);
    defer bag.deinit();
    try bag.put("k", "v", null);

    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: tc.MapCarrier = .{ .map = &map };

    const sc: ctx_mod.SpanContext = .{
        .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
        .span_id = .{ .bytes = .{ 17, 18, 19, 20, 21, 22, 23, 24 } },
    };
    try inject(arena.allocator(), mc.carrier(), sc, &bag);
    try std.testing.expect(map.get("traceparent") != null);
    try std.testing.expect(map.get("baggage") != null);
}

test "composite extract tolerates malformed pieces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("traceparent", "garbage");
    try map.put("baggage", "k=v");
    var mc: tc.MapCarrier = .{ .map = &map };
    var result = try extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context == null);
    try std.testing.expectEqualStrings("v", result.baggage.?.get("k").?);
}
