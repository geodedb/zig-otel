// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Jaeger propagator
// (https://www.jaegertracing.io/docs/1.45/client-libraries/#propagation-format).
//
// Two header families:
//
//   * `uber-trace-id: <trace-id>:<span-id>:<parent-span-id>:<flags>`
//     - trace-id: 16 or 32 lowercase hex chars (we accept both, emit 32).
//     - span-id : up to 16 hex chars (zero-padded on parse, emitted as
//                 16 chars on inject).
//     - parent  : up to 16 hex chars; OTel SpanContext doesn't track a
//                 parent-span-id so we emit `0` and accept-and-discard.
//     - flags   : hex-encoded byte; bit 0 = sampled, bit 1 = debug,
//                 bit 2 = firehose. The OpenTelemetry SpanContext only
//                 carries `flags.sampled`; debug collapses to sampled
//                 on extract; firehose is dropped (no field to store
//                 it, no use-site downstream).
//
//   * `uberctx-<key>: <urlencoded-value>` — per-entry baggage. Inject
//     emits one header per baggage entry; extract scans every header
//     starting with the `uberctx-` prefix and rebuilds a `Baggage`.
//     URL-encoding (RFC 3986 unreserved set) matches Jaeger's reference
//     client and the W3C-baggage code path in `src/propagation/baggage.zig`.

const std = @import("std");
const ctx_mod = @import("../api/context.zig");
const id = @import("../internal/id.zig");
const baggage_api = @import("../api/baggage.zig");
const propagator_mod = @import("propagator.zig");

pub const Carrier = propagator_mod.Carrier;
pub const Fields = propagator_mod.Fields;
pub const ExtractResult = propagator_mod.ExtractResult;
pub const TextMapPropagator = propagator_mod.TextMapPropagator;
pub const MapCarrier = propagator_mod.MapCarrier;

pub const uber_trace_id_header: []const u8 = "uber-trace-id";
pub const uberctx_prefix: []const u8 = "uberctx-";

/// Bit flags carried in the hex-encoded `flags` field of `uber-trace-id`.
pub const flag_sampled: u8 = 0x01;
pub const flag_debug: u8 = 0x02;
pub const flag_firehose: u8 = 0x08;

pub const propagator: TextMapPropagator = .{
    .inject_fn = jaegerInject,
    .extract_fn = jaegerExtract,
};

// ---------------------------------------------------------------- //
// Inject
// ---------------------------------------------------------------- //

fn jaegerInject(_: ?*anyopaque, arena: std.mem.Allocator, carrier: Carrier, fields: Fields) !void {
    if (fields.span_context) |sc| {
        if (sc.isValid()) try injectUberTraceId(arena, carrier, sc);
    }
    if (fields.baggage) |b| try injectUberctx(arena, carrier, b);
}

fn injectUberTraceId(arena: std.mem.Allocator, carrier: Carrier, sc: ctx_mod.SpanContext) !void {
    var tid_hex: [32]u8 = undefined;
    sc.trace_id.writeHex(&tid_hex);
    var sid_hex: [16]u8 = undefined;
    sc.span_id.writeHex(&sid_hex);
    // Per spec: parent-span-id `0` for OTel roots; flags hex-encoded
    // (lowercase, no leading zero — Jaeger reference clients emit `1`
    // not `01`). 32 + 1 + 16 + 1 + 1 + 1 + 2 = 54 max bytes (plus
    // future-proof tail for `0a`-style flag values).
    var buf: [56]u8 = undefined;
    var flag_buf: [2]u8 = undefined;
    const flag_byte: u8 = if (sc.flags.sampled) flag_sampled else 0;
    const flag_text = formatFlag(flag_byte, &flag_buf);
    const text = try std.fmt.bufPrint(buf[0..], "{s}:{s}:0:{s}", .{ tid_hex[0..], sid_hex[0..], flag_text });
    const owned = try arena.dupe(u8, text);
    try carrier.set(uber_trace_id_header, owned);
}

fn injectUberctx(arena: std.mem.Allocator, carrier: Carrier, b: *const baggage_api.Baggage) !void {
    if (b.count() == 0) return;
    for (b.iter()) |entry| {
        const header_name = try std.fmt.allocPrint(arena, "{s}{s}", .{ uberctx_prefix, entry.key });
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(arena);
        try percentEncode(arena, &encoded, entry.value);
        const owned_value = try arena.dupe(u8, encoded.items);
        try carrier.set(header_name, owned_value);
    }
}

// ---------------------------------------------------------------- //
// Extract
// ---------------------------------------------------------------- //

fn jaegerExtract(_: ?*anyopaque, allocator: std.mem.Allocator, _: std.mem.Allocator, carrier: Carrier) !ExtractResult {
    var out: ExtractResult = .{};
    errdefer out.deinit();

    if (carrier.get(uber_trace_id_header)) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        out.span_context = parseUberTraceId(trimmed) catch null;
    }

    // `uberctx-*` baggage extraction needs to scan every header — the
    // single-key `Carrier.get` API can't enumerate keys it doesn't
    // already know. We rely on the optional `Carrier.iter` extension
    // (added alongside this propagator); carriers that don't implement
    // iteration surface zero baggage entries, which is the same as
    // "no uberctx headers seen".
    out.baggage = extractUberctx(allocator, carrier) catch null;
    return out;
}

/// Parse `<trace-id>:<span-id>:<parent>:<flags>` into a SpanContext.
/// Trace-id can be 16 or 32 hex; span-id up to 16; parent-id up to 16
/// (accepted-and-discarded); flags is hex-encoded byte (1, 2, or 3
/// chars in the wild — we accept up to 2). Invalid input → caller
/// surfaces null per `jaegerExtract`'s catch.
fn parseUberTraceId(text: []const u8) !ctx_mod.SpanContext {
    var iter = std.mem.splitScalar(u8, text, ':');
    const tid_text = iter.next() orelse return error.InvalidJaegerHeader;
    const sid_text = iter.next() orelse return error.InvalidJaegerHeader;
    const parent_text = iter.next() orelse return error.InvalidJaegerHeader;
    const flags_text = iter.next() orelse return error.InvalidJaegerHeader;
    if (iter.next() != null) return error.InvalidJaegerHeader;

    const tid = try parseTraceIdFlexible(tid_text);
    const sid = try parseSpanIdFlexible(sid_text);
    // Parent-span-id is shape-validated and discarded.
    _ = try parseSpanIdFlexible(parent_text);
    const flag_byte = try parseFlag(flags_text);

    if (!tid.isValid() or !sid.isValid()) return error.InvalidJaegerHeader;

    var flags: id.TraceFlags = .{};
    if ((flag_byte & flag_sampled) != 0 or (flag_byte & flag_debug) != 0) {
        flags.sampled = true;
    }
    // flag_firehose has no OTel SpanContext slot; drop it.

    return .{
        .trace_id = tid,
        .span_id = sid,
        .flags = flags,
        .is_remote = true,
    };
}

const UberctxAccumulator = struct {
    allocator: std.mem.Allocator,
    bag: baggage_api.Baggage,
    saw_any: bool = false,
};

fn extractUberctx(allocator: std.mem.Allocator, carrier: Carrier) !?baggage_api.Baggage {
    var accum = UberctxAccumulator{
        .allocator = allocator,
        .bag = baggage_api.Baggage.init(allocator),
    };
    errdefer accum.bag.deinit();

    carrier.iter(uberctxVisitor, &accum) catch |err| switch (err) {
        // Carriers without iteration support surface no baggage —
        // production HTTP shims that need uberctx baggage MUST
        // implement `Carrier.iterFn` (the in-repo `MapCarrier` does).
        error.IterationUnsupported => {
            accum.bag.deinit();
            return null;
        },
        else => return err,
    };

    if (!accum.saw_any) {
        accum.bag.deinit();
        return null;
    }
    return accum.bag;
}

fn uberctxVisitor(visitor_ctx: ?*anyopaque, key: []const u8, value: []const u8) anyerror!void {
    const accum: *UberctxAccumulator = @ptrCast(@alignCast(visitor_ctx.?));
    if (!std.ascii.startsWithIgnoreCase(key, uberctx_prefix)) return;
    const baggage_key = key[uberctx_prefix.len..];
    if (baggage_key.len == 0) return;

    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(accum.allocator);
    percentDecode(accum.allocator, &decoded, value) catch return;
    // Skip silently on validation failures — bad baggage entries
    // mustn't poison sibling propagators.
    accum.bag.put(baggage_key, decoded.items, null) catch return;
    accum.saw_any = true;
}

// ---------------------------------------------------------------- //
// Helpers — flag formatting, hex parsing, percent-encoding.
// ---------------------------------------------------------------- //

fn formatFlag(b: u8, out: *[2]u8) []u8 {
    // Match Jaeger's reference encoding: `1`, `2`, `3`, … no leading
    // zero. The buffer is sized for the rare two-digit case (e.g.
    // `0a` if firehose ever lights up alongside debug+sampled).
    if (b < 0x10) {
        out[0] = nibbleHex(b);
        return out[0..1];
    }
    out[0] = nibbleHex(b >> 4);
    out[1] = nibbleHex(b & 0x0f);
    return out[0..2];
}

fn nibbleHex(n: u8) u8 {
    const alphabet = "0123456789abcdef";
    return alphabet[n & 0x0f];
}

fn parseFlag(text: []const u8) !u8 {
    // Accept `0`, `1`, `2`, `3`, `4`, … `ff`. Leading zeroes
    // permissible (Jaeger Java client emits `01` historically).
    if (text.len == 0 or text.len > 2) return error.InvalidJaegerHeader;
    var v: u8 = 0;
    for (text) |c| {
        const n = nibble(c) catch return error.InvalidJaegerHeader;
        v = (v << 4) | n;
    }
    return v;
}

fn parseTraceIdFlexible(text: []const u8) !id.TraceId {
    if (text.len == 0 or text.len > 32) return error.InvalidJaegerHeader;
    if (!isAllHex(text)) return error.InvalidJaegerHeader;
    var padded: [32]u8 = .{'0'} ** 32;
    @memcpy(padded[32 - text.len ..], text);
    return id.TraceId.parseHex(padded[0..]) catch error.InvalidJaegerHeader;
}

fn parseSpanIdFlexible(text: []const u8) !id.SpanId {
    if (text.len == 0 or text.len > 16) return error.InvalidJaegerHeader;
    if (!isAllHex(text)) return error.InvalidJaegerHeader;
    var padded: [16]u8 = .{'0'} ** 16;
    @memcpy(padded[16 - text.len ..], text);
    return id.SpanId.parseHex(padded[0..]) catch error.InvalidJaegerHeader;
}

fn isAllHex(text: []const u8) bool {
    for (text) |c| {
        switch (c) {
            '0'...'9', 'a'...'f', 'A'...'F' => {},
            else => return false,
        }
    }
    return true;
}

fn nibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}

fn percentEncode(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |c| {
        if (isUnreserved(c)) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hexUpper(c >> 4));
            try out.append(allocator, hexUpper(c & 0x0f));
        }
    }
}

fn percentDecode(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];
        if (c == '%') {
            if (i + 2 >= value.len) return error.InvalidJaegerHeader;
            const hi = nibble(value[i + 1]) catch return error.InvalidJaegerHeader;
            const lo = nibble(value[i + 2]) catch return error.InvalidJaegerHeader;
            try out.append(allocator, (hi << 4) | lo);
            i += 3;
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
}

fn isUnreserved(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

fn hexUpper(n: u8) u8 {
    const alphabet = "0123456789ABCDEF";
    return alphabet[n & 0x0f];
}
