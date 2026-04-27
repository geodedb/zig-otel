// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// W3C Trace Context propagator (https://www.w3.org/TR/trace-context/).
//
// `traceparent` shape:  version-trace_id-parent_id-flags
//                       00-{32-hex}-{16-hex}-{2-hex}
//
// `tracestate` is preserved verbatim across the wire when present and
// only validated for length/character safety. We never mutate or reorder it.
//
// Errors surface as named errors so callers can map them to log levels
// or HTTP status codes deterministically.

const std = @import("std");
const id = @import("../internal/id.zig");
const ctx_mod = @import("../api/context.zig");

pub const max_tracestate_len: usize = 512;
pub const max_tracestate_members: usize = 32;
pub const traceparent_header: []const u8 = "traceparent";
pub const tracestate_header: []const u8 = "tracestate";

/// Carrier abstraction over the wire-level header / metadata map.
///
/// `getFn` / `setFn` are required. `iterFn` is optional — propagators
/// that need to scan all entries (e.g. Jaeger's `uberctx-*` baggage)
/// fall back gracefully when it's null. The iterator semantics:
/// - The visitor is called once per key/value pair currently in the
///   carrier; ordering is not specified.
/// - The visitor MUST NOT mutate the carrier during iteration.
pub const Carrier = struct {
    ctx: ?*anyopaque,
    getFn: *const fn (?*anyopaque, []const u8) ?[]const u8,
    setFn: *const fn (?*anyopaque, []const u8, []const u8) anyerror!void,
    iterFn: ?*const fn (?*anyopaque, *const fn (?*anyopaque, []const u8, []const u8) anyerror!void, ?*anyopaque) anyerror!void = null,

    pub fn get(self: Carrier, key: []const u8) ?[]const u8 {
        return self.getFn(self.ctx, key);
    }

    pub fn set(self: Carrier, key: []const u8, value: []const u8) !void {
        try self.setFn(self.ctx, key, value);
    }

    /// Walk every key/value pair currently in the carrier. The visitor
    /// callback receives a borrowed `visitor_ctx` plus the key and
    /// value slices (also borrowed; lifetime tied to the carrier).
    /// Returns `error.IterationUnsupported` when the carrier doesn't
    /// implement `iterFn`.
    pub fn iter(
        self: Carrier,
        visitor: *const fn (?*anyopaque, []const u8, []const u8) anyerror!void,
        visitor_ctx: ?*anyopaque,
    ) !void {
        const f = self.iterFn orelse return error.IterationUnsupported;
        try f(self.ctx, visitor, visitor_ctx);
    }
};

/// Map-backed Carrier — owned by the caller; lifetime independent of
/// the propagator. Useful for tests and HTTP shim integrations that
/// already hand out a hash map.
pub const MapCarrier = struct {
    map: *std.StringHashMap([]const u8),

    pub fn carrier(self: *MapCarrier) Carrier {
        return .{ .ctx = self, .getFn = mapGet, .setFn = mapSet, .iterFn = mapIter };
    }
};

fn mapGet(ctx: ?*anyopaque, key: []const u8) ?[]const u8 {
    const self: *MapCarrier = @ptrCast(@alignCast(ctx.?));
    return self.map.get(key);
}

fn mapSet(ctx: ?*anyopaque, key: []const u8, value: []const u8) anyerror!void {
    const self: *MapCarrier = @ptrCast(@alignCast(ctx.?));
    try self.map.put(key, value);
}

fn mapIter(
    ctx: ?*anyopaque,
    visitor: *const fn (?*anyopaque, []const u8, []const u8) anyerror!void,
    visitor_ctx: ?*anyopaque,
) anyerror!void {
    const self: *MapCarrier = @ptrCast(@alignCast(ctx.?));
    var it = self.map.iterator();
    while (it.next()) |entry| {
        try visitor(visitor_ctx, entry.key_ptr.*, entry.value_ptr.*);
    }
}

/// Inject the active SpanContext into `carrier`. No-op if the span
/// context is not valid. The string written is allocated through
/// `arena` and lives until the caller frees the arena.
pub fn inject(arena: std.mem.Allocator, carrier: Carrier, sc: ctx_mod.SpanContext) !void {
    if (!sc.isValid()) return;

    var traceparent_buf: [55]u8 = undefined;
    var tid_hex: [32]u8 = undefined;
    sc.trace_id.writeHex(&tid_hex);
    var sid_hex: [16]u8 = undefined;
    sc.span_id.writeHex(&sid_hex);
    var flag_hex: [2]u8 = undefined;
    bytePairToHex(sc.flags.toByte(), &flag_hex);
    const tp_text = try std.fmt.bufPrint(traceparent_buf[0..], "00-{s}-{s}-{s}", .{ tid_hex[0..], sid_hex[0..], flag_hex[0..] });
    const tp = try arena.dupe(u8, tp_text);
    try carrier.set(traceparent_header, tp);

    if (sc.trace_state) |ts| {
        if (ts.len > 0) {
            const owned = try arena.dupe(u8, ts);
            try carrier.set(tracestate_header, owned);
        }
    }
}

/// Extract a SpanContext from `carrier`. Returns `null` (no propagation
/// info) when `traceparent` is missing. Returns a typed error on a
/// malformed header, per spec — the caller decides whether to log/drop.
pub fn extract(arena: std.mem.Allocator, carrier: Carrier) !?ctx_mod.SpanContext {
    const tp_value = carrier.get(traceparent_header) orelse return null;
    const sc = try parseTraceparent(tp_value);
    var out: ctx_mod.SpanContext = sc;
    out.is_remote = true;

    if (carrier.get(tracestate_header)) |ts_raw| {
        const owned = try validateAndCopyTraceState(arena, ts_raw);
        out.trace_state = owned;
    }
    return out;
}

pub fn parseTraceparent(value: []const u8) !ctx_mod.SpanContext {
    // Strict total length 55: "00-<32>-<16>-<2>"
    if (value.len < 55) return error.InvalidTraceParent;
    // Per spec, allow trailing OWS but treat anything past 55 chars in v00 as an error.
    if (value.len > 55) return error.InvalidTraceParent;
    if (value[2] != '-' or value[35] != '-' or value[52] != '-') return error.InvalidTraceParent;

    const version_text = value[0..2];
    if (!isLowerHex(version_text)) {
        // Spec: error.InvalidTraceParent: version must be 2 lowercase hex characters
        return error.InvalidTraceParent;
    }
    const version = parseHexByte(version_text) catch return error.InvalidTraceParent;
    if (version == 0xff) return error.InvalidTraceParent;

    const trace_id_text = value[3..35];
    if (!isLowerHex(trace_id_text)) return error.InvalidTraceParent;
    const tid = id.TraceId.parseHex(trace_id_text) catch return error.InvalidTraceParent;
    if (!tid.isValid()) return error.InvalidTraceParent;

    const span_id_text = value[36..52];
    if (!isLowerHex(span_id_text)) return error.InvalidTraceParent;
    const sid = id.SpanId.parseHex(span_id_text) catch return error.InvalidTraceParent;
    if (!sid.isValid()) return error.InvalidTraceParent;

    const flags_text = value[53..55];
    if (!isLowerHex(flags_text)) return error.InvalidTraceParent;
    const flags_byte = parseHexByte(flags_text) catch return error.InvalidTraceParent;

    return .{
        .trace_id = tid,
        .span_id = sid,
        .flags = id.TraceFlags.fromByte(flags_byte),
        .is_remote = true,
    };
}

fn validateAndCopyTraceState(arena: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (raw.len > max_tracestate_len) return error.InvalidTraceState;
    var member_count: usize = 0;
    var iter = std.mem.splitScalar(u8, raw, ',');
    while (iter.next()) |member_raw| {
        const member = std.mem.trim(u8, member_raw, " \t");
        if (member.len == 0) continue;
        member_count += 1;
        if (member_count > max_tracestate_members) return error.InvalidTraceState;
        const eq = std.mem.indexOfScalar(u8, member, '=') orelse return error.InvalidTraceState;
        const key = member[0..eq];
        const value = member[eq + 1 ..];
        if (!isValidTraceStateKey(key)) return error.InvalidTraceState;
        if (!isValidTraceStateValue(value)) return error.InvalidTraceState;
    }
    return try arena.dupe(u8, raw);
}

fn isLowerHex(text: []const u8) bool {
    for (text) |c| {
        switch (c) {
            '0'...'9', 'a'...'f' => {},
            else => return false,
        }
    }
    return true;
}

fn parseHexByte(text: []const u8) !u8 {
    std.debug.assert(text.len == 2);
    const hi = nibble(text[0]) catch return error.InvalidHex;
    const lo = nibble(text[1]) catch return error.InvalidHex;
    return (hi << 4) | lo;
}

fn nibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        else => error.InvalidHex,
    };
}

fn bytePairToHex(b: u8, out: *[2]u8) void {
    const alphabet = "0123456789abcdef";
    out[0] = alphabet[(b >> 4) & 0x0f];
    out[1] = alphabet[b & 0x0f];
}

fn isValidTraceStateKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 256) return false;
    var first = true;
    for (key) |c| {
        const ok = switch (c) {
            'a'...'z', '0'...'9' => true,
            '_', '-', '*', '/' => !first,
            '@' => !first,
            else => false,
        };
        if (!ok) return false;
        first = false;
    }
    return true;
}

fn isValidTraceStateValue(value: []const u8) bool {
    if (value.len == 0 or value.len > 256) return false;
    for (value) |c| {
        if (c < 0x20 or c == 0x7f or c == ',' or c == '=') return false;
    }
    return true;
}

test "parseTraceparent rejects too-short input" {
    try std.testing.expectError(error.InvalidTraceParent, parseTraceparent("00-1234"));
}

test "parseTraceparent rejects upper-case hex in version" {
    try std.testing.expectError(error.InvalidTraceParent, parseTraceparent("0F-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"));
}

test "parseTraceparent rejects ff version" {
    try std.testing.expectError(error.InvalidTraceParent, parseTraceparent("ff-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01"));
}

test "parseTraceparent rejects all-zero trace id" {
    try std.testing.expectError(error.InvalidTraceParent, parseTraceparent("00-00000000000000000000000000000000-00f067aa0ba902b7-01"));
}

test "parseTraceparent accepts the spec example" {
    const sc = try parseTraceparent("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
    try std.testing.expect(sc.flags.sampled);
    try std.testing.expect(sc.is_remote);
    var hex: [32]u8 = undefined;
    sc.trace_id.writeHex(&hex);
    try std.testing.expectEqualStrings("4bf92f3577b34da6a3ce929d0e0e4736", hex[0..]);
}

test "inject writes traceparent into carrier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: MapCarrier = .{ .map = &map };
    const sc: ctx_mod.SpanContext = .{
        .trace_id = .{ .bytes = .{ 0x4b, 0xf9, 0x2f, 0x35, 0x77, 0xb3, 0x4d, 0xa6, 0xa3, 0xce, 0x92, 0x9d, 0x0e, 0x0e, 0x47, 0x36 } },
        .span_id = .{ .bytes = .{ 0x00, 0xf0, 0x67, 0xaa, 0x0b, 0xa9, 0x02, 0xb7 } },
        .flags = .{ .sampled = true },
    };
    try inject(arena.allocator(), mc.carrier(), sc);
    const tp = map.get(traceparent_header).?;
    try std.testing.expectEqualStrings("00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01", tp);
}

test "extract returns null when traceparent missing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    var mc: MapCarrier = .{ .map = &map };
    const got = try extract(arena.allocator(), mc.carrier());
    try std.testing.expect(got == null);
}

test "extract preserves tracestate verbatim" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put(traceparent_header, "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
    try map.put(tracestate_header, "rojo=00f067aa0ba902b7,congo=t61rcWkgMzE");
    var mc: MapCarrier = .{ .map = &map };
    const sc = (try extract(arena.allocator(), mc.carrier())).?;
    try std.testing.expectEqualStrings("rojo=00f067aa0ba902b7,congo=t61rcWkgMzE", sc.trace_state.?);
}

test "extract rejects malformed tracestate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var map: std.StringHashMap([]const u8) = .init(std.testing.allocator);
    defer map.deinit();
    try map.put(traceparent_header, "00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01");
    try map.put(tracestate_header, "BAD KEY=oops");
    var mc: MapCarrier = .{ .map = &map };
    try std.testing.expectError(error.InvalidTraceState, extract(arena.allocator(), mc.carrier()));
}
