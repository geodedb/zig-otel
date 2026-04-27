// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// B3 propagator tests — single + multi header forms.
//
// Coverage matrix (per spec at github.com/openzipkin/b3-propagation):
//   * single header: positive (sampled, debug, with parent-span-id),
//                    negative (empty trace-id, missing span-id, bad hex).
//   * multi header:  positive (sampled, debug via X-B3-Flags, padded
//                    16-hex trace-id), negative (missing span-id,
//                    invalid sampled token, malformed trace-id length).
//   * round-trip:    inject(extract(ctx)) preserves trace-id, span-id,
//                    sampled flag.
//   * end-to-end:    OTEL_PROPAGATORS=b3 (and =b3multi) → factory →
//                    Composite.inject + Composite.extract round-trip.

const std = @import("std");
const otel = @import("otel");

const propagator = otel.propagation.propagator;
const b3 = otel.propagation.b3;
const config = otel.sdk.config;

// Spec example trace-id / span-id, used across most assertions.
const example_trace_id: otel.api.context.SpanContext = .{
    .trace_id = .{ .bytes = .{ 0x4b, 0xf9, 0x2f, 0x35, 0x77, 0xb3, 0x4d, 0xa6, 0xa3, 0xce, 0x92, 0x9d, 0x0e, 0x0e, 0x47, 0x36 } },
    .span_id = .{ .bytes = .{ 0x00, 0xf0, 0x67, 0xaa, 0x0b, 0xa9, 0x02, 0xb7 } },
    .flags = .{ .sampled = true },
};

const example_trace_id_hex = "4bf92f3577b34da6a3ce929d0e0e4736";
const example_span_id_hex = "00f067aa0ba902b7";

// ---------------------------------------------------------------- //
// Single-header — positive cases.
// ---------------------------------------------------------------- //

test "b3 single inject writes trace-id-span-id-sampled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: propagator.MapCarrier = .{ .map = &map };

    try b3.single_header.inject(arena.allocator(), mc.carrier(), .{ .span_context = example_trace_id });
    const got = map.get("b3").?;
    try std.testing.expectEqualStrings(example_trace_id_hex ++ "-" ++ example_span_id_hex ++ "-1", got);
}

test "b3 single extract accepts the canonical 32+16+1 form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("b3", example_trace_id_hex ++ "-" ++ example_span_id_hex ++ "-1");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try b3.single_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    const sc = result.span_context.?;
    try std.testing.expectEqualSlices(u8, example_trace_id.trace_id.bytes[0..], sc.trace_id.bytes[0..]);
    try std.testing.expectEqualSlices(u8, example_trace_id.span_id.bytes[0..], sc.span_id.bytes[0..]);
    try std.testing.expect(sc.flags.sampled);
    try std.testing.expect(sc.is_remote);
}

test "b3 single extract accepts the debug ('d') sampled token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("b3", example_trace_id_hex ++ "-" ++ example_span_id_hex ++ "-d");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try b3.single_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context.?.flags.sampled);
}

test "b3 single extract accepts and discards parent-span-id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("b3", example_trace_id_hex ++ "-" ++ example_span_id_hex ++ "-1-1111111111111111");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try b3.single_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context != null);
    // OTel SpanContext has no parent-span-id; the value is parsed
    // for shape and dropped.
}

test "b3 single extract: bare '0' surfaces empty SpanContext with sampled=false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("b3", "0");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try b3.single_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    const sc = result.span_context.?;
    try std.testing.expect(!sc.isValid());
    try std.testing.expect(!sc.flags.sampled);
}

// ---------------------------------------------------------------- //
// Single-header — negative cases.
// ---------------------------------------------------------------- //

test "b3 single rejects empty trace-id (returns null context)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("b3", "-" ++ example_span_id_hex ++ "-1");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try b3.single_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context == null);
}

test "b3 single rejects missing span-id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("b3", example_trace_id_hex);
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try b3.single_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context == null);
}

test "b3 single rejects non-hex trace-id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("b3", "ZZZZ2f3577b34da6a3ce929d0e0e4736-" ++ example_span_id_hex ++ "-1");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try b3.single_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context == null);
}

test "b3 single rejects all-zero trace-id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("b3", "00000000000000000000000000000000-" ++ example_span_id_hex ++ "-1");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try b3.single_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context == null);
}

test "b3 single rejects bad sampled token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("b3", example_trace_id_hex ++ "-" ++ example_span_id_hex ++ "-X");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try b3.single_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context == null);
}

// ---------------------------------------------------------------- //
// Multi-header — positive cases.
// ---------------------------------------------------------------- //

test "b3multi inject writes X-B3-TraceId, X-B3-SpanId, X-B3-Sampled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: propagator.MapCarrier = .{ .map = &map };

    try b3.multi_header.inject(arena.allocator(), mc.carrier(), .{ .span_context = example_trace_id });
    try std.testing.expectEqualStrings(example_trace_id_hex, map.get("X-B3-TraceId").?);
    try std.testing.expectEqualStrings(example_span_id_hex, map.get("X-B3-SpanId").?);
    try std.testing.expectEqualStrings("1", map.get("X-B3-Sampled").?);
}

test "b3multi extract accepts canonical 32+16+1 form" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("X-B3-TraceId", example_trace_id_hex);
    try map.put("X-B3-SpanId", example_span_id_hex);
    try map.put("X-B3-Sampled", "1");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try b3.multi_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    const sc = result.span_context.?;
    try std.testing.expectEqualSlices(u8, example_trace_id.trace_id.bytes[0..], sc.trace_id.bytes[0..]);
    try std.testing.expect(sc.flags.sampled);
}

test "b3multi extract: X-B3-Flags=1 overrides Sampled to true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("X-B3-TraceId", example_trace_id_hex);
    try map.put("X-B3-SpanId", example_span_id_hex);
    try map.put("X-B3-Sampled", "0");
    try map.put("X-B3-Flags", "1");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try b3.multi_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context.?.flags.sampled);
}

test "b3multi extract: 16-hex trace-id is zero-padded to 32" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("X-B3-TraceId", "a3ce929d0e0e4736"); // last 16 hex = low 64 bits
    try map.put("X-B3-SpanId", example_span_id_hex);
    try map.put("X-B3-Sampled", "1");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try b3.multi_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    const sc = result.span_context.?;
    // High 8 bytes zero, low 8 bytes match the input.
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0, 0, 0, 0, 0 }, sc.trace_id.bytes[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 0xa3, 0xce, 0x92, 0x9d, 0x0e, 0x0e, 0x47, 0x36 }, sc.trace_id.bytes[8..16]);
}

// ---------------------------------------------------------------- //
// Multi-header — negative cases.
// ---------------------------------------------------------------- //

test "b3multi rejects missing span-id (returns null context)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("X-B3-TraceId", example_trace_id_hex);
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try b3.multi_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context == null);
}

test "b3multi rejects malformed trace-id length (24 hex chars)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("X-B3-TraceId", "4bf92f3577b34da6a3ce929d"); // 24 hex chars — invalid length
    try map.put("X-B3-SpanId", example_span_id_hex);
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try b3.multi_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context == null);
}

test "b3multi rejects bad sampled token" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("X-B3-TraceId", example_trace_id_hex);
    try map.put("X-B3-SpanId", example_span_id_hex);
    try map.put("X-B3-Sampled", "true"); // spec says only `0` or `1`
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try b3.multi_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context == null);
}

test "b3multi rejects all-zero trace-id" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("X-B3-TraceId", "00000000000000000000000000000000");
    try map.put("X-B3-SpanId", example_span_id_hex);
    try map.put("X-B3-Sampled", "1");
    var mc: propagator.MapCarrier = .{ .map = &map };

    var result = try b3.multi_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context == null);
}

// ---------------------------------------------------------------- //
// Round-trip + composite end-to-end.
// ---------------------------------------------------------------- //

test "b3 single round-trip preserves trace-id, span-id, sampled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: propagator.MapCarrier = .{ .map = &map };

    try b3.single_header.inject(arena.allocator(), mc.carrier(), .{ .span_context = example_trace_id });
    var result = try b3.single_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    const got = result.span_context.?;
    try std.testing.expectEqualSlices(u8, example_trace_id.trace_id.bytes[0..], got.trace_id.bytes[0..]);
    try std.testing.expectEqualSlices(u8, example_trace_id.span_id.bytes[0..], got.span_id.bytes[0..]);
    try std.testing.expectEqual(example_trace_id.flags.sampled, got.flags.sampled);
}

test "b3 multi round-trip preserves trace-id, span-id, sampled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: propagator.MapCarrier = .{ .map = &map };

    try b3.multi_header.inject(arena.allocator(), mc.carrier(), .{ .span_context = example_trace_id });
    var result = try b3.multi_header.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    const got = result.span_context.?;
    try std.testing.expectEqualSlices(u8, example_trace_id.trace_id.bytes[0..], got.trace_id.bytes[0..]);
    try std.testing.expectEqualSlices(u8, example_trace_id.span_id.bytes[0..], got.span_id.bytes[0..]);
    try std.testing.expectEqual(example_trace_id.flags.sampled, got.flags.sampled);
}

test "OTEL_PROPAGATORS=b3 builds a Composite that round-trips through b3 single" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: propagator.MapCarrier = .{ .map = &map };

    var em = config.EnvMap.init(std.testing.allocator);
    defer em.deinit();
    try em.put("OTEL_PROPAGATORS", "b3");
    var cfg: config.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    try config.applyEnvFromMap(&cfg, std.testing.allocator, &em);
    try std.testing.expectEqual(@as(@TypeOf(cfg.propagator), .b3), cfg.propagator);

    var bundle = try config.propagatorBundleFromConfig(std.testing.allocator, &cfg, &em);
    defer bundle.deinit();
    const composite = bundle.composite();

    try composite.inject(arena.allocator(), mc.carrier(), .{ .span_context = example_trace_id });
    try std.testing.expect(map.get("b3") != null);
    try std.testing.expect(map.get("traceparent") == null);

    var result = try composite.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    const got = result.span_context.?;
    try std.testing.expectEqualSlices(u8, example_trace_id.trace_id.bytes[0..], got.trace_id.bytes[0..]);
    try std.testing.expectEqualSlices(u8, example_trace_id.span_id.bytes[0..], got.span_id.bytes[0..]);
}

test "OTEL_PROPAGATORS=b3multi builds a Composite that round-trips through b3 multi" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: propagator.MapCarrier = .{ .map = &map };

    var em = config.EnvMap.init(std.testing.allocator);
    defer em.deinit();
    try em.put("OTEL_PROPAGATORS", "b3multi");
    var cfg: config.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    try config.applyEnvFromMap(&cfg, std.testing.allocator, &em);
    try std.testing.expectEqual(@as(@TypeOf(cfg.propagator), .b3multi), cfg.propagator);

    var bundle = try config.propagatorBundleFromConfig(std.testing.allocator, &cfg, &em);
    defer bundle.deinit();
    const composite = bundle.composite();

    try composite.inject(arena.allocator(), mc.carrier(), .{ .span_context = example_trace_id });
    try std.testing.expect(map.get("X-B3-TraceId") != null);
    try std.testing.expect(map.get("X-B3-SpanId") != null);
    try std.testing.expect(map.get("b3") == null);

    var result = try composite.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    const got = result.span_context.?;
    try std.testing.expectEqualSlices(u8, example_trace_id.trace_id.bytes[0..], got.trace_id.bytes[0..]);
    try std.testing.expect(got.flags.sampled);
}

test "OTEL_PROPAGATORS=b3,baggage composes both propagators" {
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
    try em.put("OTEL_PROPAGATORS", "b3,baggage");

    var bundle = try config.propagatorBundleFromConfig(std.testing.allocator, &otel.sdk.config.Config{}, &em);
    defer bundle.deinit();
    const composite = bundle.composite();

    try composite.inject(arena.allocator(), mc.carrier(), .{ .span_context = example_trace_id, .baggage = &bag });
    try std.testing.expect(map.get("b3") != null);
    try std.testing.expect(map.get("baggage") != null);

    var result = try composite.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context != null);
    try std.testing.expectEqualStrings("u-7", result.baggage.?.get("user.id").?);
}
