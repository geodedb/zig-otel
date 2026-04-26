// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// GAP-SEC-M-2: deterministic provenance for `src/generated/otlp.zig`.
//
// This tool walks `third_party/opentelemetry-proto-v1.10.0/`, emits a
// SHA-256 over every regular file, and prints a manifest line per file.
// The manifest is also written to `docs/DEPENDENCIES.md`'s "Provenance"
// section (manually for now; see the README for the regeneration
// recipe). CI runs this tool and compares the manifest to the in-tree
// copy — any drift fails the pipeline.
//
// The actual hand-rolled encoder in `src/generated/otlp.zig` is NOT
// re-emitted by this tool. The encoder is small and stable; the
// provenance check is what we need to detect upstream changes that
// would require a manual update.
//
// Usage:
//   zig build gen-otlp                # prints the manifest to stdout
//
// Acceptance (CI):
//   tools/gen_otlp.zig manifest output is reproducible across two runs
//   on the same commit. Any difference indicates upstream drift.

const std = @import("std");

const upstream_dir = "third_party/opentelemetry-proto-v1.10.0";

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_w.interface;
    defer out.flush() catch {};

    try out.print("# otel proto-tree manifest (SHA-256 per file)\n", .{});
    try out.print("# upstream pin: opentelemetry-proto v1.10.0\n", .{});
    try out.print("# regenerate: zig build gen-otlp > docs/proto-manifest.txt\n", .{});

    var dir = std.Io.Dir.cwd().openDir(io, upstream_dir, .{ .iterate = true }) catch |err| {
        try out.print("warning: cannot open {s}: {s}\n", .{ upstream_dir, @errorName(err) });
        return;
    };
    defer dir.close(io);

    try walkAndHash(allocator, io, &dir, upstream_dir, out);
}

fn walkAndHash(allocator: std.mem.Allocator, io: std.Io, dir: *std.Io.Dir, prefix: []const u8, out: *std.Io.Writer) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        defer allocator.free(child_path);
        switch (entry.kind) {
            .file => {
                const Sha256 = std.crypto.hash.sha2.Sha256;
                var digest: [Sha256.digest_length]u8 = undefined;
                var hasher = Sha256.init(.{});
                var f = try dir.openFile(io, entry.name, .{});
                defer f.close(io);
                var buf: [4096]u8 = undefined;
                while (true) {
                    const n = f.readStreaming(io, &.{&buf}) catch |err| switch (err) {
                        error.EndOfStream => 0,
                        else => return err,
                    };
                    if (n == 0) break;
                    hasher.update(buf[0..n]);
                }
                hasher.final(&digest);
                var hex_buf: [Sha256.digest_length * 2]u8 = undefined;
                const alphabet = "0123456789abcdef";
                for (digest, 0..) |b, i| {
                    hex_buf[i * 2] = alphabet[(b >> 4) & 0x0f];
                    hex_buf[i * 2 + 1] = alphabet[b & 0x0f];
                }
                try out.print("{s}  {s}\n", .{ hex_buf[0..], child_path });
            },
            .directory => {
                var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub.close(io);
                try walkAndHash(allocator, io, &sub, child_path, out);
            },
            else => {},
        }
    }
}
