// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// NEW-M-2 (#140, CONFIDENTIAL) — CWE-59 Symlink Following
//
// Regression test: the JSONL file exporter must refuse to write through
// a symlink that has been planted inside its trusted base directory.
//
// Background (Zig 0.16.0 stdlib evidence):
//   * `lib/std/Io/Dir.zig:586` — `CreateFileOptions` has NO `follow_symlinks`
//     field at all (compare `OpenFileOptions.follow_symlinks: bool = true`
//     on line 551 of the same file).
//   * `lib/std/Io/Threaded.zig:4842` — the openat path returns `error.SymLinkLoop`
//     when `O_NOFOLLOW` hits a symlink, and `dirCreateFile` shares the openat
//     code path but never sets `O.NOFOLLOW` because the option doesn't exist.
//
// Net: `Dir.createFile(...)` follows symlinks unconditionally on Zig 0.16.
// The H-3 input-validation guard (`validateSubPath`) rejects `..` / absolute
// paths in the *string* argument, but does NOT defend against a symlink
// already present at the resolved path. An attacker with write access to
// the trusted base dir can plant `spans.jsonl -> /etc/cron.d/x` and have
// the exporter clobber the target.
//
// This test:
//   1. creates a base dir,
//   2. creates a sentinel file in a *separate* tmp dir,
//   3. plants a symlink inside the base dir pointing at the sentinel,
//   4. asserts the exporter REFUSES to open through the symlink.
//
// Pre-fix: `FileJsonl.open` returns OK and a subsequent write would
// clobber the sentinel.
// Post-fix: `FileJsonl.open` returns `error.SymLinkLoop` (POSIX `ELOOP`
// from `O_NOFOLLOW`).

const std = @import("std");
const builtin = @import("builtin");
const otel = @import("otel");

test "NEW-M-2: file exporter refuses to follow a planted symlink" {
    // Symlink semantics differ on Windows — skip there. The CI matrix
    // only enables this test on POSIX targets.
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Trusted base dir — what the operator would point the exporter at.
    var base_tmp = std.testing.tmpDir(.{});
    defer base_tmp.cleanup();

    // "Outside" target — what an attacker would try to clobber. We use
    // a second tmpDir so cleanup is automatic and we never touch a real
    // sensitive path.
    var outside_tmp = std.testing.tmpDir(.{});
    defer outside_tmp.cleanup();

    // Plant a sentinel file in the outside dir with a known content
    // marker. If the exporter follows the symlink, this file's bytes
    // will be overwritten — we assert the marker is preserved at the
    // end of the test.
    const sentinel_marker = "DO_NOT_CLOBBER_ME\n";
    {
        var sentinel = try outside_tmp.dir.createFile(io, "sentinel", .{ .truncate = true });
        defer sentinel.close(io);
        try sentinel.writeStreamingAll(io, sentinel_marker);
    }

    // Resolve the sentinel's absolute path so the symlink target is
    // unambiguous regardless of cwd.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try outside_tmp.dir.realPathFile(io, "sentinel", &path_buf);
    const sentinel_abs = path_buf[0..path_len];

    // Plant the hostile symlink: `<base>/spans.jsonl -> <sentinel_abs>`.
    try base_tmp.dir.symLink(io, sentinel_abs, "spans.jsonl", .{});

    // The fix: opening must refuse the symlink. We accept any error —
    // the contract is "do not silently follow". POSIX returns
    // `error.SymLinkLoop` from `O_NOFOLLOW` on the trailing component.
    const open_result = otel.exporters.file.FileJsonl.open(
        allocator,
        io,
        base_tmp.dir,
        "spans.jsonl",
    );

    // Assert open failed (any error is acceptable; we surface the exact
    // error in the test name only for diagnostics).
    if (open_result) |ok| {
        var jsonl = ok;
        jsonl.close();
        return error.ExporterFollowedSymlink;
    } else |err| switch (err) {
        // Linux/POSIX with O_NOFOLLOW.
        error.SymLinkLoop => {},
        // Future-proofing: if the implementation switches to a stat-then-create
        // approach, an `IsSymLink`-style error would also satisfy the contract.
        // The current Zig 0.16 std error set doesn't include that name, so
        // the only reachable path is SymLinkLoop. Leaving the catch-all here
        // documents the looser contract intentionally.
        else => return err,
    }

    // Belt-and-suspenders: the sentinel must still hold its original
    // content. If a future regression silently follows the symlink and
    // truncates it, this assertion catches the data-loss too.
    var f = try outside_tmp.dir.openFile(io, "sentinel", .{ .mode = .read_only });
    defer f.close(io);
    var buf: [64]u8 = undefined;
    const n = try f.readPositionalAll(io, &buf, 0);
    try std.testing.expectEqualStrings(sentinel_marker, buf[0..n]);
}

test "NEW-M-2: file exporter still works for a fresh path with no entry" {
    // Sanity: the new guard must not regress the normal flow where the
    // file simply does not exist yet.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var base_tmp = std.testing.tmpDir(.{});
    defer base_tmp.cleanup();

    var jsonl = try otel.exporters.file.FileJsonl.open(
        allocator,
        io,
        base_tmp.dir,
        "spans.jsonl",
    );
    defer jsonl.close();
}

test "NEW-M-2: file exporter still works when the regular file already exists" {
    // Sanity: re-opening an existing regular file (the restart path)
    // must continue to succeed; only symlinks are refused.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var base_tmp = std.testing.tmpDir(.{});
    defer base_tmp.cleanup();

    // First open creates the file.
    {
        var jsonl1 = try otel.exporters.file.FileJsonl.open(
            allocator,
            io,
            base_tmp.dir,
            "spans.jsonl",
        );
        jsonl1.close();
    }

    // Second open must reuse it without error (truncate=false preserves
    // any existing data — exercised by the H-3 test suite already).
    var jsonl2 = try otel.exporters.file.FileJsonl.open(
        allocator,
        io,
        base_tmp.dir,
        "spans.jsonl",
    );
    defer jsonl2.close();
}
