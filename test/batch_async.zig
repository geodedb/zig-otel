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
