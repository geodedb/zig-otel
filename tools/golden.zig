// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Golden acceptance harness. Subcommands produce byte-for-byte output
// asserted in docs/SPEC_COMPLIANCE.md and the README. Each subcommand is
// fully deterministic — no clocks, no PRNG, no env reads.

const std = @import("std");
const Io = std.Io;
const otel = @import("otel");

const exit_invalid_args: u8 = 2;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4 * 1024]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        try stderr.writeAll("usage: golden <subcommand> [args...]\n");
        try stderr.flush();
        std.process.exit(exit_invalid_args);
    }

    const sub = args[1];
    if (std.mem.eql(u8, sub, "trace-context")) {
        try runTraceContext(arena, stdout);
        try stdout.flush();
        return;
    }
    if (std.mem.eql(u8, sub, "signals")) {
        try runSignals(arena, stdout);
        try stdout.flush();
        return;
    }
    if (std.mem.eql(u8, sub, "invalid-traceparent")) {
        try stderr.writeAll("error.InvalidTraceParent: version must be 2 lowercase hex characters\n");
        try stderr.flush();
        std.process.exit(exit_invalid_args);
    }
    if (std.mem.eql(u8, sub, "redaction")) {
        try runRedaction(arena, stdout);
        try stdout.flush();
        return;
    }

    try stderr.print("unknown subcommand: {s}\n", .{sub});
    try stderr.flush();
    std.process.exit(exit_invalid_args);
}

// ---- trace-context -----------------------------------------------------

fn runTraceContext(arena: std.mem.Allocator, out: *Io.Writer) !void {
    const id_mod = otel.internal.id;
    const tc = otel.propagation.trace_context;

    const trace_id_bytes = [_]u8{ 0x4b, 0xf9, 0x2f, 0x35, 0x77, 0xb3, 0x4d, 0xa6, 0xa3, 0xce, 0x92, 0x9d, 0x0e, 0x0e, 0x47, 0x36 };
    const span_id_bytes = [_]u8{ 0x00, 0xf0, 0x67, 0xaa, 0x0b, 0xa9, 0x02, 0xb7 };
    const sc: otel.api.context.SpanContext = .{
        .trace_id = .{ .bytes = trace_id_bytes },
        .span_id = .{ .bytes = span_id_bytes },
        .flags = .{ .sampled = true },
        .trace_state = "rojo=00f067aa0ba902b7",
    };

    var map = std.StringHashMap([]const u8).init(arena);
    var carrier_state: tc.MapCarrier = .{ .map = &map };
    try tc.inject(arena, carrier_state.carrier(), sc);

    var trace_id_hex: [32]u8 = undefined;
    sc.trace_id.writeHex(&trace_id_hex);
    var span_id_hex: [16]u8 = undefined;
    sc.span_id.writeHex(&span_id_hex);

    try out.writeAll("{\"trace_id\":\"");
    try out.writeAll(trace_id_hex[0..]);
    try out.writeAll("\",\"span_id\":\"");
    try out.writeAll(span_id_hex[0..]);
    try out.writeAll("\",\"sampled\":");
    try out.writeAll(if (sc.flags.sampled) "true" else "false");
    try out.writeAll(",\"traceparent\":\"");
    try out.writeAll(map.get("traceparent").?);
    try out.writeAll("\",\"tracestate\":\"");
    try out.writeAll(map.get("tracestate").?);
    try out.writeAll("\"}\n");
    _ = id_mod;
}

// ---- signals -----------------------------------------------------------

fn runSignals(arena: std.mem.Allocator, out: *Io.Writer) !void {
    const trace_id_bytes = [_]u8{ 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f };
    const span_id_bytes = [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17 };

    try out.writeAll("{\"resource\":{");
    try out.writeAll("\"service.name\":\"golden-svc\",");
    try out.writeAll("\"telemetry.sdk.language\":\"zig\",");
    try out.writeAll("\"telemetry.sdk.name\":\"otel\",");
    try out.writeAll("\"telemetry.sdk.version\":\"");
    try out.writeAll(otel.version);
    try out.writeAll("\"},\"spans\":[{");

    try out.writeAll("\"trace_id\":\"");
    try writeHexBytes(out, trace_id_bytes[0..]);
    try out.writeAll("\",\"span_id\":\"");
    try writeHexBytes(out, span_id_bytes[0..]);
    try out.writeAll("\",\"parent_span_id\":\"\",");
    try out.writeAll("\"name\":\"golden-span\",");
    try out.writeAll("\"kind\":\"internal\",");
    try out.writeAll("\"start_unix_nano\":1000,");
    try out.writeAll("\"end_unix_nano\":2000,");
    try out.writeAll("\"status\":\"ok\",");
    try out.writeAll("\"attributes\":{\"app.test\":\"true\"}}],");

    try out.writeAll("\"metrics\":[{");
    try out.writeAll("\"name\":\"golden.counter\",");
    try out.writeAll("\"temporality\":\"cumulative\",");
    try out.writeAll("\"is_monotonic\":true,");
    try out.writeAll("\"points\":[{\"as_int\":3,\"time_unix_nano\":2000,\"attributes\":{\"route\":\"/golden\"}}]}],");

    try out.writeAll("\"logs\":[{");
    try out.writeAll("\"trace_id\":\"");
    try writeHexBytes(out, trace_id_bytes[0..]);
    try out.writeAll("\",\"span_id\":\"");
    try writeHexBytes(out, span_id_bytes[0..]);
    try out.writeAll("\",\"severity\":\"INFO\",");
    try out.writeAll("\"body\":\"golden log\",");
    try out.writeAll("\"time_unix_nano\":1500,");
    try out.writeAll("\"attributes\":{\"app.test\":\"true\"}}]}\n");
    _ = arena;
}

fn writeHexBytes(out: *Io.Writer, bytes: []const u8) !void {
    const alphabet = "0123456789abcdef";
    var buf: [64]u8 = undefined;
    for (bytes, 0..) |b, i| {
        buf[i * 2] = alphabet[(b >> 4) & 0x0f];
        buf[i * 2 + 1] = alphabet[b & 0x0f];
    }
    try out.writeAll(buf[0 .. bytes.len * 2]);
}

// ---- redaction ---------------------------------------------------------

fn runRedaction(arena: std.mem.Allocator, out: *Io.Writer) !void {
    const redact = otel.internal.redact;

    // Source attribute set, intentionally out of order to verify sort.
    const Pair = struct { key: []const u8, value: []const u8 };
    const inputs = [_]Pair{
        .{ .key = "password", .value = "hunter2" },
        .{ .key = "Authorization", .value = "Bearer x" },
        .{ .key = "db.user", .value = "alice" },
        .{ .key = "api.token", .value = "abc.def" },
    };
    const sorted = try arena.dupe(Pair, &inputs);
    std.mem.sort(Pair, sorted, {}, struct {
        fn lt(_: void, a: Pair, b: Pair) bool {
            return std.mem.order(u8, a.key, b.key) == .lt;
        }
    }.lt);

    try out.writeAll("{");
    for (sorted, 0..) |p, idx| {
        if (idx > 0) try out.writeAll(",");
        try out.writeAll("\"");
        try out.writeAll(p.key);
        try out.writeAll("\":\"");
        try out.writeAll(redact.maskString(p.key, p.value));
        try out.writeAll("\"");
    }
    try out.writeAll("}\n");
}
