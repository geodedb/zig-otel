// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// HTTP transport seam for the OTLP/HTTP exporter.
//
// Split out of `src/exporters/otlp_http.zig` as part of OTEL-Q-001
// (gitlab #149). Hosts the `Transport` tagged-union dispatch (closes
// OTEL-Q-NEW-A, gitlab #163), the retry classifier, and the in-house
// `std.http.Client`-based stdlib transport implementation.
//
// Pre-refactor the dispatch site at `expSpans`/`expMetrics` compared the
// transport function pointer against an `httpTransport` sentinel by
// pointer identity. LTO/inlining or wrapping the fn in a closure would
// have silently broken the production path. The tagged union flips
// dispatch to a `switch` that is type-checked and exhaustive.

const std = @import("std");
const build_options = @import("build_options");
const headers = @import("headers.zig");

/// Buffer the in-process stdlib transport uses to capture the most
/// recent response body. Held inline on the exporter struct so callers
/// can inspect partial-success responses without re-issuing the call.
pub const last_response_body_capacity: usize = 1024;

pub const TransportResult = struct {
    status: u16,
    body: []const u8,
};

/// Function-pointer signature for caller-injected transports. Tests use
/// this to substitute an in-memory fake; the production path goes
/// through `Transport.stdlib_io`.
pub const CustomFn = *const fn (
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    path: []const u8,
    headers_str: ?[]const u8,
    content_type: []const u8,
    body: []const u8,
    timeout_ms: u64,
) anyerror!TransportResult;

/// Dispatch shape for `OtlpHttpExporter`. The previous fn-pointer-only
/// design dispatched between in-house and caller-supplied transports by
/// comparing pointer identity against a sentinel — fragile under LTO,
/// inlining, or fn-wrapping. The tagged union removes that footgun and
/// makes the dispatch type-checked.
///
///  - `.stdlib_io` routes through `httpTransportImpl`, which uses the
///    `OtlpHttpExporter`'s own `std.Io` instance.
///  - `.custom` carries a fn pointer and is dispatched directly.
///
/// Test code sets `.custom` to substitute an in-memory transport;
/// production callers leave the field at its `init`-time default of
/// `.stdlib_io`.
pub const Transport = union(enum) {
    stdlib_io,
    custom: CustomFn,
};

/// Retry verdict for a single OTLP/HTTP response status. The dispatch
/// loop in `exporter.exportSignal` asks the classifier per response
/// rather than open-coding the rules at every call site.
///
/// OTEL-Q-NEW-C (gitlab #164, out of scope for this PR) tracks adding
/// 408 / 425 to the retryable bucket; this classifier is the seam that
/// fix will land on.
pub const RetryClass = enum {
    /// 2xx (excluding 207). Hand `.success` back to the SDK.
    success,
    /// 207 multistatus — collector accepted some items, rejected
    /// others. The exporter surfaces this verbatim as
    /// `error.PartialSuccess` so callers can decide to drop, retry, or
    /// re-batch.
    partial,
    /// 5xx or 429. Apply backoff and try again until budget exhausted.
    retryable,
    /// 4xx (other than 429). Drop and surface
    /// `error.RetryExhausted` — retrying a client-side bug never wins.
    fatal,
};

/// Classify an HTTP status code per OTLP retry semantics
/// (https://github.com/open-telemetry/opentelemetry-specification/blob/main/specification/protocol/exporter.md).
///
/// The output is intentionally narrow so additional retryable codes
/// (408 Request Timeout, 425 Too Early — see OTEL-Q-NEW-C / #164) can
/// be added without touching the dispatch loop.
pub fn retryClassifyHttp(status: u16) RetryClass {
    if (status == 207) return .partial;
    if (status >= 200 and status < 300) return .success;
    if (status == 429) return .retryable;
    if (status >= 500) return .retryable;
    if (status >= 400) return .fatal;
    return .fatal;
}

/// The set of transport-level errors the export loop treats as
/// retryable. Anything else is rethrown to the caller.
pub fn isRetryableTransportError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.UnsupportedTransport,
        error.NetworkUnreachable,
        => true,
        else => false,
    };
}

/// Real HTTP/HTTPS transport, gated on `-Dotel_use_devnw_tls=true`. The
/// build flag's name reflects the original Phase 6 plan (DevNW `tls`); we
/// pivoted to `std.http.Client` because the DevNW package is QUIC-first
/// (RFC 9001) and exposes no TLS-over-TCP record layer. The DevNW `tls`
/// dep stays pinned for future QUIC integration; see
/// `docs/DEPENDENCIES.md` (TLS row) for the full rationale.
///
/// Returns `error.UnsupportedTransport` when the flag is off or the
/// caller did not plumb an `io`, preserving the loud-failure contract.
///
/// `endpoint` and `header_str` come from the exporter's `OtlpConfig`.
/// `last_body_buf` and `last_body_len` are pointers into the
/// exporter's response-stash so collectors-side error bodies are
/// readable via `lastResponseBody()`. `last_status` mirrors the
/// `lastResponseStatus()` accessor.
pub fn httpTransportImpl(
    allocator: std.mem.Allocator,
    io_opt: ?std.Io,
    endpoint: []const u8,
    header_str: ?[]const u8,
    path: []const u8,
    content_type: []const u8,
    body: []const u8,
    last_body_buf: *[last_response_body_capacity]u8,
    last_body_len: *usize,
    last_status: *u16,
) anyerror!TransportResult {
    if (!build_options.use_devnw_tls) return error.UnsupportedTransport;
    const io = io_opt orelse return error.UnsupportedTransport;

    // Build full URL: endpoint already validated as starting with "http://"
    // or "https://" in `init`. Strip any trailing slash so an endpoint of
    // "http://x:8080/" + path "/v1/traces" doesn't yield "/v1//v1/traces".
    const trimmed_endpoint = std.mem.trimEnd(u8, endpoint, "/");
    const full_url = try std.fmt.allocPrint(allocator, "{s}{s}", .{ trimmed_endpoint, path });
    defer allocator.free(full_url);

    // `extra_headers` is borrowed by `fetch` for the duration of the call.
    // Always include content-type; optionally fold in user-supplied
    // headers (comma-separated `k=v` pairs from `OtlpConfig.headers`).
    // The parser (GAP-SEC-H-1) rejects CR/LF, control bytes, and any
    // user-supplied content-type so the exporter's canonical value wins.
    var headers_list: std.ArrayListUnmanaged(std.http.Header) = .empty;
    defer headers_list.deinit(allocator);
    try headers_list.append(allocator, .{ .name = "content-type", .value = content_type });
    if (header_str) |hdr_str| {
        var parsed_buf: [32]headers.HeaderEntry = undefined;
        const parsed = headers.parseHeaderString(hdr_str, &parsed_buf) catch |err| switch (err) {
            error.InvalidHeader, error.HeaderListTooLarge => return error.InvalidHeader,
        };
        for (parsed) |entry| {
            try headers_list.append(allocator, .{ .name = entry.name, .value = entry.value });
        }
    }

    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    // Capture the response body so callers can introspect partial-success
    // info and collector-side error messages without re-issuing the call.
    // Sized to the OtlpHttpExporter's stash so we never copy more than
    // the caller can hold; over-large payloads are truncated.
    var resp_writer: std.Io.Writer.Allocating = .init(allocator);
    defer resp_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = full_url },
        .method = .POST,
        .payload = body,
        .extra_headers = headers_list.items,
        .response_writer = &resp_writer.writer,
    });

    const written = resp_writer.written();
    const stash_len = @min(written.len, last_body_buf.len);
    @memcpy(last_body_buf[0..stash_len], written[0..stash_len]);
    last_body_len.* = stash_len;
    last_status.* = @intFromEnum(result.status);

    return .{ .status = @intFromEnum(result.status), .body = last_body_buf[0..stash_len] };
}

test "retryClassifyHttp success bucket covers 200..299 except 207" {
    try std.testing.expectEqual(RetryClass.success, retryClassifyHttp(200));
    try std.testing.expectEqual(RetryClass.success, retryClassifyHttp(204));
    try std.testing.expectEqual(RetryClass.success, retryClassifyHttp(299));
    try std.testing.expectEqual(RetryClass.partial, retryClassifyHttp(207));
}

test "retryClassifyHttp marks 429 + 5xx retryable, 4xx fatal" {
    try std.testing.expectEqual(RetryClass.retryable, retryClassifyHttp(429));
    try std.testing.expectEqual(RetryClass.retryable, retryClassifyHttp(500));
    try std.testing.expectEqual(RetryClass.retryable, retryClassifyHttp(503));
    try std.testing.expectEqual(RetryClass.retryable, retryClassifyHttp(599));
    try std.testing.expectEqual(RetryClass.fatal, retryClassifyHttp(400));
    try std.testing.expectEqual(RetryClass.fatal, retryClassifyHttp(404));
    try std.testing.expectEqual(RetryClass.fatal, retryClassifyHttp(499));
}

test "isRetryableTransportError catches the documented network errors" {
    try std.testing.expect(isRetryableTransportError(error.ConnectionRefused));
    try std.testing.expect(isRetryableTransportError(error.ConnectionResetByPeer));
    try std.testing.expect(isRetryableTransportError(error.UnsupportedTransport));
    try std.testing.expect(isRetryableTransportError(error.NetworkUnreachable));
    try std.testing.expect(!isRetryableTransportError(error.OutOfMemory));
}
