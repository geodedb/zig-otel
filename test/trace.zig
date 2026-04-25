// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");

const TraceId = otel.internal.id.TraceId;
const SpanId = otel.internal.id.SpanId;

test "valid traceparent parses cleanly" {
    const sc = try otel.propagation.trace_context.parseTraceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
    try std.testing.expect(sc.flags.sampled);
    try std.testing.expect(sc.is_remote);
}

test "traceparent rejects upper-case hex" {
    try std.testing.expectError(
        error.InvalidTraceParent,
        otel.propagation.trace_context.parseTraceparent("0F-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"),
    );
}

test "tracer end-to-end with in-memory exporter" {
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var rec = otel.exporters.in_memory.Recorder.init(std.testing.allocator);
    defer rec.deinit();

    const span_exporter = rec.spanExporter();
    var clock_state = otel.internal.clock.Stepped.init(1000, 100);
    var ids = otel.internal.id.Sequence.init(
        &.{TraceId{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } }},
        &.{SpanId{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8 } }},
    );

    var tp = try otel.sdk.trace.TracerProvider.init(std.testing.allocator, .{
        .resource = &resource,
        .default_exporter = span_exporter,
        .clock = clock_state.clock(),
        .id_generator = ids.generator(),
    });
    defer tp.deinit();

    const t = tp.tracer(.{ .name = "demo" });
    const span = try t.startSpan(.empty(), "op", .{});
    span.setStatus(.ok, "");
    try span.setStringAttribute("k", "v");
    span.end(2000);

    try std.testing.expectEqual(@as(usize, 1), rec.spans.items.len);
    try std.testing.expectEqual(otel.api.trace.StatusCode.ok, rec.spans.items[0].status_code);
}

test "alwaysOff sampler drops the span" {
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var tp = try otel.sdk.trace.TracerProvider.init(std.testing.allocator, .{
        .resource = &resource,
        .sampler = otel.sdk.trace.alwaysOff(),
    });
    defer tp.deinit();
    const t = tp.tracer(.{ .name = "demo" });
    const span = try t.startSpan(.empty(), "x", .{});
    try std.testing.expect(!span.isRecording());
}
