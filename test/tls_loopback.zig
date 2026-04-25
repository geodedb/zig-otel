// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// HTTPS round-trip integration test for the OTLP/HTTP exporter.
//
// Status: SCAFFOLD — currently skips at the helper boundary.
//
// Phase 6 of the DevNW dependency integration plan landed Task 6.1 (pin
// tls + wire `-Dotel_use_devnw_tls`) and Task 6.2 (this scaffold), but
// escalated Task 6.3 (real transport) to BLOCKED — the DevNW `tls`
// package targets QUIC (RFC 9001) and exposes no TLS-over-TCP client.
// See `docs/DEPENDENCIES.md` (TLS row).
//
// When the real transport lands, drop the SkipZigTest plumbing in
// `tls_test_helpers.startLoopbackHttps` and let the assertions below
// execute. The test shape (build a span -> exportSpans -> assert
// `.success` + non-empty captured body) is the contract Task 6.3 must
// satisfy.

const std = @import("std");
const otel = @import("otel");
const build_options = @import("build_options");
const helpers = @import("tls_test_helpers.zig");

test "OtlpHttpExporter round-trips a span over loopback HTTPS" {
    if (!build_options.use_devnw_tls) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var server = helpers.startLoopbackHttps(allocator) catch |err| switch (err) {
        helpers.Error.LoopbackHttpsNotImplemented => return error.SkipZigTest,
    };
    defer server.shutdown();

    var endpoint_buf: [64]u8 = undefined;
    const endpoint = try server.endpoint(&endpoint_buf);

    var resource = try otel.sdk.resource.defaultResource(allocator);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(allocator);
    defer attr_set.deinit();

    var exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(allocator, .{
        .endpoint = endpoint,
        .protocol = .http_protobuf,
        .timeout_ms = 5_000,
    });
    defer exporter.deinit();

    // Minimal span — we care about the round-trip, not the contents.
    const span: otel.sdk.exporter.SpanData = .{
        .name = "loopback-https",
        .span_context = .{
            .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
            .span_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8 } },
        },
        .start_unix_nano = 1_000,
        .end_unix_nano = 2_000,
        .attributes = &attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "loopback-test" },
        .resource = &resource,
    };

    const result = try exporter.spanExporter()
        .exportSpans(&[_]otel.sdk.exporter.SpanData{span});
    try std.testing.expectEqual(otel.sdk.exporter.SpanExportResult.success, result);
    try std.testing.expect(server.bodyLen() > 0);
}
