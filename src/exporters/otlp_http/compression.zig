// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// gzip helpers for the OTLP exporters.
//
// GAP-OTLP-COMPRESSION (#27): both the OTLP/HTTP and OTLP/gRPC
// transports declare support for `OtlpConfig.compression == .gzip`,
// but pre-fix the body bytes were always sent uncompressed and the
// `Content-Encoding` / gRPC compressed-flag byte were never set.
// This module provides the small `gzipBody` / `gunzipBody` primitives
// that the dispatch sites in `exporter.zig` (HTTP) and `otlp_grpc.zig`
// (gRPC) call into.
//
// Implementation note (Zig 0.16): the stdlib does not expose a
// top-level `std.compress.gzip.compressor` shim. Gzip is realised
// via `std.compress.flate.Compress` configured with
// `.container = .gzip`, which writes the RFC 1952 10-byte header
// and the trailing CRC-32/ISIZE footer around the deflate bitstream.
// Decompression mirrors this with `std.compress.flate.Decompress`.

const std = @import("std");
const flate = std.compress.flate;

/// Compress `src` with gzip (RFC 1952). The returned slice is owned
/// by `allocator`; the caller frees with `allocator.free`.
///
/// Empty input is supported: gzip's header + footer wrap an empty
/// deflate stream into ~20 bytes, so the output is never zero-length
/// when the wire format expects framing.
pub fn gzipBody(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    // `flate.Compress.init` asserts the output writer's buffer holds
    // at least 9 bytes (a couple of bytes are reserved for the bit
    // accumulator + container header). Seed the Allocating writer
    // with a small capacity so the assertion passes; the writer
    // grows automatically as `flate.Compress` drains.
    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, 64);
    errdefer out.deinit();

    // The deflate window buffer is `flate.max_window_len` (64 KiB) per
    // the stdlib contract. Allocated on the heap because some test
    // payloads are large enough that holding it on the stack would
    // exceed the default test-runner stack budget.
    const window_buf = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window_buf);

    var c = try flate.Compress.init(&out.writer, window_buf, .gzip, .default);
    try c.writer.writeAll(src);
    try c.finish();

    return out.toOwnedSlice();
}

/// Decompress a gzip-encoded `src` (RFC 1952). Test-only helper —
/// the production exporters never decompress. Caller frees the
/// returned slice.
pub fn gunzipBody(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    var in: std.Io.Reader = .fixed(src);

    // `Decompress.init` requires either a zero-length window (direct
    // vtable) or one of at least `flate.max_window_len`. The direct
    // path stalls when the destination needs to rebase, so we always
    // pass a full-sized window — heap-allocated to keep the helper
    // usable on small thread stacks.
    const window_buf = try allocator.alloc(u8, flate.max_window_len);
    defer allocator.free(window_buf);

    var decompress: flate.Decompress = .init(&in, .gzip, window_buf);

    var out: std.Io.Writer.Allocating = try .initCapacity(allocator, src.len);
    errdefer out.deinit();

    while (decompress.reader.peekGreedy(1)) |bytes| {
        try out.writer.writeAll(bytes);
        decompress.reader.toss(bytes.len);
    } else |e| switch (e) {
        error.ReadFailed => return decompress.err.?,
        error.EndOfStream => {},
    }

    return out.toOwnedSlice();
}

test "gzipBody round-trips through gunzipBody" {
    const allocator = std.testing.allocator;
    const original = "the quick brown fox jumps over the lazy dog" ** 32;
    const compressed = try gzipBody(allocator, original);
    defer allocator.free(compressed);
    // RFC 1952 magic bytes — 0x1f 0x8b followed by deflate (CM=8).
    try std.testing.expectEqual(@as(u8, 0x1f), compressed[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), compressed[1]);
    try std.testing.expectEqual(@as(u8, 0x08), compressed[2]);
    // Compressed should be smaller than the highly-repetitive source.
    try std.testing.expect(compressed.len < original.len);

    const decompressed = try gunzipBody(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqualSlices(u8, original, decompressed);
}

test "gzipBody handles empty input" {
    const allocator = std.testing.allocator;
    const compressed = try gzipBody(allocator, "");
    defer allocator.free(compressed);
    // Even empty input produces a valid gzip stream (header + footer).
    try std.testing.expect(compressed.len >= 20);
    try std.testing.expectEqual(@as(u8, 0x1f), compressed[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), compressed[1]);

    const decompressed = try gunzipBody(allocator, compressed);
    defer allocator.free(decompressed);
    try std.testing.expectEqual(@as(usize, 0), decompressed.len);
}
