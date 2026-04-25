// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// W3C-compatible TraceId (16 bytes) and SpanId (8 bytes), plus a pluggable
// IdGenerator with deterministic and random implementations. The SDK never
// pulls randomness directly so tests get reproducible IDs.

const std = @import("std");

pub const trace_id_bytes: usize = 16;
pub const span_id_bytes: usize = 8;

pub const TraceId = struct {
    bytes: [trace_id_bytes]u8,

    pub const invalid: TraceId = .{ .bytes = .{0} ** trace_id_bytes };

    pub fn isValid(self: TraceId) bool {
        for (self.bytes) |b| if (b != 0) return true;
        return false;
    }

    /// 32-char lowercase hex.
    pub fn writeHex(self: TraceId, out: *[32]u8) void {
        bytesToHex(self.bytes[0..], out);
    }

    pub fn toHex(self: TraceId) [32]u8 {
        var out: [32]u8 = undefined;
        self.writeHex(&out);
        return out;
    }

    pub fn parseHex(text: []const u8) !TraceId {
        if (text.len != 32) return error.InvalidTraceIdLength;
        var t: TraceId = .invalid;
        try hexToBytes(text, t.bytes[0..]);
        return t;
    }
};

pub const SpanId = struct {
    bytes: [span_id_bytes]u8,

    pub const invalid: SpanId = .{ .bytes = .{0} ** span_id_bytes };

    pub fn isValid(self: SpanId) bool {
        for (self.bytes) |b| if (b != 0) return true;
        return false;
    }

    pub fn writeHex(self: SpanId, out: *[16]u8) void {
        bytesToHex(self.bytes[0..], out);
    }

    pub fn toHex(self: SpanId) [16]u8 {
        var out: [16]u8 = undefined;
        self.writeHex(&out);
        return out;
    }

    pub fn parseHex(text: []const u8) !SpanId {
        if (text.len != 16) return error.InvalidSpanIdLength;
        var s: SpanId = .invalid;
        try hexToBytes(text, s.bytes[0..]);
        return s;
    }
};

pub const TraceFlags = packed struct(u8) {
    sampled: bool = false,
    _reserved: u7 = 0,

    pub fn toByte(self: TraceFlags) u8 {
        return @bitCast(self);
    }

    pub fn fromByte(b: u8) TraceFlags {
        return @bitCast(b);
    }
};

const hex_alphabet = "0123456789abcdef";

fn bytesToHex(in: []const u8, out: []u8) void {
    std.debug.assert(out.len >= in.len * 2);
    for (in, 0..) |b, i| {
        out[i * 2] = hex_alphabet[(b >> 4) & 0x0f];
        out[i * 2 + 1] = hex_alphabet[b & 0x0f];
    }
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => error.InvalidHex,
    };
}

fn hexToBytes(text: []const u8, out: []u8) !void {
    if (text.len != out.len * 2) return error.InvalidHex;
    var i: usize = 0;
    while (i < out.len) : (i += 1) {
        const hi = try hexNibble(text[i * 2]);
        const lo = try hexNibble(text[i * 2 + 1]);
        out[i] = (hi << 4) | lo;
    }
}

/// Pluggable ID generator. The SDK passes one to TracerProvider.init.
pub const IdGenerator = struct {
    ctx: ?*anyopaque,
    nextTraceIdFn: *const fn (?*anyopaque) TraceId,
    nextSpanIdFn: *const fn (?*anyopaque) SpanId,

    pub fn nextTraceId(self: IdGenerator) TraceId {
        return self.nextTraceIdFn(self.ctx);
    }

    pub fn nextSpanId(self: IdGenerator) SpanId {
        return self.nextSpanIdFn(self.ctx);
    }
};

/// Backed by `std.Random.DefaultPrng` for cheap, non-crypto IDs. Callers who
/// need crypto-quality randomness should plug in their own generator.
pub const Random = struct {
    prng: std.Random.DefaultPrng,

    pub fn init(seed: u64) Random {
        return .{ .prng = std.Random.DefaultPrng.init(seed) };
    }

    pub fn generator(self: *Random) IdGenerator {
        return .{ .ctx = self, .nextTraceIdFn = randomTraceId, .nextSpanIdFn = randomSpanId };
    }
};

fn randomTraceId(ctx: ?*anyopaque) TraceId {
    const self: *Random = @ptrCast(@alignCast(ctx.?));
    var t: TraceId = undefined;
    while (true) {
        self.prng.random().bytes(&t.bytes);
        if (t.isValid()) return t;
    }
}

fn randomSpanId(ctx: ?*anyopaque) SpanId {
    const self: *Random = @ptrCast(@alignCast(ctx.?));
    var s: SpanId = undefined;
    while (true) {
        self.prng.random().bytes(&s.bytes);
        if (s.isValid()) return s;
    }
}

/// Returns a fixed sequence of pre-canned IDs. Useful for golden tests.
pub const Sequence = struct {
    trace_ids: []const TraceId,
    span_ids: []const SpanId,
    trace_idx: usize = 0,
    span_idx: usize = 0,

    pub fn init(trace_ids: []const TraceId, span_ids: []const SpanId) Sequence {
        return .{ .trace_ids = trace_ids, .span_ids = span_ids };
    }

    pub fn generator(self: *Sequence) IdGenerator {
        return .{ .ctx = self, .nextTraceIdFn = sequenceTrace, .nextSpanIdFn = sequenceSpan };
    }
};

fn sequenceTrace(ctx: ?*anyopaque) TraceId {
    const self: *Sequence = @ptrCast(@alignCast(ctx.?));
    if (self.trace_ids.len == 0) return .invalid;
    const id = self.trace_ids[self.trace_idx % self.trace_ids.len];
    self.trace_idx +%= 1;
    return id;
}

fn sequenceSpan(ctx: ?*anyopaque) SpanId {
    const self: *Sequence = @ptrCast(@alignCast(ctx.?));
    if (self.span_ids.len == 0) return .invalid;
    const id = self.span_ids[self.span_idx % self.span_ids.len];
    self.span_idx +%= 1;
    return id;
}

test "trace id hex roundtrip" {
    const t: TraceId = .{ .bytes = .{ 0x4b, 0xf9, 0x2f, 0x35, 0x77, 0xb3, 0x4d, 0xa6, 0xa3, 0xce, 0x92, 0x9d, 0x0e, 0x0e, 0x47, 0x36 } };
    try std.testing.expect(t.isValid());
    const hex = t.toHex();
    try std.testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", hex[0..]);
    const round = try TraceId.parseHex(hex[0..]);
    try std.testing.expectEqualSlices(u8, t.bytes[0..], round.bytes[0..]);
}

test "span id hex roundtrip" {
    const s: SpanId = .{ .bytes = .{ 0x00, 0xf0, 0x67, 0xaa, 0x0b, 0xa9, 0x02, 0xb7 } };
    const hex = s.toHex();
    try std.testing.expectEqualStrings("00f067aa0ba902b7", hex[0..]);
    const round = try SpanId.parseHex(hex[0..]);
    try std.testing.expectEqualSlices(u8, s.bytes[0..], round.bytes[0..]);
}

test "invalid IDs are detected" {
    try std.testing.expect(!TraceId.invalid.isValid());
    try std.testing.expect(!SpanId.invalid.isValid());
}

test "trace flags pack to byte" {
    const sampled: TraceFlags = .{ .sampled = true };
    try std.testing.expectEqual(@as(u8, 0x01), sampled.toByte());
    try std.testing.expectEqual(@as(u8, 0x00), TraceFlags.fromByte(0x00).toByte());
}

test "sequence generator yields preset IDs" {
    var seq = Sequence.init(
        &.{TraceId{ .bytes = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } }},
        &.{SpanId{ .bytes = .{ 16, 17, 18, 19, 20, 21, 22, 23 } }},
    );
    const g = seq.generator();
    const t = g.nextTraceId();
    try std.testing.expectEqualSlices(u8, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 }, t.bytes[0..]);
    const s = g.nextSpanId();
    try std.testing.expectEqualSlices(u8, &.{ 16, 17, 18, 19, 20, 21, 22, 23 }, s.bytes[0..]);
}
