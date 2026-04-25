// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");
const build_options = @import("build_options");

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
    const items: [1]otel.sdk.exporter.SpanData = .{span};

    const a = try otel.exporters.otlp_http.encodeSpansProto(std.testing.allocator, items[0..]);
    defer std.testing.allocator.free(a);
    const b = try otel.exporters.otlp_http.encodeSpansProtoDevnw(std.testing.allocator, items[0..]);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
}
