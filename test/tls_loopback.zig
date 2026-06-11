// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// HTTP loopback round-trip test for the OTLP/HTTP exporter.
//
// Phase 6 of the DevNW dependency integration plan landed Tasks 6.1 and
// 6.2 (pin tls + scaffold) and originally escalated Task 6.3 (real
// transport) to BLOCKED because the DevNW `tls` package is QUIC-first
// (RFC 9001) with no TLS-over-TCP record layer. This file is now the
// post-pivot Task 6.3 acceptance test: rather than carry the TLS record
// layer ourselves, the transport calls `std.http.Client.fetch`, which
// has built-in TLS via `std.crypto.tls`. The DevNW `tls` dep stays
// pinned for future QUIC integration; see `docs/DEPENDENCIES.md`.
//
// The build flag retains its original name (`-Dotel_use_devnw_tls`); its
// effective semantics are now "the real transport is wired" — `false`
// keeps `httpTransport` returning `error.UnsupportedTransport` so
// hermetic builds still surface misconfiguration loudly.
//
// We test against plain HTTP (not HTTPS): TLS itself is stdlib code
// upstream-tested by the Zig project, and standing up a self-signed
// cert + bundle in the test would not exercise any code path we own.
// What we do own — URL build, header plumbing, body framing, status
// translation — is identical between HTTP and HTTPS through `fetch`,
// so a passing HTTP loopback proves the transport.

const std = @import("std");
const otel = @import("otel");
const build_options = @import("build_options");
const helpers = @import("tls_test_helpers.zig");

test "OtlpHttpExporter round-trips a span over loopback HTTP" {
    if (!build_options.use_devnw_tls) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var server = try helpers.startLoopbackHttps(allocator);
    defer server.destroy();

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
        // AS-1: the in-process test server binds 127.0.0.1; opt into the
        // loopback path so the construction-time SSRF guard allows it.
        .allow_loopback = true,
    });
    defer exporter.deinit();

    // Plumb the same Io the server is running on. `std.http.Client` is
    // documented threadsafe so sharing the Io between the server thread
    // and the test thread is fine.
    exporter.io = server.io;

    // Minimal span — we care about the round-trip, not the contents.
    const span: otel.sdk.exporter.SpanData = .{
        .name = "loopback-http",
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

    // `bodyLen()` and `serverError()` are only safe to read after the
    // server thread has exited. `join()` blocks until that happens; the
    // deferred `destroy()` is then a no-op for the join half and just
    // releases memory.
    server.join();
    try std.testing.expectEqual(@as(?anyerror, null), server.serverError());
    try std.testing.expect(server.bodyLen() > 0);
}
