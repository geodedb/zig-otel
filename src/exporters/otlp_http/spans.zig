// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// `expSpans` — the `SpanExporter` entry point that selects the wire
// format, encodes the batch, and routes to the shared
// `OtlpHttpExporter.exportSignal` retry loop.
//
// Split out of `src/exporters/otlp_http.zig` as part of OTEL-Q-001
// (gitlab #149).

const std = @import("std");
const exp = @import("../../sdk/export.zig");

const exporter_mod = @import("exporter.zig");
const encode_proto = @import("encode_proto.zig");
const encode_json = @import("encode_json.zig");

const span_path: []const u8 = "/v1/traces";
const ct_protobuf: []const u8 = "application/x-protobuf";
const ct_json: []const u8 = "application/json";

pub fn expSpans(ctx: ?*anyopaque, items: []const exp.SpanData) anyerror!exp.SpanExportResult {
    const self: *exporter_mod.OtlpHttpExporter = @ptrCast(@alignCast(ctx.?));
    if (self.closed) return error.RetryExhausted;
    if (items.len == 0) return .success;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const body = switch (self.config.protocol) {
        .http_protobuf, .grpc => try encode_proto.encodeSpansProto(aa, items),
        .http_json => try encode_json.encodeSpansJson(aa, items),
    };
    const content_type: []const u8 = switch (self.config.protocol) {
        .http_protobuf, .grpc => ct_protobuf,
        .http_json => ct_json,
    };

    return self.exportSignal(aa, span_path, content_type, body);
}
