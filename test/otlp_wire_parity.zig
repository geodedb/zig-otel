// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");
const build_options = @import("build_options");

fn assertParity(items: []const otel.sdk.exporter.SpanData) !void {
    const a = try otel.exporters.otlp_http.encodeSpansProto(std.testing.allocator, items);
    defer std.testing.allocator.free(a);
    const b = try otel.exporters.otlp_http.encodeSpansProtoDevnw(std.testing.allocator, items);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
}

test "in-repo and DevNW protobuf encoders produce identical bytes" {
    if (!build_options.use_devnw_protobuf) return error.SkipZigTest;
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(std.testing.allocator);
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
        .instrumentation_scope = .{ .name = "" },
        .resource = &resource,
    };
    try assertParity(&[_]otel.sdk.exporter.SpanData{span});
}

test "parity holds for non-default kind, status, and dropped count" {
    // Exercises the `kind` enum (non-`internal`), `Status.code` (non-unset),
    // and `dropped_attributes_count` (non-zero) — all three are declared
    // `.uint64` in the DevNW schema to mirror the in-repo `writeUint64`
    // calls. Without this case the parity test would not actually prove
    // those wire-type choices.
    if (!build_options.use_devnw_protobuf) return error.SkipZigTest;
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(std.testing.allocator);
    defer attr_set.deinit();
    attr_set.dropped = 7; // direct write — public field used by the encoder

    const span: otel.sdk.exporter.SpanData = .{
        .name = "client-call",
        .span_context = .{
            .trace_id = .{ .bytes = .{ 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 } },
            .span_id = .{ .bytes = .{ 8, 7, 6, 5, 4, 3, 2, 1 } },
        },
        .kind = .client,
        .status_code = .@"error",
        .status_description = "boom",
        .start_unix_nano = 100,
        .end_unix_nano = 200,
        .attributes = &attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "" },
        .resource = &resource,
        .dropped_attributes_count = 7,
    };
    try assertParity(&[_]otel.sdk.exporter.SpanData{span});
}

test "parity holds for non-string AnyValue variants" {
    // Exercises `AnyValue.int_value` (declared `.sint64` zigzag in the
    // DevNW schema to match the in-repo `writeSint64` quirk). Without
    // this case the `.sint64` choice is untested.
    if (!build_options.use_devnw_protobuf) return error.SkipZigTest;
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(std.testing.allocator);
    defer attr_set.deinit();
    try attr_set.putInt("retries", -3);
    try attr_set.putBool("ok", true);
    try attr_set.putDouble("ratio", 0.25);

    const span: otel.sdk.exporter.SpanData = .{
        .name = "values",
        .span_context = .{
            .trace_id = .{ .bytes = .{ 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5 } },
            .span_id = .{ .bytes = .{ 6, 6, 6, 6, 6, 6, 6, 6 } },
        },
        .start_unix_nano = 10,
        .end_unix_nano = 20,
        .attributes = &attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "" },
        .resource = &resource,
    };
    try assertParity(&[_]otel.sdk.exporter.SpanData{span});
}
