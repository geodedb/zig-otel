// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");

test "redaction marker is exact" {
    try std.testing.expectEqualStrings("[REDACTED]", otel.internal.redact.maskString("Authorization", "Bearer x"));
}

test "redaction passes through innocuous keys" {
    try std.testing.expectEqualStrings("alice", otel.internal.redact.maskString("db.user", "alice"));
}

test "case-insensitive sensitive token detection" {
    try std.testing.expect(otel.internal.redact.isSensitive("AUTHORIZATION"));
    try std.testing.expect(otel.internal.redact.isSensitive("X-API-KEY"));
    try std.testing.expect(otel.internal.redact.isSensitive("Cookie-Authorization-Header"));
    try std.testing.expect(!otel.internal.redact.isSensitive("user.name"));
}

test "OTLP exporter rejects HTTP scheme outside http(s)" {
    try std.testing.expectError(error.InvalidEndpoint, otel.exporters.otlp_http.OtlpHttpExporter.init(std.testing.allocator, .{ .endpoint = "ftp://x" }));
}

test "attribute set caps string values" {
    var as = otel.internal.attributes.AttributeSet.init(std.testing.allocator);
    defer as.deinit();
    var huge: [otel.internal.attributes.max_string_value_bytes + 100]u8 = undefined;
    @memset(huge[0..], 'x');
    try as.putString("k", huge[0..]);
    try std.testing.expectEqual(@as(usize, otel.internal.attributes.max_string_value_bytes), as.getString("k").?.len);
}

// -------------------------------------------------------------------------
// Fuzz target deferred. A property test for `redact.maskString` was
// drafted, but `std.testing.fuzz` in Zig 0.16 trips a stdlib type
// mismatch in `lib/compiler/test_runner.zig:566` (`*builtin.StackTrace`
// vs `*const debug.StackTrace`) on the error-trace path. The CI
// `zig-fuzz` job is `allow_failure: true` so it's advisory until
// either Zig fixes the test_runner type or we route fuzz through a
// custom runner. The redact invariants are still covered by the
// deterministic tests above.
// -------------------------------------------------------------------------

// -------------------------------------------------------------------------
// GAP-SEC-C-2 / GAP-SEC-C-3: gRPC exporter posture.
//
// Until the grpc-zig client gains TLS support, an https:// endpoint
// would silently downgrade to plaintext h2c. Refuse explicitly.
// Likewise, OtlpConfig.headers (e.g. Authorization) cannot reach the
// grpc-zig request — refuse rather than silently dropping credentials.
// -------------------------------------------------------------------------

fn makeGrpcExportSpan(resource: *otel.sdk.resource.Resource, attr_set: *otel.internal.attributes.AttributeSet) otel.sdk.exporter.SpanData {
    return .{
        .name = "x",
        .span_context = .{
            .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
            .span_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8 } },
        },
        .start_unix_nano = 1,
        .end_unix_nano = 2,
        .attributes = attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "t" },
        .resource = resource,
    };
}

test "C-2: gRPC exporter rejects https:// endpoint without explicit insecure" {
    var resource = otel.sdk.resource.Resource.init(std.testing.allocator);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(std.testing.allocator);
    defer attr_set.deinit();

    var exporter = try otel.exporters.otlp_grpc.OtlpGrpcExporter.init(std.testing.allocator, .{
        .endpoint = "https://collector.example.com:4317",
        .protocol = .grpc,
        // .insecure is false by default; the exporter must refuse rather
        // than silently downgrade to plaintext h2c.
    });
    defer exporter.deinit();

    const span = makeGrpcExportSpan(&resource, &attr_set);
    try std.testing.expectError(
        error.UnsupportedTransport,
        exporter.spanExporter().exportSpans(&[_]otel.sdk.exporter.SpanData{span}),
    );
}

// -------------------------------------------------------------------------
// GAP-SEC-H-1 / GAP-SEC-M-8: OTLP HTTP header parser RFC 7230 validation
// and content-type dedup.
//
// Reject CRLF / control-byte injection in header names and values, cap
// the lengths to RFC 7230 sanity limits, and refuse user attempts to
// override the content-type (which the exporter sets canonically).
// -------------------------------------------------------------------------

test "H-1: header parser rejects CRLF in value (response splitting)" {
    var buf: [16]otel.exporters.otlp_http.HeaderEntry = undefined;
    try std.testing.expectError(
        error.InvalidHeader,
        otel.exporters.otlp_http.parseHeaderString("X-Inject=foo\r\nEvil-Header: yes", &buf),
    );
}

test "H-1: header parser rejects embedded NUL in value" {
    var buf: [16]otel.exporters.otlp_http.HeaderEntry = undefined;
    try std.testing.expectError(
        error.InvalidHeader,
        otel.exporters.otlp_http.parseHeaderString("X-Foo=bar\x00baz", &buf),
    );
}

test "H-1: header parser rejects DEL byte in value" {
    var buf: [16]otel.exporters.otlp_http.HeaderEntry = undefined;
    try std.testing.expectError(
        error.InvalidHeader,
        otel.exporters.otlp_http.parseHeaderString("X-Foo=bar\x7f", &buf),
    );
}

test "H-1: header parser rejects space in name" {
    var buf: [16]otel.exporters.otlp_http.HeaderEntry = undefined;
    try std.testing.expectError(
        error.InvalidHeader,
        otel.exporters.otlp_http.parseHeaderString("Bad Name=value", &buf),
    );
}

test "H-1: header parser rejects colon in name" {
    var buf: [16]otel.exporters.otlp_http.HeaderEntry = undefined;
    try std.testing.expectError(
        error.InvalidHeader,
        otel.exporters.otlp_http.parseHeaderString("Bad:Name=value", &buf),
    );
}

test "H-1: header parser accepts ordinary token name" {
    var buf: [16]otel.exporters.otlp_http.HeaderEntry = undefined;
    const out = try otel.exporters.otlp_http.parseHeaderString("Authorization=Bearer abc", &buf);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("Authorization", out[0].name);
    try std.testing.expectEqualStrings("Bearer abc", out[0].value);
}

test "M-8: header parser drops user-supplied content-type" {
    var buf: [16]otel.exporters.otlp_http.HeaderEntry = undefined;
    // The exporter always emits content-type itself; user-supplied
    // overrides are dropped silently to avoid duplicate headers.
    const out = try otel.exporters.otlp_http.parseHeaderString("content-type=text/plain,X-Tenant=org-7", &buf);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expectEqualStrings("X-Tenant", out[0].name);
}

test "C-3: gRPC exporter refuses to export when headers are configured" {
    var resource = otel.sdk.resource.Resource.init(std.testing.allocator);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(std.testing.allocator);
    defer attr_set.deinit();

    var exporter = try otel.exporters.otlp_grpc.OtlpGrpcExporter.init(std.testing.allocator, .{
        .endpoint = "http://127.0.0.1:4317",
        .protocol = .grpc,
        .headers = "Authorization=Bearer x",
    });
    defer exporter.deinit();

    const span = makeGrpcExportSpan(&resource, &attr_set);
    try std.testing.expectError(
        error.UnsupportedTransport,
        exporter.spanExporter().exportSpans(&[_]otel.sdk.exporter.SpanData{span}),
    );
}
