// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// `OtlpHttpExporter` struct + the shared `exportSignal` helper.
//
// Split out of `src/exporters/otlp_http.zig` as part of OTEL-Q-001
// (gitlab #149). Pre-split, `expSpans` (lines 277-322) and `expMetrics`
// (lines 348-392) were byte-identical retry/dispatch loops with only
// the body encoder and path string differing. The shared helper here
// removes that duplication.
//
// The pre-refactor dispatch sentinel did a fn-pointer-identity check
// against an `httpTransport` marker. It has been replaced by a `switch`
// over the `transport.Transport` tagged union — closes OTEL-Q-NEW-A
// (gitlab #163).

const std = @import("std");
const exp = @import("../../sdk/export.zig");
const config_mod = @import("../../sdk/config.zig");
const id_mod = @import("../../internal/id.zig");

const transport_mod = @import("transport.zig");
const compression_mod = @import("compression.zig");
const spans_mod = @import("spans.zig");
const metrics_mod = @import("metrics.zig");
const logs_mod = @import("logs.zig");

pub const OtlpConfig = config_mod.OtlpConfig;
pub const Transport = transport_mod.Transport;
pub const TransportResult = transport_mod.TransportResult;

pub const OtlpHttpExporter = struct {
    allocator: std.mem.Allocator,
    config: OtlpConfig,
    /// Pluggable transport. Tests inject `.{ .custom = fakeTransport }`;
    /// production leaves the field at the `.stdlib_io` default. The
    /// dispatch site in `exportSignal` switches on the tag, replacing
    /// the pre-refactor fn-pointer-identity sentinel that compared the
    /// transport pointer against an `httpTransport` marker — fragile
    /// under LTO/inlining and now removed.
    transport: Transport = .stdlib_io,
    /// Optional `std.Io` used by the real HTTP transport. The default
    /// `.stdlib_io` transport requires this when
    /// `-Dotel_use_devnw_tls=true`; if it is `null`, `httpTransportImpl`
    /// returns `error.UnsupportedTransport`. Callers that swap in a
    /// custom transport (the test suite does) do not need to set this —
    /// the function pointer is dispatched directly.
    io: ?std.Io = null,
    // fips-exempt: non-security — exporter-local ID/jitter PRNG; not a secret.
    prng: std.Random.DefaultPrng,
    closed: bool = false,
    /// GAP-SEC-M-6: the response-body buffer is now read-only via the
    /// `lastResponseBody`/`lastResponseStatus` accessors. The fields
    /// remain pub for the in-process httpTransportImpl writer (which
    /// lives in `transport.zig`) and the live integration test that
    /// reads them, but the accessor surface is what callers should
    /// use.
    last_response_status: u16 = 0,
    last_response_body: [transport_mod.last_response_body_capacity]u8 = undefined,
    last_response_body_len: usize = 0,

    /// Returns the most recent response body slice (empty when none
    /// captured). The slice is valid until the next `expSpans` call.
    pub fn lastResponseBody(self: *const OtlpHttpExporter) []const u8 {
        return self.last_response_body[0..self.last_response_body_len];
    }

    /// Returns the most recent response HTTP status code (0 when none
    /// captured).
    pub fn lastResponseStatus(self: *const OtlpHttpExporter) u16 {
        return self.last_response_status;
    }

    pub fn init(allocator: std.mem.Allocator, config: OtlpConfig) !OtlpHttpExporter {
        if (config.endpoint.len == 0) return error.InvalidEndpoint;
        if (!std.mem.startsWith(u8, config.endpoint, "http://") and !std.mem.startsWith(u8, config.endpoint, "https://")) {
            return error.InvalidEndpoint;
        }
        // AS-1: SSRF guard at construction. Previously only Config.validate()
        // (reached via Config.resolve()) ran this check, so the factory /
        // initFromConfig / direct-construction paths could reach
        // http://169.254.169.254/ (cloud instance-metadata SSRF) and other
        // link-local / loopback hosts. Enforce it here so every exporter
        // construction path is covered.
        try config_mod.validateEndpoint(config.endpoint, config.allow_loopback);
        return .{
            .allocator = allocator,
            .config = config,
            .transport = .stdlib_io,
            // GAP-SEC-L-5: seed jitter PRNG from CSPRNG so two
            // exporter instances don't share a backoff schedule.
            // fips-exempt: non-security — exporter PRNG (see field above).
            .prng = std.Random.DefaultPrng.init(id_mod.csprngU64()),
        };
    }

    pub fn deinit(self: *OtlpHttpExporter) void {
        self.closed = true;
    }

    pub fn spanExporter(self: *OtlpHttpExporter) exp.SpanExporter {
        return .{ .ctx = self, .exportFn = spans_mod.expSpans, .shutdownFn = doShutdown, .forceFlushFn = doFlush };
    }

    /// OTLP/HTTP metric exporter (GAP-OTLP-METRIC-EXPORT, gitlab #7).
    /// Posts an `ExportMetricsServiceRequest` to `/v1/metrics` using the
    /// same transport/retry/headers plumbing as `spanExporter`.
    pub fn metricExporter(self: *OtlpHttpExporter) exp.MetricExporter {
        return .{ .ctx = self, .exportFn = metrics_mod.expMetrics, .shutdownFn = doShutdown, .forceFlushFn = doFlush };
    }

    /// OTLP/HTTP log exporter (GAP-OTLP-LOG-EXPORT, gitlab #8). Posts an
    /// `ExportLogsServiceRequest` to `/v1/logs` using the same
    /// transport/retry/headers plumbing as `spanExporter`/`metricExporter`.
    pub fn logExporter(self: *OtlpHttpExporter) exp.LogExporter {
        return .{ .ctx = self, .exportFn = logs_mod.expLogs, .shutdownFn = doShutdown, .forceFlushFn = doFlush };
    }

    /// Shared retry/dispatch loop used by both `expSpans` (in
    /// `spans.zig`) and `expMetrics` (in `metrics.zig`). Pre-refactor
    /// each export function carried a byte-identical copy of this loop;
    /// extracting it removes ~50 LOC of duplication and makes the
    /// classifier (`transport.retryClassifyHttp`) the single source of
    /// retry policy.
    ///
    /// Caller responsibilities:
    ///   - `arena_alloc` — the per-call arena allocator. The transport
    ///     borrows it; on retry it is reused (the body is still valid).
    ///   - `path` — `/v1/traces` or `/v1/metrics`.
    ///   - `content_type` — protobuf or JSON, chosen by the caller per
    ///     the configured protocol.
    ///   - `body` — the encoded payload. Borrowed by the transport.
    ///
    /// Returns the standard `SpanExportResult` shape (which is also
    /// what `MetricExporter.exportMetrics` returns — both signal types
    /// share the result enum).
    pub fn exportSignal(
        self: *OtlpHttpExporter,
        arena_alloc: std.mem.Allocator,
        path: []const u8,
        content_type: []const u8,
        body: []const u8,
    ) anyerror!exp.SpanExportResult {
        var retry: exp.RetryState = .{};
        while (true) {
            const result = self.dispatchTransport(arena_alloc, path, content_type, body) catch |err| {
                // Tagged-union dispatch reports network-style failures the
                // same way the legacy fn-pointer dispatch did: the
                // classifier filter decides which become retries vs.
                // bubble out.
                if (!transport_mod.isRetryableTransportError(err)) return err;
                if (!retry.shouldRetry(&self.prng)) return error.RetryExhausted;
                continue;
            };
            switch (transport_mod.retryClassifyHttp(result.status)) {
                .success => return .success,
                .partial => return error.PartialSuccess,
                .fatal => return error.RetryExhausted,
                .retryable => {
                    if (!retry.shouldRetry(&self.prng)) return error.RetryExhausted;
                    continue;
                },
            }
        }
    }

    /// One-shot transport invocation. Switches on the `Transport` tag
    /// (replaces the pre-refactor fn-pointer-identity check that
    /// compared the transport pointer against an `httpTransport`
    /// marker).
    ///
    /// GAP-OTLP-COMPRESSION (#27): when `OtlpConfig.compression == .gzip`
    /// the body is gzipped here (via `compression_mod.gzipBody`) and a
    /// `content-encoding=gzip` header is appended to the user-supplied
    /// header string. The `parseHeaderString` parser already accepts
    /// arbitrary RFC 7230 token names — `content-encoding` rides through
    /// unchanged. The compressed buffer is owned by `arena_alloc`, which
    /// the retry loop owns for the duration of the export call, so it
    /// survives any retry without leaking.
    fn dispatchTransport(
        self: *OtlpHttpExporter,
        arena_alloc: std.mem.Allocator,
        path: []const u8,
        content_type: []const u8,
        body: []const u8,
    ) anyerror!TransportResult {
        const wire_body, const wire_headers = try maybeGzip(
            arena_alloc,
            self.config.compression,
            self.config.headers,
            body,
        );

        return switch (self.transport) {
            .stdlib_io => transport_mod.httpTransportImpl(
                arena_alloc,
                self.io,
                self.config.endpoint,
                wire_headers,
                path,
                content_type,
                wire_body,
                &self.last_response_body,
                &self.last_response_body_len,
                &self.last_response_status,
            ),
            .custom => |func| func(
                arena_alloc,
                self.config.endpoint,
                path,
                wire_headers,
                content_type,
                wire_body,
                self.config.timeout_ms,
            ),
        };
    }
};

/// GAP-OTLP-COMPRESSION (#27): if compression is gzip, return gzipped
/// body bytes plus a header string with `content-encoding=gzip`
/// appended. Otherwise return the inputs unchanged. The returned slices
/// are owned by `arena` (the per-call arena allocator). Allocations
/// only happen on the gzip branch, so the `.none` path stays
/// allocation-free.
fn maybeGzip(
    arena: std.mem.Allocator,
    compression: @TypeOf(@as(OtlpConfig, .{}).compression),
    headers: ?[]const u8,
    body: []const u8,
) !struct { []const u8, ?[]const u8 } {
    switch (compression) {
        .none => return .{ body, headers },
        .gzip => {
            const gz = try compression_mod.gzipBody(arena, body);
            // Append `content-encoding=gzip` to the user-supplied
            // headers string. Format: `k=v[, k=v...]` per
            // OTEL_EXPORTER_OTLP_HEADERS. `parseHeaderString` trims
            // whitespace and skips empty entries, so a leading "," on
            // the empty-headers branch would also be tolerated — we
            // emit a clean form regardless to keep wire-tap traces
            // readable.
            const header_pair: []const u8 = "content-encoding=gzip";
            const merged: []const u8 = if (headers) |existing|
                if (existing.len == 0)
                    try arena.dupe(u8, header_pair)
                else
                    try std.fmt.allocPrint(arena, "{s}, {s}", .{ existing, header_pair })
            else
                try arena.dupe(u8, header_pair);
            return .{ gz, merged };
        },
    }
}

fn doShutdown(ctx: ?*anyopaque) void {
    const self: *OtlpHttpExporter = @ptrCast(@alignCast(ctx.?));
    self.closed = true;
}

fn doFlush(_: ?*anyopaque, _: u64) anyerror!void {}

test "init rejects empty endpoint" {
    try std.testing.expectError(error.InvalidEndpoint, OtlpHttpExporter.init(std.testing.allocator, .{ .endpoint = "" }));
}

test "init rejects unsupported scheme" {
    try std.testing.expectError(error.InvalidEndpoint, OtlpHttpExporter.init(std.testing.allocator, .{ .endpoint = "ftp://otel" }));
}
