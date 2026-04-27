// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// OTLP/gRPC exporter — limited to unary calls. Wire-frames are protobuf
// payloads with the gRPC 5-byte length-prefixed envelope. When
// `-Dotel_use_devnw_grpc=true` is set and the caller plumbs a `std.Io`,
// the real transport routes through DevNW `grpc-zig`'s `GrpcClient`.
// Without the flag (or without an `Io`), `expSpans` returns
// `error.UnsupportedTransport` so misconfiguration fails loud.

const std = @import("std");
const exp = @import("../sdk/export.zig");
const config_mod = @import("../sdk/config.zig");
const otlp_http = @import("otlp_http.zig");
const id_mod = @import("../internal/id.zig");
const build_options = @import("build_options");

// Conditional import — when the flag is off this resolves to `struct {}`
// so the gated code below compiles to a no-op stub. The Zig comptime
// branch elision in `expSpans` keeps the gRPC client out of the binary
// in hermetic builds. The umbrella module (`grpc_zig`) collapses
// upstream's two-module split (`grpc-client` + `grpc-server`) into one
// module identity — see `build.zig` and `third_party/grpc_zig/all.zig`
// for the rationale.
const grpc_zig = if (build_options.use_devnw_grpc) @import("grpc_zig") else struct {};

pub const OtlpGrpcExporter = struct {
    allocator: std.mem.Allocator,
    config: config_mod.OtlpConfig,
    /// Optional `std.Io` used by the real gRPC transport. When the
    /// `-Dotel_use_devnw_grpc` flag is on this must be plumbed before
    /// `exportSpans` is called; otherwise `expSpans` returns
    /// `error.UnsupportedTransport`. Mirrors the Phase 6
    /// `OtlpHttpExporter.io` pattern so processor wiring is symmetric.
    io: ?std.Io = null,
    prng: std.Random.DefaultPrng,
    closed: bool = false,
    /// PR-9 (#143): parsed endpoint cached at `init`. The endpoint is
    /// immutable for the exporter's lifetime, so reparsing it on every
    /// export was pure waste. The cached slices borrow from
    /// `config.endpoint`; that field's lifetime is the caller's
    /// responsibility (same as before — nothing in `config` is owned).
    parsed_endpoint: ParsedEndpoint,

    pub fn init(allocator: std.mem.Allocator, config: config_mod.OtlpConfig) !OtlpGrpcExporter {
        if (config.endpoint.len == 0) return error.InvalidEndpoint;
        if (config.protocol != .grpc) return error.InvalidConfig;
        // PR-9 (#143): parse the endpoint once at init so a malformed
        // URL is rejected here instead of at first export. The parsed
        // host/port/scheme become a borrow over `config.endpoint`,
        // which is stored by value below — so the cached slices stay
        // valid for the exporter's lifetime as long as the caller keeps
        // the original `config.endpoint` storage alive (same lifetime
        // contract as before).
        const parsed = try parseGrpcEndpoint(config.endpoint);
        return .{
            .allocator = allocator,
            .config = config,
            // GAP-SEC-L-5: seed jitter PRNG from CSPRNG so two
            // exporter instances don't share a backoff schedule.
            .prng = std.Random.DefaultPrng.init(id_mod.csprngU64()),
            .parsed_endpoint = parsed,
        };
    }

    /// GAP-SEC-C-2 / GAP-SEC-C-3: pre-flight checks that refuse to export
    /// in known-unsafe configurations. Runs before any IO so the bad
    /// config is caught even when the gRPC client itself is gated out at
    /// build time.
    ///
    /// Refuses (with `error.UnsupportedTransport`):
    ///   - C-2: `https://` endpoint while `insecure == false` — grpc-zig
    ///     does not yet expose a TLS-capable client, so the request would
    ///     silently downgrade to plaintext h2c. Track when TLS lands in
    ///     docs/DEPENDENCIES.md (gRPC row).
    ///   - C-3: `headers != null and headers.len > 0` — grpc-zig has no
    ///     metadata API yet; the headers (typically `Authorization`)
    ///     would be silently dropped, exporting telemetry without auth.
    pub fn checkExportPreconditions(self: *const OtlpGrpcExporter) !void {
        // PR-9 (#143): use the endpoint parsed once at `init` instead of
        // reparsing per call.
        if (self.parsed_endpoint.scheme_secure and !self.config.insecure) {
            return error.UnsupportedTransport;
        }
        if (self.config.headers) |h| {
            if (h.len > 0) return error.UnsupportedTransport;
        }
    }

    pub fn deinit(self: *OtlpGrpcExporter) void {
        self.closed = true;
    }

    pub fn spanExporter(self: *OtlpGrpcExporter) exp.SpanExporter {
        return .{ .ctx = self, .exportFn = expSpans, .shutdownFn = doShutdown, .forceFlushFn = doFlush };
    }

    /// OTLP/gRPC metric exporter (GAP-OTLP-METRIC-EXPORT, gitlab #7).
    /// Routes through `MetricsService/Export` instead of
    /// `TraceService/Export`. Reuses the same retry, header, and
    /// pre-flight pipeline as `spanExporter`.
    pub fn metricExporter(self: *OtlpGrpcExporter) exp.MetricExporter {
        return .{ .ctx = self, .exportFn = expMetrics, .shutdownFn = doShutdown, .forceFlushFn = doFlush };
    }

    /// OTLP/gRPC log exporter (GAP-OTLP-LOG-EXPORT, gitlab #8). Routes
    /// through `opentelemetry.proto.collector.logs.v1.LogsService/Export`.
    /// Reuses the same retry, header, and pre-flight pipeline as
    /// `spanExporter` / `metricExporter`.
    pub fn logExporter(self: *OtlpGrpcExporter) exp.LogExporter {
        return .{ .ctx = self, .exportFn = expLogs, .shutdownFn = doShutdown, .forceFlushFn = doFlush };
    }
};

fn doShutdown(ctx: ?*anyopaque) void {
    const self: *OtlpGrpcExporter = @ptrCast(@alignCast(ctx.?));
    self.closed = true;
}

fn doFlush(_: ?*anyopaque, _: u64) anyerror!void {}

const trace_export_method = "/opentelemetry.proto.collector.trace.v1.TraceService/Export";
const metrics_export_method = "/opentelemetry.proto.collector.metrics.v1.MetricsService/Export";
/// OTLP/gRPC log export method path. GAP-OTLP-LOG-EXPORT (#8).
/// Routes the encoded `ExportLogsServiceRequest` through grpc-zig's
/// `GrpcClient.call` exactly like the trace and metrics paths.
const logs_export_method = "/opentelemetry.proto.collector.logs.v1.LogsService/Export";

fn expSpans(ctx: ?*anyopaque, items: []const exp.SpanData) anyerror!exp.SpanExportResult {
    const self: *OtlpGrpcExporter = @ptrCast(@alignCast(ctx.?));
    if (self.closed) return error.RetryExhausted;
    if (items.len == 0) return .success;

    // GAP-SEC-C-2 / GAP-SEC-C-3: refuse https:// (would silently downgrade
    // to plaintext h2c without TLS support) and any non-empty headers
    // (would be silently dropped, exporting unauthenticated). Run before
    // the build-flag gate so the bad config is caught even when the gRPC
    // client itself is not compiled in.
    try self.checkExportPreconditions();

    if (!build_options.use_devnw_grpc) return error.UnsupportedTransport;
    const io = self.io orelse return error.UnsupportedTransport;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Encode once outside the retry loop — the request body is identical
    // across retries and the protobuf bytes only depend on `items`.
    const body = try otlp_http.encodeSpansProto(aa, items);

    // PR-9 (#143): use the endpoint parsed once at `init`. `OtlpConfig.endpoint`
    // is canonically `http://host:port` (or `https://...`); for gRPC we
    // ignore the scheme — h2c is the only mode the loopback server
    // speaks, and TLS-wrapped h2 would route through a different
    // transport seam (see DEPENDENCIES.md, gRPC row).
    const parsed = self.parsed_endpoint;

    var retry: exp.RetryState = .{};
    while (true) {
        const status = unaryExport(aa, io, parsed.host, parsed.port, trace_export_method, body) catch |err| {
            switch (err) {
                error.ConnectionRefused,
                error.ConnectionResetByPeer,
                error.UnsupportedTransport,
                error.NetworkUnreachable,
                error.WouldBlock,
                => {},
                else => return err,
            }
            if (!retry.shouldRetry(&self.prng)) return error.RetryExhausted;
            continue;
        };
        switch (status) {
            .ok => return .success,
            .partial_success => return error.PartialSuccess,
            .retryable => {
                if (!retry.shouldRetry(&self.prng)) return error.RetryExhausted;
                continue;
            },
            .fatal => return error.RetryExhausted,
        }
    }
}

fn expMetrics(ctx: ?*anyopaque, items: []const exp.MetricData) anyerror!exp.SpanExportResult {
    const self: *OtlpGrpcExporter = @ptrCast(@alignCast(ctx.?));
    if (self.closed) return error.RetryExhausted;
    if (items.len == 0) return .success;

    // Same C-2 / C-3 pre-flight as `expSpans` — refuse https:// without
    // insecure flag, refuse non-empty headers (grpc-zig has no TLS or
    // metadata API yet, so silently dropping these would export unauth
    // data over plaintext).
    try self.checkExportPreconditions();

    if (!build_options.use_devnw_grpc) return error.UnsupportedTransport;
    const io = self.io orelse return error.UnsupportedTransport;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const body = try otlp_http.encodeMetricsProto(aa, items);
    // PR-9 (#143): use the endpoint parsed once at `init` (see expSpans).
    const parsed = self.parsed_endpoint;

    var retry: exp.RetryState = .{};
    while (true) {
        const status = unaryExport(aa, io, parsed.host, parsed.port, metrics_export_method, body) catch |err| {
            switch (err) {
                error.ConnectionRefused,
                error.ConnectionResetByPeer,
                error.UnsupportedTransport,
                error.NetworkUnreachable,
                error.WouldBlock,
                => {},
                else => return err,
            }
            if (!retry.shouldRetry(&self.prng)) return error.RetryExhausted;
            continue;
        };
        switch (status) {
            .ok => return .success,
            .partial_success => return error.PartialSuccess,
            .retryable => {
                if (!retry.shouldRetry(&self.prng)) return error.RetryExhausted;
                continue;
            },
            .fatal => return error.RetryExhausted,
        }
    }
}

fn expLogs(ctx: ?*anyopaque, items: []const exp.LogData) anyerror!exp.SpanExportResult {
    const self: *OtlpGrpcExporter = @ptrCast(@alignCast(ctx.?));
    if (self.closed) return error.RetryExhausted;
    if (items.len == 0) return .success;

    // Same C-2 / C-3 pre-flight as `expSpans` / `expMetrics`.
    try self.checkExportPreconditions();

    if (!build_options.use_devnw_grpc) return error.UnsupportedTransport;
    const io = self.io orelse return error.UnsupportedTransport;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const body = try otlp_http.encodeLogsProto(aa, items);
    const parsed = self.parsed_endpoint;

    var retry: exp.RetryState = .{};
    while (true) {
        const status = unaryExport(aa, io, parsed.host, parsed.port, logs_export_method, body) catch |err| {
            switch (err) {
                error.ConnectionRefused,
                error.ConnectionResetByPeer,
                error.UnsupportedTransport,
                error.NetworkUnreachable,
                error.WouldBlock,
                => {},
                else => return err,
            }
            if (!retry.shouldRetry(&self.prng)) return error.RetryExhausted;
            continue;
        };
        switch (status) {
            .ok => return .success,
            .partial_success => return error.PartialSuccess,
            .retryable => {
                if (!retry.shouldRetry(&self.prng)) return error.RetryExhausted;
                continue;
            },
            .fatal => return error.RetryExhausted,
        }
    }
}

const GrpcStatus = enum { ok, partial_success, retryable, fatal };

const ParsedEndpoint = struct {
    host: []const u8,
    port: u16,
    /// True when the endpoint scheme was `https://`. Until grpc-zig grows
    /// a TLS-capable client, an https:// URL paired with `insecure=false`
    /// must be refused to avoid a silent plaintext downgrade
    /// (GAP-SEC-C-2).
    scheme_secure: bool,
};

/// Strip the optional `http://` / `https://` scheme and split `host:port`.
/// Defaults the port to 4317 (the OTLP/gRPC standard) when the endpoint
/// omits it. Records whether the scheme was https (see `scheme_secure`).
fn parseGrpcEndpoint(endpoint: []const u8) !ParsedEndpoint {
    var rest = endpoint;
    var scheme_secure = false;
    if (std.mem.startsWith(u8, rest, "https://")) {
        rest = rest["https://".len..];
        scheme_secure = true;
    } else if (std.mem.startsWith(u8, rest, "http://")) {
        rest = rest["http://".len..];
    }
    // Drop any path component — gRPC routes by HTTP/2 headers, not URL path.
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash| rest = rest[0..slash];
    if (std.mem.lastIndexOfScalar(u8, rest, ':')) |colon| {
        const host = rest[0..colon];
        const port_str = rest[colon + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidEndpoint;
        if (host.len == 0) return error.InvalidEndpoint;
        return .{ .host = host, .port = port, .scheme_secure = scheme_secure };
    }
    if (rest.len == 0) return error.InvalidEndpoint;
    return .{ .host = rest, .port = 4317, .scheme_secure = scheme_secure };
}

/// Issue a single unary OTLP/gRPC export call against the given host:port.
/// Returns the gRPC status mapped to a coarse outcome for the retry loop.
///
/// Implementation note: grpc-zig's `GrpcClient.call(method, body, alg)`
/// already handles the 5-byte length-prefix framing internally
/// (see `grpc-zig/src/transport.zig: writeMessage`), so we pass the raw
/// protobuf bytes — *not* `frame()`-wrapped bytes. Calling `frame()` here
/// would produce double-framed output that the server would reject.
/// The `frame()` helper below is kept exposed for external callers that
/// drive a custom transport (and is exercised by its own unit test).
fn unaryExport(
    allocator: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    method: []const u8,
    body: []const u8,
) !GrpcStatus {
    if (!build_options.use_devnw_grpc) return error.UnsupportedTransport;

    var client = try grpc_zig.GrpcClient.init(allocator, io, host, port);
    defer client.deinit();

    // The method path is informational from grpc-zig's perspective — the
    // server routes to `handlers.items[0]` regardless (upstream
    // `server.zig:122-128`). Real collectors route by path, so the
    // caller is responsible for passing the right service method
    // (`TraceService/Export` vs `MetricsService/Export`).
    const reply = client.call(method, body, .none) catch |err| return err;
    defer allocator.free(reply);

    // grpc-zig's client surfaces neither the trailers nor the
    // `grpc-status` value — `call()` either returns the response bytes
    // or errors. A clean return therefore implies status OK; partial
    // success and retryable failures from the server come back through
    // io errors and the retry loop above.
    return .ok;
}

/// Frame `body` with the gRPC 5-byte length prefix (compressed=0, length).
/// Exposed for callers that drive a transport other than `grpc-zig`'s
/// `GrpcClient` (which frames internally). The unit test below pins the
/// wire shape against the OTLP spec.
///
/// GAP-SEC-M-7: refuses bodies larger than `std.math.maxInt(u32)`
/// (4 GiB - 1) with `error.MessageTooLarge` so the implicit
/// `@intCast(u32)` can never silently truncate. A truncated length
/// prefix produces a frame the server interprets as much shorter than
/// the actual payload, which the receiver then misroutes — at best a
/// parse error, at worst a smuggling primitive.
pub fn frame(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    if (body.len > std.math.maxInt(u32)) return error.MessageTooLarge;
    const out = try allocator.alloc(u8, body.len + 5);
    out[0] = 0; // compression: none
    std.mem.writeInt(u32, out[1..5], @intCast(body.len), .big);
    @memcpy(out[5..], body);
    return out;
}

/// Helper for tests — checks the bounds without allocating a 4 GiB
/// payload. Returns the same `error.MessageTooLarge` the real `frame`
/// would for an oversized input.
pub fn frameBoundCheck(body_len: u64) !void {
    if (body_len > std.math.maxInt(u32)) return error.MessageTooLarge;
}

test "frame prepends 5-byte length prefix" {
    const out = try frame(std.testing.allocator, "hello");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(u8, 0), out[0]);
    try std.testing.expectEqual(@as(u32, 5), std.mem.readInt(u32, out[1..5], .big));
    try std.testing.expectEqualSlices(u8, "hello", out[5..]);
}

test "init rejects non-grpc protocol" {
    try std.testing.expectError(error.InvalidConfig, OtlpGrpcExporter.init(std.testing.allocator, .{ .endpoint = "http://x", .protocol = .http_protobuf }));
}

test "parseGrpcEndpoint splits host and port" {
    const p = try parseGrpcEndpoint("http://127.0.0.1:4317");
    try std.testing.expectEqualStrings("127.0.0.1", p.host);
    try std.testing.expectEqual(@as(u16, 4317), p.port);
    try std.testing.expectEqual(false, p.scheme_secure);
}

test "parseGrpcEndpoint defaults port to 4317" {
    const p = try parseGrpcEndpoint("collector.example.com");
    try std.testing.expectEqualStrings("collector.example.com", p.host);
    try std.testing.expectEqual(@as(u16, 4317), p.port);
    try std.testing.expectEqual(false, p.scheme_secure);
}

test "parseGrpcEndpoint strips path component" {
    const p = try parseGrpcEndpoint("http://otel:4317/v1/traces");
    try std.testing.expectEqualStrings("otel", p.host);
    try std.testing.expectEqual(@as(u16, 4317), p.port);
    try std.testing.expectEqual(false, p.scheme_secure);
}

test "parseGrpcEndpoint records https scheme as secure" {
    const p = try parseGrpcEndpoint("https://collector.example.com:4317");
    try std.testing.expectEqual(true, p.scheme_secure);
}

test "C-2: checkExportPreconditions refuses https without insecure flag" {
    var exporter = try OtlpGrpcExporter.init(std.testing.allocator, .{
        .endpoint = "https://collector.example.com:4317",
        .protocol = .grpc,
    });
    defer exporter.deinit();
    try std.testing.expectError(error.UnsupportedTransport, exporter.checkExportPreconditions());
}

test "C-2: checkExportPreconditions allows http endpoint" {
    var exporter = try OtlpGrpcExporter.init(std.testing.allocator, .{
        .endpoint = "http://127.0.0.1:4317",
        .protocol = .grpc,
    });
    defer exporter.deinit();
    try exporter.checkExportPreconditions();
}

test "C-3: checkExportPreconditions refuses non-empty headers" {
    var exporter = try OtlpGrpcExporter.init(std.testing.allocator, .{
        .endpoint = "http://127.0.0.1:4317",
        .protocol = .grpc,
        .headers = "Authorization=Bearer x",
    });
    defer exporter.deinit();
    try std.testing.expectError(error.UnsupportedTransport, exporter.checkExportPreconditions());
}

test "expSpans returns UnsupportedTransport when flag off" {
    if (build_options.use_devnw_grpc) return error.SkipZigTest;
    var resource = @import("../sdk/resource.zig").Resource.init(std.testing.allocator);
    defer resource.deinit();
    var attr_set = @import("../internal/attributes.zig").AttributeSet.init(std.testing.allocator);
    defer attr_set.deinit();

    var exporter = try OtlpGrpcExporter.init(std.testing.allocator, .{
        .endpoint = "http://127.0.0.1:4317",
        .protocol = .grpc,
    });
    defer exporter.deinit();

    const span: exp.SpanData = .{
        .name = "x",
        .span_context = .{
            .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
            .span_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8 } },
        },
        .start_unix_nano = 1,
        .end_unix_nano = 2,
        .attributes = &attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "t" },
        .resource = &resource,
    };
    try std.testing.expectError(
        error.UnsupportedTransport,
        exporter.spanExporter().exportSpans(&[_]exp.SpanData{span}),
    );
}
