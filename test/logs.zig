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

test "Span.makeCurrent activates a real span for log correlation (QN2-1)" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var rec = otel.exporters.in_memory.Recorder.init(std.testing.allocator);
    defer rec.deinit();

    var tp = try otel.sdk.trace.TracerProvider.init(std.testing.allocator, .{
        .resource = &resource,
        .default_exporter = rec.spanExporter(),
    });
    defer tp.deinit();
    var lp = try otel.sdk.logs.LoggerProvider.init(std.testing.allocator, .{
        .resource = &resource,
        .default_exporter = rec.logExporter(),
    });
    defer lp.deinit();
    const lg = lp.logger(.{ .name = "test" });
    const t = tp.tracer(.{ .name = "demo" });

    // Idiomatic path: start a REAL span, activate it via the public
    // makeCurrent() (NOT a manual ctx.attach), then emit through the public
    // logger. The emitted record must carry the span's identity.
    var span = try t.startSpan(.empty(), "work", .{});
    const sc = span.context();

    const scope = span.makeCurrent();
    lg.emit(.{ .severity = .info, .body = .{ .string = "in span" } });
    otel.api.context.restore(scope);
    span.end(null);

    // After restore, no active span: the next emit stays uncorrelated.
    lg.emit(.{ .severity = .info, .body = .{ .string = "after" } });

    try std.testing.expectEqual(@as(usize, 2), rec.logs.items.len);
    try std.testing.expectEqualSlices(u8, sc.trace_id.bytes[0..], rec.logs.items[0].trace_id.bytes[0..]);
    try std.testing.expectEqualSlices(u8, sc.span_id.bytes[0..], rec.logs.items[0].span_id.bytes[0..]);
    try std.testing.expect(!rec.logs.items[1].trace_id.isValid());
}

test "correlate never clobbers a pre-set trace id (QN2-5)" {
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

    // A DIFFERENT span is ambient...
    const ambient: otel.api.context.SpanContext = .{
        .trace_id = .{ .bytes = .{ 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA } },
        .span_id = .{ .bytes = .{ 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB, 0xBB } },
        .flags = .{ .sampled = true },
    };
    // ...but the record already carries an explicit, valid identity that
    // fill-if-empty correlation must NOT overwrite.
    const preset_tid: otel.internal.id.TraceId = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } };
    const preset_sid: otel.internal.id.SpanId = .{ .bytes = .{ 17, 18, 19, 20, 21, 22, 23, 24 } };

    const token = otel.api.context.attach(otel.api.context.Context.empty().withSpanContext(ambient));
    lg.emit(.{ .severity = .info, .body = .{ .string = "preset" }, .trace_id = preset_tid, .span_id = preset_sid });
    otel.api.context.restore(token);

    try std.testing.expectEqual(@as(usize, 1), rec.logs.items.len);
    // The pre-set identity survives; the ambient span did NOT clobber it.
    try std.testing.expectEqualSlices(u8, preset_tid.bytes[0..], rec.logs.items[0].trace_id.bytes[0..]);
    try std.testing.expectEqualSlices(u8, preset_sid.bytes[0..], rec.logs.items[0].span_id.bytes[0..]);
}

test "severity short text" {
    try std.testing.expectEqualStrings("INFO", otel.api.logs.Severity.info.shortText());
    try std.testing.expectEqualStrings("ERROR", otel.api.logs.Severity.err.shortText());
}
