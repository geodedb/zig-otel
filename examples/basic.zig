// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const Io = std.Io;
const otel = @import("otel");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [8 * 1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("otel basic example v{s}\n", .{otel.version});

    var resource = try otel.sdk.resource.defaultResource(arena);
    try resource.attributes.putString(otel.semconv.service_name, "demo");

    var exporter = otel.exporters.in_memory.Recorder.init(arena);

    var tp = try otel.sdk.trace.TracerProvider.init(arena, .{
        .resource = &resource,
        .default_exporter = exporter.spanExporter(),
    });
    defer tp.deinit();

    const tracer = tp.tracer(.{ .name = "examples/basic" });
    const span = try tracer.startSpan(.empty(), "doWork", .{});
    try span.setStringAttribute("work.kind", "demo");
    span.setStatus(.ok, "");
    span.end(null);

    // ADR-0003: default_exporter wraps in BatchSpanProcessor, so the
    // recorder is empty until we flush.
    try tp.forceFlush(1_000);

    try out.print(
        "exported {d} span(s); first name = {s}\n",
        .{ exporter.spans.items.len, exporter.spans.items[0].name },
    );
    try out.flush();
}
