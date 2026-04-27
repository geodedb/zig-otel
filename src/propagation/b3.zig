// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// B3 propagator (https://github.com/openzipkin/b3-propagation).
//
// Two header forms ship side-by-side:
//
//   * Single header `b3: <trace-id>-<span-id>-<sampled>[-<parent-span-id>]`
//     where:
//       - trace-id   : 32 hex chars (or 16, accepted-and-padded on extract)
//       - span-id    : 16 hex chars
//       - sampled    : `0` (deny), `1` (accept), or `d` (debug; sampled+1)
//       - parent     : optional 16-hex; OpenTelemetry doesn't track this so
//                      we accept-and-discard on extract and never emit on
//                      inject.
//     The special form `b3: 0` means "do not sample, no trace context"
//     and surfaces as a SpanContext-equivalent empty result with
//     `sampled=false` so downstream samplers honour the upstream
//     deny decision.
//
//   * Multi header — distinct headers carrying the same fields:
//       X-B3-TraceId, X-B3-SpanId, X-B3-ParentSpanId (extract-only),
//       X-B3-Sampled (`0` | `1`), X-B3-Flags (`1` = debug).
//     `X-B3-Flags=1` overrides `X-B3-Sampled` to `true` per spec.
//
// Both forms share the same trace-id / span-id parsers + a small
// state-machine that rejects malformed input. Each surface registers a
// `TextMapPropagator` value (`single_header` and `multi_header`) so the
// SDK factory in `sdk/config.zig` can plug them into a `Composite` from
// `OTEL_PROPAGATORS={b3,b3multi}`.

const std = @import("std");
const ctx_mod = @import("../api/context.zig");
const id = @import("../internal/id.zig");
const propagator_mod = @import("propagator.zig");

pub const Carrier = propagator_mod.Carrier;
pub const Fields = propagator_mod.Fields;
pub const ExtractResult = propagator_mod.ExtractResult;
pub const TextMapPropagator = propagator_mod.TextMapPropagator;

// Header names — exact spelling per the openzipkin/b3-propagation spec.
pub const single_header_name: []const u8 = "b3";
pub const trace_id_header: []const u8 = "X-B3-TraceId";
pub const span_id_header: []const u8 = "X-B3-SpanId";
pub const parent_span_id_header: []const u8 = "X-B3-ParentSpanId";
pub const sampled_header: []const u8 = "X-B3-Sampled";
pub const flags_header: []const u8 = "X-B3-Flags";

// ---------------------------------------------------------------- //
// Public TextMapPropagator handles.
// ---------------------------------------------------------------- //

pub const single_header: TextMapPropagator = .{
    .inject_fn = singleInject,
    .extract_fn = singleExtract,
};

pub const multi_header: TextMapPropagator = .{
    .inject_fn = multiInject,
    .extract_fn = multiExtract,
};

// ---------------------------------------------------------------- //
// Single-header impl.
// ---------------------------------------------------------------- //

fn singleInject(_: ?*anyopaque, arena: std.mem.Allocator, carrier: Carrier, fields: Fields) !void {
    const sc = fields.span_context orelse return;
    if (!sc.isValid()) return;

    // 32 + 1 + 16 + 1 + 1 = 51 bytes max for the OpenTelemetry path
    // (we never emit a parent-span-id since OTel SpanContext doesn't
    // track one).
    var buf: [51]u8 = undefined;
    var tid_hex: [32]u8 = undefined;
    sc.trace_id.writeHex(&tid_hex);
    var sid_hex: [16]u8 = undefined;
    sc.span_id.writeHex(&sid_hex);
    const sampled_char: u8 = if (sc.flags.sampled) '1' else '0';

    const text = try std.fmt.bufPrint(buf[0..], "{s}-{s}-{c}", .{ tid_hex[0..], sid_hex[0..], sampled_char });
    const owned = try arena.dupe(u8, text);
    try carrier.set(single_header_name, owned);
}

fn singleExtract(_: ?*anyopaque, _: std.mem.Allocator, _: std.mem.Allocator, carrier: Carrier) !ExtractResult {
    const raw = carrier.get(single_header_name) orelse return .{};
    const trimmed = std.mem.trim(u8, raw, " \t");

    // Special form: a bare `0` carries no trace context, just a deny
    // sampling decision. Per spec we surface an empty SpanContext
    // with sampled=false so downstream samplers honour the upstream
    // intent. SpanContext.isValid() is false (the trace_id is all
    // zeroes), so most consumers will treat this as "no context"
    // anyway — the sampling bit is preserved for samplers that
    // explicitly inspect it.
    if (std.mem.eql(u8, trimmed, "0")) {
        return .{ .span_context = .{
            .trace_id = .invalid,
            .span_id = .invalid,
            .flags = .{ .sampled = false },
            .is_remote = true,
        } };
    }

    return .{ .span_context = parseSingle(trimmed) catch return .{} };
}

/// Parse the dash-delimited single header. Rejects empty trace-id,
/// missing span-id, invalid hex, or out-of-range field count.
fn parseSingle(text: []const u8) !ctx_mod.SpanContext {
    // Walk the string field-by-field. The parent-span-id is the
    // optional 4th field; we accept-and-discard.
    var fields_iter = std.mem.splitScalar(u8, text, '-');
    const tid_text = fields_iter.next() orelse return error.InvalidB3Header;
    if (tid_text.len == 0) return error.InvalidB3Header;
    const sid_text = fields_iter.next() orelse return error.InvalidB3Header;
    const sampled_text = fields_iter.next();
    const parent_text = fields_iter.next();
    if (fields_iter.next() != null) return error.InvalidB3Header;

    const tid = try parseTraceId(tid_text);
    const sid = try parseSpanId(sid_text);
    var flags: id.TraceFlags = .{};
    if (sampled_text) |s| flags = try parseSampled(s);
    if (parent_text) |p| {
        // Validate format only — the value is accepted-and-discarded.
        _ = try parseSpanId(p);
    }

    if (!tid.isValid()) return error.InvalidB3Header;
    if (!sid.isValid()) return error.InvalidB3Header;

    return .{
        .trace_id = tid,
        .span_id = sid,
        .flags = flags,
        .is_remote = true,
    };
}

// ---------------------------------------------------------------- //
// Multi-header impl.
// ---------------------------------------------------------------- //

fn multiInject(_: ?*anyopaque, arena: std.mem.Allocator, carrier: Carrier, fields: Fields) !void {
    const sc = fields.span_context orelse return;
    if (!sc.isValid()) return;

    var tid_hex: [32]u8 = undefined;
    sc.trace_id.writeHex(&tid_hex);
    var sid_hex: [16]u8 = undefined;
    sc.span_id.writeHex(&sid_hex);

    const tid_owned = try arena.dupe(u8, tid_hex[0..]);
    try carrier.set(trace_id_header, tid_owned);

    const sid_owned = try arena.dupe(u8, sid_hex[0..]);
    try carrier.set(span_id_header, sid_owned);

    // Sampled is emitted on every inject (mirroring W3C tracecontext's
    // unconditional flag emit). We never emit Flags on inject because
    // OpenTelemetry SpanContext has no debug-override field —
    // upstream's "1=debug" is consumed-and-collapsed into
    // `flags.sampled=true` on extract.
    const sampled_owned = try arena.dupe(u8, if (sc.flags.sampled) "1" else "0");
    try carrier.set(sampled_header, sampled_owned);
}

fn multiExtract(_: ?*anyopaque, _: std.mem.Allocator, _: std.mem.Allocator, carrier: Carrier) !ExtractResult {
    const tid_text = carrier.get(trace_id_header) orelse return .{};
    const sid_text = carrier.get(span_id_header) orelse return .{};
    const sampled_text = carrier.get(sampled_header);
    const flags_text = carrier.get(flags_header);

    const tid = parseTraceId(std.mem.trim(u8, tid_text, " \t")) catch return .{};
    const sid = parseSpanId(std.mem.trim(u8, sid_text, " \t")) catch return .{};
    if (!tid.isValid() or !sid.isValid()) return .{};

    var flags: id.TraceFlags = .{};
    if (sampled_text) |s| {
        flags = parseSampled(std.mem.trim(u8, s, " \t")) catch return .{};
    }
    // X-B3-Flags=1 means debug; per spec it overrides Sampled to true.
    if (flags_text) |f| {
        const trimmed = std.mem.trim(u8, f, " \t");
        if (std.mem.eql(u8, trimmed, "1")) flags.sampled = true;
    }

    // Optional parent-span-id is accepted-and-discarded.
    if (carrier.get(parent_span_id_header)) |p| {
        _ = parseSpanId(std.mem.trim(u8, p, " \t")) catch return .{};
    }

    return .{ .span_context = .{
        .trace_id = tid,
        .span_id = sid,
        .flags = flags,
        .is_remote = true,
    } };
}

// ---------------------------------------------------------------- //
// Shared parsers.
// ---------------------------------------------------------------- //

/// Trace-id is canonically 32 lowercase hex chars. The B3 spec also
/// allows a 16-hex form for compatibility with legacy 64-bit Zipkin
/// headers; we accept that and zero-pad on the high half. On inject
/// we always emit 32 (the OpenTelemetry SpanContext is 128-bit).
fn parseTraceId(text: []const u8) !id.TraceId {
    if (text.len == 32) {
        if (!isAllHex(text)) return error.InvalidB3Header;
        return id.TraceId.parseHex(text) catch error.InvalidB3Header;
    }
    if (text.len == 16) {
        if (!isAllHex(text)) return error.InvalidB3Header;
        var padded: [32]u8 = .{'0'} ** 32;
        @memcpy(padded[16..32], text[0..16]);
        return id.TraceId.parseHex(padded[0..]) catch error.InvalidB3Header;
    }
    return error.InvalidB3Header;
}

/// Span-id is 16 hex chars; reject anything else.
fn parseSpanId(text: []const u8) !id.SpanId {
    if (text.len != 16) return error.InvalidB3Header;
    if (!isAllHex(text)) return error.InvalidB3Header;
    return id.SpanId.parseHex(text) catch error.InvalidB3Header;
}

fn parseSampled(text: []const u8) !id.TraceFlags {
    if (text.len != 1) return error.InvalidB3Header;
    return switch (text[0]) {
        '0' => .{ .sampled = false },
        '1' => .{ .sampled = true },
        'd', 'D' => .{ .sampled = true }, // debug = sampled + override
        else => error.InvalidB3Header,
    };
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
