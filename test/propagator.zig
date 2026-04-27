// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Pluggable TextMapPropagator + Composite tests. Pins the contract
// the SDK relies on at provider-build time: a single `Composite`
// dispatches inject/extract to every configured propagator, and the
// `propagatorBundleFromConfig` factory turns a parsed
// `OTEL_PROPAGATORS` enum into a working bundle.

const std = @import("std");
const otel = @import("otel");

const propagator = otel.propagation.propagator;
const config = otel.sdk.config;

test "Composite forwards inject to every member" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var bag = otel.api.baggage.Baggage.init(std.testing.allocator);
    defer bag.deinit();
    try bag.put("k", "v", null);

    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: propagator.MapCarrier = .{ .map = &map };

    const sc: otel.api.context.SpanContext = .{
        .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
        .span_id = .{ .bytes = .{ 17, 18, 19, 20, 21, 22, 23, 24 } },
    };

    const members = [_]propagator.TextMapPropagator{ propagator.trace_context, propagator.baggage };
    const composite = propagator.Composite.init(&members);
    try composite.inject(arena.allocator(), mc.carrier(), .{ .span_context = sc, .baggage = &bag });

    try std.testing.expect(map.get("traceparent") != null);
    try std.testing.expect(map.get("baggage") != null);
}

test "Composite extract merges baggage across members" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("traceparent", "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
    try map.put("baggage", "k=v");
    var mc: propagator.MapCarrier = .{ .map = &map };

    const members = [_]propagator.TextMapPropagator{ propagator.trace_context, propagator.baggage };
    const composite = propagator.Composite.init(&members);
    var result = try composite.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context != null);
    try std.testing.expect(result.span_context.?.flags.sampled);
    try std.testing.expectEqualStrings("v", result.baggage.?.get("k").?);
}

test "Composite extract tolerates malformed members without poisoning siblings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put("traceparent", "garbage");
    try map.put("baggage", "k=v");
    var mc: propagator.MapCarrier = .{ .map = &map };

    const members = [_]propagator.TextMapPropagator{ propagator.trace_context, propagator.baggage };
    const composite = propagator.Composite.init(&members);
    var result = try composite.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();
    try std.testing.expect(result.span_context == null);
    try std.testing.expectEqualStrings("v", result.baggage.?.get("k").?);
}

test "propagatorBundleFromConfig default composite has tracecontext + baggage" {
    var cfg: config.Config = .{};
    var bundle = try config.propagatorBundleFromConfig(std.testing.allocator, &cfg, null);
    defer bundle.deinit();
    try std.testing.expectEqual(@as(usize, 2), bundle.members.len);
}

test "propagatorBundleFromConfig tracecontext yields a single member" {
    var cfg: config.Config = .{ .propagator = .tracecontext };
    var bundle = try config.propagatorBundleFromConfig(std.testing.allocator, &cfg, null);
    defer bundle.deinit();
    try std.testing.expectEqual(@as(usize, 1), bundle.members.len);
}

test "propagatorBundleFromConfig none yields an empty bundle" {
    var cfg: config.Config = .{ .propagator = .none };
    var bundle = try config.propagatorBundleFromConfig(std.testing.allocator, &cfg, null);
    defer bundle.deinit();
    try std.testing.expectEqual(@as(usize, 0), bundle.members.len);
}

test "propagatorBundleFromEnvList parses comma-separated list" {
    var bundle = try config.propagatorBundleFromEnvList(std.testing.allocator, "tracecontext,baggage");
    defer bundle.deinit();
    try std.testing.expectEqual(@as(usize, 2), bundle.members.len);
}

test "propagatorBundleFromEnvList ignores unknown tokens" {
    var bundle = try config.propagatorBundleFromEnvList(std.testing.allocator, "tracecontext,unknownToken,baggage");
    defer bundle.deinit();
    try std.testing.expectEqual(@as(usize, 2), bundle.members.len);
}

test "propagatorBundleFromEnvList none short-circuits the list" {
    var bundle = try config.propagatorBundleFromEnvList(std.testing.allocator, "tracecontext,none,baggage");
    defer bundle.deinit();
    try std.testing.expectEqual(@as(usize, 0), bundle.members.len);
}

test "OTEL_PROPAGATORS comma-separated list flips parsed enum to composite" {
    var em = config.EnvMap.init(std.testing.allocator);
    defer em.deinit();
    try em.put("OTEL_PROPAGATORS", "tracecontext,baggage");
    var cfg: config.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    try config.applyEnvFromMap(&cfg, std.testing.allocator, &em);
    try std.testing.expectEqual(@as(@TypeOf(cfg.propagator), .composite), cfg.propagator);
}

test "OTEL_PROPAGATORS=tracecontext flips parsed enum to tracecontext" {
    var em = config.EnvMap.init(std.testing.allocator);
    defer em.deinit();
    try em.put("OTEL_PROPAGATORS", "tracecontext");
    var cfg: config.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    try config.applyEnvFromMap(&cfg, std.testing.allocator, &em);
    try std.testing.expectEqual(@as(@TypeOf(cfg.propagator), .tracecontext), cfg.propagator);
}

test "OTEL_PROPAGATORS=none flips parsed enum to none" {
    var em = config.EnvMap.init(std.testing.allocator);
    defer em.deinit();
    try em.put("OTEL_PROPAGATORS", "none");
    var cfg: config.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    try config.applyEnvFromMap(&cfg, std.testing.allocator, &em);
    try std.testing.expectEqual(@as(@TypeOf(cfg.propagator), .none), cfg.propagator);
}

test "tracecontext propagator round-trips through Composite" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: propagator.MapCarrier = .{ .map = &map };

    const sc: otel.api.context.SpanContext = .{
        .trace_id = .{ .bytes = .{ 0x4b, 0xf9, 0x2f, 0x35, 0x77, 0xb3, 0x4d, 0xa6, 0xa3, 0xce, 0x92, 0x9d, 0x0e, 0x0e, 0x47, 0x36 } },
        .span_id = .{ .bytes = .{ 0x00, 0xf0, 0x67, 0xaa, 0x0b, 0xa9, 0x02, 0xb7 } },
        .flags = .{ .sampled = true },
    };

    var cfg: config.Config = .{ .propagator = .tracecontext };
    var bundle = try config.propagatorBundleFromConfig(std.testing.allocator, &cfg, null);
    defer bundle.deinit();
    const composite = bundle.composite();

    try composite.inject(arena.allocator(), mc.carrier(), .{ .span_context = sc });
    var result = try composite.extract(std.testing.allocator, arena.allocator(), mc.carrier());
    defer result.deinit();

    const got = result.span_context.?;
    try std.testing.expectEqualSlices(u8, sc.trace_id.bytes[0..], got.trace_id.bytes[0..]);
    try std.testing.expectEqualSlices(u8, sc.span_id.bytes[0..], got.span_id.bytes[0..]);
    try std.testing.expect(got.flags.sampled);
}
