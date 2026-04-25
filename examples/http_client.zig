// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Demonstrates the HTTP client instrumentation helper. The "request" is
// stubbed — the goal is to show how to wrap arbitrary HTTP code in a span
// with the right semantic-convention attributes.

const std = @import("std");
const Io = std.Io;
const otel = @import("otel");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [8 * 1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("otel http_client example v{s}\n", .{otel.version});

    var resource = try otel.sdk.resource.defaultResource(arena);
    try resource.attributes.putString(otel.semconv.service_name, "http-demo");

    var rec = otel.exporters.in_memory.Recorder.init(arena);

    var tp = try otel.sdk.trace.TracerProvider.init(arena, .{
        .resource = &resource,
        .default_exporter = rec.spanExporter(),
    });
    defer tp.deinit();

    const tracer = tp.tracer(.{ .name = "examples/http_client" });

    // Stand-in for an actual outbound request.
    const span = try otel.instrumentation.http.startClientSpan(tracer, .empty(), .{
        .method = "GET",
        .url = "https://example.com/v1/items",
    });
    otel.instrumentation.http.endClientSpan(span, .{ .status_code = 200 });

    try out.print(
        "captured {d} span(s); first kind = {s}\n",
        .{ rec.spans.items.len, rec.spans.items[0].kind.toString() },
    );
    try out.flush();
}
