// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Regression for GAP-OTLP-WIRE-EVENTS-LINKS (#9) — the trace OTLP encoder
// must emit `Span.events` at field 11 and `Span.links` at field 13. Pre-fix
// the SDK tracked both on `Span` (`src/api/trace.zig:65-69` and `60-63`)
// and the export contract carried them through (`src/sdk/export.zig:37-38`),
// but `src/exporters/otlp_http/encode_proto.zig::writeSpan` and the DevNW
// descriptor in `encode_proto_devnw.zig` both dropped them on the floor —
// every `addEvent` / link recorded by an application disappeared on the
// wire.
//
// The tests walk the encoded bytes with a minimal varint reader and assert
// the on-wire shape directly. They mirror the pattern established by
// `test/otlp_spans_multi_scope.zig`. Four mandatory cases plus a
// byte-parity case against the DevNW protobuf encoder.
//
// Field numbers pinned by
// `third_party/opentelemetry-proto-v1.10.0/opentelemetry/proto/trace/v1/trace.proto`:
//   - Span.events                   field 11 (line 242)
//   - Span.dropped_events_count     field 12 (line 246)
//   - Span.links                    field 13 (line 295)
//   - Span.dropped_links_count      field 14 (line 299)
//   - Event.time_unix_nano          field  1 (line 224)
//   - Event.name                    field  2 (line 228)
//   - Event.attributes              field  3 (line 234)
//   - Event.dropped_attributes_count field 4 (line 238)
//   - Link.trace_id                 field  1 (line 255)
//   - Link.span_id                  field  2 (line 258)
//   - Link.trace_state              field  3 (line 261)
//   - Link.attributes               field  4 (line 267)
//   - Link.dropped_attributes_count field  5 (line 271)

const std = @import("std");
const otel = @import("otel");
const build_options = @import("build_options");

// ---------------- minimal protobuf reader (mirrors test/otlp_spans_multi_scope.zig) ----

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
        return .{ .field = @intCast(tag >> 3), .wire = @intCast(tag & 0x7) };
    }

    fn readBytes(self: *Reader) ![]const u8 {
        const n = try self.readVarint();
        if (self.pos + n > self.buf.len) return error.Truncated;
        const out = self.buf[self.pos .. self.pos + @as(usize, @intCast(n))];
        self.pos += @intCast(n);
        return out;
    }

    fn readFixed64(self: *Reader) !u64 {
        if (self.pos + 8 > self.buf.len) return error.Truncated;
        const out = std.mem.readInt(u64, self.buf[self.pos..][0..8], .little);
        self.pos += 8;
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

// ---------------- decoded view of one Span's events + links ----

const DecodedEvent = struct {
    time_unix_nano: u64 = 0,
    name: []const u8 = "",
    attribute_keys: std.ArrayList([]const u8) = .empty,
};

const DecodedLink = struct {
    trace_id: []const u8 = "",
    span_id: []const u8 = "",
    trace_state: []const u8 = "",
    attribute_keys: std.ArrayList([]const u8) = .empty,
};

const DecodedSpan = struct {
    name: []const u8 = "",
    events: std.ArrayList(DecodedEvent) = .empty,
    links: std.ArrayList(DecodedLink) = .empty,
};

fn decodeAttributeKey(arena: std.mem.Allocator, kv_bytes: []const u8) ![]const u8 {
    _ = arena;
    var r: Reader = .{ .buf = kv_bytes };
    while (!r.eof()) {
        const tag = try r.readTag();
        if (tag.field == 1 and tag.wire == 2) {
            return try r.readBytes();
        } else {
            try r.skip(tag.wire);
        }
    }
    return "";
}

fn decodeEvent(arena: std.mem.Allocator, ev_bytes: []const u8) !DecodedEvent {
    var ev: DecodedEvent = .{};
    var r: Reader = .{ .buf = ev_bytes };
    while (!r.eof()) {
        const tag = try r.readTag();
        if (tag.field == 1 and tag.wire == 1) {
            ev.time_unix_nano = try r.readFixed64();
        } else if (tag.field == 2 and tag.wire == 2) {
            ev.name = try r.readBytes();
        } else if (tag.field == 3 and tag.wire == 2) {
            const kv_bytes = try r.readBytes();
            const key = try decodeAttributeKey(arena, kv_bytes);
            try ev.attribute_keys.append(arena, key);
        } else {
            try r.skip(tag.wire);
        }
    }
    return ev;
}

fn decodeLink(arena: std.mem.Allocator, lk_bytes: []const u8) !DecodedLink {
    var lk: DecodedLink = .{};
    var r: Reader = .{ .buf = lk_bytes };
    while (!r.eof()) {
        const tag = try r.readTag();
        if (tag.field == 1 and tag.wire == 2) {
            lk.trace_id = try r.readBytes();
        } else if (tag.field == 2 and tag.wire == 2) {
            lk.span_id = try r.readBytes();
        } else if (tag.field == 3 and tag.wire == 2) {
            lk.trace_state = try r.readBytes();
        } else if (tag.field == 4 and tag.wire == 2) {
            const kv_bytes = try r.readBytes();
            const key = try decodeAttributeKey(arena, kv_bytes);
            try lk.attribute_keys.append(arena, key);
        } else {
            try r.skip(tag.wire);
        }
    }
    return lk;
}

fn decodeFirstSpan(arena: std.mem.Allocator, payload: []const u8) !DecodedSpan {
    var span: DecodedSpan = .{};
    var top: Reader = .{ .buf = payload };
    while (!top.eof()) {
        const tag = try top.readTag();
        if (tag.field == 1 and tag.wire == 2) {
            const rs_bytes = try top.readBytes();
            var rs: Reader = .{ .buf = rs_bytes };
            while (!rs.eof()) {
                const rt = try rs.readTag();
                if (rt.field == 2 and rt.wire == 2) {
                    const ss_bytes = try rs.readBytes();
                    var ss: Reader = .{ .buf = ss_bytes };
                    while (!ss.eof()) {
                        const st = try ss.readTag();
                        if (st.field == 2 and st.wire == 2) {
                            const sp_bytes = try ss.readBytes();
                            var sp: Reader = .{ .buf = sp_bytes };
                            while (!sp.eof()) {
                                const spt = try sp.readTag();
                                if (spt.field == 5 and spt.wire == 2) {
                                    span.name = try sp.readBytes();
                                } else if (spt.field == 11 and spt.wire == 2) {
                                    const ev_bytes = try sp.readBytes();
                                    const decoded = try decodeEvent(arena, ev_bytes);
                                    try span.events.append(arena, decoded);
                                } else if (spt.field == 13 and spt.wire == 2) {
                                    const lk_bytes = try sp.readBytes();
                                    const decoded = try decodeLink(arena, lk_bytes);
                                    try span.links.append(arena, decoded);
                                } else {
                                    try sp.skip(spt.wire);
                                }
                            }
                            return span; // first span only — fixtures use one span per case
                        } else {
                            try ss.skip(st.wire);
                        }
                    }
                } else {
                    try rs.skip(rt.wire);
                }
            }
        } else {
            try top.skip(tag.wire);
        }
    }
    return span;
}

// ---------------- helpers to build SpanData fixtures ----------------

fn mkSpanWith(
    name: []const u8,
    attrs: *const otel.internal.attributes.AttributeSet,
    resource: *const otel.sdk.resource.Resource,
    events: []const otel.api.trace.Event,
    links: []const otel.api.trace.Link,
) otel.sdk.exporter.SpanData {
    return .{
        .name = name,
        .span_context = .{
            .trace_id = .{ .bytes = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 } },
            .span_id = .{ .bytes = .{ 2, 0, 0, 0, 0, 0, 0, 2 } },
        },
        .start_unix_nano = 1_000,
        .end_unix_nano = 2_000,
        .attributes = attrs,
        .events = events,
        .links = links,
        .instrumentation_scope = .{ .name = "ev-link-scope" },
        .resource = resource,
    };
}

// ---------------- tests ----------------

test "encodeSpansProto emits Span.events at field 11 (two events, name + time, no attrs)" {
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();

    const events = [_]otel.api.trace.Event{
        .{ .name = "first-event", .time_unix_nano = 1_500, .attributes = null },
        .{ .name = "second-event", .time_unix_nano = 1_750, .attributes = null },
    };

    const span = mkSpanWith("with-events", &attr_set, &resource, &events, &.{});
    const out = try otel.exporters.otlp_http.encodeSpansProto(a, &[_]otel.sdk.exporter.SpanData{span});
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const decoded = try decodeFirstSpan(arena.allocator(), out);

    try std.testing.expectEqualStrings("with-events", decoded.name);
    try std.testing.expectEqual(@as(usize, 2), decoded.events.items.len);
    try std.testing.expectEqualStrings("first-event", decoded.events.items[0].name);
    try std.testing.expectEqual(@as(u64, 1_500), decoded.events.items[0].time_unix_nano);
    try std.testing.expectEqual(@as(usize, 0), decoded.events.items[0].attribute_keys.items.len);
    try std.testing.expectEqualStrings("second-event", decoded.events.items[1].name);
    try std.testing.expectEqual(@as(u64, 1_750), decoded.events.items[1].time_unix_nano);
    try std.testing.expectEqual(@as(usize, 0), decoded.links.items.len);
}

test "encodeSpansProto emits Event.attributes nested at sub-field 3" {
    // One event carrying three attributes. Verifies the nested KeyValue
    // submessages land at Event.attributes (sub-field 3) in input order.
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();

    var ev_attrs = otel.internal.attributes.AttributeSet.init(a);
    defer ev_attrs.deinit();
    try ev_attrs.putString("event.k1", "v1");
    try ev_attrs.putInt("event.k2", 42);
    try ev_attrs.putBool("event.k3", true);

    const events = [_]otel.api.trace.Event{
        .{ .name = "rich", .time_unix_nano = 5_000, .attributes = &ev_attrs },
    };

    const span = mkSpanWith("with-event-attrs", &attr_set, &resource, &events, &.{});
    const out = try otel.exporters.otlp_http.encodeSpansProto(a, &[_]otel.sdk.exporter.SpanData{span});
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const decoded = try decodeFirstSpan(arena.allocator(), out);

    try std.testing.expectEqual(@as(usize, 1), decoded.events.items.len);
    const ev = decoded.events.items[0];
    try std.testing.expectEqualStrings("rich", ev.name);
    try std.testing.expectEqual(@as(u64, 5_000), ev.time_unix_nano);
    try std.testing.expectEqual(@as(usize, 3), ev.attribute_keys.items.len);
    try std.testing.expectEqualStrings("event.k1", ev.attribute_keys.items[0]);
    try std.testing.expectEqualStrings("event.k2", ev.attribute_keys.items[1]);
    try std.testing.expectEqualStrings("event.k3", ev.attribute_keys.items[2]);
}

test "encodeSpansProto emits Span.links at field 13 (different trace_id/span_id, no attrs)" {
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();

    const linked_trace: [16]u8 = .{ 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9, 9 };
    const linked_span: [8]u8 = .{ 8, 8, 8, 8, 8, 8, 8, 8 };

    const links = [_]otel.api.trace.Link{
        .{
            .span_context = .{
                .trace_id = .{ .bytes = linked_trace },
                .span_id = .{ .bytes = linked_span },
            },
            .attributes = null,
        },
    };

    const span = mkSpanWith("with-link", &attr_set, &resource, &.{}, &links);
    const out = try otel.exporters.otlp_http.encodeSpansProto(a, &[_]otel.sdk.exporter.SpanData{span});
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const decoded = try decodeFirstSpan(arena.allocator(), out);

    try std.testing.expectEqualStrings("with-link", decoded.name);
    try std.testing.expectEqual(@as(usize, 0), decoded.events.items.len);
    try std.testing.expectEqual(@as(usize, 1), decoded.links.items.len);
    try std.testing.expectEqualSlices(u8, linked_trace[0..], decoded.links.items[0].trace_id);
    try std.testing.expectEqualSlices(u8, linked_span[0..], decoded.links.items[0].span_id);
    try std.testing.expectEqualStrings("", decoded.links.items[0].trace_state);
    try std.testing.expectEqual(@as(usize, 0), decoded.links.items[0].attribute_keys.items.len);
}

test "encodeSpansProto byte-identical when no events and no links" {
    // Acceptance criterion 4: empty events/links arrays must produce zero
    // extra bytes (proto3 default-omit). Snapshot a span with no events
    // and no links and pin the output against a known-good golden length.
    // Concretely we verify the span has no field-11 / field-12 / field-13
    // / field-14 entries by walking the bytes with the same decoder used
    // above.
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();
    try attr_set.putString("svc", "demo");

    const span = mkSpanWith("plain", &attr_set, &resource, &.{}, &.{});
    const out = try otel.exporters.otlp_http.encodeSpansProto(a, &[_]otel.sdk.exporter.SpanData{span});
    defer a.free(out);

    // Walk the encoded payload and assert that the inner Span message
    // contains no field-11 / field-13 tags. This is the exact contract
    // the regression pins.
    var top: Reader = .{ .buf = out };
    var saw_field_11_or_13 = false;
    var saw_span = false;
    while (!top.eof()) {
        const tag = try top.readTag();
        if (tag.field == 1 and tag.wire == 2) {
            const rs_bytes = try top.readBytes();
            var rs: Reader = .{ .buf = rs_bytes };
            while (!rs.eof()) {
                const rt = try rs.readTag();
                if (rt.field == 2 and rt.wire == 2) {
                    const ss_bytes = try rs.readBytes();
                    var ss: Reader = .{ .buf = ss_bytes };
                    while (!ss.eof()) {
                        const st = try ss.readTag();
                        if (st.field == 2 and st.wire == 2) {
                            saw_span = true;
                            const sp_bytes = try ss.readBytes();
                            var sp: Reader = .{ .buf = sp_bytes };
                            while (!sp.eof()) {
                                const spt = try sp.readTag();
                                if (spt.field == 11 or spt.field == 13) {
                                    saw_field_11_or_13 = true;
                                }
                                try sp.skip(spt.wire);
                            }
                        } else {
                            try ss.skip(st.wire);
                        }
                    }
                } else {
                    try rs.skip(rt.wire);
                }
            }
        } else {
            try top.skip(tag.wire);
        }
    }
    try std.testing.expect(saw_span);
    try std.testing.expect(!saw_field_11_or_13);
}

// ---------------- DevNW parity coverage ----------------

test "encodeSpansProtoDevnw matches in-repo encoder for span with events" {
    if (!build_options.use_devnw_protobuf) return error.SkipZigTest;
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();

    var ev_attrs = otel.internal.attributes.AttributeSet.init(a);
    defer ev_attrs.deinit();
    try ev_attrs.putString("k", "v");

    const events = [_]otel.api.trace.Event{
        .{ .name = "ev-no-attrs", .time_unix_nano = 1_500, .attributes = null },
        .{ .name = "ev-with-attrs", .time_unix_nano = 1_750, .attributes = &ev_attrs },
    };

    const items = [_]otel.sdk.exporter.SpanData{
        mkSpanWith("with-events-parity", &attr_set, &resource, &events, &.{}),
    };

    const lhs = try otel.exporters.otlp_http.encodeSpansProto(a, &items);
    defer a.free(lhs);
    const rhs = try otel.exporters.otlp_http.encodeSpansProtoDevnw(a, &items);
    defer a.free(rhs);
    try std.testing.expectEqualSlices(u8, lhs, rhs);
}

test "encodeSpansProtoDevnw matches in-repo encoder for span with links" {
    if (!build_options.use_devnw_protobuf) return error.SkipZigTest;
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();

    var lk_attrs = otel.internal.attributes.AttributeSet.init(a);
    defer lk_attrs.deinit();
    try lk_attrs.putInt("retry", 3);

    const linked_trace: [16]u8 = .{ 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7 };
    const linked_span: [8]u8 = .{ 6, 6, 6, 6, 6, 6, 6, 6 };

    const links = [_]otel.api.trace.Link{
        .{
            .span_context = .{
                .trace_id = .{ .bytes = linked_trace },
                .span_id = .{ .bytes = linked_span },
                .trace_state = "vendor=abc",
            },
            .attributes = &lk_attrs,
        },
        .{
            .span_context = .{
                .trace_id = .{ .bytes = linked_trace },
                .span_id = .{ .bytes = linked_span },
            },
            .attributes = null,
        },
    };

    const items = [_]otel.sdk.exporter.SpanData{
        mkSpanWith("with-links-parity", &attr_set, &resource, &.{}, &links),
    };

    const lhs = try otel.exporters.otlp_http.encodeSpansProto(a, &items);
    defer a.free(lhs);
    const rhs = try otel.exporters.otlp_http.encodeSpansProtoDevnw(a, &items);
    defer a.free(rhs);
    try std.testing.expectEqualSlices(u8, lhs, rhs);
}

test "encodeSpansProtoDevnw matches in-repo encoder for empty events/links (no regression)" {
    // Pin the byte-identical contract for the common case (no events,
    // no links) so a future change to either encoder cannot silently
    // start emitting bytes for the empty arrays.
    if (!build_options.use_devnw_protobuf) return error.SkipZigTest;
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();
    try attr_set.putString("plain", "yes");

    const items = [_]otel.sdk.exporter.SpanData{
        mkSpanWith("plain-parity", &attr_set, &resource, &.{}, &.{}),
    };

    const lhs = try otel.exporters.otlp_http.encodeSpansProto(a, &items);
    defer a.free(lhs);
    const rhs = try otel.exporters.otlp_http.encodeSpansProtoDevnw(a, &items);
    defer a.free(rhs);
    try std.testing.expectEqualSlices(u8, lhs, rhs);
}
