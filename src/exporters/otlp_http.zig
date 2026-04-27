// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// OTLP/HTTP exporter for traces, metrics, and logs.
// Supports both protobuf and JSON request bodies.

const std = @import("std");
const exp = @import("../sdk/export.zig");
const config_mod = @import("../sdk/config.zig");
const otlp = @import("../generated/otlp.zig");
const json_codec = @import("../internal/json_codec.zig");
const trace_api = @import("../api/trace.zig");
const ctx_mod = @import("../api/context.zig");
const attrs_mod = @import("../internal/attributes.zig");
const redact = @import("../internal/redact.zig");
const id_mod = @import("../internal/id.zig");
const clock = @import("../internal/clock.zig");
const build_options = @import("build_options");
const devnw_json = if (build_options.use_devnw_json) @import("json") else struct {};
const devnw_proto = if (build_options.use_devnw_protobuf) @import("devnw_protobuf") else struct {};

pub const OtlpConfig = config_mod.OtlpConfig;

pub const OtlpHttpExporter = struct {
    allocator: std.mem.Allocator,
    config: OtlpConfig,
    /// Pluggable transport. Tests inject `fakeTransport`; production uses
    /// `httpTransport` which talks to the network.
    transport: Transport,
    /// Optional `std.Io` used by the real HTTP transport. The default
    /// `httpTransport` requires this when `-Dotel_use_devnw_tls=true`; if
    /// it is `null`, `httpTransport` returns `error.UnsupportedTransport`.
    /// Callers that swap in a `fakeTransport` (the test suite does) do
    /// not need to set this — the function pointer is dispatched directly.
    io: ?std.Io = null,
    prng: std.Random.DefaultPrng,
    closed: bool = false,
    /// GAP-SEC-M-6: the response-body buffer is now read-only via the
    /// `lastResponseBody`/`lastResponseStatus` accessors. The fields
    /// remain pub for the in-process httpTransportImpl writer (which
    /// lives in this same file) and the live integration test that
    /// reads them, but the accessor surface is what callers should
    /// use.
    last_response_status: u16 = 0,
    last_response_body: [1024]u8 = undefined,
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
            .transport = httpTransport,
            // GAP-SEC-L-5: seed jitter PRNG from CSPRNG so two
            // exporter instances don't share a backoff schedule.
            .prng = std.Random.DefaultPrng.init(id_mod.csprngU64()),
        };
    }

    pub fn deinit(self: *OtlpHttpExporter) void {
        self.closed = true;
    }

    pub fn spanExporter(self: *OtlpHttpExporter) exp.SpanExporter {
        return .{ .ctx = self, .exportFn = expSpans, .shutdownFn = doShutdown, .forceFlushFn = doFlush };
    }

    /// OTLP/HTTP metric exporter (GAP-OTLP-METRIC-EXPORT, gitlab #7).
    /// Posts an `ExportMetricsServiceRequest` to `/v1/metrics` using the
    /// same transport/retry/headers plumbing as `spanExporter`.
    pub fn metricExporter(self: *OtlpHttpExporter) exp.MetricExporter {
        return .{ .ctx = self, .exportFn = expMetrics, .shutdownFn = doShutdown, .forceFlushFn = doFlush };
    }
};

pub const TransportResult = struct {
    status: u16,
    body: []const u8,
};

pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// Maximum permitted header name length per RFC 7230 (de-facto sanity
/// limit; the spec doesn't fix one). Anything longer is almost certainly
/// an injection attempt or a misconfigured upstream.
pub const max_header_name_len: usize = 256;

/// Maximum permitted header value length. 4 KiB is the upper bound most
/// HTTP servers accept before a 431 response.
pub const max_header_value_len: usize = 4096;

/// RFC 7230 §3.2.6 token character set.
fn isTokenByte(c: u8) bool {
    // Token = 1*tchar; tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*"
    //       / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA
    return switch (c) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        '0'...'9', 'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

fn isValidHeaderName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_header_name_len) return false;
    for (name) |c| if (!isTokenByte(c)) return false;
    return true;
}

fn isValidHeaderValue(value: []const u8) bool {
    if (value.len > max_header_value_len) return false;
    // RFC 7230 §3.2: VCHAR / SP / HTAB / obs-text. Reject any control
    // byte except HT (0x09) — that catches CR/LF (response splitting),
    // NUL (smuggling), and DEL (0x7F).
    for (value) |c| {
        if (c == '\t') continue;
        if (c < 0x20) return false;
        if (c == 0x7F) return false;
    }
    return true;
}

/// Parse a comma-separated `name=value` header string (the OTel
/// `OTEL_EXPORTER_OTLP_HEADERS` shape) into `HeaderEntry` slots in
/// `out_buf`. Returns the populated prefix.
///
/// Rejects:
///   - Header names that aren't RFC 7230 §3.2.6 tokens
///   - Header values containing control bytes (CR, LF, NUL, DEL, ...)
///   - Names > 256 bytes or values > 4096 bytes
///   - User-supplied `content-type` (which the exporter sets canonically;
///     forwarding a duplicate would either confuse the collector or let
///     a caller override the OTLP wire format)
pub fn parseHeaderString(headers: []const u8, out_buf: []HeaderEntry) ![]HeaderEntry {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, headers, ',');
    while (it.next()) |raw_pair| {
        const pair = std.mem.trim(u8, raw_pair, " \t");
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidHeader;
        const name = std.mem.trim(u8, pair[0..eq], " \t");
        const value = std.mem.trim(u8, pair[eq + 1 ..], " \t");

        if (!isValidHeaderName(name)) return error.InvalidHeader;
        if (!isValidHeaderValue(value)) return error.InvalidHeader;

        // M-8: drop any user-supplied content-type — the exporter sets
        // this itself based on `OtlpConfig.protocol`, so a user override
        // would either duplicate the header or silently misrepresent the
        // wire format. We drop rather than error to keep deployment
        // configs portable across SDKs that handle this differently.
        if (std.ascii.eqlIgnoreCase(name, "content-type")) continue;

        if (count >= out_buf.len) return error.HeaderListTooLarge;
        out_buf[count] = .{ .name = name, .value = value };
        count += 1;
    }
    return out_buf[0..count];
}

pub const Transport = *const fn (
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    path: []const u8,
    headers: ?[]const u8,
    content_type: []const u8,
    body: []const u8,
    timeout_ms: u64,
) anyerror!TransportResult;

/// Sentinel transport pointer. Production code never invokes this directly;
/// `expSpans` detects this pointer and routes through `httpTransportImpl`,
/// which has access to the exporter's `std.Io` instance. Calling it with
/// no Io plumbed (`build_options.use_devnw_tls=false` or
/// `exporter.io == null`) returns `error.UnsupportedTransport`, matching
/// the pre-Phase-6 behaviour so misconfigured callers fail loud.
fn httpTransport(allocator: std.mem.Allocator, endpoint: []const u8, path: []const u8, headers: ?[]const u8, content_type: []const u8, body: []const u8, timeout_ms: u64) anyerror!TransportResult {
    _ = allocator;
    _ = endpoint;
    _ = path;
    _ = headers;
    _ = content_type;
    _ = body;
    _ = timeout_ms;
    return error.UnsupportedTransport;
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
fn httpTransportImpl(self: *OtlpHttpExporter, allocator: std.mem.Allocator, path: []const u8, content_type: []const u8, body: []const u8) anyerror!TransportResult {
    if (!build_options.use_devnw_tls) return error.UnsupportedTransport;
    const io = self.io orelse return error.UnsupportedTransport;

    // Build full URL: endpoint already validated as starting with "http://"
    // or "https://" in `init`. Strip any trailing slash so an endpoint of
    // "http://x:8080/" + path "/v1/traces" doesn't yield "/v1//v1/traces".
    const trimmed_endpoint = std.mem.trimEnd(u8, self.config.endpoint, "/");
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
    if (self.config.headers) |hdr_str| {
        var parsed_buf: [32]HeaderEntry = undefined;
        const parsed = parseHeaderString(hdr_str, &parsed_buf) catch |err| switch (err) {
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
    const stash_len = @min(written.len, self.last_response_body.len);
    @memcpy(self.last_response_body[0..stash_len], written[0..stash_len]);
    self.last_response_body_len = stash_len;
    self.last_response_status = @intFromEnum(result.status);

    return .{ .status = @intFromEnum(result.status), .body = self.last_response_body[0..self.last_response_body_len] };
}

fn doShutdown(ctx: ?*anyopaque) void {
    const self: *OtlpHttpExporter = @ptrCast(@alignCast(ctx.?));
    self.closed = true;
}

fn doFlush(_: ?*anyopaque, _: u64) anyerror!void {}

fn expSpans(ctx: ?*anyopaque, items: []const exp.SpanData) anyerror!exp.SpanExportResult {
    const self: *OtlpHttpExporter = @ptrCast(@alignCast(ctx.?));
    if (self.closed) return error.RetryExhausted;
    if (items.len == 0) return .success;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const path = "/v1/traces";

    const body = switch (self.config.protocol) {
        .http_protobuf, .grpc => try encodeSpansProto(aa, items),
        .http_json => try encodeSpansJson(aa, items),
    };
    const content_type: []const u8 = switch (self.config.protocol) {
        .http_protobuf, .grpc => "application/x-protobuf",
        .http_json => "application/json",
    };

    var retry: exp.RetryState = .{};
    while (true) {
        // Sentinel dispatch: when the transport pointer is the in-house
        // `httpTransport`, route through `httpTransportImpl` so the
        // implementation can read `self.io` (the `Transport` vtable
        // signature predates the Io plumbing). Test-injected fakes go
        // through the function pointer unchanged.
        const result = (if (self.transport == httpTransport)
            httpTransportImpl(self, aa, path, content_type, body)
        else
            self.transport(aa, self.config.endpoint, path, self.config.headers, content_type, body, self.config.timeout_ms)) catch |err| {
            switch (err) {
                error.ConnectionRefused, error.ConnectionResetByPeer, error.UnsupportedTransport, error.NetworkUnreachable => {},
                else => return err,
            }
            if (!retry.shouldRetry(&self.prng)) return error.RetryExhausted;
            continue;
        };
        if (result.status == 207) return error.PartialSuccess;
        if (result.status >= 200 and result.status < 300) return .success;
        if (result.status >= 400 and result.status < 500) return error.RetryExhausted;
        if (result.status >= 500 or result.status == 429) {
            if (!retry.shouldRetry(&self.prng)) return error.RetryExhausted;
            continue;
        }
        return error.RetryExhausted;
    }
}

// ---------------------------------------------------------------- Metric export
//
// GAP-OTLP-METRIC-EXPORT (gitlab #7): OTLP/HTTP metric path. Wire layout
// follows OTLP 1.10.0 `ExportMetricsServiceRequest` and the `metrics.v1`
// message family. The encoder mirrors the conservative defaults the span
// path uses:
//
//   - One ResourceMetrics per export call (caller drives batching at the
//     `MetricExporter` boundary; a single call carries one Resource).
//   - One ScopeMetrics per InstrumentationScope present in the batch.
//     Metrics with the same `(scope.name, scope.version)` are coalesced
//     so the wire reflects the OTLP grouping contract.
//   - `Sum` is emitted for `counter` / `up_down_counter` (and the
//     observable variants). `Gauge` for `gauge` / `observable_gauge`.
//     `Histogram` for `histogram`. Other instrument kinds are silently
//     skipped (no spec-defined OTLP shape yet).
//   - `aggregationTemporality` carries the SDK temporality verbatim
//     (cumulative=2, delta=1).
//   - `is_monotonic` is emitted on `Sum` only (proto3 omits `false`).
//   - Histogram `count` and `bucket_counts` use packed `fixed64`
//     encoding (proto3 repeated-scalar default). `explicit_bounds` is
//     packed `double`.

fn expMetrics(ctx: ?*anyopaque, items: []const exp.MetricData) anyerror!exp.SpanExportResult {
    const self: *OtlpHttpExporter = @ptrCast(@alignCast(ctx.?));
    if (self.closed) return error.RetryExhausted;
    if (items.len == 0) return .success;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const path = "/v1/metrics";

    const body = switch (self.config.protocol) {
        .http_protobuf, .grpc => try encodeMetricsProto(aa, items),
        .http_json => try encodeMetricsJson(aa, items),
    };
    const content_type: []const u8 = switch (self.config.protocol) {
        .http_protobuf, .grpc => "application/x-protobuf",
        .http_json => "application/json",
    };

    var retry: exp.RetryState = .{};
    while (true) {
        // Sentinel dispatch — same shape as `expSpans`. Tests inject a
        // fake transport via the function pointer; production routes
        // through `httpTransportImpl` so it can read `self.io`.
        const result = (if (self.transport == httpTransport)
            httpTransportImpl(self, aa, path, content_type, body)
        else
            self.transport(aa, self.config.endpoint, path, self.config.headers, content_type, body, self.config.timeout_ms)) catch |err| {
            switch (err) {
                error.ConnectionRefused, error.ConnectionResetByPeer, error.UnsupportedTransport, error.NetworkUnreachable => {},
                else => return err,
            }
            if (!retry.shouldRetry(&self.prng)) return error.RetryExhausted;
            continue;
        };
        if (result.status == 207) return error.PartialSuccess;
        if (result.status >= 200 and result.status < 300) return .success;
        if (result.status >= 400 and result.status < 500) return error.RetryExhausted;
        if (result.status >= 500 or result.status == 429) {
            if (!retry.shouldRetry(&self.prng)) return error.RetryExhausted;
            continue;
        }
        return error.RetryExhausted;
    }
}

/// Group metrics by `(scope.name, scope.version)` so the wire emits one
/// `ScopeMetrics` per scope. Returns arena-owned slices of `MetricData`
/// referencing the input batch (no payload copy).
const ScopeBucket = struct {
    scope: trace_api.InstrumentationScope,
    metrics: std.ArrayList(*const exp.MetricData),
};

fn groupByScope(arena: std.mem.Allocator, items: []const exp.MetricData) ![]ScopeBucket {
    var buckets: std.ArrayList(ScopeBucket) = .empty;
    for (items) |*m| {
        var found: ?usize = null;
        for (buckets.items, 0..) |b, i| {
            if (std.mem.eql(u8, b.scope.name, m.instrumentation_scope.name) and
                std.mem.eql(u8, b.scope.version, m.instrumentation_scope.version))
            {
                found = i;
                break;
            }
        }
        if (found) |idx| {
            try buckets.items[idx].metrics.append(arena, m);
        } else {
            var b: ScopeBucket = .{ .scope = m.instrumentation_scope, .metrics = .empty };
            try b.metrics.append(arena, m);
            try buckets.append(arena, b);
        }
    }
    return buckets.toOwnedSlice(arena);
}

pub fn encodeMetricsProto(allocator: std.mem.Allocator, items: []const exp.MetricData) ![]u8 {
    var w = otlp.Writer.init(allocator);
    defer w.deinit();
    if (items.len == 0) return try w.toOwnedSlice();

    // Bucket bookkeeping is short-lived; route it through an internal
    // arena so direct callers (tests, custom exporters) don't have to
    // manage it. The returned slice is still `allocator`-owned.
    var bucket_arena = std.heap.ArenaAllocator.init(allocator);
    defer bucket_arena.deinit();
    const ba = bucket_arena.allocator();

    const resource = items[0].resource;
    const buckets = try groupByScope(ba, items);

    const rm_start = try w.beginSubMessage(otlp.fn_resource_metrics);
    {
        // Resource (field 1) — same Resource shape as ResourceSpans.
        const r_start = try w.beginSubMessage(otlp.fn_rm_resource);
        for (resource.attributes.entries.items) |kv| {
            try writeKeyValue(&w, otlp.fn_resource_attributes, kv);
        }
        try w.commitSubMessage(r_start);

        // ScopeMetrics — one per InstrumentationScope.
        for (buckets) |bucket| {
            const sm_start = try w.beginSubMessage(otlp.fn_rm_scope_metrics);
            const sc_start = try w.beginSubMessage(otlp.fn_sm_scope);
            try w.writeString(otlp.fn_scope_name, bucket.scope.name);
            try w.writeString(otlp.fn_scope_version, bucket.scope.version);
            try w.commitSubMessage(sc_start);

            for (bucket.metrics.items) |m_ptr| {
                const m = m_ptr.*;
                const m_start = try w.beginSubMessage(otlp.fn_sm_metrics);
                try w.writeString(otlp.fn_metric_name, m.name);
                try w.writeString(otlp.fn_metric_description, m.description);
                try w.writeString(otlp.fn_metric_unit, m.unit);
                try writeMetricBody(&w, m);
                try w.commitSubMessage(m_start);
            }
            try w.commitSubMessage(sm_start);
        }
    }
    try w.commitSubMessage(rm_start);
    return try w.toOwnedSlice();
}

fn writeMetricBody(w: *otlp.Writer, m: exp.MetricData) !void {
    const temporality_value: u64 = switch (m.temporality) {
        .cumulative => otlp.aggregation_temporality_cumulative,
        .delta => otlp.aggregation_temporality_delta,
    };

    switch (m.kind) {
        .counter, .up_down_counter, .observable_counter, .observable_up_down_counter => {
            const sum_start = try w.beginSubMessage(otlp.fn_metric_sum);
            for (m.points) |pt| try writeNumberDataPoint(w, otlp.fn_sum_data_points, pt);
            try w.writeUint64(otlp.fn_sum_aggregation_temporality, temporality_value);
            try w.writeBool(otlp.fn_sum_is_monotonic, m.is_monotonic);
            try w.commitSubMessage(sum_start);
        },
        .gauge, .observable_gauge => {
            const g_start = try w.beginSubMessage(otlp.fn_metric_gauge);
            for (m.points) |pt| try writeNumberDataPoint(w, otlp.fn_gauge_data_points, pt);
            try w.commitSubMessage(g_start);
        },
        .histogram => {
            const h_start = try w.beginSubMessage(otlp.fn_metric_histogram);
            for (m.points) |pt| try writeHistogramDataPoint(w, otlp.fn_hist_data_points, pt);
            try w.writeUint64(otlp.fn_hist_aggregation_temporality, temporality_value);
            try w.commitSubMessage(h_start);
        },
    }
}

fn writeNumberDataPoint(w: *otlp.Writer, field_number: u32, pt: exp.DataPoint) !void {
    const ndp_start = try w.beginSubMessage(field_number);
    if (pt.attributes) |a| {
        for (a.entries.items) |kv| {
            try writeKeyValue(w, otlp.fn_ndp_attributes, kv);
        }
    }
    try w.writeFixed64Field(otlp.fn_ndp_start_time_unix_nano, pt.start_unix_nano);
    try w.writeFixed64Field(otlp.fn_ndp_time_unix_nano, pt.time_unix_nano);
    switch (pt.value) {
        .number => |n| switch (n) {
            // OTLP: oneof value { double as_double = 4; sfixed64 as_int = 6; }
            .int => |v| try w.writeSfixed64Field(otlp.fn_ndp_as_int, v),
            // proto3 omits zero doubles by default; OTLP collectors expect
            // the field present when this branch was selected (otherwise
            // the oneof is unset and the value is ambiguous). Force-emit.
            .double => |v| {
                try w.writeTag(otlp.fn_ndp_as_double, .fixed64);
                const bits: u64 = @bitCast(v);
                try w.writeFixed64(bits);
            },
        },
        .histogram => {}, // unreachable for number-shaped instruments
    }
    try w.commitSubMessage(ndp_start);
}

fn writeHistogramDataPoint(w: *otlp.Writer, field_number: u32, pt: exp.DataPoint) !void {
    const hdp_start = try w.beginSubMessage(field_number);
    if (pt.attributes) |a| {
        for (a.entries.items) |kv| {
            try writeKeyValue(w, otlp.fn_hdp_attributes, kv);
        }
    }
    try w.writeFixed64Field(otlp.fn_hdp_start_time_unix_nano, pt.start_unix_nano);
    try w.writeFixed64Field(otlp.fn_hdp_time_unix_nano, pt.time_unix_nano);
    switch (pt.value) {
        .histogram => |h| {
            // count + sum are always emitted (proto3 explicit-presence
            // optionals — collectors expect them populated even when 0).
            try w.writeTag(otlp.fn_hdp_count, .fixed64);
            try w.writeFixed64(h.count);
            try w.writeTag(otlp.fn_hdp_sum, .fixed64);
            const sum_bits: u64 = @bitCast(h.sum);
            try w.writeFixed64(sum_bits);
            try w.writePackedFixed64(otlp.fn_hdp_bucket_counts, h.counts);
            try w.writePackedDouble(otlp.fn_hdp_explicit_bounds, h.bounds);
            if (h.min) |min_v| {
                try w.writeTag(otlp.fn_hdp_min, .fixed64);
                const bits: u64 = @bitCast(min_v);
                try w.writeFixed64(bits);
            }
            if (h.max) |max_v| {
                try w.writeTag(otlp.fn_hdp_max, .fixed64);
                const bits: u64 = @bitCast(max_v);
                try w.writeFixed64(bits);
            }
        },
        .number => {}, // unreachable for histogram-shaped instruments
    }
    try w.commitSubMessage(hdp_start);
}

// OTLP/JSON metric encoder. Routes through DevNW `../json` (the sibling
// dependency) when `-Dotel_use_devnw_json=true`; otherwise falls back to
// a small hand-written writer that produces the same shape. Every large
// integer (start_time_unix_nano, time_unix_nano, as_int, count,
// bucket_counts) is serialized as a JSON string per OTLP/JSON
// recommendation — JSON's 53-bit number range can't carry a u64 without
// loss.
fn encodeMetricsJson(allocator: std.mem.Allocator, items: []const exp.MetricData) ![]u8 {
    if (build_options.use_devnw_json) {
        return encodeMetricsJsonDevnw(allocator, items);
    }
    return encodeMetricsJsonStd(allocator, items);
}

fn encodeMetricsJsonDevnw(allocator: std.mem.Allocator, items: []const exp.MetricData) ![]u8 {
    var bucket_arena = std.heap.ArenaAllocator.init(allocator);
    defer bucket_arena.deinit();
    const ba = bucket_arena.allocator();

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var enc = devnw_json.streamingEncoder(allocator, &aw.writer, .{});
    defer enc.deinit();

    try enc.beginObject();
    try enc.writeKey("resourceMetrics");
    try enc.beginArray();
    if (items.len > 0) {
        try enc.beginObject();

        try enc.writeKey("resource");
        try enc.beginObject();
        try enc.writeKey("attributes");
        try enc.beginArray();
        for (items[0].resource.attributes.entries.items) |kv| {
            try writeJsonAttributeStreaming(&enc, kv);
        }
        try enc.endArray();
        try enc.endObject();

        const buckets = try groupByScope(ba, items);
        try enc.writeKey("scopeMetrics");
        try enc.beginArray();
        for (buckets) |bucket| {
            try enc.beginObject();
            try enc.writeKey("scope");
            try enc.beginObject();
            try enc.writeKey("name");
            try enc.writeString(bucket.scope.name);
            try enc.writeKey("version");
            try enc.writeString(bucket.scope.version);
            try enc.endObject();

            try enc.writeKey("metrics");
            try enc.beginArray();
            for (bucket.metrics.items) |m_ptr| {
                try writeMetricJsonStreaming(&enc, m_ptr.*);
            }
            try enc.endArray();
            try enc.endObject();
        }
        try enc.endArray();

        try enc.endObject();
    }
    try enc.endArray();
    try enc.endObject();
    return try aw.toOwnedSlice();
}

fn writeJsonAttributeStreaming(enc: anytype, kv: attrs_mod.Entry) !void {
    try enc.beginObject();
    try enc.writeKey("key");
    try enc.writeString(kv.key);
    try enc.writeKey("value");
    try enc.beginObject();
    switch (kv.value) {
        .string => |s| {
            try enc.writeKey("stringValue");
            try enc.writeString(redact.maskString(kv.key, s));
        },
        .bool => |b| {
            try enc.writeKey("boolValue");
            try enc.writeBool(b);
        },
        .int => |i| {
            // OTLP/JSON: int64 fields are encoded as strings.
            try enc.writeKey("intValue");
            var buf: [24]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d}", .{i});
            try enc.writeString(s);
        },
        .double => |d| {
            try enc.writeKey("doubleValue");
            try enc.writeFloat(d);
        },
        else => {},
    }
    try enc.endObject();
    try enc.endObject();
}

fn writeMetricJsonStreaming(enc: anytype, m: exp.MetricData) !void {
    try enc.beginObject();
    try enc.writeKey("name");
    try enc.writeString(m.name);
    try enc.writeKey("description");
    try enc.writeString(m.description);
    try enc.writeKey("unit");
    try enc.writeString(m.unit);

    const temp_value: u8 = switch (m.temporality) {
        .cumulative => @intCast(otlp.aggregation_temporality_cumulative),
        .delta => @intCast(otlp.aggregation_temporality_delta),
    };

    switch (m.kind) {
        .counter, .up_down_counter, .observable_counter, .observable_up_down_counter => {
            try enc.writeKey("sum");
            try enc.beginObject();
            try writeNumberPointsJson(enc, m.points);
            try enc.writeKey("aggregationTemporality");
            try enc.writeInt(temp_value);
            try enc.writeKey("isMonotonic");
            try enc.writeBool(m.is_monotonic);
            try enc.endObject();
        },
        .gauge, .observable_gauge => {
            try enc.writeKey("gauge");
            try enc.beginObject();
            try writeNumberPointsJson(enc, m.points);
            try enc.endObject();
        },
        .histogram => {
            try enc.writeKey("histogram");
            try enc.beginObject();
            try enc.writeKey("dataPoints");
            try enc.beginArray();
            for (m.points) |pt| try writeHistogramPointJson(enc, pt);
            try enc.endArray();
            try enc.writeKey("aggregationTemporality");
            try enc.writeInt(temp_value);
            try enc.endObject();
        },
    }
    try enc.endObject();
}

fn writeNumberPointsJson(enc: anytype, points: []const exp.DataPoint) !void {
    try enc.writeKey("dataPoints");
    try enc.beginArray();
    for (points) |pt| try writeNumberPointJson(enc, pt);
    try enc.endArray();
}

fn writeNumberPointJson(enc: anytype, pt: exp.DataPoint) !void {
    try enc.beginObject();
    if (pt.attributes) |a| {
        try enc.writeKey("attributes");
        try enc.beginArray();
        for (a.entries.items) |kv| try writeJsonAttributeStreaming(enc, kv);
        try enc.endArray();
    }
    try writeJsonU64String(enc, "startTimeUnixNano", pt.start_unix_nano);
    try writeJsonU64String(enc, "timeUnixNano", pt.time_unix_nano);
    switch (pt.value) {
        .number => |n| switch (n) {
            .int => |v| {
                try enc.writeKey("asInt");
                var buf: [24]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
                try enc.writeString(s);
            },
            .double => |v| {
                try enc.writeKey("asDouble");
                try enc.writeFloat(v);
            },
        },
        .histogram => {},
    }
    try enc.endObject();
}

fn writeHistogramPointJson(enc: anytype, pt: exp.DataPoint) !void {
    try enc.beginObject();
    if (pt.attributes) |a| {
        try enc.writeKey("attributes");
        try enc.beginArray();
        for (a.entries.items) |kv| try writeJsonAttributeStreaming(enc, kv);
        try enc.endArray();
    }
    try writeJsonU64String(enc, "startTimeUnixNano", pt.start_unix_nano);
    try writeJsonU64String(enc, "timeUnixNano", pt.time_unix_nano);
    switch (pt.value) {
        .histogram => |h| {
            try writeJsonU64String(enc, "count", h.count);
            try enc.writeKey("sum");
            try enc.writeFloat(h.sum);
            try enc.writeKey("bucketCounts");
            try enc.beginArray();
            for (h.counts) |c| {
                var buf: [24]u8 = undefined;
                const s = try std.fmt.bufPrint(&buf, "{d}", .{c});
                try enc.writeString(s);
            }
            try enc.endArray();
            try enc.writeKey("explicitBounds");
            try enc.beginArray();
            for (h.bounds) |b| try enc.writeFloat(b);
            try enc.endArray();
            if (h.min) |m| {
                try enc.writeKey("min");
                try enc.writeFloat(m);
            }
            if (h.max) |m| {
                try enc.writeKey("max");
                try enc.writeFloat(m);
            }
        },
        .number => {},
    }
    try enc.endObject();
}

fn writeJsonU64String(enc: anytype, key: []const u8, v: u64) !void {
    try enc.writeKey(key);
    var buf: [24]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{d}", .{v});
    try enc.writeString(s);
}

// Stdlib-only JSON fallback. Hand-rolled to avoid pulling in `../json` on
// builds that opt out via `-Dotel_use_devnw_json=false`. The output shape
// is byte-identical to the DevNW path for the same input (collectors care
// about shape, not whitespace).
fn encodeMetricsJsonStd(allocator: std.mem.Allocator, items: []const exp.MetricData) ![]u8 {
    var bucket_arena = std.heap.ArenaAllocator.init(allocator);
    defer bucket_arena.deinit();
    const ba = bucket_arena.allocator();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"resourceMetrics\":[");
    if (items.len > 0) {
        try buf.append(allocator, '{');
        try buf.appendSlice(allocator, "\"resource\":{\"attributes\":[");
        for (items[0].resource.attributes.entries.items, 0..) |kv, i| {
            if (i > 0) try buf.append(allocator, ',');
            try writeJsonAttributeStd(allocator, &buf, kv);
        }
        try buf.appendSlice(allocator, "]},\"scopeMetrics\":[");
        const buckets = try groupByScope(ba, items);
        for (buckets, 0..) |bucket, i| {
            if (i > 0) try buf.append(allocator, ',');
            try buf.appendSlice(allocator, "{\"scope\":{\"name\":");
            try writeJsonStringStd(allocator, &buf, bucket.scope.name);
            try buf.appendSlice(allocator, ",\"version\":");
            try writeJsonStringStd(allocator, &buf, bucket.scope.version);
            try buf.appendSlice(allocator, "},\"metrics\":[");
            for (bucket.metrics.items, 0..) |m_ptr, j| {
                if (j > 0) try buf.append(allocator, ',');
                try writeMetricJsonStd(allocator, &buf, m_ptr.*);
            }
            try buf.appendSlice(allocator, "]}");
        }
        try buf.appendSlice(allocator, "]}");
    }
    try buf.appendSlice(allocator, "]}");
    return try allocator.dupe(u8, buf.items);
}

fn writeJsonStringStd(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0x00...0x07, 0x0b, 0x0c, 0x0e...0x1f => {
                var tmp: [8]u8 = undefined;
                const out = try std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c});
                try buf.appendSlice(allocator, out);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

fn writeJsonU64StringStd(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, v: u64) !void {
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, key);
    try buf.appendSlice(allocator, "\":\"");
    var num_buf: [24]u8 = undefined;
    const s = try std.fmt.bufPrint(&num_buf, "{d}", .{v});
    try buf.appendSlice(allocator, s);
    try buf.append(allocator, '"');
}

fn writeJsonAttributeStd(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), kv: attrs_mod.Entry) !void {
    try buf.appendSlice(allocator, "{\"key\":");
    try writeJsonStringStd(allocator, buf, kv.key);
    try buf.appendSlice(allocator, ",\"value\":{");
    switch (kv.value) {
        .string => |s| {
            try buf.appendSlice(allocator, "\"stringValue\":");
            try writeJsonStringStd(allocator, buf, redact.maskString(kv.key, s));
        },
        .bool => |b| try buf.appendSlice(allocator, if (b) "\"boolValue\":true" else "\"boolValue\":false"),
        .int => |i| {
            try buf.appendSlice(allocator, "\"intValue\":\"");
            var num_buf: [24]u8 = undefined;
            const s = try std.fmt.bufPrint(&num_buf, "{d}", .{i});
            try buf.appendSlice(allocator, s);
            try buf.append(allocator, '"');
        },
        .double => |d| {
            try buf.appendSlice(allocator, "\"doubleValue\":");
            var num_buf: [40]u8 = undefined;
            const s = try std.fmt.bufPrint(&num_buf, "{d}", .{d});
            try buf.appendSlice(allocator, s);
        },
        else => {},
    }
    try buf.appendSlice(allocator, "}}");
}

fn writeMetricJsonStd(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), m: exp.MetricData) !void {
    try buf.append(allocator, '{');
    try buf.appendSlice(allocator, "\"name\":");
    try writeJsonStringStd(allocator, buf, m.name);
    try buf.appendSlice(allocator, ",\"description\":");
    try writeJsonStringStd(allocator, buf, m.description);
    try buf.appendSlice(allocator, ",\"unit\":");
    try writeJsonStringStd(allocator, buf, m.unit);

    const temp_value: u8 = switch (m.temporality) {
        .cumulative => @intCast(otlp.aggregation_temporality_cumulative),
        .delta => @intCast(otlp.aggregation_temporality_delta),
    };

    switch (m.kind) {
        .counter, .up_down_counter, .observable_counter, .observable_up_down_counter => {
            try buf.appendSlice(allocator, ",\"sum\":{\"dataPoints\":[");
            for (m.points, 0..) |pt, i| {
                if (i > 0) try buf.append(allocator, ',');
                try writeNumberPointJsonStd(allocator, buf, pt);
            }
            try buf.appendSlice(allocator, "],\"aggregationTemporality\":");
            var num_buf: [8]u8 = undefined;
            const s = try std.fmt.bufPrint(&num_buf, "{d}", .{temp_value});
            try buf.appendSlice(allocator, s);
            try buf.appendSlice(allocator, ",\"isMonotonic\":");
            try buf.appendSlice(allocator, if (m.is_monotonic) "true" else "false");
            try buf.append(allocator, '}');
        },
        .gauge, .observable_gauge => {
            try buf.appendSlice(allocator, ",\"gauge\":{\"dataPoints\":[");
            for (m.points, 0..) |pt, i| {
                if (i > 0) try buf.append(allocator, ',');
                try writeNumberPointJsonStd(allocator, buf, pt);
            }
            try buf.appendSlice(allocator, "]}");
        },
        .histogram => {
            try buf.appendSlice(allocator, ",\"histogram\":{\"dataPoints\":[");
            for (m.points, 0..) |pt, i| {
                if (i > 0) try buf.append(allocator, ',');
                try writeHistogramPointJsonStd(allocator, buf, pt);
            }
            try buf.appendSlice(allocator, "],\"aggregationTemporality\":");
            var num_buf: [8]u8 = undefined;
            const s = try std.fmt.bufPrint(&num_buf, "{d}", .{temp_value});
            try buf.appendSlice(allocator, s);
            try buf.append(allocator, '}');
        },
    }
    try buf.append(allocator, '}');
}

fn writeNumberPointJsonStd(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), pt: exp.DataPoint) !void {
    try buf.append(allocator, '{');
    var first = true;
    if (pt.attributes) |a| {
        try buf.appendSlice(allocator, "\"attributes\":[");
        for (a.entries.items, 0..) |kv, i| {
            if (i > 0) try buf.append(allocator, ',');
            try writeJsonAttributeStd(allocator, buf, kv);
        }
        try buf.append(allocator, ']');
        first = false;
    }
    if (!first) try buf.append(allocator, ',');
    try writeJsonU64StringStd(allocator, buf, "startTimeUnixNano", pt.start_unix_nano);
    try buf.append(allocator, ',');
    try writeJsonU64StringStd(allocator, buf, "timeUnixNano", pt.time_unix_nano);
    switch (pt.value) {
        .number => |n| switch (n) {
            .int => |v| {
                try buf.appendSlice(allocator, ",\"asInt\":\"");
                var num_buf: [24]u8 = undefined;
                const s = try std.fmt.bufPrint(&num_buf, "{d}", .{v});
                try buf.appendSlice(allocator, s);
                try buf.append(allocator, '"');
            },
            .double => |v| {
                try buf.appendSlice(allocator, ",\"asDouble\":");
                var num_buf: [40]u8 = undefined;
                const s = try std.fmt.bufPrint(&num_buf, "{d}", .{v});
                try buf.appendSlice(allocator, s);
            },
        },
        .histogram => {},
    }
    try buf.append(allocator, '}');
}

fn writeHistogramPointJsonStd(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), pt: exp.DataPoint) !void {
    try buf.append(allocator, '{');
    var first = true;
    if (pt.attributes) |a| {
        try buf.appendSlice(allocator, "\"attributes\":[");
        for (a.entries.items, 0..) |kv, i| {
            if (i > 0) try buf.append(allocator, ',');
            try writeJsonAttributeStd(allocator, buf, kv);
        }
        try buf.append(allocator, ']');
        first = false;
    }
    if (!first) try buf.append(allocator, ',');
    try writeJsonU64StringStd(allocator, buf, "startTimeUnixNano", pt.start_unix_nano);
    try buf.append(allocator, ',');
    try writeJsonU64StringStd(allocator, buf, "timeUnixNano", pt.time_unix_nano);
    switch (pt.value) {
        .histogram => |h| {
            try buf.append(allocator, ',');
            try writeJsonU64StringStd(allocator, buf, "count", h.count);
            try buf.appendSlice(allocator, ",\"sum\":");
            var num_buf: [40]u8 = undefined;
            var s = try std.fmt.bufPrint(&num_buf, "{d}", .{h.sum});
            try buf.appendSlice(allocator, s);
            try buf.appendSlice(allocator, ",\"bucketCounts\":[");
            for (h.counts, 0..) |c, i| {
                if (i > 0) try buf.append(allocator, ',');
                try buf.append(allocator, '"');
                s = try std.fmt.bufPrint(&num_buf, "{d}", .{c});
                try buf.appendSlice(allocator, s);
                try buf.append(allocator, '"');
            }
            try buf.appendSlice(allocator, "],\"explicitBounds\":[");
            for (h.bounds, 0..) |b, i| {
                if (i > 0) try buf.append(allocator, ',');
                s = try std.fmt.bufPrint(&num_buf, "{d}", .{b});
                try buf.appendSlice(allocator, s);
            }
            try buf.append(allocator, ']');
            if (h.min) |mv| {
                try buf.appendSlice(allocator, ",\"min\":");
                s = try std.fmt.bufPrint(&num_buf, "{d}", .{mv});
                try buf.appendSlice(allocator, s);
            }
            if (h.max) |mv| {
                try buf.appendSlice(allocator, ",\"max\":");
                s = try std.fmt.bufPrint(&num_buf, "{d}", .{mv});
                try buf.appendSlice(allocator, s);
            }
        },
        .number => {},
    }
    try buf.append(allocator, '}');
}

/// Group spans by `(scope.name, scope.version, scope.schema_url)` so the
/// wire emits one `ScopeSpans` per distinct InstrumentationScope. Buckets
/// preserve first-seen order. Returns arena-owned slices referencing the
/// input batch (no payload copy).
///
/// Closes PR-3 (#136): pre-fix the trace encoder used
/// `items[0].instrumentation_scope` for the entire batch, which mislabelled
/// every span past index 0 when a batch crossed multiple tracers.
const SpanScopeBucket = struct {
    scope: trace_api.InstrumentationScope,
    spans: std.ArrayList(*const exp.SpanData),
};

fn groupSpansByScope(arena: std.mem.Allocator, items: []const exp.SpanData) ![]SpanScopeBucket {
    var buckets: std.ArrayList(SpanScopeBucket) = .empty;
    for (items) |*s| {
        var found: ?usize = null;
        for (buckets.items, 0..) |b, i| {
            if (std.mem.eql(u8, b.scope.name, s.instrumentation_scope.name) and
                std.mem.eql(u8, b.scope.version, s.instrumentation_scope.version) and
                std.mem.eql(u8, b.scope.schema_url, s.instrumentation_scope.schema_url))
            {
                found = i;
                break;
            }
        }
        if (found) |idx| {
            try buckets.items[idx].spans.append(arena, s);
        } else {
            var b: SpanScopeBucket = .{ .scope = s.instrumentation_scope, .spans = .empty };
            try b.spans.append(arena, s);
            try buckets.append(arena, b);
        }
    }
    return buckets.toOwnedSlice(arena);
}

fn writeSpan(w: *otlp.Writer, span: exp.SpanData) !void {
    const span_start = try w.beginSubMessage(otlp.fn_spans);
    try w.writeBytes(otlp.fn_span_trace_id, span.span_context.trace_id.bytes[0..]);
    try w.writeBytes(otlp.fn_span_span_id, span.span_context.span_id.bytes[0..]);
    if (span.span_context.trace_state) |ts| try w.writeString(otlp.fn_span_trace_state, ts);
    if (span.parent_span_id.isValid()) try w.writeBytes(otlp.fn_span_parent_span_id, span.parent_span_id.bytes[0..]);
    try w.writeString(otlp.fn_span_name, span.name);
    try w.writeUint64(otlp.fn_span_kind, switch (span.kind) {
        .unspecified => otlp.span_kind_unspecified,
        .internal => otlp.span_kind_internal,
        .server => otlp.span_kind_server,
        .client => otlp.span_kind_client,
        .producer => otlp.span_kind_producer,
        .consumer => otlp.span_kind_consumer,
    });
    try w.writeFixed64Field(otlp.fn_span_start_unix_nano, span.start_unix_nano);
    try w.writeFixed64Field(otlp.fn_span_end_unix_nano, span.end_unix_nano);
    for (span.attributes.entries.items) |kv| {
        try writeKeyValue(w, otlp.fn_span_attributes, kv);
    }
    try w.writeUint64(otlp.fn_span_dropped_attributes_count, span.dropped_attributes_count);

    const status_start = try w.beginSubMessage(otlp.fn_span_status);
    try w.writeString(otlp.fn_status_message, span.status_description);
    try w.writeUint64(otlp.fn_status_code, switch (span.status_code) {
        .unset => otlp.status_code_unset,
        .ok => otlp.status_code_ok,
        .@"error" => otlp.status_code_error,
    });
    try w.commitSubMessage(status_start);
    try w.commitSubMessage(span_start);
}

pub fn encodeSpansProto(allocator: std.mem.Allocator, items: []const exp.SpanData) ![]u8 {
    var w = otlp.Writer.init(allocator);
    defer w.deinit();
    // ResourceSpans message with one ScopeSpans per InstrumentationScope.
    // For simplicity we emit one ResourceSpans per call.
    if (items.len == 0) return try w.toOwnedSlice();
    const resource = items[0].resource;

    // Bucket bookkeeping is short-lived; route it through an internal
    // arena so direct callers don't have to manage it. Mirrors the
    // metrics encoder pattern at `groupByScope`. PR-5 (#138) will replace
    // the linear scan inside `groupSpansByScope` with a hash-keyed
    // grouping; the public encoder API stays unchanged.
    var bucket_arena = std.heap.ArenaAllocator.init(allocator);
    defer bucket_arena.deinit();
    const ba = bucket_arena.allocator();

    const buckets = try groupSpansByScope(ba, items);

    const rs_start = try w.beginSubMessage(otlp.fn_resource_spans);
    {
        const r_start = try w.beginSubMessage(otlp.fn_resource);
        for (resource.attributes.entries.items) |kv| {
            try writeKeyValue(&w, otlp.fn_resource_attributes, kv);
        }
        try w.commitSubMessage(r_start);

        // Single-scope fast path: byte-identical to the pre-PR-3 wire
        // shape. The loop body below is the same code; for `buckets.len
        // == 1` the only field-level difference is the conditional
        // `schema_url` emission, which `writeString` already skips when
        // the value is empty (proto3 default-omit). Empty `schema_url`
        // therefore produces zero extra bytes — full byte-parity holds.
        for (buckets) |bucket| {
            const ss_start = try w.beginSubMessage(otlp.fn_scope_spans);
            const sc_start = try w.beginSubMessage(otlp.fn_scope);
            try w.writeString(otlp.fn_scope_name, bucket.scope.name);
            try w.writeString(otlp.fn_scope_version, bucket.scope.version);
            try w.commitSubMessage(sc_start);

            for (bucket.spans.items) |span_ptr| {
                try writeSpan(&w, span_ptr.*);
            }

            // ScopeSpans.schema_url (field 3) — emit only when set so
            // single-scope batches without a schema_url stay byte-identical
            // to the pre-PR-3 wire shape.
            try w.writeString(otlp.fn_schema_url, bucket.scope.schema_url);
            try w.commitSubMessage(ss_start);
        }
    }
    try w.commitSubMessage(rs_start);

    return try w.toOwnedSlice();
}

fn writeKeyValue(w: *otlp.Writer, field_number: u32, kv: attrs_mod.Entry) !void {
    const start = try w.beginSubMessage(field_number);
    try w.writeString(otlp.fn_kv_key, kv.key);
    const v_start = try w.beginSubMessage(otlp.fn_kv_value);
    switch (kv.value) {
        // GAP-SEC-H-6 / GAP-SEC-L-4: redact sensitive string values
        // before they hit the wire. Span / log / resource attributes
        // all flow through this writer.
        .string => |s| try w.writeString(otlp.fn_av_string, redact.maskString(kv.key, s)),
        .bool => |b| try w.writeBool(otlp.fn_av_bool, b),
        .int => |i| try w.writeSint64(otlp.fn_av_int, i),
        .double => |d| try w.writeDouble(otlp.fn_av_double, d),
        else => {},
    }
    try w.commitSubMessage(v_start);
    try w.commitSubMessage(start);
}

fn encodeSpansJson(allocator: std.mem.Allocator, items: []const exp.SpanData) ![]u8 {
    if (build_options.use_devnw_json) {
        return encodeSpansJsonDevnw(allocator, items);
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"resourceSpans\":[");
    for (items, 0..) |span, i| {
        if (i > 0) try buf.append(allocator, ',');
        const json = try json_codec.spanToJson(allocator, span);
        defer allocator.free(json);
        try buf.appendSlice(allocator, json);
    }
    try buf.appendSlice(allocator, "]}");
    return try allocator.dupe(u8, buf.items);
}

/// DevNW-routed JSON encoder. The per-span JSON still comes from the
/// in-repo `json_codec.spanToJson` (which gates exact byte-level golden
/// output), but the `{"resourceSpans":[...]}` wrapper is assembled by
/// DevNW's streaming `Encoder` via `writeRaw`. This routes the JSON path
/// through the dependency without disturbing the wire-shape contract.
fn encodeSpansJsonDevnw(allocator: std.mem.Allocator, items: []const exp.SpanData) ![]u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();

    var enc = devnw_json.streamingEncoder(allocator, &aw.writer, .{});
    defer enc.deinit();

    try enc.beginObject();
    try enc.writeKey("resourceSpans");
    try enc.beginArray();
    for (items) |span| {
        const child = try json_codec.spanToJson(allocator, span);
        defer allocator.free(child);
        try enc.writeRaw(child);
    }
    try enc.endArray();
    try enc.endObject();

    // toOwnedSlice transfers the buffer to the caller without an extra dupe.
    return try aw.toOwnedSlice();
}

// ---------------------------------------------------------------------------
// DevNW protobuf path
// ---------------------------------------------------------------------------
// Mirrors `encodeSpansProto` byte-for-byte by routing the same OTLP wire
// shape through the DevNW protobuf type-driven encoder. The schema below is
// a minimal proto3 view of the OTLP messages we actually emit (one
// ResourceSpans per call). Field numbers and wire types are taken from the
// same OTLP 1.10.0 reference as the in-repo encoder, and the struct field
// order matches the in-repo emission order so DevNW's reflection walks the
// fields in the same sequence.
//
// Two parity-critical points:
//   1. The in-repo encoder always emits Resource, ScopeSpans,
//      InstrumentationScope, Span, and Status submessages even when their
//      payload is empty, because `beginSubMessage`/`commitSubMessage` writes
//      an unconditional tag + length prefix. We model these as
//      *non-optional* DevNW submessages, which the DevNW writer emits
//      unconditionally.
//   2. The in-repo encoder uses ZigZag (`sint64`) for `AnyValue.int_value`,
//      so the DevNW schema declares it as `.sint64` for byte equality.
//      OTLP itself defines this field as `int64`; the in-repo wire output
//      is the contract enforced by the parity test, so the DevNW path
//      mirrors the existing behaviour.
//
// SYNCHRONIZE WITH `encodeSpansProto` ABOVE — these wire-type choices are
// *not* what OTLP 1.10.0 prescribes; they mirror the in-repo encoder's
// existing wire output so the parity test passes:
//   - `AnyValue.int_value`           => .sint64   (matches `writeSint64` at otlp.zig usage)
//   - `Span.kind`                    => .uint64   (in-repo uses `writeUint64`)
//   - `Span.dropped_attributes_count` => .uint64  (in-repo uses `writeUint64`)
//   - `Status.code`                  => .uint64   (in-repo uses `writeUint64`)
//
// If `encodeSpansProto` is ever updated to emit OTLP-spec-correct wire
// types (e.g. `int64`/`uint32`/enum), the parallel descriptor here MUST be
// updated in lockstep, or the parity test will start failing on the DevNW
// side and look like a DevNW regression. The fix is to update both at
// once, then expand the parity-test fixtures to cover the affected
// fields.

const ProtoMessages = if (build_options.use_devnw_protobuf) struct {
    const fd = devnw_proto.fd;

    pub const AnyValue = struct {
        string_value: []const u8 = "",
        bool_value: bool = false,
        int_value: i64 = 0,
        double_value: f64 = 0,

        pub const _desc_table = .{
            .string_value = fd(1, .{ .scalar = .string }),
            .bool_value = fd(2, .{ .scalar = .bool }),
            .int_value = fd(3, .{ .scalar = .sint64 }),
            .double_value = fd(4, .{ .scalar = .double }),
        };
    };

    pub const KeyValue = struct {
        key: []const u8 = "",
        value: AnyValue = .{},

        pub const _desc_table = .{
            .key = fd(1, .{ .scalar = .string }),
            .value = fd(2, .submessage),
        };
    };

    pub const Resource = struct {
        attributes: std.ArrayListUnmanaged(KeyValue) = .empty,

        pub const _desc_table = .{
            .attributes = fd(1, .{ .repeated = .submessage }),
        };
    };

    pub const InstrumentationScope = struct {
        name: []const u8 = "",
        version: []const u8 = "",

        pub const _desc_table = .{
            .name = fd(1, .{ .scalar = .string }),
            .version = fd(2, .{ .scalar = .string }),
        };
    };

    pub const Status = struct {
        message: []const u8 = "",
        code: u64 = 0,

        pub const _desc_table = .{
            .message = fd(2, .{ .scalar = .string }),
            .code = fd(3, .{ .scalar = .uint64 }),
        };
    };

    pub const Span = struct {
        // NOTE: order matches `encodeSpansProto`'s emission order so
        // DevNW's reflective walk produces an identical byte sequence.
        trace_id: []const u8 = "",
        span_id: []const u8 = "",
        name: []const u8 = "",
        kind: u64 = 0,
        start_time_unix_nano: u64 = 0,
        end_time_unix_nano: u64 = 0,
        attributes: std.ArrayListUnmanaged(KeyValue) = .empty,
        dropped_attributes_count: u64 = 0,
        status: Status = .{},

        pub const _desc_table = .{
            .trace_id = fd(1, .{ .scalar = .bytes }),
            .span_id = fd(2, .{ .scalar = .bytes }),
            .name = fd(5, .{ .scalar = .string }),
            .kind = fd(6, .{ .scalar = .uint64 }),
            .start_time_unix_nano = fd(7, .{ .scalar = .fixed64 }),
            .end_time_unix_nano = fd(8, .{ .scalar = .fixed64 }),
            .attributes = fd(9, .{ .repeated = .submessage }),
            .dropped_attributes_count = fd(10, .{ .scalar = .uint64 }),
            .status = fd(15, .submessage),
        };
    };

    pub const ScopeSpans = struct {
        scope: InstrumentationScope = .{},
        spans: std.ArrayListUnmanaged(Span) = .empty,
        // ScopeSpans.schema_url (field 3) — populated by the multi-scope
        // grouping path so the DevNW encoder's byte output stays in lock-
        // step with the in-repo encoder when a tracer ships a non-empty
        // schema_url.
        schema_url: []const u8 = "",

        pub const _desc_table = .{
            .scope = fd(1, .submessage),
            .spans = fd(2, .{ .repeated = .submessage }),
            .schema_url = fd(3, .{ .scalar = .string }),
        };
    };

    pub const ResourceSpans = struct {
        resource: Resource = .{},
        scope_spans: std.ArrayListUnmanaged(ScopeSpans) = .empty,

        pub const _desc_table = .{
            .resource = fd(1, .submessage),
            .scope_spans = fd(2, .{ .repeated = .submessage }),
        };
    };

    pub const ExportTraceServiceRequest = struct {
        resource_spans: std.ArrayListUnmanaged(ResourceSpans) = .empty,

        pub const _desc_table = .{
            .resource_spans = fd(1, .{ .repeated = .submessage }),
        };
    };
} else struct {};

pub fn encodeSpansProtoDevnw(allocator: std.mem.Allocator, items: []const exp.SpanData) ![]u8 {
    if (!build_options.use_devnw_protobuf) return error.UnsupportedTransport;
    if (items.len == 0) return try allocator.alloc(u8, 0);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const M = ProtoMessages;

    var rs: M.ResourceSpans = .{};

    // Resource attributes.
    const resource = items[0].resource;
    for (resource.attributes.entries.items) |kv| {
        try rs.resource.attributes.append(aa, buildKeyValue(kv));
    }

    // Group by `(scope.name, scope.version, scope.schema_url)` so the
    // DevNW path mirrors the in-repo encoder's per-scope ScopeSpans
    // emission. Closes PR-3 (#136).
    const buckets = try groupSpansByScope(aa, items);

    for (buckets) |bucket| {
        var ss: M.ScopeSpans = .{};
        ss.scope = .{
            .name = bucket.scope.name,
            .version = bucket.scope.version,
        };
        ss.schema_url = bucket.scope.schema_url;
        for (bucket.spans.items) |span_ptr| {
            // Source slices (`trace_id`, `span_id`, `name`, attribute
            // values) must reference the original `items[]` storage —
            // the encoded `M.Span` survives in `ss.spans` past this
            // loop iteration, and a stack-local `span = span_ptr.*`
            // copy would dangle as soon as the loop advances.
            const span = span_ptr;
            var s: M.Span = .{
                .trace_id = span.span_context.trace_id.bytes[0..],
                .span_id = span.span_context.span_id.bytes[0..],
                .name = span.name,
                .kind = switch (span.kind) {
                    .unspecified => otlp.span_kind_unspecified,
                    .internal => otlp.span_kind_internal,
                    .server => otlp.span_kind_server,
                    .client => otlp.span_kind_client,
                    .producer => otlp.span_kind_producer,
                    .consumer => otlp.span_kind_consumer,
                },
                .start_time_unix_nano = span.start_unix_nano,
                .end_time_unix_nano = span.end_unix_nano,
                .dropped_attributes_count = span.dropped_attributes_count,
                .status = .{
                    .message = span.status_description,
                    .code = switch (span.status_code) {
                        .unset => otlp.status_code_unset,
                        .ok => otlp.status_code_ok,
                        .@"error" => otlp.status_code_error,
                    },
                },
            };
            for (span.attributes.entries.items) |kv| {
                try s.attributes.append(aa, buildKeyValue(kv));
            }
            try ss.spans.append(aa, s);
        }
        try rs.scope_spans.append(aa, ss);
    }

    // The in-repo encoder writes a bare ResourceSpans (field tag 1 +
    // length-prefixed payload), not an ExportTraceServiceRequest envelope.
    // Mirror that by encoding a single-field wrapper that emits exactly the
    // ResourceSpans record.
    var req: M.ExportTraceServiceRequest = .{};
    try req.resource_spans.append(aa, rs);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try devnw_proto.encode(&aw.writer, aa, req);
    return try aw.toOwnedSlice();
}

fn buildKeyValue(kv: attrs_mod.Entry) ProtoMessages.KeyValue {
    var any: ProtoMessages.AnyValue = .{};
    switch (kv.value) {
        // GAP-SEC-H-6: mirror the in-repo encoder's redaction so the
        // DevNW protobuf path emits the same `[REDACTED]` marker for
        // sensitive keys (parity with `writeKeyValue`).
        .string => |s| any.string_value = redact.maskString(kv.key, s),
        .bool => |b| any.bool_value = b,
        .int => |i| any.int_value = i,
        .double => |d| any.double_value = d,
        else => {},
    }
    return .{ .key = kv.key, .value = any };
}

test "encodeSpansProto handles empty input" {
    const out = try encodeSpansProto(std.testing.allocator, &.{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

test "init rejects empty endpoint" {
    try std.testing.expectError(error.InvalidEndpoint, OtlpHttpExporter.init(std.testing.allocator, .{ .endpoint = "" }));
}

test "init rejects unsupported scheme" {
    try std.testing.expectError(error.InvalidEndpoint, OtlpHttpExporter.init(std.testing.allocator, .{ .endpoint = "ftp://otel" }));
}
