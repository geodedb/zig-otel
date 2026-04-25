// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");
const build_options = @import("build_options");

test "slog bridge forwards severity and scope" {
    if (!build_options.use_devnw_slog) return error.SkipZigTest;

    const Captured = struct {
        var severity: ?otel.api.logs.Severity = null;
        var body: ?[]const u8 = null;
        fn cb(_: ?*anyopaque, r: otel.api.logs.LogRecord) void {
            severity = r.severity;
            switch (r.body) {
                .string => |s| body = s,
                else => {},
            }
        }
    };
    Captured.severity = null;
    Captured.body = null;

    const logger: otel.api.logs.Logger = .{ .scope = .{ .name = "test" }, .emitFn = Captured.cb };
    otel.instrumentation.std_log.setLogger(logger);
    defer otel.instrumentation.std_log.clearLogger();

    otel.instrumentation.std_log.bridgeLogFn(.warn, .my_scope, "alert {d}", .{99});

    try std.testing.expectEqual(otel.api.logs.Severity.warn, Captured.severity.?);
    try std.testing.expect(std.mem.indexOf(u8, Captured.body.?, "alert 99") != null);
}
