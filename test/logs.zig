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

test "emit correlates with the active (ambient) context" {
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
    const lg = lp.logger(.{ .name = "test" });

    const sc: otel.api.context.SpanContext = .{
        .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
        .span_id = .{ .bytes = .{ 17, 18, 19, 20, 21, 22, 23, 24 } },
        .flags = .{ .sampled = true },
    };

    // Make the span the active (ambient) context, then emit via the PUBLIC
    // logger path (NOT correlate directly). The emit path must stamp the
    // record's trace/span IDs from the active context.
    const token = otel.api.context.attach(otel.api.context.Context.empty().withSpanContext(sc));
    lg.emit(.{ .severity = .info, .body = .{ .string = "in-span" } });
    otel.api.context.restore(token);

    // After restoring, there is no active span: IDs must stay invalid.
    lg.emit(.{ .severity = .info, .body = .{ .string = "out-of-span" } });

    try std.testing.expectEqual(@as(usize, 2), rec.logs.items.len);

    // Emitted within the active context: correlated.
    try std.testing.expectEqualSlices(u8, sc.trace_id.bytes[0..], rec.logs.items[0].trace_id.bytes[0..]);
    try std.testing.expectEqualSlices(u8, sc.span_id.bytes[0..], rec.logs.items[0].span_id.bytes[0..]);

    // Emitted with no active span: IDs left invalid.
    try std.testing.expect(!rec.logs.items[1].trace_id.isValid());
    try std.testing.expect(!rec.logs.items[1].span_id.isValid());
}

test "severity short text" {
    try std.testing.expectEqualStrings("INFO", otel.api.logs.Severity.info.shortText());
    try std.testing.expectEqualStrings("ERROR", otel.api.logs.Severity.err.shortText());
}
