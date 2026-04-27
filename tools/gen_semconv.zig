// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// NEW-H-1 / GAP-SEC-M-2: deterministic provenance for `src/generated/semconv.zig`.
//
// Walks `third_party/semantic-conventions-v1.40.0/`, emits SHA-256 per
// file (sorted by path), and supports both regenerate and verify modes.
// Same shape and rationale as `tools/gen_otlp.zig` — see that file's
// doc comment for the why.
//
// Modes:
//   * `zig build gen-semconv`               — prints the manifest to stdout.
//   * `zig build verify-semconv-manifest`   — drift check, exits 2 on mismatch.
//
// NEW-H-1 closure: refuses to emit if the upstream tree contains only
// LICENSE (the former toothless state).

const std = @import("std");
const manifest = @import("manifest");

const upstream_dir = "third_party/semantic-conventions-v1.40.0";
const manifest_path = "docs/semconv-manifest.txt";
const upstream_pin = "semantic-conventions v1.40.0";
const recipe = "zig build gen-semconv > docs/semconv-manifest.txt";
const tool_name = "gen-semconv";

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stdout_buf: [4096]u8 = undefined;
    var stdout_w = std.Io.File.stdout().writer(io, &stdout_buf);
    const out = &stdout_w.interface;
    defer out.flush() catch {};

    var stderr_buf: [4096]u8 = undefined;
    var stderr_w = std.Io.File.stderr().writer(io, &stderr_buf);
    const err = &stderr_w.interface;
    defer err.flush() catch {};

    var mode: manifest.Mode = .emit;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const argv = try init.minimal.args.toSlice(arena.allocator());
    for (argv[1..]) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.eql(u8, arg, "--verify")) {
            mode = .verify;
        } else if (std.mem.eql(u8, arg, "--emit")) {
            mode = .emit;
        } else {
            try err.print("{s}: unknown arg `{s}` (expected --emit or --verify)\n", .{ tool_name, arg });
            err.flush() catch {};
            std.process.exit(2);
        }
    }

    manifest.run(allocator, io, mode, .{
        .upstream_dir = upstream_dir,
        .manifest_path = manifest_path,
        .upstream_pin = upstream_pin,
        .regenerate_recipe = recipe,
        .tool_name = tool_name,
    }, out, err) catch |e| switch (e) {
        manifest.ManifestError.OnlyLicenseFound,
        manifest.ManifestError.UpstreamTreeEmpty,
        manifest.ManifestError.ManifestDrift,
        manifest.ManifestError.ManifestMissing,
        => {
            out.flush() catch {};
            err.flush() catch {};
            std.process.exit(2);
        },
        else => return e,
    };
}
