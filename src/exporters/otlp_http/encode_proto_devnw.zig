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
const attrs_mod = @import("../../internal/attributes.zig");
const redact = @import("../../internal/redact.zig");
const build_options = @import("build_options");
const devnw_proto = if (build_options.use_devnw_protobuf) @import("devnw_protobuf") else struct {};

const encode_proto = @import("encode_proto.zig");

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
