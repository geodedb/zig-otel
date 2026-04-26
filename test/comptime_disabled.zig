// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Verifies the `-Dotel_disabled=true` comptime elision contract:
// every API call site collapses to a no-op handle so the optimizer
// can dead-code-eliminate the disabled path. Tests self-skip when
// the flag is `false` (the default) so this file participates in
// both build modes without altering live-SDK semantics.

const std = @import("std");
const otel = @import("otel");
const build_options = @import("build_options");

test "build_options.otel_disabled is reachable" {
    // Verifies the option is threaded through; passes under both flag values.
    _ = build_options.otel_disabled;
}

test "tracer.startSpan returns Span.noop when otel_disabled (comptime)" {
    if (!build_options.otel_disabled) return error.SkipZigTest;
    // Construct an API-layer Tracer with the default (noop) vtable.
    const t: otel.api.trace.Tracer = .{ .scope = .{ .name = "test" } };
    const s = try t.startSpan(.empty(), "x", .{});
    try std.testing.expect(!s.isRecording());
    try std.testing.expect(s.state == null);
}

test "tracer.startSpan via SDK provider returns noop when otel_disabled" {
    if (!build_options.otel_disabled) return error.SkipZigTest;
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var tp = try otel.sdk.trace.TracerProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer tp.deinit();
    const tracer = tp.tracer(.{ .name = "test" });
    const s = try tracer.startSpan(.empty(), "x", .{});
    try std.testing.expect(!s.isRecording());
    try std.testing.expect(s.state == null);
    s.end(null);
}

test "counter.add is a no-op when otel_disabled (no allocations)" {
    if (!build_options.otel_disabled) return error.SkipZigTest;
    const m: otel.api.metrics.Meter = .{ .scope = .{ .name = "test" } };
    const c = try m.counter(.{ .name = "test_counter", .kind = .counter });
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) c.add(1, &.{});
}

test "histogram.record is a no-op when otel_disabled" {
    if (!build_options.otel_disabled) return error.SkipZigTest;
    const m: otel.api.metrics.Meter = .{ .scope = .{ .name = "test" } };
    const h = try m.histogram(.{ .name = "test_hist", .kind = .histogram });
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) h.record(1.5, &.{});
}

test "gauge.set is a no-op when otel_disabled" {
    if (!build_options.otel_disabled) return error.SkipZigTest;
    const m: otel.api.metrics.Meter = .{ .scope = .{ .name = "test" } };
    const g = try m.gauge(.{ .name = "test_gauge", .kind = .gauge });
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) g.set(2.5, &.{});
}

test "upDownCounter.add is a no-op when otel_disabled" {
    if (!build_options.otel_disabled) return error.SkipZigTest;
    const m: otel.api.metrics.Meter = .{ .scope = .{ .name = "test" } };
    const udc = try m.upDownCounter(.{ .name = "test_udc", .kind = .up_down_counter });
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) udc.add(-1, &.{});
}

test "logger.emit is a no-op when otel_disabled" {
    if (!build_options.otel_disabled) return error.SkipZigTest;
    const lg: otel.api.logs.Logger = .{ .scope = .{ .name = "test" } };
    var i: u32 = 0;
    while (i < 1_000) : (i += 1) lg.emit(.{ .severity = .info, .body = .{ .string = "x" } });
}

test "MeterProvider.meter returns noop Meter when otel_disabled" {
    if (!build_options.otel_disabled) return error.SkipZigTest;
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try otel.sdk.metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();
    const m = mp.meter(.{ .name = "test" });
    const c = try m.counter(.{ .name = "test_counter", .kind = .counter });
    c.add(42, &.{});
    // Snapshot must be empty: noop Meter never registered an instrument.
    const snap = try otel.sdk.metrics.collect(&mp, std.testing.allocator);
    defer {
        for (snap) |s| std.testing.allocator.free(s.points);
        std.testing.allocator.free(snap);
    }
    try std.testing.expectEqual(@as(usize, 0), snap.len);
}

test "LoggerProvider.logger returns noop Logger when otel_disabled" {
    if (!build_options.otel_disabled) return error.SkipZigTest;
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var rec = otel.exporters.in_memory.Recorder.init(std.testing.allocator);
    defer rec.deinit();
    var lp = try otel.sdk.logs.LoggerProvider.init(std.testing.allocator, .{
        .resource = &resource,
        .default_exporter = rec.logExporter(),
    });
    defer lp.deinit();
    const lg = lp.logger(.{ .name = "test" });
    lg.emit(.{ .severity = .info, .body = .{ .string = "hello" } });
    // Noop logger drops the record; recorder stays empty.
    try std.testing.expectEqual(@as(usize, 0), rec.logs.items.len);
}
