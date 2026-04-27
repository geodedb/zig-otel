// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Protobuf encoder for OTLP logs.
//
// Closes GAP-OTLP-LOG-EXPORT (#8) — wires the log signal onto the OTLP
// wire alongside spans (`encode_proto.zig`) and metrics (same file).
//
// Wire layout (pinned against
// `third_party/opentelemetry-proto-v1.10.0/opentelemetry/proto/logs/v1/logs.proto`
// and the matching `collector/logs/v1/logs_service.proto`):
//
//   ExportLogsServiceRequest {
//     repeated ResourceLogs resource_logs = 1;
//   }
//   ResourceLogs {
//     Resource resource = 1;
//     repeated ScopeLogs scope_logs = 2;
//     string schema_url = 3;
//   }
//   ScopeLogs {
//     InstrumentationScope scope = 1;
//     repeated LogRecord log_records = 2;
//     string schema_url = 3;
//   }
//   LogRecord {
//     fixed64 time_unix_nano = 1;
//     SeverityNumber severity_number = 2;
//     string severity_text = 3;
//     reserved 4;
//     AnyValue body = 5;
//     repeated KeyValue attributes = 6;
//     uint32 dropped_attributes_count = 7;
//     fixed32 flags = 8;
//     bytes trace_id = 9;        // 16 bytes
//     bytes span_id = 10;        // 8 bytes
//     fixed64 observed_time_unix_nano = 11;
//     string event_name = 12;
//   }
//
// The encoder mirrors the conservative defaults the span / metric paths
// use:
//   - One ResourceLogs per export call (caller drives batching at the
//     `LogExporter` boundary; a single call carries one Resource).
//   - One ScopeLogs per `(scope.name, scope.version, scope.schema_url)`
//     bucket present in the batch — same hash-keyed `groupByScope`
//     primitive the spans encoder uses (PR-5 / #138). Stage C's
//     `ScopeKey3Context` is reused via the local copy below to keep the
//     encoder stand-alone (private to the file, same as the span helper).
//   - `time_unix_nano` and `observed_time_unix_nano` always go through
//     `writeFixed64Field`, which writes zero verbatim because the proto
//     declares the fields as `fixed64` (not `uint64`). That's a deliberate
//     spec choice: a zero value indicates "unknown or missing timestamp"
//     per `logs.proto:140-142,156-159`, and the field MUST be present so
//     receivers can distinguish "unknown" from "field absent". Mirrors the
//     span encoder's start/end_unix_nano emission convention.
//   - `severity_number` is a uint64-encoded varint per the
//     `SeverityNumber` enum at `logs.proto:87-113`.
//   - `trace_id` / `span_id` only emit when valid; an all-zero ID would
//     waste bytes and the spec explicitly says receivers should treat
//     all-zero IDs as "not associated with a trace/span".
//   - `flags` uses the new `writeFixed32Field` helper which honours
//     proto3 default-omit so empty TraceFlags don't add bytes.
//   - `event_name` is a recent addition (logs.proto:225 — present in v1.10.0
//     but NOT in older v1.x.x trees). Older collectors that pre-date v1.5
//     silently ignore unknown fields per proto3, so emitting unconditionally
//     is wire-safe; collectors that DO speak v1.10.0+ will surface the
//     event name. Empty string is dropped by `writeString` so logs without
//     `event_name` produce zero extra bytes.

const std = @import("std");
const exp = @import("../../sdk/export.zig");
const otlp = @import("../../generated/otlp.zig");
const trace_api = @import("../../api/trace.zig");
const logs_api = @import("../../api/logs.zig");
const attrs_mod = @import("../../internal/attributes.zig");
const redact = @import("../../internal/redact.zig");

// ---------------------------------------------------------------- Scope hash key
//
// Local copy of the (name, version, schema_url) hash key used by the spans
// encoder. Sharing across modules would tangle the visibility of a
// < 30-LOC helper that also exists in the JSON encoder; keep the
// duplication narrow. Closes GAP-PERF-PR-5 (#138)-style O(R) bucketing
// for the logs path (parity with spans/metrics).
const ScopeKey3 = struct {
    name: []const u8,
    version: []const u8,
    schema_url: []const u8,
};

const ScopeKey3Context = struct {
    pub fn hash(_: @This(), k: ScopeKey3) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.name);
        h.update(&[_]u8{0});
        h.update(k.version);
        h.update(&[_]u8{0});
        h.update(k.schema_url);
        return h.final();
    }
    pub fn eql(_: @This(), a: ScopeKey3, b: ScopeKey3) bool {
        return std.mem.eql(u8, a.name, b.name) and
            std.mem.eql(u8, a.version, b.version) and
            std.mem.eql(u8, a.schema_url, b.schema_url);
    }
};

// ---------------------------------------------------------------- Log grouping
//
// Group log records by `(scope.name, scope.version, scope.schema_url)` so
// the wire emits one `ScopeLogs` per distinct InstrumentationScope.
// Buckets preserve first-seen order; arena-owned slices reference the
// caller's input batch (no payload copy).
pub const LogScopeBucket = struct {
    scope: trace_api.InstrumentationScope,
    logs: std.ArrayList(*const exp.LogData),
};

pub fn groupLogsByScope(arena: std.mem.Allocator, items: []const exp.LogData) ![]LogScopeBucket {
    var buckets: std.ArrayList(LogScopeBucket) = .empty;
    var index_map = std.HashMap(ScopeKey3, usize, ScopeKey3Context, std.hash_map.default_max_load_percentage).init(arena);
    defer index_map.deinit();

    for (items) |*l| {
        const key: ScopeKey3 = .{
            .name = l.instrumentation_scope.name,
            .version = l.instrumentation_scope.version,
            .schema_url = l.instrumentation_scope.schema_url,
        };
        const gop = try index_map.getOrPut(key);
        if (gop.found_existing) {
            try buckets.items[gop.value_ptr.*].logs.append(arena, l);
        } else {
            const idx = buckets.items.len;
            var b: LogScopeBucket = .{ .scope = l.instrumentation_scope, .logs = .empty };
            try b.logs.append(arena, l);
            try buckets.append(arena, b);
            gop.value_ptr.* = idx;
        }
    }
    return buckets.toOwnedSlice(arena);
}

// ---------------------------------------------------------------- Log encoder

pub fn encodeLogsProto(allocator: std.mem.Allocator, items: []const exp.LogData) ![]u8 {
    var w = otlp.Writer.init(allocator);
    defer w.deinit();
    if (items.len == 0) return try w.toOwnedSlice();

    var bucket_arena = std.heap.ArenaAllocator.init(allocator);
    defer bucket_arena.deinit();
    const ba = bucket_arena.allocator();

    const resource = items[0].resource;
    const buckets = try groupLogsByScope(ba, items);

    const rl_start = try w.beginSubMessage(otlp.fn_resource_logs);
    {
        // Resource (field 1).
        const r_start = try w.beginSubMessage(otlp.fn_rl_resource);
        for (resource.attributes.entries.items) |kv| {
            try writeKeyValue(&w, otlp.fn_resource_attributes, kv);
        }
        try w.commitSubMessage(r_start);

        // ScopeLogs — one per InstrumentationScope.
        for (buckets) |bucket| {
            const sl_start = try w.beginSubMessage(otlp.fn_rl_scope_logs);
            const sc_start = try w.beginSubMessage(otlp.fn_sl_scope);
            try w.writeString(otlp.fn_scope_name, bucket.scope.name);
            try w.writeString(otlp.fn_scope_version, bucket.scope.version);
            try w.commitSubMessage(sc_start);

            for (bucket.logs.items) |l_ptr| {
                try writeLogRecord(&w, l_ptr.*);
            }

            // ScopeLogs.schema_url (field 3) — emit only when set so
            // empty-schema_url batches stay byte-minimal (proto3 default
            // omit).
            try w.writeString(otlp.fn_sl_schema_url, bucket.scope.schema_url);
            try w.commitSubMessage(sl_start);
        }

        // ResourceLogs.schema_url (field 3) — mirrors the spans/metrics
        // path. Pinned by `logs.proto:64`.
        try w.writeString(otlp.fn_rl_schema_url, resource.schema_url);
    }
    try w.commitSubMessage(rl_start);

    return try w.toOwnedSlice();
}

fn writeLogRecord(w: *otlp.Writer, l: exp.LogData) !void {
    const r = l.record;
    const lr_start = try w.beginSubMessage(otlp.fn_sl_log_records);

    // time_unix_nano (1, fixed64). Per logs.proto:140-142 the field MUST
    // be set when the timestamp is known; zero is a sentinel for "unknown
    // or missing". We always emit (no proto3 default-omit) so the
    // distinction survives.
    try w.writeTag(otlp.fn_lr_time_unix_nano, .fixed64);
    try w.writeFixed64(r.timestamp_unix_nano);

    // severity_number (2, varint). proto3 default-omit on zero matches
    // the OTLP spec — `SEVERITY_NUMBER_UNSPECIFIED = 0` is the default.
    try w.writeUint64(otlp.fn_lr_severity_number, @intFromEnum(r.severity));

    // severity_text (3, string). proto3 default-omit on empty.
    try w.writeString(otlp.fn_lr_severity_text, r.severity_text);

    // body (5, AnyValue). Only emit when the body carries a payload —
    // `none` collapses to no submessage on the wire. Mirrors the
    // existing AnyValue encoding in `writeKeyValue`.
    switch (r.body) {
        .none => {},
        else => try writeBody(w, r.body),
    }

    // attributes (6, repeated KeyValue) and dropped_attributes_count (7).
    if (r.attributes) |a| {
        for (a.entries.items) |kv| {
            try writeKeyValue(w, otlp.fn_lr_attributes, kv);
        }
        try w.writeUint64(otlp.fn_lr_dropped_attributes_count, a.dropped);
    }

    // flags (8, fixed32). proto3 default-omit on zero via
    // `writeFixed32Field`.
    try w.writeFixed32Field(otlp.fn_lr_flags, r.flags.toByte());

    // trace_id (9, bytes — 16). Skip when unset so the spec's "not
    // associated with a trace" semantics survive.
    if (r.trace_id.isValid()) {
        try w.writeBytes(otlp.fn_lr_trace_id, r.trace_id.bytes[0..]);
    }
    // span_id (10, bytes — 8). Same skip-when-invalid contract.
    if (r.span_id.isValid()) {
        try w.writeBytes(otlp.fn_lr_span_id, r.span_id.bytes[0..]);
    }

    // observed_time_unix_nano (11, fixed64). Always emitted for the same
    // reason as time_unix_nano — zero is a sentinel that must reach the
    // collector intact.
    try w.writeTag(otlp.fn_lr_observed_time_unix_nano, .fixed64);
    try w.writeFixed64(r.observed_unix_nano);

    // event_name (12, string). proto3 default-omit on empty.
    try w.writeString(otlp.fn_lr_event_name, r.event_name);

    try w.commitSubMessage(lr_start);
}

/// Encode `LogRecord.body` as an `AnyValue` submessage (field 5).
/// Mirrors `writeKeyValue`'s value-encoding cases. The redactor is
/// not invoked here — `Body` does not carry a key, so the redactor's
/// key-driven heuristics have nothing to match against. Sensitive
/// payload data SHOULD already be filtered by the producer; the
/// attribute-side redactor still applies.
fn writeBody(w: *otlp.Writer, body: logs_api.Body) !void {
    const v_start = try w.beginSubMessage(otlp.fn_lr_body);
    switch (body) {
        .string => |s| try w.writeString(otlp.fn_av_string, s),
        .bool => |b| try w.writeBool(otlp.fn_av_bool, b),
        .int => |i| try w.writeSint64(otlp.fn_av_int, i),
        .double => |d| try w.writeDouble(otlp.fn_av_double, d),
        .none => {},
    }
    try w.commitSubMessage(v_start);
}

fn writeKeyValue(w: *otlp.Writer, field_number: u32, kv: attrs_mod.Entry) !void {
    const start = try w.beginSubMessage(field_number);
    try w.writeString(otlp.fn_kv_key, kv.key);
    const v_start = try w.beginSubMessage(otlp.fn_kv_value);
    switch (kv.value) {
        // GAP-SEC-H-6 / GAP-SEC-L-4: redact sensitive string values
        // before they hit the wire. Span / log / resource attributes
        // all flow through the same redactor.
        .string => |s| try w.writeString(otlp.fn_av_string, redact.maskString(kv.key, s)),
        .bool => |b| try w.writeBool(otlp.fn_av_bool, b),
        .int => |i| try w.writeSint64(otlp.fn_av_int, i),
        .double => |d| try w.writeDouble(otlp.fn_av_double, d),
        else => {},
    }
    try w.commitSubMessage(v_start);
    try w.commitSubMessage(start);
}

test "encodeLogsProto handles empty input" {
    const out = try encodeLogsProto(std.testing.allocator, &.{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
