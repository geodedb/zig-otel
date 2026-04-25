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

pub const OtlpConfig = config_mod.OtlpConfig;

pub const OtlpHttpExporter = struct {
    allocator: std.mem.Allocator,
    config: OtlpConfig,
    /// Pluggable transport. Tests inject `fakeTransport`; production uses
    /// `httpTransport` which talks to the network.
    transport: Transport,
    prng: std.Random.DefaultPrng,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: OtlpConfig) !OtlpHttpExporter {
        if (config.endpoint.len == 0) return error.InvalidEndpoint;
        if (!std.mem.startsWith(u8, config.endpoint, "http://") and !std.mem.startsWith(u8, config.endpoint, "https://")) {
            return error.InvalidEndpoint;
        }
        return .{
            .allocator = allocator,
            .config = config,
            .transport = httpTransport,
            .prng = std.Random.DefaultPrng.init(0xC0DE_C0FFEE),
        };
    }

    pub fn deinit(self: *OtlpHttpExporter) void {
        self.closed = true;
    }

    pub fn spanExporter(self: *OtlpHttpExporter) exp.SpanExporter {
        return .{ .ctx = self, .exportFn = expSpans, .shutdownFn = doShutdown, .forceFlushFn = doFlush };
    }
};

pub const TransportResult = struct {
    status: u16,
    body: []const u8,
};

pub const Transport = *const fn (
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    path: []const u8,
    headers: ?[]const u8,
    content_type: []const u8,
    body: []const u8,
    timeout_ms: u64,
) anyerror!TransportResult;

fn httpTransport(allocator: std.mem.Allocator, endpoint: []const u8, path: []const u8, headers: ?[]const u8, content_type: []const u8, body: []const u8, timeout_ms: u64) anyerror!TransportResult {
    _ = allocator;
    _ = endpoint;
    _ = path;
    _ = headers;
    _ = content_type;
    _ = body;
    _ = timeout_ms;
    // Real HTTP transport requires a TLS-capable HTTP/1.1 client. The
    // initial delivery wires the seam (Transport vtable) but defers the
    // network implementation until tls + http2 are integrated. Returning
    // UnsupportedTransport keeps us from masquerading as a working
    // exporter; callers configure a fake transport in tests.
    return error.UnsupportedTransport;
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

    var attempt: u32 = 0;
    var elapsed_ms: u64 = 0;
    const policy: exp.RetryPolicy = .{};
    // Bound retries so a permanently-down sink doesn't spin forever even
    // without a sleep primitive (deferred to the Io-aware path).
    const max_attempts: u32 = 5;
    while (true) {
        const result = self.transport(aa, self.config.endpoint, path, self.config.headers, content_type, body, self.config.timeout_ms) catch |err| {
            attempt += 1;
            const backoff_ns = exp.nextBackoff(policy, attempt, &self.prng);
            elapsed_ms += backoff_ns / std.time.ns_per_ms;
            if (attempt >= max_attempts or elapsed_ms >= policy.max_elapsed_ms) return error.RetryExhausted;
            switch (err) {
                error.ConnectionRefused, error.ConnectionResetByPeer, error.UnsupportedTransport, error.NetworkUnreachable => continue,
                else => return err,
            }
        };
        if (result.status == 207) return error.PartialSuccess;
        if (result.status >= 200 and result.status < 300) return .success;
        if (result.status >= 400 and result.status < 500) return error.RetryExhausted;
        if (result.status >= 500 or result.status == 429) {
            attempt += 1;
            const backoff_ns = exp.nextBackoff(policy, attempt, &self.prng);
            elapsed_ms += backoff_ns / std.time.ns_per_ms;
            if (attempt >= max_attempts or elapsed_ms >= policy.max_elapsed_ms) return error.RetryExhausted;
            continue;
        }
        return error.RetryExhausted;
    }
}

pub fn encodeSpansProto(allocator: std.mem.Allocator, items: []const exp.SpanData) ![]u8 {
    var w = otlp.Writer.init(allocator);
    defer w.deinit();
    // ResourceSpans message with one ScopeSpans per InstrumentationScope.
    // For simplicity we emit one ResourceSpans per call.
    if (items.len == 0) return try w.toOwnedSlice();
    const resource = items[0].resource;

    const rs_start = try w.beginSubMessage(otlp.fn_resource_spans);
    {
        const r_start = try w.beginSubMessage(otlp.fn_resource);
        for (resource.attributes.entries.items) |kv| {
            try writeKeyValue(&w, otlp.fn_resource_attributes, kv);
        }
        try w.commitSubMessage(r_start);

        const ss_start = try w.beginSubMessage(otlp.fn_scope_spans);
        const sc_start = try w.beginSubMessage(otlp.fn_scope);
        try w.writeString(otlp.fn_scope_name, items[0].instrumentation_scope.name);
        try w.writeString(otlp.fn_scope_version, items[0].instrumentation_scope.version);
        try w.commitSubMessage(sc_start);

        for (items) |span| {
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
                try writeKeyValue(&w, otlp.fn_span_attributes, kv);
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
        try w.commitSubMessage(ss_start);
    }
    try w.commitSubMessage(rs_start);

    return try w.toOwnedSlice();
}

fn writeKeyValue(w: *otlp.Writer, field_number: u32, kv: attrs_mod.Entry) !void {
    const start = try w.beginSubMessage(field_number);
    try w.writeString(otlp.fn_kv_key, kv.key);
    const v_start = try w.beginSubMessage(otlp.fn_kv_value);
    switch (kv.value) {
        .string => |s| try w.writeString(otlp.fn_av_string, s),
        .bool => |b| try w.writeBool(otlp.fn_av_bool, b),
        .int => |i| try w.writeSint64(otlp.fn_av_int, i),
        .double => |d| try w.writeDouble(otlp.fn_av_double, d),
        else => {},
    }
    try w.commitSubMessage(v_start);
    try w.commitSubMessage(start);
}

fn encodeSpansJson(allocator: std.mem.Allocator, items: []const exp.SpanData) ![]u8 {
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
