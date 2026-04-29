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
const redact = @import("../internal/redact.zig");
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
        defer sdk_metrics.freeSnapshot(self.allocator, datas);

        for (datas) |m| {
            const sanitized = try sanitize(self.allocator, m.name);
            defer self.allocator.free(sanitized);
            // Zig 0.16: std.ArrayList uses the allocator-passing (unmanaged)
            // shape; there is no .writer() method. Use .print(gpa, fmt, args).
            try buf.print(self.allocator, "# HELP {s} {s}\n", .{ sanitized, m.description });
            const promkind: []const u8 = switch (m.kind) {
                .counter, .observable_counter => "counter",
                .histogram => "histogram",
                .gauge, .observable_gauge => "gauge",
                .up_down_counter, .observable_up_down_counter => "gauge",
            };
            try buf.print(self.allocator, "# TYPE {s} {s}\n", .{ sanitized, promkind });
            for (m.points) |pt| {
                switch (pt.value) {
                    .number => |n| {
                        try buf.appendSlice(self.allocator, sanitized);
                        try writeLabels(self.allocator, &buf, pt.attributes);
                        try buf.append(self.allocator, ' ');
                        switch (n) {
                            .int => |i| try buf.print(self.allocator, "{d}", .{i}),
                            .double => |d| try buf.print(self.allocator, "{d}", .{d}),
                        }
                        try buf.append(self.allocator, '\n');
                    },
                    .histogram => |h| {
                        // _count, _sum, _bucket family.
                        try buf.appendSlice(self.allocator, sanitized);
                        try buf.appendSlice(self.allocator, "_count");
                        try writeLabels(self.allocator, &buf, pt.attributes);
                        try buf.print(self.allocator, " {d}\n", .{h.count});
                        try buf.appendSlice(self.allocator, sanitized);
                        try buf.appendSlice(self.allocator, "_sum");
                        try writeLabels(self.allocator, &buf, pt.attributes);
                        try buf.print(self.allocator, " {d}\n", .{h.sum});

                        for (h.bounds, 0..) |b, idx| {
                            try buf.appendSlice(self.allocator, sanitized);
                            try buf.appendSlice(self.allocator, "_bucket");
                            try writeBucketLabels(self.allocator, &buf, pt.attributes, b);
                            try buf.print(self.allocator, " {d}\n", .{h.counts[idx]});
                        }
                        // +Inf bucket
                        try buf.appendSlice(self.allocator, sanitized);
                        try buf.appendSlice(self.allocator, "_bucket");
                        try writeBucketLabelsInf(self.allocator, &buf, pt.attributes);
                        try buf.print(self.allocator, " {d}\n", .{h.count});
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

/// Sanitise a Prometheus label *name* per `[a-zA-Z_][a-zA-Z0-9_]*`.
/// Bytes outside the allowed set become `_`. If the first byte is a
/// digit, an `_` prefix is prepended so the result still matches the
/// regex. Caller owns the returned slice.
pub fn sanitiseLabelName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (name.len == 0) return allocator.dupe(u8, "_");
    const needs_prefix = name[0] >= '0' and name[0] <= '9';
    const out = try allocator.alloc(u8, name.len + @as(usize, if (needs_prefix) 1 else 0));
    var oi: usize = 0;
    if (needs_prefix) {
        out[0] = '_';
        oi = 1;
    }
    for (name) |c| {
        out[oi] = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_' => c,
            else => '_',
        };
        oi += 1;
    }
    return out;
}

/// Escape a Prometheus label *value* per the 0.0.4 text format:
///   `\\` -> `\\\\`,  `"` -> `\\"`,  `\n` -> `\\n`.
/// Caller owns the returned slice.
pub fn escapeLabelValue(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    // Worst case: every byte expands to 2 chars (e.g. all backslashes).
    var out = try std.ArrayList(u8).initCapacity(allocator, value.len);
    errdefer out.deinit(allocator);
    for (value) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            else => try out.append(allocator, c),
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn writeLabelKey(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8) !void {
    const sanitised = try sanitiseLabelName(allocator, key);
    defer allocator.free(sanitised);
    try buf.appendSlice(allocator, sanitised);
}

fn writeLabels(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), attrs_opt: ?*const attrs_mod.AttributeSet) !void {
    const a = attrs_opt orelse return;
    if (a.entries.items.len == 0) return;
    try buf.append(allocator, '{');
    for (a.entries.items, 0..) |entry, i| {
        if (i > 0) try buf.append(allocator, ',');
        try writeLabelKey(allocator, buf, entry.key);
        try buf.append(allocator, '=');
        try buf.append(allocator, '"');
        try writeStringValue(allocator, buf, entry.key, entry.value);
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, '}');
}

fn writeBucketLabels(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), attrs_opt: ?*const attrs_mod.AttributeSet, le: f64) !void {
    try buf.append(allocator, '{');
    if (attrs_opt) |a| {
        for (a.entries.items) |entry| {
            try writeLabelKey(allocator, buf, entry.key);
            try buf.append(allocator, '=');
            try buf.append(allocator, '"');
            try writeStringValue(allocator, buf, entry.key, entry.value);
            try buf.append(allocator, '"');
            try buf.append(allocator, ',');
        }
    }
    try buf.appendSlice(allocator, "le=\"");
    try buf.print(allocator, "{d}", .{le});
    try buf.appendSlice(allocator, "\"}");
}

fn writeBucketLabelsInf(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), attrs_opt: ?*const attrs_mod.AttributeSet) !void {
    try buf.append(allocator, '{');
    if (attrs_opt) |a| {
        for (a.entries.items) |entry| {
            try writeLabelKey(allocator, buf, entry.key);
            try buf.append(allocator, '=');
            try buf.append(allocator, '"');
            try writeStringValue(allocator, buf, entry.key, entry.value);
            try buf.append(allocator, '"');
            try buf.append(allocator, ',');
        }
    }
    try buf.appendSlice(allocator, "le=\"+Inf\"}");
}

/// GAP-SEC-H-6: redact the value when the key matches the sensitive
/// taxonomy. Strings are then escaped per the Prometheus 0.0.4 text
/// format. Non-string values pass through unchanged — there's no
/// secret-shape attack on numerics or booleans.
fn writeStringValue(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, v: attrs_mod.Value) !void {
    switch (v) {
        .string => |s| {
            const masked = redact.maskString(key, s);
            const escaped = try escapeLabelValue(allocator, masked);
            defer allocator.free(escaped);
            try buf.appendSlice(allocator, escaped);
        },
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .int => |i| try buf.print(allocator, "{d}", .{i}),
        .double => |d| try buf.print(allocator, "{d}", .{d}),
        else => try buf.appendSlice(allocator, "<array>"),
    }
}
