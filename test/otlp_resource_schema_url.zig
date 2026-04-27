// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Regression test for GAP-OTLP-WIRE-SCHEMA-URL (#26) — `Resource.schema_url`
// must be emitted on the OTLP wire at `ResourceSpans.schema_url`
// (field 3) and `ResourceMetrics.schema_url` (field 3). Pre-fix the
// SDK tracked the value on the `Resource` struct but the encoders
// dropped it on the floor.
//
// Per `third_party/opentelemetry-proto-v1.10.0/opentelemetry/proto/...`:
//   - trace/v1/trace.proto:64    → ResourceSpans.schema_url   = 3
//   - metrics/v1/metrics.proto:82 → ResourceMetrics.schema_url = 3
//
// The test walks the encoded bytes with a minimal varint reader and
// asserts the schema_url value is present on the parent message —
// it does NOT confuse the existing ScopeSpans.schema_url emission,
// because ScopeSpans is field 2 inside the ResourceSpans payload and
// schema_url is read at the ResourceSpans level. The DevNW encoder
// path is exercised through `encodeSpansProtoDevnw` for byte parity
// (when the build flag is on).
//
// Acceptance criteria 4 — single-resource fast path stays
// byte-identical when schema_url is empty — is exercised by the
// existing parity test in `test/otlp_wire_parity.zig`; it would
// regress if this fix accidentally emitted a tag for an empty
// schema_url. `Writer.writeString` skips empty values (proto3
// default-omit), so the parity test continues to pin that contract.

const std = @import("std");
const otel = @import("otel");
const build_options = @import("build_options");

const SCHEMA_URL = "https://opentelemetry.io/schemas/1.32.0";

// ---------------- minimal protobuf reader ----------------

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn eof(self: *const Reader) bool {
        return self.pos >= self.buf.len;
    }

    fn readVarint(self: *Reader) !u64 {
        var v: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (self.pos >= self.buf.len) return error.Truncated;
            const b = self.buf[self.pos];
            self.pos += 1;
            v |= (@as(u64, b & 0x7f)) << shift;
            if (b & 0x80 == 0) return v;
            shift += 7;
            if (shift >= 64) return error.VarintOverflow;
        }
    }

    fn readTag(self: *Reader) !struct { field: u32, wire: u3 } {
        const tag = try self.readVarint();
        return .{
            .field = @intCast(tag >> 3),
            .wire = @intCast(tag & 0x7),
        };
    }

    fn readBytes(self: *Reader) ![]const u8 {
        const n = try self.readVarint();
        if (self.pos + n > self.buf.len) return error.Truncated;
        const out = self.buf[self.pos .. self.pos + @as(usize, @intCast(n))];
        self.pos += @intCast(n);
        return out;
    }

    fn skip(self: *Reader, wire: u3) !void {
        switch (wire) {
            0 => _ = try self.readVarint(),
            1 => {
                if (self.pos + 8 > self.buf.len) return error.Truncated;
                self.pos += 8;
            },
            2 => _ = try self.readBytes(),
            5 => {
                if (self.pos + 4 > self.buf.len) return error.Truncated;
                self.pos += 4;
            },
            else => return error.UnsupportedWireType,
        }
    }
};

// Walk a single ResourceSpans payload (field 1 of the encoded batch)
// and return the bytes of `schema_url` (field 3) at the
// ResourceSpans level. Returns null when the field is absent so
// callers can pin both the "set" and "unset / empty" cases.
fn extractResourceSpansSchemaUrl(payload: []const u8) !?[]const u8 {
    var top: Reader = .{ .buf = payload };
    while (!top.eof()) {
        const tag = try top.readTag();
        if (tag.field == 1 and tag.wire == 2) {
            const rs_bytes = try top.readBytes();
            var rs: Reader = .{ .buf = rs_bytes };
            while (!rs.eof()) {
                const rt = try rs.readTag();
                if (rt.field == 3 and rt.wire == 2) {
                    return try rs.readBytes();
                }
                try rs.skip(rt.wire);
            }
            return null;
        }
        try top.skip(tag.wire);
    }
    return null;
}

fn extractResourceMetricsSchemaUrl(payload: []const u8) !?[]const u8 {
    var top: Reader = .{ .buf = payload };
    while (!top.eof()) {
        const tag = try top.readTag();
        if (tag.field == 1 and tag.wire == 2) {
            const rm_bytes = try top.readBytes();
            var rm: Reader = .{ .buf = rm_bytes };
            while (!rm.eof()) {
                const rt = try rm.readTag();
                if (rt.field == 3 and rt.wire == 2) {
                    return try rm.readBytes();
                }
                try rm.skip(rt.wire);
            }
            return null;
        }
        try top.skip(tag.wire);
    }
    return null;
}

// ---------------- tests ----------------

test "encodeSpansProto emits Resource.schema_url at ResourceSpans field 3" {
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    resource.schema_url = SCHEMA_URL;

    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();
    try attr_set.putString("k", "v");

    const span: otel.sdk.exporter.SpanData = .{
        .name = "demo",
        .span_context = .{
            .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
            .span_id = .{ .bytes = .{ 9, 8, 7, 6, 5, 4, 3, 2 } },
        },
        .start_unix_nano = 1_000,
        .end_unix_nano = 2_000,
        .attributes = &attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "tracer", .version = "1.0" },
        .resource = &resource,
    };

    const out = try otel.exporters.otlp_http.encodeSpansProto(a, &[_]otel.sdk.exporter.SpanData{span});
    defer a.free(out);

    const got = try extractResourceSpansSchemaUrl(out);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings(SCHEMA_URL, got.?);
}

test "encodeSpansProto omits ResourceSpans.schema_url when Resource.schema_url is empty" {
    // Acceptance criterion 4: proto3 default-omit. Empty string must
    // not produce a tag; the byte sequence stays identical to a batch
    // built without ever touching schema_url.
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();

    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();

    const span: otel.sdk.exporter.SpanData = .{
        .name = "demo",
        .span_context = .{
            .trace_id = .{ .bytes = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } },
            .span_id = .{ .bytes = .{ 1, 0, 0, 0, 0, 0, 0, 1 } },
        },
        .start_unix_nano = 1,
        .end_unix_nano = 2,
        .attributes = &attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "" },
        .resource = &resource,
    };

    const out = try otel.exporters.otlp_http.encodeSpansProto(a, &[_]otel.sdk.exporter.SpanData{span});
    defer a.free(out);

    const got = try extractResourceSpansSchemaUrl(out);
    try std.testing.expect(got == null);
}

test "encodeMetricsProto emits Resource.schema_url at ResourceMetrics field 3" {
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    resource.schema_url = SCHEMA_URL;

    const dp_attrs = otel.internal.attributes.AttributeSet.init(a);
    const points = [_]otel.sdk.exporter.DataPoint{.{
        .start_unix_nano = 0,
        .time_unix_nano = 1_000,
        .value = .{ .number = .{ .int = 7 } },
        .attributes = &dp_attrs,
    }};

    const metric: otel.sdk.exporter.MetricData = .{
        .name = "requests",
        .description = "",
        .unit = "",
        .kind = .counter,
        .temporality = .cumulative,
        .is_monotonic = true,
        .points = &points,
        .instrumentation_scope = .{ .name = "meter", .version = "1.0" },
        .resource = &resource,
    };

    const out = try otel.exporters.otlp_http.encodeMetricsProto(a, &[_]otel.sdk.exporter.MetricData{metric});
    defer a.free(out);

    const got = try extractResourceMetricsSchemaUrl(out);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings(SCHEMA_URL, got.?);
}

test "encodeMetricsProto omits ResourceMetrics.schema_url when Resource.schema_url is empty" {
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();

    const dp_attrs = otel.internal.attributes.AttributeSet.init(a);
    const points = [_]otel.sdk.exporter.DataPoint{.{
        .start_unix_nano = 0,
        .time_unix_nano = 1_000,
        .value = .{ .number = .{ .int = 1 } },
        .attributes = &dp_attrs,
    }};

    const metric: otel.sdk.exporter.MetricData = .{
        .name = "requests",
        .description = "",
        .unit = "",
        .kind = .counter,
        .temporality = .cumulative,
        .is_monotonic = true,
        .points = &points,
        .instrumentation_scope = .{ .name = "meter", .version = "1.0" },
        .resource = &resource,
    };

    const out = try otel.exporters.otlp_http.encodeMetricsProto(a, &[_]otel.sdk.exporter.MetricData{metric});
    defer a.free(out);

    const got = try extractResourceMetricsSchemaUrl(out);
    try std.testing.expect(got == null);
}

test "encodeSpansProtoDevnw emits Resource.schema_url at ResourceSpans field 3" {
    if (!build_options.use_devnw_protobuf) return error.SkipZigTest;
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    resource.schema_url = SCHEMA_URL;

    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();
    try attr_set.putString("k", "v");

    const span: otel.sdk.exporter.SpanData = .{
        .name = "demo",
        .span_context = .{
            .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
            .span_id = .{ .bytes = .{ 9, 8, 7, 6, 5, 4, 3, 2 } },
        },
        .start_unix_nano = 1_000,
        .end_unix_nano = 2_000,
        .attributes = &attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "tracer", .version = "1.0" },
        .resource = &resource,
    };

    const items = [_]otel.sdk.exporter.SpanData{span};
    const lhs = try otel.exporters.otlp_http.encodeSpansProto(a, &items);
    defer a.free(lhs);
    const rhs = try otel.exporters.otlp_http.encodeSpansProtoDevnw(a, &items);
    defer a.free(rhs);
    // Byte parity covers both the in-repo encoder's tag-3 emission and
    // the DevNW encoder's matching descriptor entry — without the
    // schema_url descriptor the DevNW path would silently omit it,
    // breaking this assertion.
    try std.testing.expectEqualSlices(u8, lhs, rhs);

    const got = try extractResourceSpansSchemaUrl(rhs);
    try std.testing.expect(got != null);
    try std.testing.expectEqualStrings(SCHEMA_URL, got.?);
}
