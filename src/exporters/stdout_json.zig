// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Stdout JSON exporter — one JSON object per call, terminated by '\n'.
// Useful for `kubectl logs`-style pipelines and the example apps.

const std = @import("std");
const exp = @import("../sdk/export.zig");
const trace_api = @import("../api/trace.zig");
const logs_api = @import("../api/logs.zig");
const attrs_mod = @import("../internal/attributes.zig");
const json_codec = @import("../internal/json_codec.zig");

pub const StdoutJson = struct {
    allocator: std.mem.Allocator,
    /// Optional override; defaults to the process stdout file descriptor.
    /// Tests inject their own buffer.
    out_writer: ?*std.Io.Writer = null,

    pub fn init(allocator: std.mem.Allocator) StdoutJson {
        return .{ .allocator = allocator };
    }

    pub fn spanExporter(self: *StdoutJson) exp.SpanExporter {
        return .{ .ctx = self, .exportFn = expSpans, .shutdownFn = noopShutdown, .forceFlushFn = noopFlush };
    }

    pub fn metricExporter(self: *StdoutJson) exp.MetricExporter {
        return .{ .ctx = self, .exportFn = expMetrics, .shutdownFn = noopShutdown, .forceFlushFn = noopFlush };
    }

    pub fn logExporter(self: *StdoutJson) exp.LogExporter {
        return .{ .ctx = self, .exportFn = expLogs, .shutdownFn = noopShutdown, .forceFlushFn = noopFlush };
    }
};

fn noopShutdown(_: ?*anyopaque) void {}
fn noopFlush(_: ?*anyopaque, _: u64) anyerror!void {}

fn writeAndFlush(self: *StdoutJson, payload: []const u8) !void {
    if (self.out_writer) |w| {
        try w.writeAll(payload);
        try w.writeByte('\n');
        return;
    }
    // Fallback: write directly via std.posix to avoid an Io context here.
    const fd = std.posix.STDOUT_FILENO;
    _ = std.posix.write(fd, payload) catch return;
    _ = std.posix.write(fd, "\n") catch return;
}

fn expSpans(ctx: ?*anyopaque, items: []const exp.SpanData) anyerror!exp.SpanExportResult {
    const self: *StdoutJson = @ptrCast(@alignCast(ctx.?));

    for (items) |span| {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const json = try json_codec.spanToJson(aa, span);
        try writeAndFlush(self, json);
    }
    return .success;
}

fn expMetrics(ctx: ?*anyopaque, items: []const exp.MetricData) anyerror!exp.SpanExportResult {
    const self: *StdoutJson = @ptrCast(@alignCast(ctx.?));
    for (items) |m| {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const json = try json_codec.metricToJson(aa, m);
        try writeAndFlush(self, json);
    }
    return .success;
}

fn expLogs(ctx: ?*anyopaque, items: []const exp.LogData) anyerror!exp.SpanExportResult {
    const self: *StdoutJson = @ptrCast(@alignCast(ctx.?));
    for (items) |l| {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const json = try json_codec.logToJson(aa, l);
        try writeAndFlush(self, json);
    }
    return .success;
}

test "stdout exporter writes span json to provided writer" {
    var resource = try @import("../sdk/resource.zig").defaultResource(std.testing.allocator);
    defer resource.deinit();
    var attr_set = attrs_mod.AttributeSet.init(std.testing.allocator);
    defer attr_set.deinit();
    try attr_set.putString("k", "v");
    const span: exp.SpanData = .{
        .name = "t",
        .span_context = .{ .trace_id = .invalid, .span_id = .invalid },
        .kind = .internal,
        .start_unix_nano = 1,
        .end_unix_nano = 2,
        .attributes = &attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "" },
        .resource = &resource,
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    var sj = StdoutJson.init(std.testing.allocator);
    sj.out_writer = &aw.writer;
    const exporter = sj.spanExporter();
    _ = try exporter.exportSpans(&[_]exp.SpanData{span});
    const written_bytes = aw.written();
    try std.testing.expect(written_bytes.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, written_bytes, "\"name\":\"t\"") != null);
}
