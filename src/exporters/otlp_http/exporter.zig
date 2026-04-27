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
const spans_mod = @import("spans.zig");
const metrics_mod = @import("metrics.zig");

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
        return .{
            .allocator = allocator,
            .config = config,
            .transport = .stdlib_io,
            // GAP-SEC-L-5: seed jitter PRNG from CSPRNG so two
            // exporter instances don't share a backoff schedule.
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
    fn dispatchTransport(
        self: *OtlpHttpExporter,
        arena_alloc: std.mem.Allocator,
        path: []const u8,
        content_type: []const u8,
        body: []const u8,
    ) anyerror!TransportResult {
        return switch (self.transport) {
            .stdlib_io => transport_mod.httpTransportImpl(
                arena_alloc,
                self.io,
                self.config.endpoint,
                self.config.headers,
                path,
                content_type,
                body,
                &self.last_response_body,
                &self.last_response_body_len,
                &self.last_response_status,
            ),
            .custom => |func| func(
                arena_alloc,
                self.config.endpoint,
                path,
                self.config.headers,
                content_type,
                body,
                self.config.timeout_ms,
            ),
        };
    }
};

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
