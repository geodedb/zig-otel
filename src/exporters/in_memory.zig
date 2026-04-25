// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// In-memory exporter for traces, metrics, and logs. Test-only; collects
// items as cheap copies and surfaces them via the `recorded_*` slices.

const std = @import("std");
const exp = @import("../sdk/export.zig");
const trace_api = @import("../api/trace.zig");
const metrics_api = @import("../api/metrics.zig");
const logs_api = @import("../api/logs.zig");
const id_mod = @import("../internal/id.zig");
const ctx_mod = @import("../api/context.zig");
const attrs_mod = @import("../internal/attributes.zig");

pub const StoredSpan = struct {
    name: []u8,
    sc: ctx_mod.SpanContext,
    parent_span_id: id_mod.SpanId,
    kind: trace_api.SpanKind,
    start_unix_nano: u64,
    end_unix_nano: u64,
    status_code: trace_api.StatusCode,
    attribute_kv: []KV,

    pub fn deinit(self: *StoredSpan, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.attribute_kv) |kv| {
            allocator.free(kv.key);
            allocator.free(kv.value);
        }
        allocator.free(self.attribute_kv);
    }
};

pub const KV = struct {
    key: []u8,
    value: []u8,
};

pub const StoredMetric = struct {
    name: []u8,
    int_value: ?i64 = null,
    double_value: ?f64 = null,

    pub fn deinit(self: *StoredMetric, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const StoredLog = struct {
    body: []u8,
    severity: logs_api.Severity,
    trace_id: id_mod.TraceId,
    span_id: id_mod.SpanId,

    pub fn deinit(self: *StoredLog, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub const Recorder = struct {
    allocator: std.mem.Allocator,
    spans: std.ArrayList(StoredSpan) = .empty,
    metrics: std.ArrayList(StoredMetric) = .empty,
    logs: std.ArrayList(StoredLog) = .empty,
    /// Single-threaded by contract. Concurrent producers must wrap calls
    /// in their own lock; the SDK contract for the export pipeline hands
    /// items off serially so this matches normal use.
    _: void = {},

    pub fn init(allocator: std.mem.Allocator) Recorder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Recorder) void {
        for (self.spans.items) |*s| s.deinit(self.allocator);
        self.spans.deinit(self.allocator);
        for (self.metrics.items) |*m| m.deinit(self.allocator);
        self.metrics.deinit(self.allocator);
        for (self.logs.items) |*l| l.deinit(self.allocator);
        self.logs.deinit(self.allocator);
    }

    pub fn spanExporter(self: *Recorder) exp.SpanExporter {
        return .{ .ctx = self, .exportFn = expSpans, .shutdownFn = noopShutdown, .forceFlushFn = noopFlush };
    }

    pub fn metricExporter(self: *Recorder) exp.MetricExporter {
        return .{ .ctx = self, .exportFn = expMetrics, .shutdownFn = noopShutdown, .forceFlushFn = noopFlush };
    }

    pub fn logExporter(self: *Recorder) exp.LogExporter {
        return .{ .ctx = self, .exportFn = expLogs, .shutdownFn = noopShutdown, .forceFlushFn = noopFlush };
    }
};

fn noopShutdown(_: ?*anyopaque) void {}
fn noopFlush(_: ?*anyopaque, _: u64) anyerror!void {}

fn expSpans(ctx: ?*anyopaque, items: []const exp.SpanData) anyerror!exp.SpanExportResult {
    const self: *Recorder = @ptrCast(@alignCast(ctx.?));
    for (items) |span| {
        const kvs = try cloneKVs(self.allocator, span.attributes);
        try self.spans.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, span.name),
            .sc = span.span_context,
            .parent_span_id = span.parent_span_id,
            .kind = span.kind,
            .start_unix_nano = span.start_unix_nano,
            .end_unix_nano = span.end_unix_nano,
            .status_code = span.status_code,
            .attribute_kv = kvs,
        });
    }
    return .success;
}

fn expMetrics(ctx: ?*anyopaque, items: []const exp.MetricData) anyerror!exp.SpanExportResult {
    const self: *Recorder = @ptrCast(@alignCast(ctx.?));
    for (items) |m| {
        var int_v: ?i64 = null;
        var dbl_v: ?f64 = null;
        if (m.points.len > 0) {
            switch (m.points[0].value) {
                .number => |n| switch (n) {
                    .int => |i| int_v = i,
                    .double => |d| dbl_v = d,
                },
                .histogram => {},
            }
        }
        try self.metrics.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, m.name),
            .int_value = int_v,
            .double_value = dbl_v,
        });
    }
    return .success;
}

fn expLogs(ctx: ?*anyopaque, items: []const exp.LogData) anyerror!exp.SpanExportResult {
    const self: *Recorder = @ptrCast(@alignCast(ctx.?));
    for (items) |l| {
        const body_str = switch (l.record.body) {
            .string => |s| try self.allocator.dupe(u8, s),
            .bool => |b| try self.allocator.dupe(u8, if (b) "true" else "false"),
            .int => |i| try std.fmt.allocPrint(self.allocator, "{d}", .{i}),
            .double => |d| try std.fmt.allocPrint(self.allocator, "{d}", .{d}),
            .none => try self.allocator.dupe(u8, ""),
        };
        try self.logs.append(self.allocator, .{
            .body = body_str,
            .severity = l.record.severity,
            .trace_id = l.record.trace_id,
            .span_id = l.record.span_id,
        });
    }
    return .success;
}

fn cloneKVs(allocator: std.mem.Allocator, set: *const attrs_mod.AttributeSet) ![]KV {
    const out = try allocator.alloc(KV, set.entries.items.len);
    for (set.entries.items, 0..) |e, i| {
        out[i].key = try allocator.dupe(u8, e.key);
        out[i].value = try valueToString(allocator, e.value);
    }
    return out;
}

fn valueToString(allocator: std.mem.Allocator, v: attrs_mod.Value) ![]u8 {
    return switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        .bool => |b| try allocator.dupe(u8, if (b) "true" else "false"),
        .int => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .double => |d| try std.fmt.allocPrint(allocator, "{d}", .{d}),
        else => try allocator.dupe(u8, "<array>"),
    };
}

test "recorder captures spans" {
    var rec = Recorder.init(std.testing.allocator);
    defer rec.deinit();

    var resource = try @import("../sdk/resource.zig").defaultResource(std.testing.allocator);
    defer resource.deinit();
    var attr_set = attrs_mod.AttributeSet.init(std.testing.allocator);
    defer attr_set.deinit();
    try attr_set.putString("k", "v");

    const span: exp.SpanData = .{
        .name = "test",
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
    const exporter = rec.spanExporter();
    _ = try exporter.exportSpans(&[_]exp.SpanData{span});
    try std.testing.expectEqual(@as(usize, 1), rec.spans.items.len);
    try std.testing.expectEqualStrings("test", rec.spans.items[0].name);
}
