// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");

test "counter aggregates additions" {
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try otel.sdk.metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const m = mp.meter(.{ .name = "demo" });
    const c = try m.counter(.{ .name = "events", .kind = .counter });
    c.add(1, &.{});
    c.add(2, &.{});
    c.add(4, &.{});

    const snapshot = try otel.sdk.metrics.collect(&mp, std.testing.allocator);
    defer {
        for (snapshot) |s| std.testing.allocator.free(s.points);
        std.testing.allocator.free(snapshot);
    }
    try std.testing.expectEqual(@as(i64, 7), snapshot[0].points[0].value.number.int);
}

test "histogram bucket layout" {
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try otel.sdk.metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const m = mp.meter(.{ .name = "demo" });
    const h = try m.histogram(.{
        .name = "latency",
        .kind = .histogram,
        .explicit_buckets = .{ .boundaries = &.{ 1.0, 5.0 } },
    });
    h.record(0.5, &.{});
    h.record(2.0, &.{});
    h.record(10.0, &.{});

    const snapshot = try otel.sdk.metrics.collect(&mp, std.testing.allocator);
    defer {
        for (snapshot) |s| std.testing.allocator.free(s.points);
        std.testing.allocator.free(snapshot);
    }
    const hp = snapshot[0].points[0].value.histogram;
    try std.testing.expectEqual(@as(u64, 3), hp.count);
    try std.testing.expectEqualSlices(u64, &.{ 1, 1, 1 }, hp.counts);
}

test "delta vs cumulative descriptor preserved" {
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try otel.sdk.metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();
    const m = mp.meter(.{ .name = "demo" });
    const c = try m.counter(.{ .name = "x", .kind = .counter, .temporality = .delta });
    c.add(1, &.{});
    const snapshot = try otel.sdk.metrics.collect(&mp, std.testing.allocator);
    defer {
        for (snapshot) |s| std.testing.allocator.free(s.points);
        std.testing.allocator.free(snapshot);
    }
    try std.testing.expectEqual(otel.api.metrics.Temporality.delta, snapshot[0].temporality);
}
