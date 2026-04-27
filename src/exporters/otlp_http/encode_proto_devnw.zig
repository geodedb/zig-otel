// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// DevNW protobuf encoder path for OTLP spans.
//
// Split out of `encode_proto.zig` so that file stays under the 600-LOC
// gate set by OTEL-Q-001 (gitlab #149). The behaviour is unchanged:
// when `-Dotel_use_devnw_protobuf=true`, this module's
// `encodeSpansProtoDevnw` produces a byte-identical envelope to
// `encode_proto.encodeSpansProto`. The wire-parity test in
// `test/otlp_wire_parity.zig` and the multi-scope parity test in
// `test/otlp_spans_multi_scope.zig` both pin that contract.
//
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
// SYNCHRONIZE WITH `encodeSpansProto` IN `encode_proto.zig` — these
// wire-type choices are *not* what OTLP 1.10.0 prescribes; they mirror
// the in-repo encoder's existing wire output so the parity test passes:
//   - `AnyValue.int_value`           => .sint64   (matches `writeSint64`)
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

const std = @import("std");
const exp = @import("../../sdk/export.zig");
const otlp = @import("../../generated/otlp.zig");
const logs_api = @import("../../api/logs.zig");
const attrs_mod = @import("../../internal/attributes.zig");
const redact = @import("../../internal/redact.zig");
const build_options = @import("build_options");
const devnw_proto = if (build_options.use_devnw_protobuf) @import("devnw_protobuf") else struct {};

const encode_proto = @import("encode_proto.zig");
const encode_logs = @import("encode_logs.zig");

// `logs_api.Body` is read via `r.body` in `encodeLogsProtoDevnw`, so the
// import is consumed transitively. This `comptime` reference keeps the
// import live in builds where the DevNW protobuf flag is off and the
// only callsite is gated out at compile time.
comptime {
    _ = logs_api;
}

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

    // Span.Event — closes GAP-OTLP-WIRE-EVENTS-LINKS (#9). Sub-fields per
    // `third_party/opentelemetry-proto-v1.10.0/opentelemetry/proto/trace/v1/trace.proto:222-239`.
    // Field-emission order mirrors `writeEvent` in `encode_proto.zig` so
    // DevNW's reflective walk produces a byte-identical Event submessage.
    // `dropped_attributes_count` is declared `.uint64` to mirror the
    // in-repo encoder's `writeUint64` (the OTLP spec types it `uint32`,
    // but as with the rest of this descriptor the parity contract is the
    // in-repo wire output, not the .proto definition — see the file
    // header note on wire-type drift).
    pub const Event = struct {
        time_unix_nano: u64 = 0,
        name: []const u8 = "",
        attributes: std.ArrayListUnmanaged(KeyValue) = .empty,
        dropped_attributes_count: u64 = 0,

        pub const _desc_table = .{
            .time_unix_nano = fd(1, .{ .scalar = .fixed64 }),
            .name = fd(2, .{ .scalar = .string }),
            .attributes = fd(3, .{ .repeated = .submessage }),
            .dropped_attributes_count = fd(4, .{ .scalar = .uint64 }),
        };
    };

    // Span.Link — closes GAP-OTLP-WIRE-EVENTS-LINKS (#9). Sub-fields per
    // `trace.proto:252-291`. The SDK does not track per-link `flags`
    // (field 6 fixed32) so it is intentionally absent from the descriptor;
    // proto3 default-omit on a missing field produces no bytes, which
    // matches the in-repo encoder's `writeLink` output.
    pub const Link = struct {
        trace_id: []const u8 = "",
        span_id: []const u8 = "",
        trace_state: []const u8 = "",
        attributes: std.ArrayListUnmanaged(KeyValue) = .empty,
        dropped_attributes_count: u64 = 0,

        pub const _desc_table = .{
            .trace_id = fd(1, .{ .scalar = .bytes }),
            .span_id = fd(2, .{ .scalar = .bytes }),
            .trace_state = fd(3, .{ .scalar = .string }),
            .attributes = fd(4, .{ .repeated = .submessage }),
            .dropped_attributes_count = fd(5, .{ .scalar = .uint64 }),
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
        // GAP-OTLP-WIRE-EVENTS-LINKS (#9): events/links land between
        // dropped_attributes_count (field 10) and status (field 15) so
        // the byte sequence matches `writeSpan`'s emission order.
        events: std.ArrayListUnmanaged(Event) = .empty,
        dropped_events_count: u64 = 0,
        links: std.ArrayListUnmanaged(Link) = .empty,
        dropped_links_count: u64 = 0,
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
            .events = fd(11, .{ .repeated = .submessage }),
            .dropped_events_count = fd(12, .{ .scalar = .uint64 }),
            .links = fd(13, .{ .repeated = .submessage }),
            .dropped_links_count = fd(14, .{ .scalar = .uint64 }),
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
        // ResourceSpans.schema_url (field 3) — closes
        // GAP-OTLP-WIRE-SCHEMA-URL (#26). Field number per
        // `third_party/opentelemetry-proto-v1.10.0/opentelemetry/proto/trace/v1/trace.proto:64`.
        // The DevNW writer skips empty strings (proto3 default-omit),
        // so single-resource batches without a schema_url stay byte-
        // identical to the in-repo encoder's output.
        schema_url: []const u8 = "",

        pub const _desc_table = .{
            .resource = fd(1, .submessage),
            .scope_spans = fd(2, .{ .repeated = .submessage }),
            .schema_url = fd(3, .{ .scalar = .string }),
        };
    };

    pub const ExportTraceServiceRequest = struct {
        resource_spans: std.ArrayListUnmanaged(ResourceSpans) = .empty,

        pub const _desc_table = .{
            .resource_spans = fd(1, .{ .repeated = .submessage }),
        };
    };

    // ---- Logs (closes GAP-OTLP-LOG-EXPORT (#8) on the DevNW path) ----
    //
    // Field-emission order mirrors `writeLogRecord` in `encode_logs.zig`
    // so the DevNW reflective walk produces a byte-identical LogRecord
    // submessage when both encoders run on the same input. The same
    // `dropped_attributes_count = uint64` and `severity_number = uint64`
    // wire-type drift caveat applies as for the span descriptors above —
    // `encode_logs.zig` uses `writeUint64`, which is varint, so the DevNW
    // schema declares the same wire type. Updating one encoder
    // independently will fail the parity test until both update.
    pub const LogRecord = struct {
        time_unix_nano: u64 = 0,
        severity_number: u64 = 0,
        severity_text: []const u8 = "",
        body: AnyValue = .{},
        attributes: std.ArrayListUnmanaged(KeyValue) = .empty,
        dropped_attributes_count: u64 = 0,
        flags: u32 = 0,
        trace_id: []const u8 = "",
        span_id: []const u8 = "",
        observed_time_unix_nano: u64 = 0,
        event_name: []const u8 = "",

        pub const _desc_table = .{
            .time_unix_nano = fd(1, .{ .scalar = .fixed64 }),
            .severity_number = fd(2, .{ .scalar = .uint64 }),
            .severity_text = fd(3, .{ .scalar = .string }),
            .body = fd(5, .submessage),
            .attributes = fd(6, .{ .repeated = .submessage }),
            .dropped_attributes_count = fd(7, .{ .scalar = .uint64 }),
            .flags = fd(8, .{ .scalar = .fixed32 }),
            .trace_id = fd(9, .{ .scalar = .bytes }),
            .span_id = fd(10, .{ .scalar = .bytes }),
            .observed_time_unix_nano = fd(11, .{ .scalar = .fixed64 }),
            .event_name = fd(12, .{ .scalar = .string }),
        };
    };

    pub const ScopeLogs = struct {
        scope: InstrumentationScope = .{},
        log_records: std.ArrayListUnmanaged(LogRecord) = .empty,
        schema_url: []const u8 = "",

        pub const _desc_table = .{
            .scope = fd(1, .submessage),
            .log_records = fd(2, .{ .repeated = .submessage }),
            .schema_url = fd(3, .{ .scalar = .string }),
        };
    };

    pub const ResourceLogs = struct {
        resource: Resource = .{},
        scope_logs: std.ArrayListUnmanaged(ScopeLogs) = .empty,
        schema_url: []const u8 = "",

        pub const _desc_table = .{
            .resource = fd(1, .submessage),
            .scope_logs = fd(2, .{ .repeated = .submessage }),
            .schema_url = fd(3, .{ .scalar = .string }),
        };
    };

    pub const ExportLogsServiceRequest = struct {
        resource_logs: std.ArrayListUnmanaged(ResourceLogs) = .empty,

        pub const _desc_table = .{
            .resource_logs = fd(1, .{ .repeated = .submessage }),
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
    // ResourceSpans.schema_url — closes GAP-OTLP-WIRE-SCHEMA-URL (#26).
    // Mirrors the in-repo encoder so the parity test
    // (`test/otlp_wire_parity.zig` + `test/otlp_resource_schema_url.zig`)
    // sees byte-identical output on both paths.
    rs.schema_url = resource.schema_url;

    // Group by `(scope.name, scope.version, scope.schema_url)` so the
    // DevNW path mirrors the in-repo encoder's per-scope ScopeSpans
    // emission. Closes PR-3 (#136).
    const buckets = try encode_proto.groupSpansByScope(aa, items);

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
            // GAP-OTLP-WIRE-EVENTS-LINKS (#9): mirror `writeEvent` /
            // `writeLink` in `encode_proto.zig` so the DevNW path emits
            // events at field 11 and links at field 13 in the same order
            // and with the same sub-message shape as the in-repo encoder.
            for (span.events) |ev| {
                var ev_msg: M.Event = .{
                    .time_unix_nano = ev.time_unix_nano,
                    .name = ev.name,
                };
                if (ev.attributes) |a| {
                    for (a.entries.items) |kv| {
                        try ev_msg.attributes.append(aa, buildKeyValue(kv));
                    }
                    ev_msg.dropped_attributes_count = a.dropped;
                }
                try s.events.append(aa, ev_msg);
            }
            s.dropped_events_count = span.dropped_events_count;
            for (span.links) |lk| {
                var lk_msg: M.Link = .{
                    .trace_id = lk.span_context.trace_id.bytes[0..],
                    .span_id = lk.span_context.span_id.bytes[0..],
                    .trace_state = lk.span_context.trace_state orelse "",
                };
                if (lk.attributes) |a| {
                    for (a.entries.items) |kv| {
                        try lk_msg.attributes.append(aa, buildKeyValue(kv));
                    }
                    lk_msg.dropped_attributes_count = a.dropped;
                }
                try s.links.append(aa, lk_msg);
            }
            s.dropped_links_count = span.dropped_links_count;
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

/// DevNW protobuf encoder for OTLP logs (closes GAP-OTLP-LOG-EXPORT (#8)
/// on the DevNW path). Mirrors `encodeLogsProto` byte-for-byte so the
/// parity test in `test/otlp_logs_wire.zig` passes when
/// `-Dotel_use_devnw_protobuf=true`.
///
/// Important wire-shape caveat: the in-repo encoder ALWAYS emits
/// `time_unix_nano` (field 1) and `observed_time_unix_nano` (field 11) —
/// even when zero — because the OTLP spec uses zero as the
/// "unknown timestamp" sentinel. DevNW's reflective writer applies proto3
/// default-omit on `fixed64`/`fixed32`, so a zero timestamp would NOT
/// appear on the DevNW side, breaking byte parity. Callers driving the
/// parity test MUST therefore use non-zero timestamps. The encoder here
/// accepts any input, but the parity contract only holds when timestamps
/// are non-zero. (The `LogRecord.flags` field has the same default-omit
/// behaviour, but the in-repo encoder also default-omits zero flags via
/// `writeFixed32Field`, so flags parity holds regardless.)
pub fn encodeLogsProtoDevnw(allocator: std.mem.Allocator, items: []const exp.LogData) ![]u8 {
    if (!build_options.use_devnw_protobuf) return error.UnsupportedTransport;
    if (items.len == 0) return try allocator.alloc(u8, 0);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const M = ProtoMessages;
    var rl: M.ResourceLogs = .{};

    const resource = items[0].resource;
    for (resource.attributes.entries.items) |kv| {
        try rl.resource.attributes.append(aa, buildKeyValue(kv));
    }
    rl.schema_url = resource.schema_url;

    const buckets = try encode_logs.groupLogsByScope(aa, items);
    for (buckets) |bucket| {
        var sl: M.ScopeLogs = .{};
        sl.scope = .{
            .name = bucket.scope.name,
            .version = bucket.scope.version,
        };
        sl.schema_url = bucket.scope.schema_url;
        for (bucket.logs.items) |l_ptr| {
            const r = l_ptr.record;
            var lr: M.LogRecord = .{
                .time_unix_nano = r.timestamp_unix_nano,
                .severity_number = @intFromEnum(r.severity),
                .severity_text = r.severity_text,
                .dropped_attributes_count = if (r.attributes) |a| a.dropped else 0,
                .flags = r.flags.toByte(),
                .observed_time_unix_nano = r.observed_unix_nano,
                .event_name = r.event_name,
            };
            // Body is a submessage; skip when none so DevNW emits zero
            // bytes — same as the in-repo `writeLogRecord` skip path.
            switch (r.body) {
                .none => {},
                .string => |s| lr.body.string_value = s,
                .bool => |b| lr.body.bool_value = b,
                .int => |i| lr.body.int_value = i,
                .double => |d| lr.body.double_value = d,
            }
            // trace_id / span_id only when valid (matches in-repo skip).
            if (r.trace_id.isValid()) {
                lr.trace_id = r.trace_id.bytes[0..];
            }
            if (r.span_id.isValid()) {
                lr.span_id = r.span_id.bytes[0..];
            }
            if (r.attributes) |a| {
                for (a.entries.items) |kv| {
                    try lr.attributes.append(aa, buildKeyValue(kv));
                }
            }
            try sl.log_records.append(aa, lr);
        }
        try rl.scope_logs.append(aa, sl);
    }

    var req: M.ExportLogsServiceRequest = .{};
    try req.resource_logs.append(aa, rl);

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
