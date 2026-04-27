// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// NEW-H-1 / GAP-SEC-M-2: shared SHA-256 manifest engine for the
// `tools/gen_otlp.zig` and `tools/gen_semconv.zig` provenance gates.
//
// The previous generator implementation walked an upstream tree
// containing only `LICENSE` and printed a single hash line — a
// "deterministic provenance" facade that anchored nothing about the
// actual `.proto` / YAML model files the hand-rolled encoders were
// derived from. NEW-H-1 (#134, confidential, CWE-345) treats that gap
// as a supply-chain forgery primitive.
//
// This module fixes the gate structurally:
//
//   * `compute()` walks the vendored tree, sorts every regular file by
//     POSIX path (no filesystem-iteration-order dependence), and
//     SHA-256s each one. Output is deterministic across machines.
//   * `requireSpecPayload()` fails loud (`error.OnlyLicenseFound` /
//     `error.UpstreamTreeEmpty`) if the upstream directory has nothing
//     but `LICENSE` (or nothing at all). This is the structural
//     assertion the original gate was missing.
//   * `verify()` re-computes the manifest and byte-compares against the
//     committed manifest; any drift returns `error.ManifestDrift` for
//     the calling tool to translate to a non-zero exit.
//
// The manifest format is one `<sha256-hex>  <path>` line per file,
// sorted by path. Three header lines (`# ...`) precede the body so a
// human grep sees the upstream pin and the regeneration recipe.
//
// Tests for this module live in `test/manifest_provenance.zig` and
// gate the structural invariant: a stripped-LICENSE-only upstream
// tree fails the generator, and the committed manifests resolve
// `verify()` clean against the on-disk vendored tree.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Mode = enum {
    /// Print the manifest to stdout (`zig build gen-otlp`,
    /// `zig build gen-semconv`).
    emit,
    /// Re-compute and exit non-zero on drift (`zig build verify-proto-manifest`,
    /// `zig build verify-semconv-manifest`).
    verify,
};

pub const Args = struct {
    /// Vendored upstream directory, repo-relative
    /// (e.g. `third_party/opentelemetry-proto-v1.10.0`).
    upstream_dir: []const u8,
    /// On-disk manifest the verify mode compares against
    /// (e.g. `docs/proto-manifest.txt`).
    manifest_path: []const u8,
    /// Pin string baked into the header (e.g. `opentelemetry-proto v1.10.0`).
    upstream_pin: []const u8,
    /// Build step that emits the manifest, baked into the header
    /// (e.g. `zig build gen-otlp > docs/proto-manifest.txt`).
    regenerate_recipe: []const u8,
    /// Tool label printed in error messages.
    tool_name: []const u8,
};

pub const ManifestError = error{
    OnlyLicenseFound,
    UpstreamTreeEmpty,
    ManifestDrift,
    ManifestMissing,
};

pub const Entry = struct {
    /// repo-relative path (e.g. `third_party/.../foo/bar.proto`)
    path: []u8,
    /// 64-byte hex SHA-256
    sha_hex: [64]u8,
};

/// Run the manifest generator end-to-end.
///
/// `mode == .emit` prints the manifest to `stdout`.
/// `mode == .verify` reads `args.manifest_path` from disk and compares
/// the live computation against it; returns `error.ManifestDrift` if
/// the bytes differ. The verify path uses `std.process.exit(2)` for the
/// drift case via the calling tool wrapper, but only after closing IO.
pub fn run(allocator: std.mem.Allocator, io: std.Io, mode: Mode, args: Args, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const computed = try compute(allocator, io, args);
    defer freeManifest(allocator, computed);

    try requireSpecPayload(args, computed, stderr);

    switch (mode) {
        .emit => {
            try writeManifest(stdout, args, computed);
        },
        .verify => {
            const on_disk = std.Io.Dir.cwd().readFileAlloc(io, args.manifest_path, allocator, .limited(8 * 1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => {
                    try stderr.print("{s}: manifest file missing: {s}\n", .{ args.tool_name, args.manifest_path });
                    return ManifestError.ManifestMissing;
                },
                else => return err,
            };
            defer allocator.free(on_disk);

            // Render the freshly-computed manifest into a buffer for
            // byte-equal comparison with the on-disk copy.
            var buf: std.Io.Writer.Allocating = .init(allocator);
            defer buf.deinit();
            try writeManifest(&buf.writer, args, computed);
            const fresh = buf.written();

            if (!std.mem.eql(u8, fresh, on_disk)) {
                try stderr.print(
                    "{s}: manifest drift detected — `{s}` is stale.\n" ++
                        "       Re-run the generator to refresh:\n" ++
                        "         {s}\n",
                    .{ args.tool_name, args.manifest_path, args.regenerate_recipe },
                );
                // Hint at the first divergence so a human can locate it.
                try diffHint(fresh, on_disk, stderr);
                return ManifestError.ManifestDrift;
            }
        },
    }
}

/// Walk `args.upstream_dir`, SHA-256 every regular file, and return a
/// path-sorted list of (path, sha) entries. Caller owns the returned
/// memory and must release it via `freeManifest`.
pub fn compute(allocator: std.mem.Allocator, io: std.Io, args: Args) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer freeArrayList(allocator, &entries);

    var dir = std.Io.Dir.cwd().openDir(io, args.upstream_dir, .{ .iterate = true }) catch |err| {
        return err;
    };
    defer dir.close(io);

    try walk(allocator, io, &dir, args.upstream_dir, &entries);

    // Sort entries by their repo-relative path so the manifest is
    // independent of filesystem iteration order. POSIX byte-wise
    // compare matches sha256sum's natural output order.
    std.mem.sort(Entry, entries.items, {}, lessByPath);

    return entries.toOwnedSlice(allocator);
}

fn lessByPath(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

fn walk(allocator: std.mem.Allocator, io: std.Io, dir: *std.Io.Dir, prefix: []const u8, entries: *std.ArrayList(Entry)) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const child_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .file => {
                var f = try dir.openFile(io, entry.name, .{});
                defer f.close(io);
                var hasher = Sha256.init(.{});
                var buf: [4096]u8 = undefined;
                while (true) {
                    const n = f.readStreaming(io, &.{&buf}) catch |err| switch (err) {
                        error.EndOfStream => 0,
                        else => return err,
                    };
                    if (n == 0) break;
                    hasher.update(buf[0..n]);
                }
                var digest: [Sha256.digest_length]u8 = undefined;
                hasher.final(&digest);

                var sha_hex: [64]u8 = undefined;
                const alphabet = "0123456789abcdef";
                for (digest, 0..) |b, i| {
                    sha_hex[i * 2] = alphabet[(b >> 4) & 0x0f];
                    sha_hex[i * 2 + 1] = alphabet[b & 0x0f];
                }

                try entries.append(allocator, .{ .path = child_path, .sha_hex = sha_hex });
            },
            .directory => {
                defer allocator.free(child_path);
                var sub = try dir.openDir(io, entry.name, .{ .iterate = true });
                defer sub.close(io);
                try walk(allocator, io, &sub, child_path, entries);
            },
            else => {
                // Symlinks, devices, fifos: not part of a vendored
                // spec tree. Skipping them keeps the manifest
                // reproducible across filesystems that surface those
                // entry kinds differently.
                allocator.free(child_path);
            },
        }
    }
}

/// Fail loud if the upstream tree is empty or contains only LICENSE.
/// This is the structural assertion that closes NEW-H-1: a vendored
/// directory holding only the LICENSE file cannot anchor encoder
/// provenance, so the generator must refuse to emit a "successful"
/// manifest in that state.
pub fn requireSpecPayload(args: Args, entries: []const Entry, stderr: *std.Io.Writer) !void {
    if (entries.len == 0) {
        try stderr.print(
            "{s}: upstream tree `{s}` is empty.\n" ++
                "       The vendored spec sources are required for the manifest\n" ++
                "       to anchor anything; restore them before regenerating.\n",
            .{ args.tool_name, args.upstream_dir },
        );
        return ManifestError.UpstreamTreeEmpty;
    }

    // "Only LICENSE present" was the original toothless state. We
    // detect it by counting non-LICENSE files; a single LICENSE entry
    // alone fails loudly. (A repo with LICENSE plus README and
    // version.properties — i.e. real spec content — passes.)
    var non_license: usize = 0;
    for (entries) |e| {
        if (!std.mem.endsWith(u8, e.path, "/LICENSE")) non_license += 1;
    }
    if (non_license == 0) {
        try stderr.print(
            "{s}: upstream tree `{s}` contains only LICENSE.\n" ++
                "       NEW-H-1 (CWE-345): a LICENSE-only manifest does not\n" ++
                "       anchor the encoder/semconv generator's actual upstream.\n" ++
                "       Vendor the real spec sources before regenerating.\n",
            .{ args.tool_name, args.upstream_dir },
        );
        return ManifestError.OnlyLicenseFound;
    }
}

fn writeManifest(out: *std.Io.Writer, args: Args, entries: []const Entry) !void {
    try out.print(
        "# otel manifest (SHA-256 per file)\n" ++
            "# upstream pin: {s}\n" ++
            "# regenerate:   {s}\n",
        .{ args.upstream_pin, args.regenerate_recipe },
    );
    for (entries) |e| {
        try out.print("{s}  {s}\n", .{ e.sha_hex[0..], e.path });
    }
}

fn diffHint(fresh: []const u8, on_disk: []const u8, stderr: *std.Io.Writer) !void {
    // Find the first divergent line; print it on each side. Cheap
    // signal for the operator without dragging in a full diff.
    var fresh_it = std.mem.splitScalar(u8, fresh, '\n');
    var disk_it = std.mem.splitScalar(u8, on_disk, '\n');
    var lineno: usize = 0;
    while (true) {
        lineno += 1;
        const a = fresh_it.next();
        const b = disk_it.next();
        if (a == null and b == null) return;
        const aval = a orelse "";
        const bval = b orelse "";
        if (!std.mem.eql(u8, aval, bval)) {
            try stderr.print("       first divergence at line {d}:\n", .{lineno});
            try stderr.print("         expected: {s}\n", .{aval});
            try stderr.print("         on disk:  {s}\n", .{bval});
            return;
        }
    }
}

fn freeArrayList(allocator: std.mem.Allocator, list: *std.ArrayList(Entry)) void {
    for (list.items) |*e| allocator.free(e.path);
    list.deinit(allocator);
}

pub fn freeManifest(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |*e| allocator.free(e.path);
    allocator.free(entries);
}
