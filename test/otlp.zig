// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");

const fake_state = struct {
    var attempts: u32 = 0;
    var responses: []const Response = &.{};
    var last_body_len: usize = 0;
};

const Response = struct {
    status: u16,
    body: []const u8 = "",
    err: ?anyerror = null,
};

fn fakeTransport(_: std.mem.Allocator, _: []const u8, _: []const u8, _: ?[]const u8, _: []const u8, body: []const u8, _: u64) anyerror!otel.exporters.otlp_http.TransportResult {
    fake_state.last_body_len = body.len;
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
    exporter.transport = fakeTransport;
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
    exporter.transport = fakeTransport;
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
    const out = try otel.exporters.otlp_grpc.frame(std.testing.allocator, "abc");
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
    exporter.transport = fakeTransport;
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
