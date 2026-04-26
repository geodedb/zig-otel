// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");

test "logger correlates with active span" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var rec = otel.exporters.in_memory.Recorder.init(std.testing.allocator);
    defer rec.deinit();

    var lp = try otel.sdk.logs.LoggerProvider.init(std.testing.allocator, .{
        .resource = &resource,
        .default_exporter = rec.logExporter(),
    });
    defer lp.deinit();

    const sc: otel.api.context.SpanContext = .{
        .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
        .span_id = .{ .bytes = .{ 17, 18, 19, 20, 21, 22, 23, 24 } },
        .flags = .{ .sampled = true },
    };
    var record: otel.api.logs.LogRecord = .{
        .severity = .info,
        .body = .{ .string = "hello" },
    };
    otel.sdk.logs.correlate(otel.api.context.Context.empty().withSpanContext(sc), &record);

    const lg = lp.logger(.{ .name = "test" });
    lg.emit(record);

    try std.testing.expectEqual(@as(usize, 1), rec.logs.items.len);
    try std.testing.expectEqual(otel.api.logs.Severity.info, rec.logs.items[0].severity);
    try std.testing.expectEqualSlices(u8, sc.trace_id.bytes[0..], rec.logs.items[0].trace_id.bytes[0..]);
}

test "severity short text" {
    try std.testing.expectEqualStrings("INFO", otel.api.logs.Severity.info.shortText());
    try std.testing.expectEqualStrings("ERROR", otel.api.logs.Severity.err.shortText());
}
