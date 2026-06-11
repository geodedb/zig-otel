// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Protobuf encoders for OTLP spans and metrics.
//
// Split out of `src/exporters/otlp_http.zig` as part of OTEL-Q-001
// (gitlab #149). Hosts:
//   - `encodeSpansProto` (in-repo writer; the wire-format contract).
//   - `encodeMetricsProto` (same writer).
//   - `encodeSpansProtoDevnw` (DevNW protobuf encoder, gated on
//     `-Dotel_use_devnw_protobuf=true`; produces byte-identical output
//     to `encodeSpansProto` and is exercised by the parity test).
//   - The comptime `ProtoMessages` schema struct shared between the
//     two paths.
//   - `groupByScope` / `groupSpansByScope` bucketing helpers.
//
// Behaviour is preserved bit-for-bit relative to the pre-split file;
// this is a refactor commit only.

const std = @import("std");
const exp = @import("../../sdk/export.zig");
const otlp = @import("../../generated/otlp.zig");
const trace_api = @import("../../api/trace.zig");
const attrs_mod = @import("../../internal/attributes.zig");
const redact = @import("../../internal/redact.zig");

// ---------------------------------------------------------------- Scope hash key
//
// Closes GAP-PERF-PR-5 (#138). Replaces the prior O(R x S) linear scan
// in `groupByScope` / `groupSpansByScope` with an O(R) amortised
// hash-keyed lookup.
//
// Strategy: single-level content hash on the `(name, version, schema_url)`
// tuple, hashed with `std.hash.Wyhash` over the three byte slices. We do
// NOT use a pointer-hash on `*const InstrumentationScope` because the
// SDK copies `instrumentation_scope` *by value* into `SpanData` /
// `MetricData` (`src/sdk/export.zig:39,572`); pointers therefore differ
// per-record even when scopes are content-equal, which would defeat the
// fast path. Slice-pointer hashing is also unsafe: callers may construct
// scopes with freshly-allocated name buffers (see the duplicate-instance
// test in `test/otlp_spans_multi_scope.zig`).
//
// Two ScopeKey variants are needed because metric grouping omits
// `schema_url` (it is not part of the metric scope contract here) while
// span grouping must include it (PR-3 / #136 made schema_url part of the
// scope identity).
const ScopeKey2 = struct {
    name: []const u8,
    version: []const u8,
};

/// Shared `(name, version, schema_url)` scope hash key. Re-used by the
/// logs encoder (`encode_logs.zig`) so the Wyhash seed and `eql` policy
/// live in exactly one place (QN-NEW-3); span and log scope grouping must
/// not drift.
pub const ScopeKey3 = struct {
    name: []const u8,
    version: []const u8,
    schema_url: []const u8,
};

const ScopeKey2Context = struct {
    pub fn hash(_: @This(), k: ScopeKey2) u64 {
        var h = std.hash.Wyhash.init(0);
        h.update(k.name);
        h.update(&[_]u8{0});
        h.update(k.version);
        return h.final();
    }
    pub fn eql(_: @This(), a: ScopeKey2, b: ScopeKey2) bool {
        return std.mem.eql(u8, a.name, b.name) and
            std.mem.eql(u8, a.version, b.version);
    }
};

/// HashMap context for `ScopeKey3`. `pub` so the logs encoder shares it
/// (QN-NEW-3).
pub const ScopeKey3Context = struct {
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

// ---------------------------------------------------------------- Metric grouping
//
// Group metrics by `(scope.name, scope.version)` so the wire emits one
// `ScopeMetrics` per scope. Returns arena-owned slices of `MetricData`
// referencing the input batch (no payload copy). Buckets preserve
// first-seen order — the hash-map only memoises bucket indices; the
// `buckets` ArrayList is what defines emission order.
const ScopeBucket = struct {
    scope: trace_api.InstrumentationScope,
    metrics: std.ArrayList(*const exp.MetricData),
};

fn groupByScope(arena: std.mem.Allocator, items: []const exp.MetricData) ![]ScopeBucket {
    var buckets: std.ArrayList(ScopeBucket) = .empty;
    var index_map = std.HashMap(ScopeKey2, usize, ScopeKey2Context, std.hash_map.default_max_load_percentage).init(arena);
    defer index_map.deinit();

    for (items) |*m| {
        const key: ScopeKey2 = .{
            .name = m.instrumentation_scope.name,
            .version = m.instrumentation_scope.version,
        };
        const gop = try index_map.getOrPut(key);
        if (gop.found_existing) {
            try buckets.items[gop.value_ptr.*].metrics.append(arena, m);
        } else {
            const idx = buckets.items.len;
            var b: ScopeBucket = .{ .scope = m.instrumentation_scope, .metrics = .empty };
            try b.metrics.append(arena, m);
            try buckets.append(arena, b);
            gop.value_ptr.* = idx;
        }
    }
    return buckets.toOwnedSlice(arena);
}

// ---------------------------------------------------------------- Metric encoder

pub fn encodeMetricsProto(allocator: std.mem.Allocator, items: []const exp.MetricData) ![]u8 {
    var w = otlp.Writer.init(allocator);
    defer w.deinit();
    if (items.len == 0) return try w.toOwnedSlice();

    // Bucket bookkeeping is short-lived; route it through an internal
    // arena so direct callers (tests, custom exporters) don't have to
    // manage it. The returned slice is still `allocator`-owned.
    var bucket_arena = std.heap.ArenaAllocator.init(allocator);
    defer bucket_arena.deinit();
    const ba = bucket_arena.allocator();

    const resource = items[0].resource;
    const buckets = try groupByScope(ba, items);

    const rm_start = try w.beginSubMessage(otlp.fn_resource_metrics);
    {
        // Resource (field 1) — same Resource shape as ResourceSpans.
        const r_start = try w.beginSubMessage(otlp.fn_rm_resource);
        for (resource.attributes.entries.items) |kv| {
            try writeKeyValue(&w, otlp.fn_resource_attributes, kv);
        }
        try w.commitSubMessage(r_start);

        // ScopeMetrics — one per InstrumentationScope.
        for (buckets) |bucket| {
            const sm_start = try w.beginSubMessage(otlp.fn_rm_scope_metrics);
            const sc_start = try w.beginSubMessage(otlp.fn_sm_scope);
            try w.writeString(otlp.fn_scope_name, bucket.scope.name);
            try w.writeString(otlp.fn_scope_version, bucket.scope.version);
            try w.commitSubMessage(sc_start);

            for (bucket.metrics.items) |m_ptr| {
                const m = m_ptr.*;
                const m_start = try w.beginSubMessage(otlp.fn_sm_metrics);
                try w.writeString(otlp.fn_metric_name, m.name);
                try w.writeString(otlp.fn_metric_description, m.description);
                try w.writeString(otlp.fn_metric_unit, m.unit);
                try writeMetricBody(&w, m);
                try w.commitSubMessage(m_start);
            }
            try w.commitSubMessage(sm_start);
        }

        // ResourceMetrics.schema_url (field 3) — closes
        // GAP-OTLP-WIRE-SCHEMA-URL (#26). Mirrors the trace path; the
        // value is shared by every ScopeMetrics in this batch. Empty
        // string is dropped by `writeString` (proto3 default-omit) so
        // pre-fix wire bytes are unchanged when no detector set
        // `schema_url`. See
        // `third_party/opentelemetry-proto-v1.10.0/opentelemetry/proto/metrics/v1/metrics.proto:82`.
        try w.writeString(otlp.fn_rm_schema_url, resource.schema_url);
    }
    try w.commitSubMessage(rm_start);
    return try w.toOwnedSlice();
}

fn writeMetricBody(w: *otlp.Writer, m: exp.MetricData) !void {
    const temporality_value: u64 = switch (m.temporality) {
        .cumulative => otlp.aggregation_temporality_cumulative,
        .delta => otlp.aggregation_temporality_delta,
    };

    switch (m.kind) {
        .counter, .up_down_counter, .observable_counter, .observable_up_down_counter => {
            const sum_start = try w.beginSubMessage(otlp.fn_metric_sum);
            for (m.points) |pt| try writeNumberDataPoint(w, otlp.fn_sum_data_points, pt);
            try w.writeUint64(otlp.fn_sum_aggregation_temporality, temporality_value);
            try w.writeBool(otlp.fn_sum_is_monotonic, m.is_monotonic);
            try w.commitSubMessage(sum_start);
        },
        .gauge, .observable_gauge => {
            const g_start = try w.beginSubMessage(otlp.fn_metric_gauge);
            for (m.points) |pt| try writeNumberDataPoint(w, otlp.fn_gauge_data_points, pt);
            try w.commitSubMessage(g_start);
        },
        .histogram => {
            const h_start = try w.beginSubMessage(otlp.fn_metric_histogram);
            for (m.points) |pt| try writeHistogramDataPoint(w, otlp.fn_hist_data_points, pt);
            try w.writeUint64(otlp.fn_hist_aggregation_temporality, temporality_value);
            try w.commitSubMessage(h_start);
        },
    }
}

fn writeNumberDataPoint(w: *otlp.Writer, field_number: u32, pt: exp.DataPoint) !void {
    const ndp_start = try w.beginSubMessage(field_number);
    if (pt.attributes) |a| {
        for (a.entries.items) |kv| {
            try writeKeyValue(w, otlp.fn_ndp_attributes, kv);
        }
    }
    try w.writeFixed64Field(otlp.fn_ndp_start_time_unix_nano, pt.start_unix_nano);
    try w.writeFixed64Field(otlp.fn_ndp_time_unix_nano, pt.time_unix_nano);
    switch (pt.value) {
        .number => |n| switch (n) {
            // OTLP: oneof value { double as_double = 4; sfixed64 as_int = 6; }
            .int => |v| try w.writeSfixed64Field(otlp.fn_ndp_as_int, v),
            // proto3 omits zero doubles by default; OTLP collectors expect
            // the field present when this branch was selected (otherwise
            // the oneof is unset and the value is ambiguous). Force-emit.
            .double => |v| {
                try w.writeTag(otlp.fn_ndp_as_double, .fixed64);
                const bits: u64 = @bitCast(v);
                try w.writeFixed64(bits);
            },
        },
        .histogram => {}, // unreachable for number-shaped instruments
    }
    try w.commitSubMessage(ndp_start);
}

fn writeHistogramDataPoint(w: *otlp.Writer, field_number: u32, pt: exp.DataPoint) !void {
    const hdp_start = try w.beginSubMessage(field_number);
    if (pt.attributes) |a| {
        for (a.entries.items) |kv| {
            try writeKeyValue(w, otlp.fn_hdp_attributes, kv);
        }
    }
    try w.writeFixed64Field(otlp.fn_hdp_start_time_unix_nano, pt.start_unix_nano);
    try w.writeFixed64Field(otlp.fn_hdp_time_unix_nano, pt.time_unix_nano);
    switch (pt.value) {
        .histogram => |h| {
            // count + sum are always emitted (proto3 explicit-presence
            // optionals — collectors expect them populated even when 0).
            try w.writeTag(otlp.fn_hdp_count, .fixed64);
            try w.writeFixed64(h.count);
            try w.writeTag(otlp.fn_hdp_sum, .fixed64);
            const sum_bits: u64 = @bitCast(h.sum);
            try w.writeFixed64(sum_bits);
            try w.writePackedFixed64(otlp.fn_hdp_bucket_counts, h.counts);
            try w.writePackedDouble(otlp.fn_hdp_explicit_bounds, h.bounds);
            if (h.min) |min_v| {
                try w.writeTag(otlp.fn_hdp_min, .fixed64);
                const bits: u64 = @bitCast(min_v);
                try w.writeFixed64(bits);
            }
            if (h.max) |max_v| {
                try w.writeTag(otlp.fn_hdp_max, .fixed64);
                const bits: u64 = @bitCast(max_v);
                try w.writeFixed64(bits);
            }
        },
        .number => {}, // unreachable for histogram-shaped instruments
    }
    try w.commitSubMessage(hdp_start);
}

// ---------------------------------------------------------------- Span grouping

/// Group spans by `(scope.name, scope.version, scope.schema_url)` so the
/// wire emits one `ScopeSpans` per distinct InstrumentationScope. Buckets
/// preserve first-seen order. Returns arena-owned slices referencing the
/// input batch (no payload copy).
///
/// Closes PR-3 (#136): pre-fix the trace encoder used
/// `items[0].instrumentation_scope` for the entire batch, which mislabelled
/// every span past index 0 when a batch crossed multiple tracers.
pub const SpanScopeBucket = struct {
    scope: trace_api.InstrumentationScope,
    spans: std.ArrayList(*const exp.SpanData),
};

pub fn groupSpansByScope(arena: std.mem.Allocator, items: []const exp.SpanData) ![]SpanScopeBucket {
    var buckets: std.ArrayList(SpanScopeBucket) = .empty;
    // Hash-keyed bucket index — closes GAP-PERF-PR-5 (#138). See the
    // header note above the `ScopeKey2`/`ScopeKey3` declarations for the
    // rationale (content hash on the tuple, not pointer hash).
    var index_map = std.HashMap(ScopeKey3, usize, ScopeKey3Context, std.hash_map.default_max_load_percentage).init(arena);
    defer index_map.deinit();

    for (items) |*s| {
        const key: ScopeKey3 = .{
            .name = s.instrumentation_scope.name,
            .version = s.instrumentation_scope.version,
            .schema_url = s.instrumentation_scope.schema_url,
        };
        const gop = try index_map.getOrPut(key);
        if (gop.found_existing) {
            try buckets.items[gop.value_ptr.*].spans.append(arena, s);
        } else {
            const idx = buckets.items.len;
            var b: SpanScopeBucket = .{ .scope = s.instrumentation_scope, .spans = .empty };
            try b.spans.append(arena, s);
            try buckets.append(arena, b);
            gop.value_ptr.* = idx;
        }
    }
    return buckets.toOwnedSlice(arena);
}

fn writeSpan(w: *otlp.Writer, span: exp.SpanData) !void {
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
        try writeKeyValue(w, otlp.fn_span_attributes, kv);
    }
    try w.writeUint64(otlp.fn_span_dropped_attributes_count, span.dropped_attributes_count);

    // Span.events (field 11) and Span.dropped_events_count (field 12) —
    // closes GAP-OTLP-WIRE-EVENTS-LINKS (#9). Pre-fix the SDK tracked
    // events on `Span.events` (`src/api/trace.zig:65-69`) and the SpanData
    // export contract carries them through (`src/sdk/export.zig:37,42`),
    // but the encoder dropped them on the floor — `addEvent` /
    // `recordException` callers lost ALL data on the wire. Field numbers
    // pinned by
    // `third_party/opentelemetry-proto-v1.10.0/opentelemetry/proto/trace/v1/trace.proto:242,246`.
    // Empty `events` slice emits zero bytes (proto3 default-omit), so
    // spans without events stay byte-identical to the pre-fix wire shape.
    for (span.events) |ev| {
        try writeEvent(w, ev);
    }
    try w.writeUint64(otlp.fn_span_dropped_events_count, span.dropped_events_count);

    // Span.links (field 13) and Span.dropped_links_count (field 14) —
    // same closure (#9). Field numbers pinned by `trace.proto:295,299`.
    for (span.links) |lk| {
        try writeLink(w, lk);
    }
    try w.writeUint64(otlp.fn_span_dropped_links_count, span.dropped_links_count);

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

/// Span.Event (proto field 11 on Span; sub-fields per `trace.proto:222-239`).
/// Layout: time_unix_nano (1, fixed64), name (2, string), attributes
/// (3, repeated KeyValue), dropped_attributes_count (4, uint32). The SDK
/// stores the time as an absolute unix-nano on the `Event` struct, mirroring
/// `Span.start_time_unix_nano` — so `writeFixed64Field` is the same path used
/// by the parent span's clocks.
fn writeEvent(w: *otlp.Writer, ev: trace_api.Event) !void {
    const ev_start = try w.beginSubMessage(otlp.fn_span_events);
    try w.writeFixed64Field(otlp.fn_event_time_unix_nano, ev.time_unix_nano);
    try w.writeString(otlp.fn_event_name, ev.name);
    if (ev.attributes) |a| {
        for (a.entries.items) |kv| {
            try writeKeyValue(w, otlp.fn_event_attributes, kv);
        }
        try w.writeUint64(otlp.fn_event_dropped_attributes_count, a.dropped);
    }
    try w.commitSubMessage(ev_start);
}

/// Span.Link (proto field 13 on Span; sub-fields per `trace.proto:252-291`).
/// Layout: trace_id (1, bytes), span_id (2, bytes), trace_state (3, string),
/// attributes (4, repeated KeyValue), dropped_attributes_count (5, uint32),
/// flags (6, fixed32). The SDK's `Link` (`src/api/trace.zig:60-63`) tracks
/// only `span_context` + `attributes`; per-link `trace_state` is read from
/// the link's `SpanContext.trace_state`, and `flags` is not tracked, so it
/// is left at zero (proto3 default-omit for `fixed32`-via-`writeUint64`
/// would zero-omit, but since the SDK has no source for it we simply do
/// not emit the field).
fn writeLink(w: *otlp.Writer, lk: trace_api.Link) !void {
    const lk_start = try w.beginSubMessage(otlp.fn_span_links);
    try w.writeBytes(otlp.fn_link_trace_id, lk.span_context.trace_id.bytes[0..]);
    try w.writeBytes(otlp.fn_link_span_id, lk.span_context.span_id.bytes[0..]);
    if (lk.span_context.trace_state) |ts| try w.writeString(otlp.fn_link_trace_state, ts);
    if (lk.attributes) |a| {
        for (a.entries.items) |kv| {
            try writeKeyValue(w, otlp.fn_link_attributes, kv);
        }
        try w.writeUint64(otlp.fn_link_dropped_attributes_count, a.dropped);
    }
    try w.commitSubMessage(lk_start);
}

pub fn encodeSpansProto(allocator: std.mem.Allocator, items: []const exp.SpanData) ![]u8 {
    var w = otlp.Writer.init(allocator);
    defer w.deinit();
    // ResourceSpans message with one ScopeSpans per InstrumentationScope.
    // For simplicity we emit one ResourceSpans per call.
    if (items.len == 0) return try w.toOwnedSlice();
    const resource = items[0].resource;

    // Bucket bookkeeping is short-lived; route it through an internal
    // arena so direct callers don't have to manage it. Mirrors the
    // metrics encoder pattern at `groupByScope`. `groupSpansByScope` itself
    // uses a hash-keyed index (closes GAP-PERF-PR-5 / #138) so this is
    // O(R) amortised across the whole batch.
    var bucket_arena = std.heap.ArenaAllocator.init(allocator);
    defer bucket_arena.deinit();
    const ba = bucket_arena.allocator();

    const buckets = try groupSpansByScope(ba, items);

    const rs_start = try w.beginSubMessage(otlp.fn_resource_spans);
    {
        const r_start = try w.beginSubMessage(otlp.fn_resource);
        for (resource.attributes.entries.items) |kv| {
            try writeKeyValue(&w, otlp.fn_resource_attributes, kv);
        }
        try w.commitSubMessage(r_start);

        // Single-scope fast path: byte-identical to the pre-PR-3 wire
        // shape. The loop body below is the same code; for `buckets.len
        // == 1` the only field-level difference is the conditional
        // `schema_url` emission, which `writeString` already skips when
        // the value is empty (proto3 default-omit). Empty `schema_url`
        // therefore produces zero extra bytes — full byte-parity holds.
        for (buckets) |bucket| {
            const ss_start = try w.beginSubMessage(otlp.fn_scope_spans);
            const sc_start = try w.beginSubMessage(otlp.fn_scope);
            try w.writeString(otlp.fn_scope_name, bucket.scope.name);
            try w.writeString(otlp.fn_scope_version, bucket.scope.version);
            try w.commitSubMessage(sc_start);

            for (bucket.spans.items) |span_ptr| {
                try writeSpan(&w, span_ptr.*);
            }

            // ScopeSpans.schema_url (field 3) — emit only when set so
            // single-scope batches without a schema_url stay byte-identical
            // to the pre-PR-3 wire shape.
            try w.writeString(otlp.fn_schema_url, bucket.scope.schema_url);
            try w.commitSubMessage(ss_start);
        }

        // ResourceSpans.schema_url (field 3) — closes
        // GAP-OTLP-WIRE-SCHEMA-URL (#26). The Resource is shared across
        // every ScopeSpans in this batch, so the value is emitted once
        // at the parent message. `writeString` skips empty values
        // (proto3 default-omit), preserving byte-parity for the
        // common case where no detector populated `schema_url`.
        // Same field number (3) as `ScopeSpans.schema_url`; the
        // constant is shared. See
        // `third_party/opentelemetry-proto-v1.10.0/opentelemetry/proto/trace/v1/trace.proto:64`.
        try w.writeString(otlp.fn_schema_url, resource.schema_url);
    }
    try w.commitSubMessage(rs_start);

    return try w.toOwnedSlice();
}

/// Encode one OTLP `KeyValue` (key + AnyValue) at `field_number`.
///
/// `pub` so the logs encoder (`encode_logs.zig`) shares the single
/// definition (QN-NEW-3) — the redaction policy and the `else => {}`
/// silent-drop must not diverge between the span and log paths. Span,
/// log, and resource attributes all flow through this writer.
pub fn writeKeyValue(w: *otlp.Writer, field_number: u32, kv: attrs_mod.Entry) !void {
    const start = try w.beginSubMessage(field_number);
    try w.writeString(otlp.fn_kv_key, kv.key);
    const v_start = try w.beginSubMessage(otlp.fn_kv_value);
    switch (kv.value) {
        // GAP-SEC-H-6 / GAP-SEC-L-4: redact sensitive string values
        // before they hit the wire. Span / log / resource attributes
        // all flow through this writer.
        .string => |s| try w.writeString(otlp.fn_av_string, redact.maskString(kv.key, s)),
        .bool => |b| try w.writeBool(otlp.fn_av_bool, b),
        .int => |i| try w.writeSint64(otlp.fn_av_int, i),
        .double => |d| try w.writeDouble(otlp.fn_av_double, d),
        else => {},
    }
    try w.commitSubMessage(v_start);
    try w.commitSubMessage(start);
}

// The DevNW protobuf path (`encodeSpansProtoDevnw` and the
// `ProtoMessages` schema struct) lives in `encode_proto_devnw.zig`.
// Splitting it out keeps this file under the 600-LOC review budget set
// by OTEL-Q-001 (gitlab #149).

test "encodeSpansProto handles empty input" {
    const out = try encodeSpansProto(std.testing.allocator, &.{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}
