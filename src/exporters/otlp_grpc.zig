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

    pub fn init(allocator: std.mem.Allocator, config: config_mod.OtlpConfig) !OtlpGrpcExporter {
        if (config.endpoint.len == 0) return error.InvalidEndpoint;
        if (config.protocol != .grpc) return error.InvalidConfig;
        return .{
            .allocator = allocator,
            .config = config,
            .prng = std.Random.DefaultPrng.init(0xC0DE_C0FFEE),
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
        const parsed = try parseGrpcEndpoint(self.config.endpoint);
        if (parsed.scheme_secure and !self.config.insecure) {
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
};

fn doShutdown(ctx: ?*anyopaque) void {
    const self: *OtlpGrpcExporter = @ptrCast(@alignCast(ctx.?));
    self.closed = true;
}

fn doFlush(_: ?*anyopaque, _: u64) anyerror!void {}

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

    // Parse host + port out of the endpoint URL. `OtlpConfig.endpoint`
    // is canonically `http://host:port` (or `https://...`); for gRPC we
    // ignore the scheme — h2c is the only mode the loopback server
    // speaks, and TLS-wrapped h2 would route through a different
    // transport seam (see DEPENDENCIES.md, gRPC row).
    const parsed = try parseGrpcEndpoint(self.config.endpoint);

    var attempt: u32 = 0;
    var elapsed_ms: u64 = 0;
    const policy: exp.RetryPolicy = .{};
    const max_attempts: u32 = 5;
    while (true) {
        const status = unaryExport(aa, io, parsed.host, parsed.port, body) catch |err| {
            attempt += 1;
            const backoff_ns = exp.nextBackoff(policy, attempt, &self.prng);
            elapsed_ms += backoff_ns / std.time.ns_per_ms;
            if (attempt >= max_attempts or elapsed_ms >= policy.max_elapsed_ms) return error.RetryExhausted;
            switch (err) {
                error.ConnectionRefused,
                error.ConnectionResetByPeer,
                error.UnsupportedTransport,
                error.NetworkUnreachable,
                error.WouldBlock,
                => continue,
                else => return err,
            }
        };
        switch (status) {
            .ok => return .success,
            .partial_success => return error.PartialSuccess,
            .retryable => {
                attempt += 1;
                const backoff_ns = exp.nextBackoff(policy, attempt, &self.prng);
                elapsed_ms += backoff_ns / std.time.ns_per_ms;
                if (attempt >= max_attempts or elapsed_ms >= policy.max_elapsed_ms) return error.RetryExhausted;
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
    body: []const u8,
) !GrpcStatus {
    if (!build_options.use_devnw_grpc) return error.UnsupportedTransport;

    var client = try grpc_zig.GrpcClient.init(allocator, io, host, port);
    defer client.deinit();

    // The method path is informational from grpc-zig's perspective — the
    // server routes to `handlers.items[0]` regardless (upstream
    // `server.zig:122-128`). For OTLP this is acceptable: real
    // collectors expose exactly one handler per gRPC service.
    const reply = client.call(
        "/opentelemetry.proto.collector.trace.v1.TraceService/Export",
        body,
        .none,
    ) catch |err| return err;
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
pub fn frame(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, body.len + 5);
    out[0] = 0; // compression: none
    std.mem.writeInt(u32, out[1..5], @intCast(body.len), .big);
    @memcpy(out[5..], body);
    return out;
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
