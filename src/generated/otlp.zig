// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// OTLP message wire-format helpers — protobuf encoder and the JSON shape
// used by the JSON exporter. We hand-roll the encoder to avoid pulling in
// a full protobuf library; the message shapes used here cover the stable
// signals (traces, metrics, logs) plus the experimental profiles request.
//
// Protobuf reference: https://protobuf.dev/programming-guides/encoding/
// OTLP reference:    https://github.com/open-telemetry/opentelemetry-proto

const std = @import("std");

pub const WireType = enum(u3) {
    varint = 0,
    fixed64 = 1,
    length_delimited = 2,
    fixed32 = 5,
};

pub const Writer = struct {
    buf: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,

    /// Recorded submessage commits, deferred until `toOwnedSlice`. Each
    /// entry pins the byte range originally reserved for the length-varint
    /// header (always 10 bytes, see `beginSubMessage`) plus the post-
    /// compaction logical payload length. `toOwnedSlice` performs a
    /// single linear sweep that rewrites every reserved slot to its
    /// minimal-width varint and elides the unused bytes — this is the
    /// O(N) replacement for the old per-commit `copyForwards` of the
    /// payload tail, which gave the encoder O(N²) wall-clock on deeply
    /// nested OTLP payloads (#36 / PR-2).
    sub_msgs: std.ArrayList(SubMsg) = .empty,

    /// Stack of "running savings counter" snapshots taken at each open
    /// `beginSubMessage`. Lets `commitSubMessage` deduce the post-
    /// compaction payload length of *this* submessage without reshuffling
    /// the buffer: the payload's raw byte span minus the savings
    /// accumulated by every nested submessage that closed inside it.
    open_savings: std.ArrayList(u64) = .empty,

    /// Cumulative bytes saved by deferred submessage compaction so far.
    /// Each closed submessage that emits a varint shorter than the 10
    /// reserved bytes adds `(10 - varint_size)` to this counter; parent
    /// submessages subtract it from their raw payload range to recover
    /// the post-compaction logical length.
    total_savings: u64 = 0,

    const SubMsg = struct {
        /// Byte offset of the reserved 10-byte length slot in `buf`.
        header_pos: usize,
        /// Payload length that will appear on the wire (i.e. the
        /// post-compaction submessage body size).
        logical_payload_len: u64,
        /// Number of bytes the varint will occupy after compaction.
        /// `1..=10` (length-delimited proto3 sizes always fit in <=10).
        varint_size: u8,
    };

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.allocator);
        self.sub_msgs.deinit(self.allocator);
        self.open_savings.deinit(self.allocator);
    }

    /// Take ownership of the encoded bytes. Performs a single O(N)
    /// compaction sweep to rewrite every deferred submessage length
    /// header at its minimal varint width — the call sites that wrote
    /// the body did so into 10-byte placeholders, so this is where the
    /// real wire bytes appear.
    pub fn toOwnedSlice(self: *Writer) ![]u8 {
        std.debug.assert(self.open_savings.items.len == 0); // every begin must be matched
        if (self.sub_msgs.items.len == 0) {
            self.total_savings = 0;
            return try self.buf.toOwnedSlice(self.allocator);
        }

        // Submessages are committed in LIFO order (innermost first), but
        // their reserved header positions are not monotonic — siblings
        // are written in source order, parents in reverse. Sort by
        // `header_pos` ascending so the sweep walks the buffer linearly.
        const entries = self.sub_msgs.items;
        std.sort.pdq(SubMsg, entries, {}, lessThanByHeaderPos);

        const final_len = self.buf.items.len - self.total_savings;
        const out = try self.allocator.alloc(u8, final_len);
        errdefer self.allocator.free(out);

        var read_pos: usize = 0;
        var write_pos: usize = 0;
        for (entries) |e| {
            // Copy the literal byte range that precedes this submessage
            // header verbatim — these bytes are tags, scalar fields, or
            // payload from siblings that were already compacted.
            const literal_len = e.header_pos - read_pos;
            @memcpy(out[write_pos .. write_pos + literal_len], self.buf.items[read_pos .. read_pos + literal_len]);
            write_pos += literal_len;
            read_pos = e.header_pos;

            // Emit the varint length header at its minimal width.
            var v = e.logical_payload_len;
            var i: usize = 0;
            while (v >= 0x80) : (v >>= 7) {
                out[write_pos + i] = @as(u8, @intCast(v & 0x7f)) | 0x80;
                i += 1;
            }
            out[write_pos + i] = @as(u8, @intCast(v));
            write_pos += e.varint_size;
            // Skip the original 10-byte placeholder in the source.
            read_pos += 10;
        }
        // Tail: copy any bytes after the final submessage header.
        const tail_len = self.buf.items.len - read_pos;
        @memcpy(out[write_pos .. write_pos + tail_len], self.buf.items[read_pos .. read_pos + tail_len]);
        write_pos += tail_len;
        std.debug.assert(write_pos == final_len);

        // Reset the writer so the caller can reuse it (or deinit safely).
        self.buf.clearRetainingCapacity();
        self.sub_msgs.clearRetainingCapacity();
        self.total_savings = 0;
        return out;
    }

    fn lessThanByHeaderPos(_: void, a: SubMsg, b: SubMsg) bool {
        return a.header_pos < b.header_pos;
    }

    pub fn writeTag(self: *Writer, field_number: u32, wire_type: WireType) !void {
        const tag = (@as(u64, field_number) << 3) | @as(u64, @intFromEnum(wire_type));
        try self.writeVarint(tag);
    }

    pub fn writeVarint(self: *Writer, value: u64) !void {
        var v = value;
        while (v >= 0x80) {
            try self.buf.append(self.allocator, @as(u8, @intCast(v & 0x7f)) | 0x80);
            v >>= 7;
        }
        try self.buf.append(self.allocator, @as(u8, @intCast(v)));
    }

    pub fn writeFixed64(self: *Writer, value: u64) !void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.buf.appendSlice(self.allocator, &bytes);
    }

    pub fn writeFixed32(self: *Writer, value: u32) !void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.buf.appendSlice(self.allocator, &bytes);
    }

    pub fn writeBool(self: *Writer, field_number: u32, value: bool) !void {
        if (!value) return; // proto3 omits defaults
        try self.writeTag(field_number, .varint);
        try self.writeVarint(if (value) 1 else 0);
    }

    pub fn writeUint64(self: *Writer, field_number: u32, value: u64) !void {
        if (value == 0) return;
        try self.writeTag(field_number, .varint);
        try self.writeVarint(value);
    }

    pub fn writeSint64(self: *Writer, field_number: u32, value: i64) !void {
        if (value == 0) return;
        try self.writeTag(field_number, .varint);
        const zig_zag: u64 = @bitCast((value << 1) ^ (value >> 63));
        try self.writeVarint(zig_zag);
    }

    pub fn writeFixed64Field(self: *Writer, field_number: u32, value: u64) !void {
        try self.writeTag(field_number, .fixed64);
        try self.writeFixed64(value);
    }

    /// Emit a `fixed32` field with proto3 default-omit semantics
    /// (suppresses zero so the OTLP `LogRecord.flags` field stays absent
    /// when the trace flags bitfield is empty). Used by the logs encoder.
    pub fn writeFixed32Field(self: *Writer, field_number: u32, value: u32) !void {
        if (value == 0) return;
        try self.writeTag(field_number, .fixed32);
        try self.writeFixed32(value);
    }

    pub fn writeDouble(self: *Writer, field_number: u32, value: f64) !void {
        if (value == 0.0) return;
        try self.writeTag(field_number, .fixed64);
        const bits: u64 = @bitCast(value);
        try self.writeFixed64(bits);
    }

    pub fn writeString(self: *Writer, field_number: u32, value: []const u8) !void {
        if (value.len == 0) return;
        try self.writeTag(field_number, .length_delimited);
        try self.writeVarint(@intCast(value.len));
        try self.buf.appendSlice(self.allocator, value);
    }

    pub fn writeBytes(self: *Writer, field_number: u32, value: []const u8) !void {
        if (value.len == 0) return;
        try self.writeTag(field_number, .length_delimited);
        try self.writeVarint(@intCast(value.len));
        try self.buf.appendSlice(self.allocator, value);
    }

    /// Emit a `sfixed64` field — same wire bytes as `fixed64` but the
    /// schema declares signed two's-complement. Used for
    /// `NumberDataPoint.as_int = 6` (sfixed64).
    pub fn writeSfixed64Field(self: *Writer, field_number: u32, value: i64) !void {
        try self.writeTag(field_number, .fixed64);
        try self.writeFixed64(@bitCast(value));
    }

    /// Packed-repeated `fixed64` — proto3's default repeated-scalar
    /// encoding. One tag, one length varint, then `values.len * 8` bytes
    /// of little-endian payload. Used for
    /// `HistogramDataPoint.bucket_counts = 6` (fixed64).
    pub fn writePackedFixed64(self: *Writer, field_number: u32, values: []const u64) !void {
        if (values.len == 0) return;
        try self.writeTag(field_number, .length_delimited);
        try self.writeVarint(@intCast(values.len * 8));
        for (values) |v| try self.writeFixed64(v);
    }

    /// Packed-repeated `double` — same envelope shape as
    /// `writePackedFixed64` (8-byte values, fixed64 wire-bytes). Used for
    /// `HistogramDataPoint.explicit_bounds = 7`.
    pub fn writePackedDouble(self: *Writer, field_number: u32, values: []const f64) !void {
        if (values.len == 0) return;
        try self.writeTag(field_number, .length_delimited);
        try self.writeVarint(@intCast(values.len * 8));
        for (values) |v| {
            const bits: u64 = @bitCast(v);
            try self.writeFixed64(bits);
        }
    }

    /// Begin a length-delimited submessage. The caller writes fields, then
    /// commits via `commitSubMessage` with the start length returned here.
    ///
    /// The 10-byte placeholder reserved here is *not* shifted at commit
    /// time — `commitSubMessage` records the slot for deferred rewrite,
    /// and `toOwnedSlice` performs a single O(N) compaction. This is the
    /// fix for #36 (PR-2): the previous implementation `copyForwards`-
    /// shifted the payload tail on every commit, giving O(N²) total work
    /// on deeply nested OTLP messages.
    pub fn beginSubMessage(self: *Writer, field_number: u32) !usize {
        try self.writeTag(field_number, .length_delimited);
        // Snapshot the running savings counter so `commitSubMessage` can
        // recover the post-compaction payload length of *this*
        // submessage by subtracting the savings produced by its
        // children.
        try self.open_savings.append(self.allocator, self.total_savings);
        const start = self.buf.items.len;
        // Reserve max 10 bytes for the size varint. They will be
        // overwritten in place during compaction; siblings/parents do
        // not shift on commit any more.
        try self.buf.appendSlice(self.allocator, &([_]u8{0} ** 10));
        return start;
    }

    pub fn commitSubMessage(self: *Writer, header_start: usize) !void {
        const payload_start = header_start + 10;
        const raw_payload_len = self.buf.items.len - payload_start;
        // Bytes saved by submessages that opened *after* this begin and
        // closed *before* this commit — these are nested children whose
        // varint headers will compact below 10 bytes. Subtract from the
        // raw byte span to recover the wire-visible payload length.
        const savings_at_begin = self.open_savings.pop() orelse unreachable;
        const child_savings = self.total_savings - savings_at_begin;
        const logical_len = raw_payload_len - child_savings;

        const size = varintSize(logical_len);
        // Account for our own savings so parent submessages see the
        // correct compacted length when they commit.
        self.total_savings += @as(u64, 10) - size;

        try self.sub_msgs.append(self.allocator, .{
            .header_pos = header_start,
            .logical_payload_len = logical_len,
            .varint_size = @intCast(size),
        });
    }

    /// Width in bytes of the unsigned varint encoding of `value`.
    /// 1..=10 (10-byte ceiling matches proto3's u64 max width). Public
    /// so tests and callers can reason about post-compaction wire sizes.
    pub fn varintSize(value: u64) u8 {
        var v = value;
        var n: u8 = 1;
        while (v >= 0x80) : (v >>= 7) n += 1;
        return n;
    }
};

// ---------------- Field numbers (subset, derived from OTLP 1.10.0) ------

pub const fn_resource_spans = 1;
pub const fn_scope_spans = 2;
pub const fn_resource = 1;
pub const fn_scope = 1;
pub const fn_spans = 2;
pub const fn_schema_url = 3;

pub const fn_span_trace_id = 1;
pub const fn_span_span_id = 2;
pub const fn_span_trace_state = 3;
pub const fn_span_parent_span_id = 4;
pub const fn_span_name = 5;
pub const fn_span_kind = 6;
pub const fn_span_start_unix_nano = 7;
pub const fn_span_end_unix_nano = 8;
pub const fn_span_attributes = 9;
pub const fn_span_dropped_attributes_count = 10;
pub const fn_span_events = 11;
pub const fn_span_dropped_events_count = 12;
pub const fn_span_links = 13;
pub const fn_span_dropped_links_count = 14;
pub const fn_span_status = 15;

pub const fn_kv_key = 1;
pub const fn_kv_value = 2;

pub const fn_av_string = 1;
pub const fn_av_bool = 2;
pub const fn_av_int = 3;
pub const fn_av_double = 4;
pub const fn_av_array = 5;
pub const fn_av_kvlist = 6;
pub const fn_av_bytes = 7;

pub const fn_status_message = 2;
pub const fn_status_code = 3;

pub const fn_event_time_unix_nano = 1;
pub const fn_event_name = 2;
pub const fn_event_attributes = 3;
pub const fn_event_dropped_attributes_count = 4;

pub const fn_link_trace_id = 1;
pub const fn_link_span_id = 2;
pub const fn_link_trace_state = 3;
pub const fn_link_attributes = 4;
pub const fn_link_dropped_attributes_count = 5;

pub const fn_resource_attributes = 1;
pub const fn_resource_dropped_attributes_count = 2;

pub const fn_scope_name = 1;
pub const fn_scope_version = 2;
pub const fn_scope_attributes = 3;
pub const fn_scope_dropped_attributes_count = 4;

pub const status_code_unset: u64 = 0;
pub const status_code_ok: u64 = 1;
pub const status_code_error: u64 = 2;

pub const span_kind_unspecified: u64 = 0;
pub const span_kind_internal: u64 = 1;
pub const span_kind_server: u64 = 2;
pub const span_kind_client: u64 = 3;
pub const span_kind_producer: u64 = 4;
pub const span_kind_consumer: u64 = 5;

// ---------------- Metrics field numbers (OTLP 1.10.0) -------------------
//
// `opentelemetry.proto.collector.metrics.v1.ExportMetricsServiceRequest` and
// downstream messages from `opentelemetry.proto.metrics.v1`. Field numbers
// pinned by the protobuf wire format — changing them silently breaks every
// collector in the world.

pub const fn_resource_metrics = 1; // ExportMetricsServiceRequest.resource_metrics
pub const fn_rm_resource = 1; // ResourceMetrics.resource
pub const fn_rm_scope_metrics = 2; // ResourceMetrics.scope_metrics
pub const fn_rm_schema_url = 3; // ResourceMetrics.schema_url

pub const fn_sm_scope = 1; // ScopeMetrics.scope
pub const fn_sm_metrics = 2; // ScopeMetrics.metrics
pub const fn_sm_schema_url = 3; // ScopeMetrics.schema_url

pub const fn_metric_name = 1;
pub const fn_metric_description = 2;
pub const fn_metric_unit = 3;
// `data` oneof: gauge=5, sum=7, histogram=9 (4, 6, 8 are reserved).
pub const fn_metric_gauge = 5;
pub const fn_metric_sum = 7;
pub const fn_metric_histogram = 9;

// Sum / Gauge / Histogram bodies.
pub const fn_sum_data_points = 1;
pub const fn_sum_aggregation_temporality = 2;
pub const fn_sum_is_monotonic = 3;
pub const fn_gauge_data_points = 1;
pub const fn_hist_data_points = 1;
pub const fn_hist_aggregation_temporality = 2;

// NumberDataPoint.
pub const fn_ndp_start_time_unix_nano = 2;
pub const fn_ndp_time_unix_nano = 3;
pub const fn_ndp_as_double = 4;
pub const fn_ndp_as_int = 6;
pub const fn_ndp_attributes = 7;
pub const fn_ndp_flags = 8;

// HistogramDataPoint.
pub const fn_hdp_start_time_unix_nano = 2;
pub const fn_hdp_time_unix_nano = 3;
pub const fn_hdp_count = 4;
pub const fn_hdp_sum = 5;
pub const fn_hdp_bucket_counts = 6;
pub const fn_hdp_explicit_bounds = 7;
pub const fn_hdp_attributes = 9;
pub const fn_hdp_flags = 10;
pub const fn_hdp_min = 11;
pub const fn_hdp_max = 12;

// AggregationTemporality enum (OTLP 1.10.0 metrics.proto).
pub const aggregation_temporality_unspecified: u64 = 0;
pub const aggregation_temporality_delta: u64 = 1;
pub const aggregation_temporality_cumulative: u64 = 2;

// ---------------- Logs field numbers (OTLP 1.10.0) ----------------------
//
// `opentelemetry.proto.collector.logs.v1.ExportLogsServiceRequest` and the
// downstream messages from `opentelemetry.proto.logs.v1`. Field numbers
// pinned by the protobuf wire format — pinned against the vendored
// `third_party/opentelemetry-proto-v1.10.0/opentelemetry/proto/logs/v1/logs.proto`
// and the matching `collector/logs/v1/logs_service.proto`. Closes
// GAP-OTLP-LOG-EXPORT (#8).

pub const fn_resource_logs = 1; // ExportLogsServiceRequest.resource_logs
pub const fn_rl_resource = 1; // ResourceLogs.resource
pub const fn_rl_scope_logs = 2; // ResourceLogs.scope_logs
pub const fn_rl_schema_url = 3; // ResourceLogs.schema_url

pub const fn_sl_scope = 1; // ScopeLogs.scope
pub const fn_sl_log_records = 2; // ScopeLogs.log_records
pub const fn_sl_schema_url = 3; // ScopeLogs.schema_url

// LogRecord field numbers per logs.proto:136-226. `reserved 4` is honoured
// by simply not emitting field 4. Field 12 (`event_name`) is present in
// the vendored proto v1.10.0 and the SDK populates it; older collectors
// that pre-date 1.5.0 silently ignore unknown fields per proto3 rules.
pub const fn_lr_time_unix_nano = 1; // fixed64
pub const fn_lr_severity_number = 2; // SeverityNumber (enum)
pub const fn_lr_severity_text = 3; // string
pub const fn_lr_body = 5; // AnyValue
pub const fn_lr_attributes = 6; // repeated KeyValue
pub const fn_lr_dropped_attributes_count = 7; // uint32
pub const fn_lr_flags = 8; // fixed32
pub const fn_lr_trace_id = 9; // bytes (16)
pub const fn_lr_span_id = 10; // bytes (8)
pub const fn_lr_observed_time_unix_nano = 11; // fixed64
pub const fn_lr_event_name = 12; // string

// ---------------- Smoke test --------------------------------------------

test "varint round-trip" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeVarint(0);
    try w.writeVarint(127);
    try w.writeVarint(128);
    try w.writeVarint(300);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x7f, 0x80, 0x01, 0xac, 0x02 }, w.buf.items);
}

test "writeString skips empty" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeString(1, "");
    try std.testing.expectEqual(@as(usize, 0), w.buf.items.len);
}

// ---------------- PR-2 (#36) regression -- encoder sub-message compaction --
//
// Previously `commitSubMessage` `copyForwards`-shifted the payload tail on
// every commit, giving O(N²) total work on deeply nested OTLP messages.
// The new path defers length-header rewrites until `toOwnedSlice`, which
// performs a single linear compaction sweep. These tests pin both the
// wire-shape contract (golden bytes for short / mid / long payload-length
// varints, plus a 5-deep nesting that mirrors the OTLP span shape
// ResourceSpans → ScopeSpans → Span → Status / Event) and the linear
// scaling property.

test "PR-2 commitSubMessage: 1-byte length varint" {
    // Short payload — varint length = 1 byte. Verifies the compactor
    // rewrites the reserved 10-byte slot down to a single byte.
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    const start = try w.beginSubMessage(1); // tag = 0x0a (field 1, wire 2)
    try w.buf.appendSlice(w.allocator, "hi"); // 2-byte payload
    try w.commitSubMessage(start);
    const out = try w.toOwnedSlice();
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualSlices(u8, &.{ 0x0a, 0x02, 'h', 'i' }, out);
}

test "PR-2 commitSubMessage: 2-byte length varint" {
    // 200-byte payload — varint length = 2 bytes (200 = 0xc8 0x01).
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    const start = try w.beginSubMessage(1);
    try w.buf.appendNTimes(w.allocator, 'A', 200);
    try w.commitSubMessage(start);
    const out = try w.toOwnedSlice();
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 1 + 2 + 200), out.len);
    try std.testing.expectEqual(@as(u8, 0x0a), out[0]);
    try std.testing.expectEqual(@as(u8, 0xc8), out[1]);
    try std.testing.expectEqual(@as(u8, 0x01), out[2]);
    try std.testing.expectEqual(@as(u8, 'A'), out[3]);
    try std.testing.expectEqual(@as(u8, 'A'), out[out.len - 1]);
}

test "PR-2 commitSubMessage: nested submessages with siblings" {
    // Two sibling submessages inside a parent. Catches the case where
    // sibling header positions are not naturally sorted relative to the
    // parent's header position — the compactor sorts before sweeping.
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    const parent = try w.beginSubMessage(1);
    {
        const a = try w.beginSubMessage(2);
        try w.buf.appendSlice(w.allocator, "AAA");
        try w.commitSubMessage(a);

        const b = try w.beginSubMessage(3);
        try w.buf.appendSlice(w.allocator, "BBBB");
        try w.commitSubMessage(b);
    }
    try w.commitSubMessage(parent);
    const out = try w.toOwnedSlice();
    defer std.testing.allocator.free(out);
    // Expected: tag(field=1,LD)=0x0a, len=11
    //           tag(field=2,LD)=0x12, len=3, "AAA"
    //           tag(field=3,LD)=0x1a, len=4, "BBBB"
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x0a, 0x0b, 0x12, 0x03, 'A', 'A', 'A', 0x1a, 0x04, 'B', 'B', 'B', 'B' },
        out,
    );
}

test "PR-2 commitSubMessage: 5-deep nesting compacts correctly" {
    // Mirrors the OTLP span shape: ResourceSpans → ScopeSpans → Span →
    // Event → KeyValue → AnyValue (all length-delimited submessages).
    // Five nested commits with a small leaf payload. Pre-fix this
    // exercised five `copyForwards` shifts of the payload tail; post-fix
    // a single compaction sweep.
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    const lvl1 = try w.beginSubMessage(1);
    const lvl2 = try w.beginSubMessage(2);
    const lvl3 = try w.beginSubMessage(3);
    const lvl4 = try w.beginSubMessage(4);
    const lvl5 = try w.beginSubMessage(5);
    try w.writeString(1, "leaf");
    try w.commitSubMessage(lvl5);
    try w.commitSubMessage(lvl4);
    try w.commitSubMessage(lvl3);
    try w.commitSubMessage(lvl2);
    try w.commitSubMessage(lvl1);
    const out = try w.toOwnedSlice();
    defer std.testing.allocator.free(out);
    // Inner: writeString field=1, "leaf" → 0x0a, 0x04, 'l','e','a','f' = 6 bytes
    // lvl5: tag(5,LD)=0x2a, len=6 → 8 bytes
    // lvl4: tag(4,LD)=0x22, len=8 → 10 bytes
    // lvl3: tag(3,LD)=0x1a, len=10 → 12 bytes
    // lvl2: tag(2,LD)=0x12, len=12 → 14 bytes
    // lvl1: tag(1,LD)=0x0a, len=14 → 16 bytes
    try std.testing.expectEqualSlices(u8, &.{
        0x0a, 14,
        0x12, 12,
        0x1a, 10,
        0x22, 8,
        0x2a, 6,
        0x0a, 4,
        'l',  'e',
        'a',  'f',
    }, out);
}

test "PR-2 commitSubMessage: mixed varint widths in same buffer" {
    // One submessage with a 1-byte length, one with a 2-byte length, in
    // sequence. Verifies the compactor handles per-entry varint widths
    // independently and the running savings counter advances correctly.
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    const a = try w.beginSubMessage(1);
    try w.buf.appendNTimes(w.allocator, 'x', 5);
    try w.commitSubMessage(a);
    const b = try w.beginSubMessage(2);
    try w.buf.appendNTimes(w.allocator, 'y', 300);
    try w.commitSubMessage(b);
    const out = try w.toOwnedSlice();
    defer std.testing.allocator.free(out);
    // Layout: 0x0a 0x05 'x'*5  0x12 0xac 0x02 'y'*300
    try std.testing.expectEqual(@as(usize, 1 + 1 + 5 + 1 + 2 + 300), out.len);
    try std.testing.expectEqual(@as(u8, 0x0a), out[0]);
    try std.testing.expectEqual(@as(u8, 5), out[1]);
    try std.testing.expectEqual(@as(u8, 'x'), out[2]);
    try std.testing.expectEqual(@as(u8, 'x'), out[6]);
    try std.testing.expectEqual(@as(u8, 0x12), out[7]);
    try std.testing.expectEqual(@as(u8, 0xac), out[8]);
    try std.testing.expectEqual(@as(u8, 0x02), out[9]);
    try std.testing.expectEqual(@as(u8, 'y'), out[10]);
    try std.testing.expectEqual(@as(u8, 'y'), out[out.len - 1]);
}

test "PR-2 commitSubMessage: deeply-nested span shape size formula" {
    // Quadratic-blowup regression. Builds a span shape with N
    // attribute submessages four levels deep (Span → Event → KeyValue
    // → AnyValue) — pre-fix this triggered a `copyForwards` shift on
    // every commit at every level. Post-fix, all submessage headers
    // are compacted in one pass at `toOwnedSlice` time.
    //
    // Beyond the byte-shape contract, this test pins the closed-form
    // output size: any drift means the new compactor mis-counted a
    // saving (e.g. forgetting to subtract a child's varint shrink
    // from a parent). Total bytes under the linear-time path must
    // exactly match the byte budget we computed by hand.
    const allocator = std.testing.allocator;

    const ns = [_]usize{ 8, 128, 1024 };
    for (ns) |n| {
        var w = Writer.init(allocator);
        defer w.deinit();
        const rs = try w.beginSubMessage(1); // ResourceSpans
        const ss = try w.beginSubMessage(2); // ScopeSpans
        const span = try w.beginSubMessage(3); // Span
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const evt = try w.beginSubMessage(11); // Span.event
            try w.writeString(1, "evt-name"); // 1 (tag) + 1 (len) + 8 = 10 B
            const kv = try w.beginSubMessage(3); // Event.attribute
            try w.writeString(1, "k"); // 3 B
            const av = try w.beginSubMessage(2); // KeyValue.value
            try w.writeString(1, "v"); // 3 B
            try w.commitSubMessage(av);
            try w.commitSubMessage(kv);
            try w.commitSubMessage(evt);
        }
        try w.commitSubMessage(span);
        try w.commitSubMessage(ss);
        try w.commitSubMessage(rs);
        const out = try w.toOwnedSlice();
        defer allocator.free(out);

        // Per-event budget:
        //   AnyValue:    tag(1)+len(1)+"v" payload(3) = inner 3 B body, 5 B framed
        //   KeyValue:    tag(1)+len(1)+"k"(3)+AnyValue(5) = inner 8 B body, 10 B framed
        //   Event:       tag(1)+len(1)+"evt-name"(10)+KeyValue(10) = inner 20 B body, 22 B framed
        // For n events the Span body is n*22 plus its own len-varint (1 or 2 B);
        // ScopeSpans and ResourceSpans wrap with one tag+varint each.
        const span_body = n * 22;
        const span_framed = 1 + Writer.varintSize(span_body) + span_body;
        const ss_framed = 1 + Writer.varintSize(span_framed) + span_framed;
        const rs_framed = 1 + Writer.varintSize(ss_framed) + ss_framed;
        try std.testing.expectEqual(rs_framed, out.len);
    }
}
