// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Asynchronous BatchSpanProcessor drain test.
//
// Gated on `-Dotel_use_devnw_pool=true`. The flag-off build still compiles
// this file (the compile-time gate skips at runtime via SkipZigTest), so
// `zig build test` always exercises the synchronous-drain code path
// described in `src/sdk/export.zig`.

const std = @import("std");
const otel = @import("otel");
const build_options = @import("build_options");

test "BatchSpanProcessor async drain exports all spans" {
    if (!build_options.use_devnw_pool) return error.SkipZigTest;

    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();

    var rec = otel.exporters.in_memory.Recorder.init(std.testing.allocator);
    defer rec.deinit();

    const exporter = rec.spanExporter();
    var bsp = try otel.sdk.exporter.BatchSpanProcessor.init(std.testing.allocator, exporter, &resource, .{
        .max_queue_size = 4096,
        .max_export_batch_size = 64,
        .schedule_delay_ms = 5,
        .async_workers = 2, // activates DevNW thread-pool
    });
    defer bsp.deinit();

    const proc = bsp.processor();
    var tp = try otel.sdk.trace.TracerProvider.init(std.testing.allocator, .{
        .resource = &resource,
        .processors = &.{proc},
    });
    defer tp.deinit();

    const tracer = tp.tracer(.{ .name = "demo" });
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const s = try tracer.startSpan(.empty(), "x", .{});
        s.end(null);
    }
    try bsp.processor().forceFlush(1_000);
    try std.testing.expectEqual(@as(usize, 200), rec.spans.items.len);
}

test "BatchSpanProcessor periodic timer drains under-batch queue" {
    if (!build_options.use_devnw_pool) return error.SkipZigTest;

    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();

    var rec = otel.exporters.in_memory.Recorder.init(std.testing.allocator);
    defer rec.deinit();

    const exporter = rec.spanExporter();
    // Batch size 64 with only 5 spans — only the timer can flush
    // these. schedule_delay_ms = 10ms keeps the test under a second
    // even on a busy CI runner.
    var bsp = try otel.sdk.exporter.BatchSpanProcessor.init(std.testing.allocator, exporter, &resource, .{
        .max_queue_size = 4096,
        .max_export_batch_size = 64,
        .schedule_delay_ms = 10,
        .async_workers = 1,
    });
    defer bsp.deinit();

    const proc = bsp.processor();
    var tp = try otel.sdk.trace.TracerProvider.init(std.testing.allocator, .{
        .resource = &resource,
        .processors = &.{proc},
    });
    defer tp.deinit();

    const tracer = tp.tracer(.{ .name = "demo" });
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const s = try tracer.startSpan(.empty(), "x", .{});
        s.end(null);
    }

    // Wait for at least two timer ticks worth of time. Don't call
    // forceFlush — the assertion is that the timer drained on its
    // own. Use a small budget so the test stays fast.
    var spins: u32 = 0;
    while (rec.spans.items.len < 5 and spins < 50) : (spins += 1) {
        otel.internal.clock.sleepNs(20 * std.time.ns_per_ms);
    }
    try std.testing.expectEqual(@as(usize, 5), rec.spans.items.len);
}
