// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");

const fake_state = struct {
    var attempts: u32 = 0;
    var responses: []const Response = &.{};
    var last_body_len: usize = 0;
    /// Static prefix capture so tests can assert envelope shape without
    /// chasing the exporter's arena allocator across a `defer arena.deinit()`.
    var last_body_prefix: [256]u8 = undefined;
    var last_body_prefix_len: usize = 0;
};

const Response = struct {
    status: u16,
    body: []const u8 = "",
    err: ?anyerror = null,
};

fn fakeTransport(_: std.mem.Allocator, _: []const u8, _: []const u8, _: ?[]const u8, _: []const u8, body: []const u8, _: u64) anyerror!otel.exporters.otlp_http.TransportResult {
    fake_state.last_body_len = body.len;
    const n = @min(body.len, fake_state.last_body_prefix.len);
    @memcpy(fake_state.last_body_prefix[0..n], body[0..n]);
    fake_state.last_body_prefix_len = n;
    const idx = @min(fake_state.attempts, fake_state.responses.len - 1);
    fake_state.attempts += 1;
    const r = fake_state.responses[idx];
    if (r.err) |e| return e;
    return .{ .status = r.status, .body = r.body };
}

test "OTLP exporter retries on 503" {
    fake_state.attempts = 0;
    fake_state.responses = &.{
        .{ .status = 503 },
        .{ .status = 200 },
    };

    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(std.testing.allocator);
    defer attr_set.deinit();

    var exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(std.testing.allocator, .{
        .endpoint = "http://localhost:4318",
        .protocol = .http_protobuf,
        .timeout_ms = 100,
    });
    // OTEL-Q-NEW-A (#163): Transport is a tagged union; tests inject
    // their fake under the `.custom` tag so the production path stays a
    // type-checked switch instead of a fn-pointer-identity sentinel.
    exporter.transport = .{ .custom = fakeTransport };
    defer exporter.deinit();

    const span: otel.sdk.exporter.SpanData = .{
        .name = "x",
        .span_context = .{ .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } }, .span_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8 } } },
        .start_unix_nano = 1000,
        .end_unix_nano = 2000,
        .attributes = &attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "" },
        .resource = &resource,
    };
    const result = try exporter.spanExporter().exportSpans(&[_]otel.sdk.exporter.SpanData{span});
    try std.testing.expectEqual(otel.sdk.exporter.SpanExportResult.success, result);
    try std.testing.expect(fake_state.last_body_len > 0);
}

test "OTLP exporter returns PartialSuccess on 207" {
    fake_state.attempts = 0;
    fake_state.responses = &.{.{ .status = 207 }};
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(std.testing.allocator);
    defer attr_set.deinit();
    var exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(std.testing.allocator, .{ .endpoint = "http://localhost:4318" });
    exporter.transport = .{ .custom = fakeTransport };
    defer exporter.deinit();
    const span: otel.sdk.exporter.SpanData = .{
        .name = "x",
        .span_context = .{ .trace_id = .{ .bytes = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } }, .span_id = .{ .bytes = .{ 1, 0, 0, 0, 0, 0, 0, 0 } } },
        .start_unix_nano = 1,
        .end_unix_nano = 2,
        .attributes = &attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "" },
        .resource = &resource,
    };
    try std.testing.expectError(error.PartialSuccess, exporter.spanExporter().exportSpans(&[_]otel.sdk.exporter.SpanData{span}));
}

test "gRPC frame prefix" {
    const out = try otel.exporters.otlp_grpc.frame(std.testing.allocator, "abc", false);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(u8, 0), out[0]);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, out[1..5], .big));
}

test "OTLP HTTP JSON body wraps in resourceSpans" {
    fake_state.attempts = 0;
    fake_state.responses = &.{.{ .status = 200 }};
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(std.testing.allocator);
    defer attr_set.deinit();
    var exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(std.testing.allocator, .{
        .endpoint = "http://localhost:4318",
        .protocol = .http_json,
    });
    exporter.transport = .{ .custom = fakeTransport };
    defer exporter.deinit();
    const span: otel.sdk.exporter.SpanData = .{
        .name = "x",
        .span_context = .{
            .trace_id = .{ .bytes = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
            .span_id = .{ .bytes = .{ 1, 0, 0, 0, 0, 0, 0, 0 } },
        },
        .start_unix_nano = 1,
        .end_unix_nano = 2,
        .attributes = &attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "" },
        .resource = &resource,
    };
    const result = try exporter.spanExporter().exportSpans(&[_]otel.sdk.exporter.SpanData{span});
    try std.testing.expectEqual(otel.sdk.exporter.SpanExportResult.success, result);
    try std.testing.expect(fake_state.last_body_len > 0);
    const prefix = fake_state.last_body_prefix[0..fake_state.last_body_prefix_len];
    try std.testing.expect(std.mem.startsWith(u8, prefix, "{\"resourceSpans\":["));
}

test "OTLP HTTP JSON envelope wraps DevNW-encoded body identically" {
    if (!@import("build_options").use_devnw_json) return error.SkipZigTest;
    fake_state.attempts = 0;
    fake_state.responses = &.{.{ .status = 200 }};
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(std.testing.allocator);
    defer attr_set.deinit();
    var exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(std.testing.allocator, .{
        .endpoint = "http://localhost:4318",
        .protocol = .http_json,
    });
    exporter.transport = .{ .custom = fakeTransport };
    defer exporter.deinit();
    const span: otel.sdk.exporter.SpanData = .{
        .name = "x",
        .span_context = .{
            .trace_id = .{ .bytes = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
            .span_id = .{ .bytes = .{ 1, 0, 0, 0, 0, 0, 0, 0 } },
        },
        .start_unix_nano = 1,
        .end_unix_nano = 2,
        .attributes = &attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "" },
        .resource = &resource,
    };
    _ = try exporter.spanExporter().exportSpans(&[_]otel.sdk.exporter.SpanData{span});
    const prefix = fake_state.last_body_prefix[0..fake_state.last_body_prefix_len];
    try std.testing.expect(std.mem.startsWith(u8, prefix, "{\"resourceSpans\":["));
}

// -------------------------------------------------------------------------
// PN-NEW-3/4: pre-sizing the proto encoder buffer must not change a single
// wire byte. This characterizes a 3-span batch's protobuf encoding so the
// `ensureTotalCapacity` pre-size (capacity-only) is proven byte-identical:
//   1. the exact encoded length is pinned, and
//   2. the leading ResourceSpans envelope bytes are pinned, and
//   3. two independent encodes of the same input are byte-for-byte equal.
// Combined with the existing wire-parity suite, any contents drift fails.
// -------------------------------------------------------------------------

fn makeProtoSpan(
    resource: *otel.sdk.resource.Resource,
    attr_set: *otel.internal.attributes.AttributeSet,
    trace_lo: u8,
    span_lo: u8,
) otel.sdk.exporter.SpanData {
    return .{
        .name = "demo-span",
        .span_context = .{
            .trace_id = .{ .bytes = .{ trace_lo, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
            .span_id = .{ .bytes = .{ span_lo, 6, 5, 4, 3, 2, 1, 0 } },
        },
        .start_unix_nano = 1_000,
        .end_unix_nano = 2_000,
        .attributes = attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "scope" },
        .resource = resource,
    };
}

test "PN-NEW-3/4: 3-span batch encodes to byte-identical proto" {
    const a = std.testing.allocator;
    var resource = otel.sdk.resource.Resource.init(a);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();
    try attr_set.putString("http.method", "GET");

    const spans = [_]otel.sdk.exporter.SpanData{
        makeProtoSpan(&resource, &attr_set, 1, 11),
        makeProtoSpan(&resource, &attr_set, 2, 12),
        makeProtoSpan(&resource, &attr_set, 3, 13),
    };

    const out1 = try otel.exporters.otlp_http.encodeSpansProto(a, &spans);
    defer a.free(out1);
    const out2 = try otel.exporters.otlp_http.encodeSpansProto(a, &spans);
    defer a.free(out2);

    // Determinism: two encodes of the same input are identical.
    try std.testing.expectEqualSlices(u8, out1, out2);

    // Pinned wire shape. The pre-size change is capacity-only, so this exact
    // byte count must not move.
    try std.testing.expectEqual(@as(usize, 272), out1.len);
    // ResourceSpans is field 1, length-delimited → tag 0x0a, then a 2-byte
    // length varint for the 269-byte payload (269 = 0x8d 0x02).
    try std.testing.expectEqual(@as(u8, 0x0a), out1[0]);
    try std.testing.expectEqual(@as(u8, 0x8d), out1[1]);
    try std.testing.expectEqual(@as(u8, 0x02), out1[2]);
}

test "profiles gating returns UnsupportedTransport" {
    const p: otel.api.profiles.Profiler = .{ .scope = .{ .name = "x" } };
    const profile: otel.api.profiles.Profile = .{
        .sample_types = &.{},
        .samples = &.{},
        .locations = &.{},
        .functions = &.{},
        .start_unix_nano = 0,
        .duration_nanos = 0,
    };
    try std.testing.expectError(error.UnsupportedTransport, p.emit(profile));
}
