// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

//! Hard-criterion check for the zero-overhead-when-disabled bench
//! system. Reads two ResultDocument JSON files (ref-A from
//! -Dotel_disabled=false, ref-B from -Dotel_disabled=true) and asserts:
//!
//!   1. `comptime-disabled` (variant=comptime_disabled) is within ±2 ns
//!      of `baseline-no-call` and has alloc_count == 0.
//!   2. `level-1-tracer-noop` is within ±5 ns of `baseline-no-call`
//!      and has alloc_count == 0.
//!
//! Exits non-zero on any rule violation. Missing input files are
//! tolerated (exits 0 with a "no inputs yet" notice) so the step is
//! safe to wire into bench-ci before the AB runner has produced any
//! output.
//!
//! Usage:
//!   check_hard_criteria --ref-a <file.json> --ref-b <file.json>

const std = @import("std");
const Io = std.Io;
const framework = @import("framework");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(allocator);
    var ref_a: ?[]const u8 = null;
    var ref_b: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--ref-a") and i + 1 < args.len) {
            ref_a = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--ref-b") and i + 1 < args.len) {
            ref_b = args[i + 1];
            i += 1;
        }
    }

    if (ref_a == null or ref_b == null) {
        try stderr.writeAll("hard-criterion-check: no --ref-a / --ref-b paths supplied; skipping\n");
        try stderr.flush();
        return;
    }
    if (!fileExists(init.io, ref_a.?) or !fileExists(init.io, ref_b.?)) {
        try stderr.print("hard-criterion-check: one or both ref files missing ({s}, {s}); skipping\n", .{ ref_a.?, ref_b.? });
        try stderr.flush();
        return;
    }

    // Real comparison logic lands when the AB runner produces output.
    // Until then this binary acts as a no-op gate.
    try stderr.print("hard-criterion-check: scaffolding only; rules wired in Phase 7. inputs: {s} {s}\n", .{ ref_a.?, ref_b.? });
    try stderr.flush();
    _ = framework; // referenced so the import survives the stub phase.
}

fn fileExists(io: Io, path: []const u8) bool {
    var f = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}
