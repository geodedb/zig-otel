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

// -------------------------------------------------------------------------
// GAP-SEC-H-2: Prometheus label-value escaping + label-name sanitisation.
//
// Prometheus 0.0.4 text format mandates `\\`, `\"`, `\n` escapes inside
// label values. Without them, a payload like `pwned"} 999\n...` would
// break the line and inject a synthetic metric. Label names that violate
// `[a-zA-Z_][a-zA-Z0-9_]*` would silently mangle dashboards.
// -------------------------------------------------------------------------

test "H-2: escapes double-quote in label value" {
    const out = try otel.exporters.prometheus.escapeLabelValue(std.testing.allocator, "p\"q");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("p\\\"q", out);
}

test "H-2: escapes backslash in label value" {
    const out = try otel.exporters.prometheus.escapeLabelValue(std.testing.allocator, "a\\b");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\\\\b", out);
}

test "H-2: escapes newline in label value" {
    const out = try otel.exporters.prometheus.escapeLabelValue(std.testing.allocator, "x\ny");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("x\\ny", out);
}

test "H-2: round-trips an injection payload safely" {
    const payload = "pwned\"} 999\ninjected_metric{x=\"y";
    const out = try otel.exporters.prometheus.escapeLabelValue(std.testing.allocator, payload);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("pwned\\\"} 999\\ninjected_metric{x=\\\"y", out);
}

test "H-2: sanitiseLabelName replaces invalid bytes with underscore" {
    const out = try otel.exporters.prometheus.sanitiseLabelName(std.testing.allocator, "k\"e:y");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("k_e_y", out);
}

test "H-2: sanitiseLabelName prefixes leading digit with underscore" {
    const out = try otel.exporters.prometheus.sanitiseLabelName(std.testing.allocator, "9foo");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("_9foo", out);
}

// -------------------------------------------------------------------------
// GAP-SEC-H-4: skip_tls_verify field is a footgun in a public OTel SDK.
// Removed entirely (rather than wired) because std.http.Client doesn't
// expose a stable per-fetch TLS-verify knob and "I configured it but it
// silently ignored me" is a worse failure mode than "the field doesn't
// exist". TLS verification is therefore *always on* for the HTTPS path.
// -------------------------------------------------------------------------

test "H-4: OtlpConfig has no skip_tls_verify field" {
    const fields = std.meta.fields(otel.sdk.config.OtlpConfig);
    inline for (fields) |f| {
        try std.testing.expect(!std.mem.eql(u8, f.name, "skip_tls_verify"));
    }
}

// -------------------------------------------------------------------------
// GAP-SEC-H-3: File exporter must require an explicit base directory
// and reject absolute paths or any `..` component.
// -------------------------------------------------------------------------

test "H-3: file exporter rejects parent-traversal sub_path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(
        error.InvalidPath,
        otel.exporters.file.FileJsonl.open(std.testing.allocator, std.testing.io, tmp.dir, "../escape.txt"),
    );
}

test "H-3: file exporter rejects absolute path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(
        error.InvalidPath,
        otel.exporters.file.FileJsonl.open(std.testing.allocator, std.testing.io, tmp.dir, "/etc/cron.d/x"),
    );
}

test "H-3: file exporter rejects empty sub_path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try std.testing.expectError(
        error.InvalidPath,
        otel.exporters.file.FileJsonl.open(std.testing.allocator, std.testing.io, tmp.dir, ""),
    );
}

test "H-3: file exporter accepts a relative path inside the base dir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var jsonl = try otel.exporters.file.FileJsonl.open(std.testing.allocator, std.testing.io, tmp.dir, "spans.jsonl");
    defer jsonl.close();
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
