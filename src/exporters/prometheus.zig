// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Prometheus text exposition exporter. Renders metrics using the
// `text_format` 0.0.4 wire format. The exporter is pull-based — call
// `render` to materialise the latest snapshot.

const std = @import("std");
const exp = @import("../sdk/export.zig");
const metrics_api = @import("../api/metrics.zig");
const attrs_mod = @import("../internal/attributes.zig");
const sdk_metrics = @import("../sdk/metrics.zig");
const MeterProvider = sdk_metrics.MeterProvider;

pub const Prometheus = struct {
    allocator: std.mem.Allocator,
    provider: *MeterProvider,

    pub fn init(allocator: std.mem.Allocator, provider: *MeterProvider) Prometheus {
        return .{ .allocator = allocator, .provider = provider };
    }

    /// Render the current metric snapshot as a Prometheus exposition
    /// payload. Caller owns the returned slice.
    pub fn render(self: *Prometheus) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);

        const datas = try sdk_metrics.collect(self.provider, self.allocator);
        defer {
            for (datas) |m| self.allocator.free(m.points);
            self.allocator.free(datas);
        }

        for (datas) |m| {
            const sanitized = try sanitize(self.allocator, m.name);
            defer self.allocator.free(sanitized);
            try buf.writer(self.allocator).print("# HELP {s} {s}\n", .{ sanitized, m.description });
            const promkind: []const u8 = switch (m.kind) {
                .counter, .observable_counter => "counter",
                .histogram => "histogram",
                .gauge, .observable_gauge => "gauge",
                .up_down_counter, .observable_up_down_counter => "gauge",
            };
            try buf.writer(self.allocator).print("# TYPE {s} {s}\n", .{ sanitized, promkind });
            for (m.points) |pt| {
                switch (pt.value) {
                    .number => |n| {
                        try buf.appendSlice(self.allocator, sanitized);
                        try writeLabels(self.allocator, &buf, pt.attributes);
                        try buf.append(self.allocator, ' ');
                        switch (n) {
                            .int => |i| try buf.writer(self.allocator).print("{d}", .{i}),
                            .double => |d| try buf.writer(self.allocator).print("{d}", .{d}),
                        }
                        try buf.append(self.allocator, '\n');
                    },
                    .histogram => |h| {
                        // _count, _sum, _bucket family.
                        try buf.appendSlice(self.allocator, sanitized);
                        try buf.appendSlice(self.allocator, "_count");
                        try writeLabels(self.allocator, &buf, pt.attributes);
                        try buf.writer(self.allocator).print(" {d}\n", .{h.count});
                        try buf.appendSlice(self.allocator, sanitized);
                        try buf.appendSlice(self.allocator, "_sum");
                        try writeLabels(self.allocator, &buf, pt.attributes);
                        try buf.writer(self.allocator).print(" {d}\n", .{h.sum});

                        for (h.bounds, 0..) |b, idx| {
                            try buf.appendSlice(self.allocator, sanitized);
                            try buf.appendSlice(self.allocator, "_bucket");
                            try writeBucketLabels(self.allocator, &buf, pt.attributes, b);
                            try buf.writer(self.allocator).print(" {d}\n", .{h.counts[idx]});
                        }
                        // +Inf bucket
                        try buf.appendSlice(self.allocator, sanitized);
                        try buf.appendSlice(self.allocator, "_bucket");
                        try writeBucketLabelsInf(self.allocator, &buf, pt.attributes);
                        try buf.writer(self.allocator).print(" {d}\n", .{h.count});
                    },
                }
            }
        }
        return try self.allocator.dupe(u8, buf.items);
    }
};

fn sanitize(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, name.len);
    for (name, 0..) |c, i| {
        out[i] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => c,
            else => '_',
        };
    }
    return out;
}

fn writeLabels(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), attrs_opt: ?*const attrs_mod.AttributeSet) !void {
    const a = attrs_opt orelse return;
    if (a.entries.items.len == 0) return;
    try buf.append(allocator, '{');
    for (a.entries.items, 0..) |entry, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, entry.key);
        try buf.append(allocator, '=');
        try buf.append(allocator, '"');
        try writeStringValue(allocator, buf, entry.value);
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, '}');
}

fn writeBucketLabels(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), attrs_opt: ?*const attrs_mod.AttributeSet, le: f64) !void {
    try buf.append(allocator, '{');
    if (attrs_opt) |a| {
        for (a.entries.items) |entry| {
            try buf.appendSlice(allocator, entry.key);
            try buf.append(allocator, '=');
            try buf.append(allocator, '"');
            try writeStringValue(allocator, buf, entry.value);
            try buf.append(allocator, '"');
            try buf.append(allocator, ',');
        }
    }
    try buf.appendSlice(allocator, "le=\"");
    try buf.writer(allocator).print("{d}", .{le});
    try buf.appendSlice(allocator, "\"}");
}

fn writeBucketLabelsInf(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), attrs_opt: ?*const attrs_mod.AttributeSet) !void {
    try buf.append(allocator, '{');
    if (attrs_opt) |a| {
        for (a.entries.items) |entry| {
            try buf.appendSlice(allocator, entry.key);
            try buf.append(allocator, '=');
            try buf.append(allocator, '"');
            try writeStringValue(allocator, buf, entry.value);
            try buf.append(allocator, '"');
            try buf.append(allocator, ',');
        }
    }
    try buf.appendSlice(allocator, "le=\"+Inf\"}");
}

fn writeStringValue(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), v: attrs_mod.Value) !void {
    switch (v) {
        .string => |s| try buf.appendSlice(allocator, s),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .int => |i| try buf.writer(allocator).print("{d}", .{i}),
        .double => |d| try buf.writer(allocator).print("{d}", .{d}),
        else => try buf.appendSlice(allocator, "<array>"),
    }
}
