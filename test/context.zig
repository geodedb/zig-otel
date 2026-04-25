// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");

test "empty context has no slots" {
    const c = otel.api.context.Context.empty();
    try std.testing.expect(c.activeSpanContext() == null);
    try std.testing.expect(c.activeBaggage() == null);
    try std.testing.expect(c.activeSpan() == null);
}

test "withSpanContext returns a fresh context" {
    const sc: otel.api.context.SpanContext = .{
        .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
        .span_id = .{ .bytes = .{ 17, 18, 19, 20, 21, 22, 23, 24 } },
        .flags = .{ .sampled = true },
    };
    const c = otel.api.context.Context.empty().withSpanContext(sc);
    try std.testing.expect(c.activeSpanContext() != null);
    try std.testing.expect(c.activeSpanContext().?.flags.sampled);
}

test "active baggage borrows the caller's value" {
    var bag = otel.api.baggage.Baggage.init(std.testing.allocator);
    defer bag.deinit();
    try bag.put("k", "v", null);
    const c = otel.api.context.Context.empty().withBaggageRef(&bag);
    try std.testing.expectEqualStrings("v", c.activeBaggage().?.get("k").?);
}
