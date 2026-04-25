// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// OTLP/gRPC exporter — limited to unary calls. Wire-frames are protobuf
// payloads with the gRPC 5-byte length-prefixed envelope. The transport
// vtable is shared with the HTTP exporter; production uses an HTTP/2
// client (deferred), tests inject a fake transport.

const std = @import("std");
const exp = @import("../sdk/export.zig");
const config_mod = @import("../sdk/config.zig");
const otlp_http = @import("otlp_http.zig");

pub const OtlpGrpcExporter = struct {
    allocator: std.mem.Allocator,
    config: config_mod.OtlpConfig,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: config_mod.OtlpConfig) !OtlpGrpcExporter {
        if (config.endpoint.len == 0) return error.InvalidEndpoint;
        if (config.protocol != .grpc) return error.InvalidConfig;
        return .{ .allocator = allocator, .config = config };
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

fn expSpans(_: ?*anyopaque, _: []const exp.SpanData) anyerror!exp.SpanExportResult {
    // Real HTTP/2 transport for gRPC unary lands once we wire the tls + http2
    // dependencies. Until then we fail loud rather than silently dropping.
    return error.UnsupportedTransport;
}

/// Frame `body` with the gRPC 5-byte length prefix (compressed=0, length).
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
