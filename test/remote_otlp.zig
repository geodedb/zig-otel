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
// The HTTPS test sends a fresh trace (a parent span with several
// children) using the current wall-clock timestamp so the trace falls
// inside the backend's retention window. It then prints the trace_id
// hex and the collector's HTTP response (status + body) so the
// operator can search the dashboard for the exact ID and inspect any
// `ExportTracePartialSuccess` messages from the collector.

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

/// Pretty-print a hex-encoded byte slice into a 64-byte stack buffer.
fn hex(out: []u8, in: []const u8) []const u8 {
    const alphabet = "0123456789abcdef";
    var n: usize = 0;
    for (in) |b| {
        if (n + 2 > out.len) break;
        out[n] = alphabet[(b >> 4) & 0x0f];
        out[n + 1] = alphabet[b & 0x0f];
        n += 2;
    }
    return out[0..n];
}

fn nowNanos() u64 {
    return otel.internal.clock.unixNanoNow();
}

/// GAP-SEC-H-7: best-effort credential pattern detector. Returns true if
/// `text` looks like it might contain a bearer token, cookie, or
/// `key=secret`-shaped pair. Used to suppress dumping arbitrary
/// collector responses to CI logs (which used to include the
/// Authorization header on early-failure paths).
fn scrubCredentials(text: []const u8) bool {
    const needles = [_][]const u8{ "Bearer ", "Authorization", "Set-Cookie", "token=", "secret=" };
    for (needles) |needle| {
        if (std.ascii.indexOfIgnoreCase(text, needle) != null) return true;
    }
    return false;
}

/// Returns true when running under CI, in which case the printer hashes
/// rather than echoes the endpoint URL (it's user data via the
/// `OTEL_INTEGRATION_*_ENDPOINT` env var).
fn isCi() bool {
    var buf: [16]u8 = undefined;
    return envInto(&buf, "CI") != null;
}

/// Hash `endpoint` with SHA-256 and write the first 16 hex chars into
/// `out_buf`. Used in CI logs so an attacker who scrapes a CI log
/// can't tell which collector got hit.
fn hashEndpoint(out_buf: []u8, endpoint: []const u8) []const u8 {
    const Sha256 = std.crypto.hash.sha2.Sha256;
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(endpoint, &digest, .{});
    return hex(out_buf, digest[0..8]);
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
    try resource.attributes.putString("service.namespace", "devnw.zig");
    try resource.attributes.putString("service.version", otel.version);
    try resource.attributes.putString("deployment.environment", "ci-or-local");

    var attr_set = otel.internal.attributes.AttributeSet.init(allocator);
    defer attr_set.deinit();
    try attr_set.putString("test.suite", "remote-otlp");
    try attr_set.putString("test.transport", "https");
    try attr_set.putString("test.run_id", "remote-otlp-live");

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

    // Build a fresh trace_id from the current wall-clock nanos + a
    // fixed marker so each run is uniquely searchable. Span ids derive
    // from the same timestamp.
    const now = nowNanos();
    var trace_id_bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, trace_id_bytes[0..8], now, .big);
    std.mem.writeInt(u64, trace_id_bytes[8..16], 0xDE_AD_BE_EF_FE_ED_CA_FE, .big);
    var parent_span_id_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &parent_span_id_bytes, now ^ 0xA5A5_A5A5_A5A5_A5A5, .big);

    // Print the IDs to stderr so the operator can search the dashboard
    // for this exact emission. `std.testing` swallows stdout but lets
    // stderr through, so this surfaces in `zig build test --summary all`.
    var hex_buf: [64]u8 = undefined;
    std.debug.print("\n=== otel-zig live OTLP/HTTPS emission ===\n", .{});
    if (isCi()) {
        var ep_hash_buf: [32]u8 = undefined;
        std.debug.print("  endpoint   = sha256:{s} (hashed in CI)\n", .{hashEndpoint(&ep_hash_buf, endpoint)});
    } else {
        std.debug.print("  endpoint   = {s}\n", .{endpoint});
    }
    std.debug.print("  trace_id   = {s}\n", .{hex(&hex_buf, trace_id_bytes[0..])});
    std.debug.print("  parent_id  = {s}\n", .{hex(hex_buf[16..], parent_span_id_bytes[0..])});
    std.debug.print("  service    = otel-zig-integration\n", .{});
    std.debug.print("  start_nano = {d}\n", .{now});

    // Build a parent span + 4 children. Real wall-clock timestamps put
    // the trace inside Tempo's retention window — older spans (e.g.
    // unix nanos = 1000) get silently dropped by the backend.
    const parent_start = now;
    const parent_end = now + 50 * std.time.ns_per_ms;
    const parent: otel.sdk.exporter.SpanData = .{
        .name = "remote-otlp-integration.parent",
        .span_context = .{
            .trace_id = .{ .bytes = trace_id_bytes },
            .span_id = .{ .bytes = parent_span_id_bytes },
            .flags = .{ .sampled = true },
        },
        .kind = .server,
        .start_unix_nano = parent_start,
        .end_unix_nano = parent_end,
        .attributes = &attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "otel-zig.integration", .version = "0.1.0" },
        .resource = &resource,
    };

    var children: [4]otel.sdk.exporter.SpanData = undefined;
    var child_attrs: [4]otel.internal.attributes.AttributeSet = undefined;
    for (&child_attrs, 0..) |*a, i| {
        a.* = otel.internal.attributes.AttributeSet.init(allocator);
        try a.putString("test.suite", "remote-otlp");
        try a.putString("test.transport", "https");
        try a.putInt("child.index", @intCast(i));
    }
    defer for (&child_attrs) |*a| a.deinit();

    inline for (.{ "fetch", "decode", "validate", "persist" }, 0..) |op, i| {
        var child_id: [8]u8 = undefined;
        std.mem.writeInt(u64, &child_id, now ^ (0x1111_2222_3333_4444 *% (i + 1)), .big);
        const child_start = parent_start + @as(u64, i) * 5 * std.time.ns_per_ms;
        children[i] = .{
            .name = "remote-otlp-integration." ++ op,
            .span_context = .{
                .trace_id = .{ .bytes = trace_id_bytes },
                .span_id = .{ .bytes = child_id },
                .flags = .{ .sampled = true },
            },
            .parent_span_id = .{ .bytes = parent_span_id_bytes },
            .kind = .internal,
            .start_unix_nano = child_start,
            .end_unix_nano = child_start + 4 * std.time.ns_per_ms,
            .attributes = &child_attrs[i],
            .events = &.{},
            .links = &.{},
            .instrumentation_scope = .{ .name = "otel-zig.integration", .version = "0.1.0" },
            .resource = &resource,
        };
    }

    var batch: [5]otel.sdk.exporter.SpanData = undefined;
    batch[0] = parent;
    @memcpy(batch[1..], children[0..]);

    const result = try exporter.spanExporter().exportSpans(batch[0..]);

    std.debug.print("  http.status = {d}\n", .{exporter.lastResponseStatus()});
    const resp_full = exporter.lastResponseBody();
    std.debug.print("  resp.bytes  = {d}\n", .{resp_full.len});
    // GAP-SEC-H-7: only dump the response body when the export *failed*
    // (the success path's body is always empty for OTLP/HTTPS), and
    // even then suppress it if it looks like it might contain
    // credentials. This prevents Authorization headers (which some
    // collectors echo on HTTP errors) from leaking into CI logs.
    const success = result == .success or result == .partial_success;
    if (!success and resp_full.len > 0) {
        const resp = resp_full;
        if (scrubCredentials(resp)) {
            std.debug.print("  resp.body   = (suppressed: credential pattern detected)\n", .{});
        } else {
            // Hash the first 32 bytes so the operator can correlate
            // failures across runs without the full body in the log.
            var head_hash_buf: [32]u8 = undefined;
            const head = if (resp.len < 32) resp else resp[0..32];
            const Sha256 = std.crypto.hash.sha2.Sha256;
            var digest: [Sha256.digest_length]u8 = undefined;
            Sha256.hash(head, &digest, .{});
            std.debug.print("  resp.head_sha = {s}\n", .{hex(&head_hash_buf, digest[0..8])});
        }
    }
    std.debug.print("=== /otel-zig live OTLP/HTTPS emission ===\n\n", .{});

    if (result != .success and result != .partial_success) {
        std.debug.print("unexpected export result: {s}\n", .{@tagName(result)});
        return error.UnexpectedExportResult;
    }

    // Light verification: the collector returns an
    // `ExportTraceServiceResponse` whose body is empty (`0a 00`) when
    // no spans were rejected, OR includes a populated
    // `partial_success` submessage when some were rejected. Anything
    // longer than ~32 bytes likely contains a rejection reason — fail
    // the test so CI surfaces it.
    if (exporter.lastResponseBody().len > 32) {
        std.debug.print("collector returned a long response body — likely a partial-success rejection. See body above.\n", .{});
        return error.PartialSuccessReported;
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
