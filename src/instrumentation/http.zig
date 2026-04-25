// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// HTTP client/server instrumentation helpers. The library is transport
// agnostic — these helpers wrap arbitrary code in correctly-named spans
// and tag them with the OpenTelemetry HTTP semantic conventions.

const std = @import("std");
const trace_api = @import("../api/trace.zig");
const ctx_mod = @import("../api/context.zig");
const semconv = @import("../generated/semconv.zig");

pub const ClientRequest = struct {
    method: []const u8,
    url: []const u8,
    /// Optional override; default is `{method} {host}` per spec.
    span_name: ?[]const u8 = null,
};

pub const ClientResponse = struct {
    status_code: u16,
    /// Optional outgoing response body length (bytes).
    body_size: ?u64 = null,
};

pub fn startClientSpan(tracer: trace_api.Tracer, parent: ctx_mod.Context, req: ClientRequest) !trace_api.Span {
    var name_buf: [256]u8 = undefined;
    const default_name = std.fmt.bufPrint(name_buf[0..], "{s}", .{req.method}) catch req.method;
    const span_name = req.span_name orelse default_name;
    const span = try tracer.startSpan(parent, span_name, .{ .kind = .client });
    try span.setStringAttribute(semconv.http_request_method, req.method);
    try span.setStringAttribute(semconv.url_full, req.url);
    return span;
}

pub fn endClientSpan(span: trace_api.Span, response: ClientResponse) void {
    span.setIntAttribute(semconv.http_response_status_code, @intCast(response.status_code)) catch {};
    if (response.status_code >= 400) span.setStatus(.@"error", "");
    span.end(null);
}

pub const ServerRequest = struct {
    method: []const u8,
    route: []const u8,
    url: []const u8,
};

pub fn startServerSpan(tracer: trace_api.Tracer, parent: ctx_mod.Context, req: ServerRequest) !trace_api.Span {
    var name_buf: [256]u8 = undefined;
    const span_name = std.fmt.bufPrint(name_buf[0..], "{s} {s}", .{ req.method, req.route }) catch req.route;
    const span = try tracer.startSpan(parent, span_name, .{ .kind = .server });
    try span.setStringAttribute(semconv.http_request_method, req.method);
    try span.setStringAttribute(semconv.http_route, req.route);
    try span.setStringAttribute(semconv.url_path, req.url);
    return span;
}

pub fn endServerSpan(span: trace_api.Span, status_code: u16) void {
    span.setIntAttribute(semconv.http_response_status_code, @intCast(status_code)) catch {};
    if (status_code >= 500) span.setStatus(.@"error", "");
    span.end(null);
}
