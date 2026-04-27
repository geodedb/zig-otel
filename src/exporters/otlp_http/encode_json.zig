// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// JSON encoders for OTLP spans and metrics.
//
// Split out of `src/exporters/otlp_http.zig` as part of OTEL-Q-001
// (gitlab #149). Hosts:
//   - `encodeMetricsJson` (DevNW + stdlib paths fronted by a single
//     dispatcher that routes on `build_options.use_devnw_json`).
//   - `encodeSpansJson` (same shape: DevNW wrapper around
//     `json_codec.spanToJson`, stdlib fallback assembles the same
//     envelope by hand).
//
// Behaviour is preserved bit-for-bit relative to the pre-split file;
// this is a refactor commit only.

const std = @import("std");
const exp = @import("../../sdk/export.zig");
const otlp = @import("../../generated/otlp.zig");
const trace_api = @import("../../api/trace.zig");
const attrs_mod = @import("../../internal/attributes.zig");
const redact = @import("../../internal/redact.zig");
const json_codec = @import("../../internal/json_codec.zig");
const build_options = @import("build_options");
const devnw_json = if (build_options.use_devnw_json) @import("json") else struct {};

// ---------------------------------------------------------------- Metric grouping
//
// Local copy of the metric ScopeBucket. The proto encoder has its own
// (also internal). Sharing across modules would tangle visibility for a
// helper that's < 25 LOC; keep the duplication to keep the surface
// inert.
const ScopeBucket = struct {
    scope: trace_api.InstrumentationScope,
    metrics: std.ArrayList(*const exp.MetricData),
};

fn groupByScope(arena: std.mem.Allocator, items: []const exp.MetricData) ![]ScopeBucket {
    var buckets: std.ArrayList(ScopeBucket) = .empty;
    for (items) |*m| {
        var found: ?usize = null;
        for (buckets.items, 0..) |b, i| {
            if (std.mem.eql(u8, b.scope.name, m.instrumentation_scope.name) and
                std.mem.eql(u8, b.scope.version, m.instrumentation_scope.version))
            {
                found = i;
                break;
            }
        }
        if (found) |idx| {
            try buckets.items[idx].metrics.append(arena, m);
        } else {
            var b: ScopeBucket = .{ .scope = m.instrumentation_scope, .metrics = .empty };
            try b.metrics.append(arena, m);
            try buckets.append(arena, b);
        }
    }
    return buckets.toOwnedSlice(arena);
}

// ---------------------------------------------------------------- Metric JSON
//
// OTLP/JSON metric encoder. Routes through DevNW `../json` (the sibling
// dependency) when `-Dotel_use_devnw_json=true`; otherwise falls back to
// a small hand-written writer that produces the same shape. Every large
// integer (start_time_unix_nano, time_unix_nano, as_int, count,
// bucket_counts) is serialized as a JSON string per OTLP/JSON
// recommendation — JSON's 53-bit number range can't carry a u64 without
// loss.
pub fn encodeMetricsJson(allocator: std.mem.Allocator, items: []const exp.MetricData) ![]u8 {
    if (build_options.use_devnw_json) {
        return encodeMetricsJsonDevnw(allocator, items);
    }
    return encodeMetricsJsonStd(allocator, items);
}

fn encodeMetricsJsonDevnw(allocator: std.mem.Allocator, items: []const exp.MetricData) ![]u8 {
    var bucket_arena = std.heap.ArenaAllocator.init(allocator);
    defer bucket_arena.deinit();
    const ba = bucket_arena.allocator();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var enc = devnw_json.streamingEncoder(allocator, &aw.writer, .{});
    defer enc.deinit();

    try enc.beginObject();
    try enc.writeKey("resourceMetrics");
    try enc.beginArray();
    if (items.len > 0) {
        try enc.beginObject();

        try enc.writeKey("resource");
        try enc.beginObject();
        try enc.writeKey("attributes");
        try enc.beginArray();
        for (items[0].resource.attributes.entries.items) |kv| {
            try writeJsonAttributeStreaming(&enc, kv);
        }
        try enc.endArray();
        try enc.endObject();

        const buckets = try groupByScope(ba, items);
        try enc.writeKey("scopeMetrics");
        try enc.beginArray();
        for (buckets) |bucket| {
            try enc.beginObject();
            try enc.writeKey("scope");
            try enc.beginObject();
            try enc.writeKey("name");
            try enc.writeString(bucket.scope.name);
            try enc.writeKey("version");
            try enc.writeString(bucket.scope.version);
            try enc.endObject();

            try enc.writeKey("metrics");
            try enc.beginArray();
            for (bucket.metrics.items) |m_ptr| {
                try writeMetricJsonStreaming(&enc, m_ptr.*);
            }
            try enc.endArray();
            try enc.endObject();
        }
        try enc.endArray();

        try enc.endObject();
    }
    try enc.endArray();
    try enc.endObject();
    return try aw.toOwnedSlice();
}

fn writeJsonAttributeStreaming(enc: anytype, kv: attrs_mod.Entry) !void {
    try enc.beginObject();
    try enc.writeKey("key");
    try enc.writeString(kv.key);
    try enc.writeKey("value");
    try enc.beginObject();
    switch (kv.value) {
        .string => |s| {
            try enc.writeKey("stringValue");
            try enc.writeString(redact.maskString(kv.key, s));
        },
        .bool => |b| {
            try enc.writeKey("boolValue");
            try enc.writeBool(b);
        },
        .int => |i| {
            // OTLP/JSON: int64 fields are encoded as strings.
            try enc.writeKey("intValue");
            var buf: [24]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{i});
            try enc.writeString(s);
        },
        .double => |d| {
            try enc.writeKey("doubleValue");
            try enc.writeFloat(d);
        },
        else => {},
    }
    try enc.endObject();
    try enc.endObject();
}

fn writeMetricJsonStreaming(enc: anytype, m: exp.MetricData) !void {
    try enc.beginObject();
    try enc.writeKey("name");
    try enc.writeString(m.name);
    try enc.writeKey("description");
    try enc.writeString(m.description);
    try enc.writeKey("unit");
    try enc.writeString(m.unit);

    const temp_value: u8 = switch (m.temporality) {
        .cumulative => @intCast(otlp.aggregation_temporality_cumulative),
        .delta => @intCast(otlp.aggregation_temporality_delta),
    };

    switch (m.kind) {
        .counter, .up_down_counter, .observable_counter, .observable_up_down_counter => {
            try enc.writeKey("sum");
            try enc.beginObject();
            try writeNumberPointsJson(enc, m.points);
            try enc.writeKey("aggregationTemporality");
            try enc.writeInt(temp_value);
            try enc.writeKey("isMonotonic");
            try enc.writeBool(m.is_monotonic);
            try enc.endObject();
        },
        .gauge, .observable_gauge => {
            try enc.writeKey("gauge");
            try enc.beginObject();
            try writeNumberPointsJson(enc, m.points);
            try enc.endObject();
        },
        .histogram => {
            try enc.writeKey("histogram");
            try enc.beginObject();
            try enc.writeKey("dataPoints");
            try enc.beginArray();
            for (m.points) |pt| try writeHistogramPointJson(enc, pt);
            try enc.endArray();
            try enc.writeKey("aggregationTemporality");
            try enc.writeInt(temp_value);
            try enc.endObject();
        },
    }
    try enc.endObject();
}

fn writeNumberPointsJson(enc: anytype, points: []const exp.DataPoint) !void {
    try enc.writeKey("dataPoints");
    try enc.beginArray();
    for (points) |pt| try writeNumberPointJson(enc, pt);
    try enc.endArray();
}

fn writeNumberPointJson(enc: anytype, pt: exp.DataPoint) !void {
    try enc.beginObject();
    if (pt.attributes) |a| {
        try enc.writeKey("attributes");
        try enc.beginArray();
        for (a.entries.items) |kv| try writeJsonAttributeStreaming(enc, kv);
        try enc.endArray();
    }
    try writeJsonU64String(enc, "startTimeUnixNano", pt.start_unix_nano);
    try writeJsonU64String(enc, "timeUnixNano", pt.time_unix_nano);
    switch (pt.value) {
        .number => |n| switch (n) {
            .int => |v| {
                try enc.writeKey("asInt");
                var buf: [24]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
                try enc.writeString(s);
            },
            .double => |v| {
                try enc.writeKey("asDouble");
                try enc.writeFloat(v);
            },
        },
        .histogram => {},
    }
    try enc.endObject();
}

fn writeHistogramPointJson(enc: anytype, pt: exp.DataPoint) !void {
    try enc.beginObject();
    if (pt.attributes) |a| {
        try enc.writeKey("attributes");
        try enc.beginArray();
        for (a.entries.items) |kv| try writeJsonAttributeStreaming(enc, kv);
        try enc.endArray();
    }
    try writeJsonU64String(enc, "startTimeUnixNano", pt.start_unix_nano);
    try writeJsonU64String(enc, "timeUnixNano", pt.time_unix_nano);
    switch (pt.value) {
        .histogram => |h| {
            try writeJsonU64String(enc, "count", h.count);
            try enc.writeKey("sum");
            try enc.writeFloat(h.sum);
            try enc.writeKey("bucketCounts");
            try enc.beginArray();
            for (h.counts) |c| {
                var buf: [24]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "{d}", .{c});
                try enc.writeString(s);
            }
            try enc.endArray();
            try enc.writeKey("explicitBounds");
            try enc.beginArray();
            for (h.bounds) |b| try enc.writeFloat(b);
            try enc.endArray();
            if (h.min) |m| {
                try enc.writeKey("min");
                try enc.writeFloat(m);
            }
            if (h.max) |m| {
                try enc.writeKey("max");
                try enc.writeFloat(m);
            }
        },
        .number => {},
    }
    try enc.endObject();
}

fn writeJsonU64String(enc: anytype, key: []const u8, v: u64) !void {
    try enc.writeKey(key);
    var buf: [24]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
    try enc.writeString(s);
}

// Stdlib-only JSON fallback. Hand-rolled to avoid pulling in `../json` on
// builds that opt out via `-Dotel_use_devnw_json=false`. The output shape
// is byte-identical to the DevNW path for the same input (collectors care
// about shape, not whitespace).
fn encodeMetricsJsonStd(allocator: std.mem.Allocator, items: []const exp.MetricData) ![]u8 {
    var bucket_arena = std.heap.ArenaAllocator.init(allocator);
    defer bucket_arena.deinit();
    const ba = bucket_arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"resourceMetrics\":[");
    if (items.len > 0) {
        try buf.append(allocator, '{');
        try buf.appendSlice(allocator, "\"resource\":{\"attributes\":[");
        for (items[0].resource.attributes.entries.items, 0..) |kv, i| {
            if (i > 0) try buf.append(allocator, ',');
            try writeJsonAttributeStd(allocator, &buf, kv);
        }
        try buf.appendSlice(allocator, "]},\"scopeMetrics\":[");
        const buckets = try groupByScope(ba, items);
        for (buckets, 0..) |bucket, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"scope\":{\"name\":");
            try writeJsonStringStd(allocator, &buf, bucket.scope.name);
            try buf.appendSlice(allocator, ",\"version\":");
            try writeJsonStringStd(allocator, &buf, bucket.scope.version);
            try buf.appendSlice(allocator, "},\"metrics\":[");
            for (bucket.metrics.items, 0..) |m_ptr, j| {
                if (j > 0) try buf.append(allocator, ',');
                try writeMetricJsonStd(allocator, &buf, m_ptr.*);
            }
            try buf.appendSlice(allocator, "]}");
        }
        try buf.appendSlice(allocator, "]}");
    }
    try buf.appendSlice(allocator, "]}");
    return try allocator.dupe(u8, buf.items);
}

fn writeJsonStringStd(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x00...0x07, 0x0b, 0x0c, 0x0e...0x1f => {
                var tmp: [8]u8 = undefined;
                const out = try std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c});
                try buf.appendSlice(allocator, out);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

fn writeJsonU64StringStd(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, v: u64) !void {
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, key);
    try buf.appendSlice(allocator, "\":\"");
    var num_buf: [24]u8 = undefined;
    const s = try std.fmt.bufPrint(&num_buf, "{d}", .{v});
    try buf.appendSlice(allocator, s);
    try buf.append(allocator, '"');
}

fn writeJsonAttributeStd(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), kv: attrs_mod.Entry) !void {
    try buf.appendSlice(allocator, "{\"key\":");
    try writeJsonStringStd(allocator, buf, kv.key);
    try buf.appendSlice(allocator, ",\"value\":{");
    switch (kv.value) {
        .string => |s| {
            try buf.appendSlice(allocator, "\"stringValue\":");
            try writeJsonStringStd(allocator, buf, redact.maskString(kv.key, s));
        },
        .bool => |b| try buf.appendSlice(allocator, if (b) "\"boolValue\":true" else "\"boolValue\":false"),
        .int => |i| {
            try buf.appendSlice(allocator, "\"intValue\":\"");
            var num_buf: [24]u8 = undefined;
            const s = try std.fmt.bufPrint(&num_buf, "{d}", .{i});
            try buf.appendSlice(allocator, s);
            try buf.append(allocator, '"');
        },
        .double => |d| {
            try buf.appendSlice(allocator, "\"doubleValue\":");
            var num_buf: [40]u8 = undefined;
            const s = try std.fmt.bufPrint(&num_buf, "{d}", .{d});
            try buf.appendSlice(allocator, s);
        },
        else => {},
    }
    try buf.appendSlice(allocator, "}}");
}

fn writeMetricJsonStd(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), m: exp.MetricData) !void {
    try buf.append(allocator, '{');
    try buf.appendSlice(allocator, "\"name\":");
    try writeJsonStringStd(allocator, buf, m.name);
    try buf.appendSlice(allocator, ",\"description\":");
    try writeJsonStringStd(allocator, buf, m.description);
    try buf.appendSlice(allocator, ",\"unit\":");
    try writeJsonStringStd(allocator, buf, m.unit);

    const temp_value: u8 = switch (m.temporality) {
        .cumulative => @intCast(otlp.aggregation_temporality_cumulative),
        .delta => @intCast(otlp.aggregation_temporality_delta),
    };

    switch (m.kind) {
        .counter, .up_down_counter, .observable_counter, .observable_up_down_counter => {
            try buf.appendSlice(allocator, ",\"sum\":{\"dataPoints\":[");
            for (m.points, 0..) |pt, i| {
                if (i > 0) try buf.append(allocator, ',');
                try writeNumberPointJsonStd(allocator, buf, pt);
            }
            try buf.appendSlice(allocator, "],\"aggregationTemporality\":");
            var num_buf: [8]u8 = undefined;
            const s = try std.fmt.bufPrint(&num_buf, "{d}", .{temp_value});
            try buf.appendSlice(allocator, s);
            try buf.appendSlice(allocator, ",\"isMonotonic\":");
            try buf.appendSlice(allocator, if (m.is_monotonic) "true" else "false");
            try buf.append(allocator, '}');
        },
        .gauge, .observable_gauge => {
            try buf.appendSlice(allocator, ",\"gauge\":{\"dataPoints\":[");
            for (m.points, 0..) |pt, i| {
                if (i > 0) try buf.append(allocator, ',');
                try writeNumberPointJsonStd(allocator, buf, pt);
            }
            try buf.appendSlice(allocator, "]}");
        },
        .histogram => {
            try buf.appendSlice(allocator, ",\"histogram\":{\"dataPoints\":[");
            for (m.points, 0..) |pt, i| {
                if (i > 0) try buf.append(allocator, ',');
                try writeHistogramPointJsonStd(allocator, buf, pt);
            }
            try buf.appendSlice(allocator, "],\"aggregationTemporality\":");
            var num_buf: [8]u8 = undefined;
            const s = try std.fmt.bufPrint(&num_buf, "{d}", .{temp_value});
            try buf.appendSlice(allocator, s);
            try buf.append(allocator, '}');
        },
    }
    try buf.append(allocator, '}');
}

fn writeNumberPointJsonStd(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), pt: exp.DataPoint) !void {
    try buf.append(allocator, '{');
    var first = true;
    if (pt.attributes) |a| {
        try buf.appendSlice(allocator, "\"attributes\":[");
        for (a.entries.items, 0..) |kv, i| {
            if (i > 0) try buf.append(allocator, ',');
            try writeJsonAttributeStd(allocator, buf, kv);
        }
        try buf.append(allocator, ']');
        first = false;
    }
    if (!first) try buf.append(allocator, ',');
    try writeJsonU64StringStd(allocator, buf, "startTimeUnixNano", pt.start_unix_nano);
    try buf.append(allocator, ',');
    try writeJsonU64StringStd(allocator, buf, "timeUnixNano", pt.time_unix_nano);
    switch (pt.value) {
        .number => |n| switch (n) {
            .int => |v| {
                try buf.appendSlice(allocator, ",\"asInt\":\"");
                var num_buf: [24]u8 = undefined;
                const s = try std.fmt.bufPrint(&num_buf, "{d}", .{v});
                try buf.appendSlice(allocator, s);
                try buf.append(allocator, '"');
            },
            .double => |v| {
                try buf.appendSlice(allocator, ",\"asDouble\":");
                var num_buf: [40]u8 = undefined;
                const s = try std.fmt.bufPrint(&num_buf, "{d}", .{v});
                try buf.appendSlice(allocator, s);
            },
        },
        .histogram => {},
    }
    try buf.append(allocator, '}');
}

fn writeHistogramPointJsonStd(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), pt: exp.DataPoint) !void {
    try buf.append(allocator, '{');
    var first = true;
    if (pt.attributes) |a| {
        try buf.appendSlice(allocator, "\"attributes\":[");
        for (a.entries.items, 0..) |kv, i| {
            if (i > 0) try buf.append(allocator, ',');
            try writeJsonAttributeStd(allocator, buf, kv);
        }
        try buf.append(allocator, ']');
        first = false;
    }
    if (!first) try buf.append(allocator, ',');
    try writeJsonU64StringStd(allocator, buf, "startTimeUnixNano", pt.start_unix_nano);
    try buf.append(allocator, ',');
    try writeJsonU64StringStd(allocator, buf, "timeUnixNano", pt.time_unix_nano);
    switch (pt.value) {
        .histogram => |h| {
            try buf.append(allocator, ',');
            try writeJsonU64StringStd(allocator, buf, "count", h.count);
            try buf.appendSlice(allocator, ",\"sum\":");
            var num_buf: [40]u8 = undefined;
            var s = try std.fmt.bufPrint(&num_buf, "{d}", .{h.sum});
            try buf.appendSlice(allocator, s);
            try buf.appendSlice(allocator, ",\"bucketCounts\":[");
            for (h.counts, 0..) |c, i| {
                if (i > 0) try buf.append(allocator, ',');
                try buf.append(allocator, '"');
                s = try std.fmt.bufPrint(&num_buf, "{d}", .{c});
                try buf.appendSlice(allocator, s);
                try buf.append(allocator, '"');
            }
            try buf.appendSlice(allocator, "],\"explicitBounds\":[");
            for (h.bounds, 0..) |b, i| {
                if (i > 0) try buf.append(allocator, ',');
                s = try std.fmt.bufPrint(&num_buf, "{d}", .{b});
                try buf.appendSlice(allocator, s);
            }
            try buf.append(allocator, ']');
            if (h.min) |mv| {
                try buf.appendSlice(allocator, ",\"min\":");
                s = try std.fmt.bufPrint(&num_buf, "{d}", .{mv});
                try buf.appendSlice(allocator, s);
            }
            if (h.max) |mv| {
                try buf.appendSlice(allocator, ",\"max\":");
                s = try std.fmt.bufPrint(&num_buf, "{d}", .{mv});
                try buf.appendSlice(allocator, s);
            }
        },
        .number => {},
    }
    try buf.append(allocator, '}');
}

// ---------------------------------------------------------------- Span JSON

pub fn encodeSpansJson(allocator: std.mem.Allocator, items: []const exp.SpanData) ![]u8 {
    if (build_options.use_devnw_json) {
        return encodeSpansJsonDevnw(allocator, items);
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"resourceSpans\":[");
    for (items, 0..) |span, i| {
        if (i > 0) try buf.append(allocator, ',');
        const json = try json_codec.spanToJson(allocator, span);
        defer allocator.free(json);
        try buf.appendSlice(allocator, json);
    }
    try buf.appendSlice(allocator, "]}");
    return try allocator.dupe(u8, buf.items);
}

/// DevNW-routed JSON encoder. The per-span JSON still comes from the
/// in-repo `json_codec.spanToJson` (which gates exact byte-level golden
/// output), but the `{"resourceSpans":[...]}` wrapper is assembled by
/// DevNW's streaming `Encoder` via `writeRaw`. This routes the JSON path
/// through the dependency without disturbing the wire-shape contract.
fn encodeSpansJsonDevnw(allocator: std.mem.Allocator, items: []const exp.SpanData) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var enc = devnw_json.streamingEncoder(allocator, &aw.writer, .{});
    defer enc.deinit();

    try enc.beginObject();
    try enc.writeKey("resourceSpans");
    try enc.beginArray();
    for (items) |span| {
        const child = try json_codec.spanToJson(allocator, span);
        defer allocator.free(child);
        try enc.writeRaw(child);
    }
    try enc.endArray();
    try enc.endObject();

    // toOwnedSlice transfers the buffer to the caller without an extra dupe.
    return try aw.toOwnedSlice();
}
