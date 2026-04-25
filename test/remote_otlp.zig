// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Live OTLP integration tests against a real collector.
//
// These tests hit a network endpoint and are therefore *not* part of
// the hermetic default suite. They self-skip unless every prerequisite
// is satisfied:
//
//   1. The build flag for the corresponding transport is on
//      (`-Dotel_use_devnw_tls=true` for HTTPS,
//       `-Dotel_use_devnw_grpc=true` for gRPC).
//   2. The endpoint env var is set (`OTEL_INTEGRATION_HTTPS_ENDPOINT`
//      or `OTEL_INTEGRATION_GRPCS_ENDPOINT`).
//
// In CI, the `otlp-integration-live` job sets all of those for the
// GitLab Observability endpoints. Locally:
//
//   OTEL_INTEGRATION_HTTPS_ENDPOINT=https://5333796.otel.gitlab-o11y.com:14318 \
//   OTEL_EXPORTER_OTLP_HEADERS="Authorization=Bearer <token>" \
//   zig build test-remote-otlp -Dotel_use_devnw_tls=true
//
// Authentication, if required by the collector, is read from the
// `OTEL_EXPORTER_OTLP_HEADERS` env var via `OtlpConfig.headers` and
// folded into the request. The exporter retries on transport errors
// per the existing retry policy; a 200/202/204 from the collector is
// treated as success.

const std = @import("std");
const otel = @import("otel");
const build_options = @import("build_options");

/// Build an `Environ` view over the current process's libc environ
/// block. 0.16 dropped the convenience `std.process.getEnvVarOwned`
/// helper; the new API is `Environ.getPosix(env, key)` against an
/// `Environ` constructed from a `Block`. On a libc-linked Linux
/// build the canonical `Block` is `PosixBlock { slice }`, sourced
/// from the C global `environ`.
fn currentEnviron() std.process.Environ {
    const c_env = std.c.environ;
    var len: usize = 0;
    while (c_env[len] != null) : (len += 1) {}
    return .{ .block = .{ .slice = c_env[0..len :null] } };
}

/// Read an env var into a caller-supplied buffer. Returns the slice
/// occupied or null when missing/empty/oversize.
fn envInto(buf: []u8, name: []const u8) ?[]const u8 {
    const env = currentEnviron();
    const value = env.getPosix(name) orelse return null;
    if (value.len == 0 or value.len > buf.len) return null;
    @memcpy(buf[0..value.len], value);
    return buf[0..value.len];
}

fn buildSpan(resource: *const otel.sdk.resource.Resource, attrs: *const otel.internal.attributes.AttributeSet) otel.sdk.exporter.SpanData {
    return .{
        .name = "remote-otlp-integration",
        .span_context = .{
            .trace_id = .{ .bytes = .{ 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89 } },
            .span_id = .{ .bytes = .{ 0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10 } },
            .flags = .{ .sampled = true },
        },
        .kind = .client,
        .start_unix_nano = 1_000_000,
        .end_unix_nano = 2_000_000,
        .attributes = attrs,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "otel-zig.integration", .version = "0.1.0" },
        .resource = resource,
    };
}

test "OTLP/HTTPS live export to remote collector" {
    if (!build_options.use_devnw_tls) return error.SkipZigTest;
    var endpoint_buf: [512]u8 = undefined;
    const endpoint = envInto(&endpoint_buf, "OTEL_INTEGRATION_HTTPS_ENDPOINT") orelse return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();

    var resource = try otel.sdk.resource.defaultResource(allocator);
    defer resource.deinit();
    try resource.attributes.putString(otel.semconv.service_name, "otel-zig-integration");

    var attr_set = otel.internal.attributes.AttributeSet.init(allocator);
    defer attr_set.deinit();
    try attr_set.putString("test.suite", "remote-otlp");
    try attr_set.putString("test.transport", "https");

    var headers_buf: [4096]u8 = undefined;
    const headers = envInto(&headers_buf, "OTEL_EXPORTER_OTLP_HEADERS");

    var exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(allocator, .{
        .endpoint = endpoint,
        .protocol = .http_protobuf,
        .headers = headers,
        .timeout_ms = 30_000,
    });
    defer exporter.deinit();
    exporter.io = threaded.io();

    const span = buildSpan(&resource, &attr_set);
    const result = try exporter.spanExporter().exportSpans(&[_]otel.sdk.exporter.SpanData{span});
    // 200/202/204 → .success. 207 (PartialSuccess) is also acceptable —
    // the collector accepted the batch even if it dropped some spans.
    if (result != .success and result != .partial_success) {
        std.debug.print("unexpected export result: {s}\n", .{@tagName(result)});
        return error.UnexpectedExportResult;
    }
}

test "OTLP/gRPCS live export to remote collector" {
    if (!build_options.use_devnw_grpc) return error.SkipZigTest;
    var endpoint_buf: [512]u8 = undefined;
    const endpoint = envInto(&endpoint_buf, "OTEL_INTEGRATION_GRPCS_ENDPOINT") orelse return error.SkipZigTest;

    // The grpc-zig client currently drives only cleartext h2; TLS is
    // available on the server side but not yet wired into the client's
    // public init API. Until that lands, gRPCS against a TLS-only
    // endpoint cannot succeed end-to-end. Skip with a clear marker so
    // CI shows the test as intentionally skipped, not silently
    // missing. Switch to an active assertion once grpc-zig exposes a
    // `GrpcClient.initTls` (or equivalent).
    _ = endpoint;
    return error.SkipZigTest;
}
