// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// OTLP/HTTP exporter facade.
//
// Pre-refactor this was a 1407-LOC single-file exporter. OTEL-Q-001
// (gitlab #149) split it into the `src/exporters/otlp_http/` module
// tree; this file is now a thin re-export so every existing
// `@import("exporters/otlp_http.zig").Foo` keeps resolving.
//
// Module map:
//
//   ├─ otlp_http.zig             (this file — facade only)
//   └─ otlp_http/
//      ├─ exporter.zig           OtlpHttpExporter struct + exportSignal helper
//      ├─ transport.zig          Transport tagged union + retry classifier
//      ├─ headers.zig            RFC 7230 header parsing
//      ├─ encode_proto.zig       protobuf encoders for spans + metrics
//      ├─ encode_json.zig        JSON encoders for spans + metrics
//      ├─ spans.zig              expSpans entry point
//      └─ metrics.zig            expMetrics entry point
//
// Closes:
//   - OTEL-Q-001 (#149): file split, largest module < 600 LOC.
//   - OTEL-Q-NEW-A (#163): tagged-union Transport replaces the
//     fn-pointer-identity sentinel that previously compared the
//     transport function pointer against an `httpTransport` marker.

const exporter_mod = @import("otlp_http/exporter.zig");
const transport_mod = @import("otlp_http/transport.zig");
const headers_mod = @import("otlp_http/headers.zig");
const compression_mod = @import("otlp_http/compression.zig");
const encode_proto_mod = @import("otlp_http/encode_proto.zig");
const encode_proto_devnw_mod = @import("otlp_http/encode_proto_devnw.zig");
const encode_json_mod = @import("otlp_http/encode_json.zig");
const encode_logs_mod = @import("otlp_http/encode_logs.zig");

// ---- Public re-exports ----

/// The OTLP/HTTP exporter struct. See `otlp_http/exporter.zig`.
pub const OtlpHttpExporter = exporter_mod.OtlpHttpExporter;

/// Exporter configuration. Re-exported from `sdk/config.zig` via
/// `exporter.zig` for backwards compatibility with callers that read
/// `otlp_http.OtlpConfig`.
pub const OtlpConfig = exporter_mod.OtlpConfig;

/// Tagged-union transport dispatch (closes OTEL-Q-NEW-A / #163). See
/// `otlp_http/transport.zig`.
pub const Transport = transport_mod.Transport;
pub const TransportResult = transport_mod.TransportResult;
pub const CustomFn = transport_mod.CustomFn;
pub const RetryClass = transport_mod.RetryClass;
pub const retryClassifyHttp = transport_mod.retryClassifyHttp;

// ---- Header parsing (re-exported for tests + downstream callers) ----
pub const HeaderEntry = headers_mod.HeaderEntry;
pub const max_header_name_len = headers_mod.max_header_name_len;
pub const max_header_value_len = headers_mod.max_header_value_len;
pub const parseHeaderString = headers_mod.parseHeaderString;

// ---- gzip helpers (GAP-OTLP-COMPRESSION #27, re-exported for tests) ----
pub const gzipBody = compression_mod.gzipBody;
pub const gunzipBody = compression_mod.gunzipBody;

// ---- Encoders (used by tests + `otlp_grpc.zig`) ----
pub const encodeSpansProto = encode_proto_mod.encodeSpansProto;
pub const encodeSpansProtoDevnw = encode_proto_devnw_mod.encodeSpansProtoDevnw;
pub const encodeMetricsProto = encode_proto_mod.encodeMetricsProto;
pub const encodeSpansJson = encode_json_mod.encodeSpansJson;
pub const encodeMetricsJson = encode_json_mod.encodeMetricsJson;

// GAP-OTLP-LOG-EXPORT (#8): encoder + grouping helpers.
pub const encodeLogsProto = encode_logs_mod.encodeLogsProto;
pub const encodeLogsProtoDevnw = encode_proto_devnw_mod.encodeLogsProtoDevnw;
pub const encodeLogsJson = encode_json_mod.encodeLogsJson;
pub const groupLogsByScope = encode_logs_mod.groupLogsByScope;
pub const LogScopeBucket = encode_logs_mod.LogScopeBucket;

// ---- Test aggregation ----
//
// Re-export the submodule tests so `zig build test` walks them through
// the same facade callers import. Without `refAllDecls`, Zig only runs
// tests it can reach from the root test source set; the submodules
// currently only get pulled in transitively from this facade, so we
// reference them explicitly below.
test {
    const std = @import("std");
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(exporter_mod);
    std.testing.refAllDecls(transport_mod);
    std.testing.refAllDecls(headers_mod);
    std.testing.refAllDecls(compression_mod);
    std.testing.refAllDecls(encode_proto_mod);
    std.testing.refAllDecls(encode_proto_devnw_mod);
    std.testing.refAllDecls(encode_json_mod);
    std.testing.refAllDecls(encode_logs_mod);
    std.testing.refAllDecls(@import("otlp_http/spans.zig"));
    std.testing.refAllDecls(@import("otlp_http/metrics.zig"));
    std.testing.refAllDecls(@import("otlp_http/logs.zig"));
}
