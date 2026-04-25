// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// std.log → OpenTelemetry logs bridge. Wire `bridgeLogFn` into your
// `std.options.log_fn` to forward all `std.log.*` calls into a Logger,
// preserving severity and the active SpanContext for correlation.

const std = @import("std");
const logs_api = @import("../api/logs.zig");
const ctx_mod = @import("../api/context.zig");
const build_options = @import("build_options");
const slog = if (build_options.use_devnw_slog) @import("slog") else struct {};

threadlocal var current_logger: ?logs_api.Logger = null;
threadlocal var current_context: ?ctx_mod.Context = null;

/// Install a Logger so subsequent `std.log.*` calls forward to it.
pub fn setLogger(logger: logs_api.Logger) void {
    current_logger = logger;
}

pub fn clearLogger() void {
    current_logger = null;
}

/// Pin a context so the bridge can copy trace/span IDs onto records.
pub fn setContext(ctx: ctx_mod.Context) void {
    current_context = ctx;
}

pub fn clearContext() void {
    current_context = null;
}

/// Drop-in for `std.options.log_fn`.
pub fn bridgeLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const logger = current_logger orelse return;
    // The slog branch may expand control characters (e.g. `\n` → `\\n`),
    // so the sanitised destination buffer is sized 2x the rendered buffer
    // to absorb worst-case escape expansion without dropping the record.
    var buf: [8192]u8 = undefined;
    const message = if (build_options.use_devnw_slog) blk: {
        // Route formatting through slog's text-value writer so log payloads
        // are sanitized identically across the DevNW ecosystem (control
        // chars, etc). The std.fmt.bufPrint call materializes the format
        // args; writeTextValue then renders the resulting string as a slog
        // Value.
        var fmt_buf: [4096]u8 = undefined;
        const rendered = std.fmt.bufPrint(&fmt_buf, format, args) catch return;
        var writer: std.Io.Writer = .fixed(&buf);
        slog.text_value.writeTextValue(&writer, slog.Value{ .str = rendered }) catch break :blk rendered;
        break :blk writer.buffered();
    } else std.fmt.bufPrint(&buf, format, args) catch return;
    var record: logs_api.LogRecord = .{
        .severity = mapLevel(level),
        .severity_text = @tagName(level),
        .body = .{ .string = message },
        .timestamp_unix_nano = posixNow(),
        .scope = .{ .name = @tagName(scope) },
    };
    if (current_context) |c| {
        if (c.activeSpanContext()) |sc| {
            record.trace_id = sc.trace_id;
            record.span_id = sc.span_id;
            record.flags = sc.flags;
        }
    }
    logger.emit(record);
}

fn posixNow() u64 {
    return @import("../internal/clock.zig").unixNanoNow();
}

fn mapLevel(level: std.log.Level) logs_api.Severity {
    return switch (level) {
        .err => .err,
        .warn => .warn,
        .info => .info,
        .debug => .debug,
    };
}

test "bridge forwards records to active logger" {
    const Captured = struct {
        var record: ?logs_api.LogRecord = null;
        fn cb(_: ?*anyopaque, r: logs_api.LogRecord) void {
            record = r;
        }
    };
    Captured.record = null;
    const logger: logs_api.Logger = .{ .scope = .{ .name = "" }, .emitFn = Captured.cb };
    setLogger(logger);
    defer clearLogger();
    bridgeLogFn(.info, .test_scope, "hello {d}", .{42});
    try std.testing.expect(Captured.record != null);
    try std.testing.expectEqual(logs_api.Severity.info, Captured.record.?.severity);
    try std.testing.expectEqualStrings("hello 42", Captured.record.?.body.string);
}
