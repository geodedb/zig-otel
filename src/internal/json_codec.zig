// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Stable JSON shape for telemetry data. Used by the stdout/file exporters
// and (with a wrapping object) by the golden harness.
//
// The schema is deterministic — attributes and resource keys are
// alphabetically sorted, every string is JSON-escaped, and every numeric
// value is emitted in a way that round-trips through `json.parse`.

const std = @import("std");
const exp = @import("../sdk/export.zig");
const trace_api = @import("../api/trace.zig");
const logs_api = @import("../api/logs.zig");
const attrs_mod = @import("attributes.zig");
const id_mod = @import("id.zig");
const ctx_mod = @import("../api/context.zig");
const Resource = @import("../sdk/resource.zig").Resource;
const redact = @import("redact.zig");

pub fn spanToJson(arena: std.mem.Allocator, span: exp.SpanData) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);

    try buf.append(arena, '{');
    try writeKeyString(arena, &buf, "trace_id", &hexBuf32(span.span_context.trace_id));
    try buf.append(arena, ',');
    try writeKeyString(arena, &buf, "span_id", &hexBuf16(span.span_context.span_id));
    try buf.append(arena, ',');
    try writeKey(arena, &buf, "parent_span_id");
    if (span.parent_span_id.isValid()) {
        try writeJsonString(arena, &buf, &hexBuf16(span.parent_span_id));
    } else {
        try writeJsonString(arena, &buf, "");
    }
    try buf.append(arena, ',');
    try writeKeyString(arena, &buf, "name", span.name);
    try buf.append(arena, ',');
    try writeKeyString(arena, &buf, "kind", span.kind.toString());
    try buf.append(arena, ',');
    try writeKeyU64(arena, &buf, "start_unix_nano", span.start_unix_nano);
    try buf.append(arena, ',');
    try writeKeyU64(arena, &buf, "end_unix_nano", span.end_unix_nano);
    try buf.append(arena, ',');
    try writeKeyString(arena, &buf, "status", span.status_code.toString());
    try buf.append(arena, ',');
    try writeKey(arena, &buf, "attributes");
    try writeAttributes(arena, &buf, span.attributes);
    try buf.append(arena, '}');
    return try arena.dupe(u8, buf.items);
}

pub fn metricToJson(arena: std.mem.Allocator, metric: exp.MetricData) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);
    try buf.append(arena, '{');
    try writeKeyString(arena, &buf, "name", metric.name);
    try buf.append(arena, ',');
    try writeKeyString(arena, &buf, "temporality", switch (metric.temporality) {
        .cumulative => "cumulative",
        .delta => "delta",
    });
    try buf.append(arena, ',');
    try writeKey(arena, &buf, "is_monotonic");
    try buf.appendSlice(arena, if (metric.is_monotonic) "true" else "false");
    try buf.append(arena, ',');
    try writeKey(arena, &buf, "points");
    try buf.append(arena, '[');
    for (metric.points, 0..) |pt, idx| {
        if (idx > 0) try buf.append(arena, ',');
        try writePoint(arena, &buf, pt);
    }
    try buf.append(arena, ']');
    try buf.append(arena, '}');
    return try arena.dupe(u8, buf.items);
}

pub fn logToJson(arena: std.mem.Allocator, l: exp.LogData) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena);
    try buf.append(arena, '{');
    try writeKeyString(arena, &buf, "trace_id", &hexBuf32(l.record.trace_id));
    try buf.append(arena, ',');
    try writeKeyString(arena, &buf, "span_id", &hexBuf16(l.record.span_id));
    try buf.append(arena, ',');
    try writeKeyString(arena, &buf, "severity", l.record.severity.shortText());
    try buf.append(arena, ',');
    try writeKey(arena, &buf, "body");
    try writeBody(arena, &buf, l.record.body);
    try buf.append(arena, ',');
    try writeKeyU64(arena, &buf, "time_unix_nano", l.record.timestamp_unix_nano);
    try buf.append(arena, ',');
    try writeKey(arena, &buf, "attributes");
    if (l.record.attributes) |a| {
        try writeAttributes(arena, &buf, a);
    } else {
        try buf.appendSlice(arena, "{}");
    }
    try buf.append(arena, '}');
    return try arena.dupe(u8, buf.items);
}

pub fn writePoint(arena: std.mem.Allocator, buf: *std.ArrayList(u8), pt: exp.DataPoint) !void {
    try buf.append(arena, '{');
    switch (pt.value) {
        .number => |n| switch (n) {
            .int => |i| {
                try writeKey(arena, buf, "as_int");
                try writeI64(arena, buf, i);
            },
            .double => |d| {
                try writeKey(arena, buf, "as_double");
                try writeF64(arena, buf, d);
            },
        },
        .histogram => |h| {
            try writeKeyU64(arena, buf, "count", h.count);
            try buf.append(arena, ',');
            try writeKey(arena, buf, "sum");
            try writeF64(arena, buf, h.sum);
            try buf.append(arena, ',');
            try writeKey(arena, buf, "bounds");
            try buf.append(arena, '[');
            for (h.bounds, 0..) |b, j| {
                if (j > 0) try buf.append(arena, ',');
                try writeF64(arena, buf, b);
            }
            try buf.append(arena, ']');
            try buf.append(arena, ',');
            try writeKey(arena, buf, "counts");
            try buf.append(arena, '[');
            for (h.counts, 0..) |c, j| {
                if (j > 0) try buf.append(arena, ',');
                try writeU64(arena, buf, c);
            }
            try buf.append(arena, ']');
        },
    }
    try buf.append(arena, ',');
    try writeKeyU64(arena, buf, "time_unix_nano", pt.time_unix_nano);
    try buf.append(arena, ',');
    try writeKey(arena, buf, "attributes");
    if (pt.attributes) |a| {
        try writeAttributes(arena, buf, a);
    } else {
        try buf.appendSlice(arena, "{}");
    }
    try buf.append(arena, '}');
}

pub fn writeResource(arena: std.mem.Allocator, buf: *std.ArrayList(u8), resource: *const Resource) !void {
    try writeAttributes(arena, buf, &resource.attributes);
}

pub fn writeAttributes(arena: std.mem.Allocator, buf: *std.ArrayList(u8), set: *const attrs_mod.AttributeSet) !void {
    try buf.append(arena, '{');
    const sorted = try set.sortedEntries(arena);
    defer arena.free(sorted);
    for (sorted, 0..) |entry, i| {
        if (i > 0) try buf.append(arena, ',');
        try writeKey(arena, buf, entry.key);
        try writeValueRedacted(arena, buf, entry.key, entry.value);
    }
    try buf.append(arena, '}');
}

/// GAP-SEC-H-6 / GAP-SEC-L-4: route every string attribute value through
/// the redactor so sensitive keys (password / token / api.key /
/// authorization / credential, plus their separator-tolerant variants)
/// emit `[REDACTED]` instead of the actual secret.
fn writeValueRedacted(arena: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, v: attrs_mod.Value) !void {
    switch (v) {
        .string => |s| try writeJsonString(arena, buf, redact.maskString(key, s)),
        .bool => |b| try buf.appendSlice(arena, if (b) "true" else "false"),
        .int => |i| try writeI64(arena, buf, i),
        .double => |d| try writeF64(arena, buf, d),
        else => try buf.appendSlice(arena, "null"),
    }
}

fn writeValue(arena: std.mem.Allocator, buf: *std.ArrayList(u8), v: attrs_mod.Value) !void {
    switch (v) {
        .string => |s| try writeJsonString(arena, buf, s),
        .bool => |b| try buf.appendSlice(arena, if (b) "true" else "false"),
        .int => |i| try writeI64(arena, buf, i),
        .double => |d| try writeF64(arena, buf, d),
        else => try buf.appendSlice(arena, "null"),
    }
}

fn writeBody(arena: std.mem.Allocator, buf: *std.ArrayList(u8), body: logs_api.Body) !void {
    switch (body) {
        .string => |s| try writeJsonString(arena, buf, s),
        .bool => |b| try buf.appendSlice(arena, if (b) "true" else "false"),
        .int => |i| try writeI64(arena, buf, i),
        .double => |d| try writeF64(arena, buf, d),
        .none => try buf.appendSlice(arena, "null"),
    }
}

pub fn writeKey(arena: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8) !void {
    try writeJsonString(arena, buf, key);
    try buf.append(arena, ':');
}

pub fn writeKeyString(arena: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: []const u8) !void {
    try writeKey(arena, buf, key);
    try writeJsonString(arena, buf, value);
}

pub fn writeKeyU64(arena: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, value: u64) !void {
    try writeKey(arena, buf, key);
    try writeU64(arena, buf, value);
}

pub fn writeU64(arena: std.mem.Allocator, buf: *std.ArrayList(u8), value: u64) !void {
    var tmp: [24]u8 = undefined;
    const out = try std.fmt.bufPrint(tmp[0..], "{d}", .{value});
    try buf.appendSlice(arena, out);
}

pub fn writeI64(arena: std.mem.Allocator, buf: *std.ArrayList(u8), value: i64) !void {
    var tmp: [24]u8 = undefined;
    const out = try std.fmt.bufPrint(tmp[0..], "{d}", .{value});
    try buf.appendSlice(arena, out);
}

pub fn writeF64(arena: std.mem.Allocator, buf: *std.ArrayList(u8), value: f64) !void {
    var tmp: [40]u8 = undefined;
    const out = try std.fmt.bufPrint(tmp[0..], "{d}", .{value});
    try buf.appendSlice(arena, out);
}

pub fn writeJsonString(arena: std.mem.Allocator, buf: *std.ArrayList(u8), value: []const u8) !void {
    try buf.append(arena, '"');
    for (value) |c| {
        switch (c) {
            '"' => try buf.appendSlice(arena, "\\\""),
            '\\' => try buf.appendSlice(arena, "\\\\"),
            '\n' => try buf.appendSlice(arena, "\\n"),
            '\r' => try buf.appendSlice(arena, "\\r"),
            '\t' => try buf.appendSlice(arena, "\\t"),
            0x08 => try buf.appendSlice(arena, "\\b"),
            0x0c => try buf.appendSlice(arena, "\\f"),
            0x00...0x07, 0x0b, 0x0e...0x1f => {
                var tmp: [6]u8 = undefined;
                const out = try std.fmt.bufPrint(tmp[0..], "\\u{x:0>4}", .{c});
                try buf.appendSlice(arena, out);
            },
            else => try buf.append(arena, c),
        }
    }
    try buf.append(arena, '"');
}

pub fn hexBuf32(t: id_mod.TraceId) [32]u8 {
    return t.toHex();
}

pub fn hexBuf16(s: id_mod.SpanId) [16]u8 {
    return s.toHex();
}

test "writeJsonString escapes control characters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(arena.allocator());
    try writeJsonString(arena.allocator(), &buf, "a\"b\nc\u{1}");
    try std.testing.expectEqualStrings("\"a\\\"b\\nc\\u0001\"", buf.items);
}
