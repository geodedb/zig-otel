// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Logs API surface. LogRecord is a value built up by the caller and emitted
// via Logger.emit. The SDK pipeline owns persistence/export.

const std = @import("std");
const attrs = @import("../internal/attributes.zig");
const id = @import("../internal/id.zig");
const InstrumentationScope = @import("trace.zig").InstrumentationScope;
const build_options = @import("build_options");

pub const Severity = enum(u8) {
    unspecified = 0,
    trace = 1,
    trace2 = 2,
    trace3 = 3,
    trace4 = 4,
    debug = 5,
    debug2 = 6,
    debug3 = 7,
    debug4 = 8,
    info = 9,
    info2 = 10,
    info3 = 11,
    info4 = 12,
    warn = 13,
    warn2 = 14,
    warn3 = 15,
    warn4 = 16,
    err = 17,
    err2 = 18,
    err3 = 19,
    err4 = 20,
    fatal = 21,
    fatal2 = 22,
    fatal3 = 23,
    fatal4 = 24,

    pub fn shortText(self: Severity) []const u8 {
        return switch (self) {
            .trace, .trace2, .trace3, .trace4 => "TRACE",
            .debug, .debug2, .debug3, .debug4 => "DEBUG",
            .info, .info2, .info3, .info4 => "INFO",
            .warn, .warn2, .warn3, .warn4 => "WARN",
            .err, .err2, .err3, .err4 => "ERROR",
            .fatal, .fatal2, .fatal3, .fatal4 => "FATAL",
            else => "UNSPECIFIED",
        };
    }
};

pub const Body = union(enum) {
    string: []const u8,
    bool: bool,
    int: i64,
    double: f64,
    none,
};

pub const LogRecord = struct {
    timestamp_unix_nano: u64 = 0,
    observed_unix_nano: u64 = 0,
    severity: Severity = .info,
    severity_text: []const u8 = "",
    body: Body = .none,
    attributes: ?*attrs.AttributeSet = null,
    trace_id: id.TraceId = .invalid,
    span_id: id.SpanId = .invalid,
    flags: id.TraceFlags = .{},
    scope: InstrumentationScope = .{ .name = "" },
    /// Set internally by the bridge to mark exception/event-shaped logs.
    event_name: []const u8 = "",
};

pub const Logger = struct {
    ctx: ?*anyopaque = null,
    scope: InstrumentationScope,
    emitFn: *const fn (?*anyopaque, LogRecord) void = noopEmit,

    pub fn emit(self: Logger, record: LogRecord) void {
        if (comptime build_options.otel_disabled) return;
        var r = record;
        if (r.scope.name.len == 0) r.scope = self.scope;
        self.emitFn(self.ctx, r);
    }
};

fn noopEmit(_: ?*anyopaque, _: LogRecord) void {}

test "severity short text covers ranges" {
    try std.testing.expectEqualStrings("INFO", Severity.info.shortText());
    try std.testing.expectEqualStrings("INFO", Severity.info4.shortText());
    try std.testing.expectEqualStrings("ERROR", Severity.err2.shortText());
}
