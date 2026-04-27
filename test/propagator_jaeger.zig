// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Jaeger propagator tests — `uber-trace-id` SpanContext + per-entry
// `uberctx-<key>` baggage.

const std = @import("std");
const otel = @import("otel");

const propagator = otel.propagation.propagator;
const jaeger = otel.propagation.jaeger;
const config = otel.sdk.config;

const example_trace_id: otel.api.context.SpanContext = .{
    .trace_id = .{ .bytes = .{ 0x4b, 0xf9, 0x2f, 0x35, 0x77, 0xb3, 0x4d, 0xa6, 0xa3, 0xce, 0x92, 0x9d, 0x0e, 0x0e, 0x47, 0x36 } },
    .span_id = .{ .bytes = .{ 0x00, 0xf0, 0x67, 0xaa, 0x0b, 0xa9, 0x02, 0xb7 } },
    .flags = .{ .sampled = true },
};
const trace_hex_32 = "4bf92f3577b34da6a3ce929d0e0e4736";
const span_hex_16 = "00f067aa0ba902b7";

// ---------------------------------------------------------------- //
// Inject — positive
// ---------------------------------------------------------------- //

test "jaeger inject writes uber-trace-id with sampled=1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: propagator.MapCarrier = .{ .map = &map };

    try jaeger.propagator.inject(arena.allocator(), mc.carrier(), .{ .span_context = example_trace_id });
    const got = map.get("uber-trace-id").?;
    try std.testing.expectEqualStrings(trace_hex_32 ++ ":" ++ span_hex_16 ++ ":0:1", got);
}

test "jaeger inject writes flags=0 when not sampled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: propagator.MapCarrier = .{ .map = &map };

    var sc = example_trace_id;
    sc.flags.sampled = false;
    try jaeger.propagator.inject(arena.allocator(), mc.carrier(), .{ .span_context = sc });
    const got = map.get("uber-trace-id").?;
    try std.testing.expectEqualStrings(trace_hex_32 ++ ":" ++ span_hex_16 ++ ":0:0", got);
}

test "jaeger inject writes uberctx-<key> for every baggage entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = otel.api.baggage.Baggage.init(std.testing.allocator);
    defer bag.deinit();
    try bag.put("user.id", "u-1", null);
    try bag.put("region", "us-east-1", null);

    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: propagator.MapCarrier = .{ .map = &map };

    try jaeger.propagator.inject(arena.allocator(), mc.carrier(), .{ .baggage = &bag });
    try std.testing.expectEqualStrings("u-1", map.get("uberctx-user.id").?);
    try std.testing.expectEqualStrings("us-east-1", map.get("uberctx-region").?);
}

test "jaeger inject percent-encodes non-unreserved bytes in baggage values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = otel.api.baggage.Baggage.init(std.testing.allocator);
    defer bag.deinit();
    try bag.put("k", "value with spaces", null);

    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: propagator.MapCarrier = .{ .map = &map };

    try jaeger.propagator.inject(arena.allocator(), mc.carrier(), .{ .baggage = &bag });
    try std.testing.expectEqualStrings("value%20with%20spaces", map.get("uberctx-k").?);
}

// ---------------------------------------------------------------- //
// Extract — positive
// ---------------------------------------------------------------- //

test "jaeger extract: 32-hex trace + 16-hex span + flags=1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("uber-trace-id", trace_hex_32 ++ ":" ++ span_hex_16 ++ ":0:1");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try jaeger.propagator.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    const sc = result.span_context.?;
    try std.testing.expectEqualSlices(u8, example_trace_id.trace_id.bytes[0..], sc.trace_id.bytes[0..]);
    try std.testing.expectEqualSlices(u8, example_trace_id.span_id.bytes[0..], sc.span_id.bytes[0..]);
    try std.testing.expect(sc.flags.sampled);
    try std.testing.expect(sc.is_remote);
}

test "jaeger extract: 16-hex trace-id is zero-padded to 32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("uber-trace-id", "a3ce929d0e0e4736:" ++ span_hex_16 ++ ":0:1");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try jaeger.propagator.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    const sc = result.span_context.?;
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, sc.trace_id.bytes[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0xa3, 0xce, 0x92, 0x9d, 0x0e, 0x0e, 0x47, 0x36 }, sc.trace_id.bytes[8..16]);
}

test "jaeger extract: debug flag (bit 1) collapses to sampled=true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    // flag byte 0x02 = debug, no sampled bit set; per spec must
    // surface as sampled=true on the OTel side.
    try map.put("uber-trace-id", trace_hex_32 ++ ":" ++ span_hex_16 ++ ":0:2");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try jaeger.propagator.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context.?.flags.sampled);
}

test "jaeger extract: parent-span-id non-zero is accepted-and-discarded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("uber-trace-id", trace_hex_32 ++ ":" ++ span_hex_16 ++ ":1111111111111111:1");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try jaeger.propagator.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context != null);
    // OTel SpanContext doesn't carry parent-span-id; the field is
    // shape-validated and dropped.
}

test "jaeger extract: uberctx-<key> headers populate Baggage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("uber-trace-id", trace_hex_32 ++ ":" ++ span_hex_16 ++ ":0:1");
    try map.put("uberctx-user.id", "u-1");
    try map.put("uberctx-region", "us-east-1");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try jaeger.propagator.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expectEqualStrings("u-1", result.baggage.?.get("user.id").?);
    try std.testing.expectEqualStrings("us-east-1", result.baggage.?.get("region").?);
}

test "jaeger extract: uberctx values are URL-decoded" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("uber-trace-id", trace_hex_32 ++ ":" ++ span_hex_16 ++ ":0:1");
    try map.put("uberctx-key", "value%20with%20spaces");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try jaeger.propagator.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expectEqualStrings("value with spaces", result.baggage.?.get("key").?);
}

// ---------------------------------------------------------------- //
// Extract — negative
// ---------------------------------------------------------------- //

test "jaeger extract rejects too few colon-separated fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("uber-trace-id", trace_hex_32 ++ ":" ++ span_hex_16 ++ ":0");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try jaeger.propagator.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context == null);
}

test "jaeger extract rejects too many colon-separated fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("uber-trace-id", trace_hex_32 ++ ":" ++ span_hex_16 ++ ":0:1:extra");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try jaeger.propagator.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context == null);
}

test "jaeger extract rejects non-hex trace-id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("uber-trace-id", "GGGG2f3577b34da6a3ce929d0e0e4736:" ++ span_hex_16 ++ ":0:1");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try jaeger.propagator.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context == null);
}

test "jaeger extract rejects all-zero trace-id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("uber-trace-id", "00000000000000000000000000000000:" ++ span_hex_16 ++ ":0:1");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try jaeger.propagator.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context == null);
}

test "jaeger extract rejects oversized trace-id (>32 hex chars)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("uber-trace-id", "00" ++ trace_hex_32 ++ ":" ++ span_hex_16 ++ ":0:1"); // 34 hex chars
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try jaeger.propagator.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context == null);
}

test "jaeger extract rejects empty flags field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("uber-trace-id", trace_hex_32 ++ ":" ++ span_hex_16 ++ ":0:");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try jaeger.propagator.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context == null);
}

// ---------------------------------------------------------------- //
// Round-trip
// ---------------------------------------------------------------- //

test "jaeger uber-trace-id round-trip preserves trace-id, span-id, sampled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: propagator.MapCarrier = .{ .map = &map };

    try jaeger.propagator.inject(arena.allocator(), mc.carrier(), .{ .span_context = example_trace_id });
    var result = try jaeger.propagator.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    const got = result.span_context.?;
    try std.testing.expectEqualSlices(u8, example_trace_id.trace_id.bytes[0..], got.trace_id.bytes[0..]);
    try std.testing.expectEqualSlices(u8, example_trace_id.span_id.bytes[0..], got.span_id.bytes[0..]);
    try std.testing.expectEqual(example_trace_id.flags.sampled, got.flags.sampled);
}

test "jaeger uberctx baggage round-trips with URL-encoding for special bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = otel.api.baggage.Baggage.init(std.testing.allocator);
    defer bag.deinit();
    try bag.put("greeting", "hello world", null);
    try bag.put("session", "abc-123_xyz", null);

    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: propagator.MapCarrier = .{ .map = &map };

    try jaeger.propagator.inject(arena.allocator(), mc.carrier(), .{
        .span_context = example_trace_id,
        .baggage = &bag,
    });
    var result = try jaeger.propagator.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expectEqualStrings("hello world", result.baggage.?.get("greeting").?);
    try std.testing.expectEqualStrings("abc-123_xyz", result.baggage.?.get("session").?);
}

// ---------------------------------------------------------------- //
// End-to-end via OTEL_PROPAGATORS env var + factory.
// ---------------------------------------------------------------- //

test "OTEL_PROPAGATORS=jaeger builds a Composite that round-trips uber-trace-id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: propagator.MapCarrier = .{ .map = &map };

    var em = config.EnvMap.init(std.testing.allocator);
    defer em.deinit();
    try em.put("OTEL_PROPAGATORS", "jaeger");
    var cfg: config.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    try config.applyEnvFromMap(&cfg, std.testing.allocator, &em);
    try std.testing.expectEqual(@as(@TypeOf(cfg.propagator), .jaeger), cfg.propagator);

    var bundle = try config.propagatorBundleFromConfig(std.testing.allocator, &cfg, &em);
    defer bundle.deinit();
    const composite = bundle.composite();

    try composite.inject(arena.allocator(), mc.carrier(), .{ .span_context = example_trace_id });
    try std.testing.expect(map.get("uber-trace-id") != null);
    try std.testing.expect(map.get("traceparent") == null);
    try std.testing.expect(map.get("b3") == null);

    var result = try composite.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    const got = result.span_context.?;
    try std.testing.expectEqualSlices(u8, example_trace_id.trace_id.bytes[0..], got.trace_id.bytes[0..]);
    try std.testing.expectEqualSlices(u8, example_trace_id.span_id.bytes[0..], got.span_id.bytes[0..]);
}

test "OTEL_PROPAGATORS=jaeger composite carries uberctx baggage end-to-end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = otel.api.baggage.Baggage.init(std.testing.allocator);
    defer bag.deinit();
    try bag.put("user.id", "u-7", null);

    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: propagator.MapCarrier = .{ .map = &map };

    var em = config.EnvMap.init(std.testing.allocator);
    defer em.deinit();
    try em.put("OTEL_PROPAGATORS", "jaeger");
    var bundle = try config.propagatorBundleFromConfig(std.testing.allocator, &config.Config{}, &em);
    defer bundle.deinit();
    const composite = bundle.composite();

    try composite.inject(arena.allocator(), mc.carrier(), .{
        .span_context = example_trace_id,
        .baggage = &bag,
    });
    try std.testing.expect(map.get("uberctx-user.id") != null);

    var result = try composite.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expectEqualStrings("u-7", result.baggage.?.get("user.id").?);
}
