// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Wire-byte regression tests for GAP-OTLP-COMPRESSION (#27).
//
// Acceptance criteria pinned here:
//   - HTTP `.none` baseline: body bytes match the encoder output and
//     no `Content-Encoding` header is emitted.
//   - HTTP `.gzip`: body is gzipped, `Content-Encoding: gzip` is in
//     the headers passed to the transport, and the decompressed body
//     is byte-identical to the encoder output.
//   - HTTP `.gzip` empty payload: still produces a valid gzip stream
//     (header + footer wrap an empty deflate bitstream).
//   - HTTP `.gzip` large payload (>= 64 KiB): round-trips cleanly.
//   - gRPC framing: `frame(body, false)` emits `[0, len_be, body]`,
//     `frameGzip(body)` emits `[1, len_be, gzipped_bytes]` and the
//     gzipped bytes decompress to the original.
//
// Out of scope (tracked as Partial follow-ups):
//   - `grpc-encoding: gzip` request metadata header — grpc-zig's
//     `client.call` does not yet expose a request-metadata API.
//   - Wire-correct framing flag inside `grpc-zig`'s `transport.zig`
//     (the upstream client emits `0` regardless of compression). The
//     OTLP/gRPC loopback test already self-skips because of an
//     unrelated structural bug in upstream's client (it uses the
//     server-side `writeMessage` helper); compression follows the
//     same gating until that lands.

const std = @import("std");
const otel = @import("otel");

// ---- HTTP custom transport scaffolding ---------------------------------

const FakeState = struct {
    last_headers_buf: [256]u8 = undefined,
    last_headers_len: usize = 0,
    last_headers_present: bool = false,
    last_body: []u8 = &.{},
    /// `last_body` is owned by `gpa`; a previous test invocation's body
    /// is freed at the start of each `resetFake` so the leak detector
    /// stays clean.
    gpa: std.mem.Allocator,

    fn resetFake(self: *FakeState) void {
        self.last_headers_len = 0;
        self.last_headers_present = false;
        if (self.last_body.len != 0) {
            self.gpa.free(self.last_body);
            self.last_body = &.{};
        }
    }

    fn deinit(self: *FakeState) void {
        if (self.last_body.len != 0) self.gpa.free(self.last_body);
    }
};

var fake_state: FakeState = .{ .gpa = std.testing.allocator };

fn fakeTransport(
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    headers: ?[]const u8,
    _: []const u8,
    body: []const u8,
    _: u64,
) anyerror!otel.exporters.otlp_http.TransportResult {
    if (headers) |h| {
        fake_state.last_headers_present = true;
        const n = @min(h.len, fake_state.last_headers_buf.len);
        @memcpy(fake_state.last_headers_buf[0..n], h[0..n]);
        fake_state.last_headers_len = n;
    } else {
        fake_state.last_headers_present = false;
        fake_state.last_headers_len = 0;
    }
    // Make a heap-owned copy so the body survives the arena's `defer`
    // in the caller. The previous body is freed by `resetFake`.
    fake_state.last_body = try fake_state.gpa.dupe(u8, body);
    return .{ .status = 200, .body = "" };
}

fn buildSpanExporter(
    allocator: std.mem.Allocator,
    compression: @TypeOf(@as(otel.sdk.config.OtlpConfig, .{}).compression),
) !otel.exporters.otlp_http.OtlpHttpExporter {
    var exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(allocator, .{
        .endpoint = "http://localhost:4318",
        .protocol = .http_protobuf,
        .timeout_ms = 100,
        .compression = compression,
    });
    exporter.transport = .{ .custom = fakeTransport };
    return exporter;
}

fn makeFixture(allocator: std.mem.Allocator) !struct {
    resource: otel.sdk.resource.Resource,
    attrs: otel.internal.attributes.AttributeSet,
} {
    return .{
        .resource = try otel.sdk.resource.defaultResource(allocator),
        .attrs = otel.internal.attributes.AttributeSet.init(allocator),
    };
}

fn makeSpan(
    resource: *const otel.sdk.resource.Resource,
    attrs: *const otel.internal.attributes.AttributeSet,
    name: []const u8,
) otel.sdk.exporter.SpanData {
    return .{
        .name = name,
        .span_context = .{
            .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
            .span_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8 } },
        },
        .start_unix_nano = 1,
        .end_unix_nano = 2,
        .attributes = attrs,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "" },
        .resource = resource,
    };
}

// ---- HTTP tests --------------------------------------------------------

test "GAP-OTLP-COMPRESSION HTTP .none: body uncompressed, no Content-Encoding" {
    const allocator = std.testing.allocator;
    fake_state.resetFake();
    defer fake_state.resetFake();

    var fix = try makeFixture(allocator);
    defer fix.resource.deinit();
    defer fix.attrs.deinit();

    var exporter = try buildSpanExporter(allocator, .none);
    defer exporter.deinit();

    const span = makeSpan(&fix.resource, &fix.attrs, "x");
    const result = try exporter.spanExporter().exportSpans(&[_]otel.sdk.exporter.SpanData{span});
    try std.testing.expectEqual(otel.sdk.exporter.SpanExportResult.success, result);

    // Headers passed to the transport must be `null` (the default
    // `OtlpConfig.headers` is `null` and no compression header was
    // appended).
    try std.testing.expect(!fake_state.last_headers_present);
    // Body bytes should match the encoder output exactly.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const expected = try otel.exporters.otlp_http.encodeSpansProto(
        arena.allocator(),
        &[_]otel.sdk.exporter.SpanData{span},
    );
    try std.testing.expectEqualSlices(u8, expected, fake_state.last_body);
}

test "GAP-OTLP-COMPRESSION HTTP .gzip: body gzipped, Content-Encoding=gzip, round-trip" {
    const allocator = std.testing.allocator;
    fake_state.resetFake();
    defer fake_state.resetFake();

    var fix = try makeFixture(allocator);
    defer fix.resource.deinit();
    defer fix.attrs.deinit();

    var exporter = try buildSpanExporter(allocator, .gzip);
    defer exporter.deinit();

    const span = makeSpan(&fix.resource, &fix.attrs, "x");
    const result = try exporter.spanExporter().exportSpans(&[_]otel.sdk.exporter.SpanData{span});
    try std.testing.expectEqual(otel.sdk.exporter.SpanExportResult.success, result);

    // Header must contain `content-encoding=gzip` (case-insensitive,
    // RFC 7230 token rules — we emit lowercase to match the OTLP
    // headers convention).
    try std.testing.expect(fake_state.last_headers_present);
    const headers = fake_state.last_headers_buf[0..fake_state.last_headers_len];
    try std.testing.expect(std.mem.indexOf(u8, headers, "content-encoding=gzip") != null);

    // Body must start with the gzip magic (0x1f 0x8b 0x08 ...).
    try std.testing.expect(fake_state.last_body.len >= 3);
    try std.testing.expectEqual(@as(u8, 0x1f), fake_state.last_body[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), fake_state.last_body[1]);
    try std.testing.expectEqual(@as(u8, 0x08), fake_state.last_body[2]);

    // Decompress and compare to the encoder output.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const expected = try otel.exporters.otlp_http.encodeSpansProto(
        arena.allocator(),
        &[_]otel.sdk.exporter.SpanData{span},
    );
    const decompressed = try otel.exporters.otlp_http.gunzipBody(allocator, fake_state.last_body);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, expected, decompressed);
}

test "GAP-OTLP-COMPRESSION HTTP .gzip: appends to user-supplied headers" {
    // The transport already accepts `headers = "k=v, k2=v2"` for the
    // OTEL_EXPORTER_OTLP_HEADERS surface. Compression must merge with
    // whatever the user supplied rather than overwriting it.
    const allocator = std.testing.allocator;
    fake_state.resetFake();
    defer fake_state.resetFake();

    var fix = try makeFixture(allocator);
    defer fix.resource.deinit();
    defer fix.attrs.deinit();

    var exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(allocator, .{
        .endpoint = "http://localhost:4318",
        .protocol = .http_protobuf,
        .timeout_ms = 100,
        .headers = "x-custom=hello",
        .compression = .gzip,
    });
    exporter.transport = .{ .custom = fakeTransport };
    defer exporter.deinit();

    const span = makeSpan(&fix.resource, &fix.attrs, "x");
    _ = try exporter.spanExporter().exportSpans(&[_]otel.sdk.exporter.SpanData{span});

    try std.testing.expect(fake_state.last_headers_present);
    const headers = fake_state.last_headers_buf[0..fake_state.last_headers_len];
    try std.testing.expect(std.mem.indexOf(u8, headers, "x-custom=hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, headers, "content-encoding=gzip") != null);
}

test "GAP-OTLP-COMPRESSION HTTP .gzip large body (>= 64 KiB) round-trips cleanly" {
    // The deflate window is 32 KiB and the stdlib initialises a
    // separate 64 KiB working buffer in `gzipBody`. A payload ~96 KiB
    // forces the compressor to drain through the window at least
    // twice — the most likely place where a buggy buffer-handoff
    // would corrupt bytes.
    const allocator = std.testing.allocator;
    const size: usize = 96 * 1024;
    const payload = try allocator.alloc(u8, size);
    defer allocator.free(payload);
    var prng = std.Random.DefaultPrng.init(0xC0FFEEC0FFEE);
    const rand = prng.random();
    rand.bytes(payload);

    const compressed = try otel.exporters.otlp_http.gzipBody(allocator, payload);
    defer allocator.free(compressed);
    try std.testing.expect(compressed.len > 20);

    const decompressed = try otel.exporters.otlp_http.gunzipBody(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, payload, decompressed);
}

test "GAP-OTLP-COMPRESSION HTTP .gzip empty body still emits valid gzip frame" {
    const allocator = std.testing.allocator;
    const compressed = try otel.exporters.otlp_http.gzipBody(allocator, "");
    defer allocator.free(compressed);
    // RFC 1952 minimum: 10-byte header + 8-byte footer + at least one
    // byte for the deflate empty stored block. >= 20 covers all
    // deflate level encodings.
    try std.testing.expect(compressed.len >= 20);

    const decompressed = try otel.exporters.otlp_http.gunzipBody(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqual(@as(usize, 0), decompressed.len);
}

// ---- gRPC framing tests ------------------------------------------------

test "GAP-OTLP-COMPRESSION gRPC frame() default: prefix [0, len_be, body]" {
    const allocator = std.testing.allocator;
    const out = try otel.exporters.otlp_grpc.frame(allocator, "abc", false);
    defer allocator.free(out);
    try std.testing.expectEqual(@as(u8, 0), out[0]);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, out[1..5], .big));
    try std.testing.expectEqualSlices(u8, "abc", out[5..]);
}

test "GAP-OTLP-COMPRESSION gRPC frame() compressed: prefix [1, len_be, body]" {
    const allocator = std.testing.allocator;
    const out = try otel.exporters.otlp_grpc.frame(allocator, "abc", true);
    defer allocator.free(out);
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, out[1..5], .big));
    try std.testing.expectEqualSlices(u8, "abc", out[5..]);
}

test "GAP-OTLP-COMPRESSION gRPC frameGzip emits compressed framing + gzipped body" {
    const allocator = std.testing.allocator;
    const original = "the quick brown fox jumps over the lazy dog" ** 8;
    const out = try otel.exporters.otlp_grpc.frameGzip(allocator, original);
    defer allocator.free(out);

    // Wire shape: [1, len_be(compressed.len), gzipped_bytes].
    try std.testing.expectEqual(@as(u8, 1), out[0]);
    const len = std.mem.readInt(u32, out[1..5], .big);
    try std.testing.expectEqual(@as(u32, @intCast(out.len - 5)), len);
    // Gzip magic.
    try std.testing.expectEqual(@as(u8, 0x1f), out[5]);
    try std.testing.expectEqual(@as(u8, 0x8b), out[6]);

    const decompressed = try otel.exporters.otlp_http.gunzipBody(allocator, out[5..]);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, original, decompressed);
}
