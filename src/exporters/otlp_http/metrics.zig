// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// `expMetrics` — the `MetricExporter` entry point that selects the
// wire format, encodes the batch, and routes to the shared
// `OtlpHttpExporter.exportSignal` retry loop.
//
// Split out of `src/exporters/otlp_http.zig` as part of OTEL-Q-001
// (gitlab #149).
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

const std = @import("std");
const exp = @import("../../sdk/export.zig");

const exporter_mod = @import("exporter.zig");
const encode_proto = @import("encode_proto.zig");
const encode_json = @import("encode_json.zig");

const metric_path: []const u8 = "/v1/metrics";
const ct_protobuf: []const u8 = "application/x-protobuf";
const ct_json: []const u8 = "application/json";

pub fn expMetrics(ctx: ?*anyopaque, items: []const exp.MetricData) anyerror!exp.SpanExportResult {
    const self: *exporter_mod.OtlpHttpExporter = @ptrCast(@alignCast(ctx.?));
    if (self.closed) return error.RetryExhausted;
    if (items.len == 0) return .success;

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const body = switch (self.config.protocol) {
        .http_protobuf, .grpc => try encode_proto.encodeMetricsProto(aa, items),
        .http_json => try encode_json.encodeMetricsJson(aa, items),
    };
    const content_type: []const u8 = switch (self.config.protocol) {
        .http_protobuf, .grpc => ct_protobuf,
        .http_json => ct_json,
    };

    return self.exportSignal(aa, metric_path, content_type, body);
}
