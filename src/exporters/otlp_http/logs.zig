// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// `expLogs` — the `LogExporter` entry point that selects the wire
// format, encodes the batch, and routes to the shared
// `OtlpHttpExporter.exportSignal` retry loop.
//
// Closes GAP-OTLP-LOG-EXPORT (#8) on the OTLP/HTTP path. Mirrors the
// `expSpans` (`spans.zig`) and `expMetrics` (`metrics.zig`) shape so all
// three signals share the same retry / header / transport plumbing.
//
// Wire-shape contract: `ExportLogsServiceRequest` from
// `opentelemetry.proto.collector.logs.v1`. POSTed at `/v1/logs` per OTLP
// spec (https://opentelemetry.io/docs/specs/otlp/#otlphttp-request).

const std = @import("std");
const exp = @import("../../sdk/export.zig");

const exporter_mod = @import("exporter.zig");
const encode_logs = @import("encode_logs.zig");
const encode_json = @import("encode_json.zig");

const log_path: []const u8 = "/v1/logs";
const ct_protobuf: []const u8 = "application/x-protobuf";
const ct_json: []const u8 = "application/json";

pub fn expLogs(ctx: ?*anyopaque, items: []const exp.LogData) anyerror!exp.SpanExportResult {
    const self: *exporter_mod.OtlpHttpExporter = @ptrCast(@alignCast(ctx.?));
    if (self.closed) return error.RetryExhausted;
    if (items.len == 0) return .success;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const body = switch (self.config.protocol) {
        .http_protobuf, .grpc => try encode_logs.encodeLogsProto(aa, items),
        .http_json => try encode_json.encodeLogsJson(aa, items),
    };
    const content_type: []const u8 = switch (self.config.protocol) {
        .http_protobuf, .grpc => ct_protobuf,
        .http_json => ct_json,
    };

    return self.exportSignal(aa, log_path, content_type, body);
}
