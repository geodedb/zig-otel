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

    pub fn init(allocator: std.mem.Allocator) Writer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Writer) void {
        self.buf.deinit(self.allocator);
    }

    pub fn toOwnedSlice(self: *Writer) ![]u8 {
        return try self.buf.toOwnedSlice(self.allocator);
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

    /// Begin a length-delimited submessage. The caller writes fields, then
    /// commits via `commitSubMessage` with the start length returned here.
    pub fn beginSubMessage(self: *Writer, field_number: u32) !usize {
        try self.writeTag(field_number, .length_delimited);
        // Reserve max 10 bytes for the size varint; we'll patch when committing.
        const start = self.buf.items.len;
        try self.buf.appendSlice(self.allocator, &([_]u8{0} ** 10));
        return start;
    }

    pub fn commitSubMessage(self: *Writer, header_start: usize) !void {
        const payload_start = header_start + 10;
        const payload_len = self.buf.items.len - payload_start;
        // Encode the size varint at `header_start`.
        var size_buf: [10]u8 = undefined;
        var v = @as(u64, @intCast(payload_len));
        var i: usize = 0;
        while (v >= 0x80) : (v >>= 7) {
            size_buf[i] = @as(u8, @intCast(v & 0x7f)) | 0x80;
            i += 1;
        }
        size_buf[i] = @as(u8, @intCast(v));
        const size_len = i + 1;
        // Shift the payload back so the size is contiguous.
        @memcpy(self.buf.items[header_start .. header_start + size_len], size_buf[0..size_len]);
        if (size_len < 10) {
            std.mem.copyForwards(u8, self.buf.items[header_start + size_len .. header_start + size_len + payload_len], self.buf.items[payload_start..]);
            self.buf.shrinkRetainingCapacity(self.buf.items.len - (10 - size_len));
        }
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
