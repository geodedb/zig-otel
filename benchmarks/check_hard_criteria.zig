// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

//! Hard-criterion check for the zero-overhead-when-disabled bench
//! system. Reads two ResultDocument JSON files (ref-A produced by the
//! `-Dotel_disabled=false` build, ref-B by `-Dotel_disabled=true`) and
//! verifies the architecture-document hard criteria:
//!
//!   1. `comptime-disabled` ns/op (in ref-B) is within `+2 ns` of
//!      `baseline-no-call` ns/op (in ref-B). Per-op allocations in the
//!      timed loop must be `~0` (allowed setup tolerance: 100 bytes
//!      across all sampled rounds, since the body still constructs a
//!      provider once per iteration).
//!   2. `level-1-tracer-noop` ns/op (in ref-A) is within `+5 ns` of
//!      `baseline-no-call` ns/op (in ref-A). alloc_count must be 0.
//!
//! Exits non-zero on any violation. Missing input files are tolerated
//! (exits 0 with a "no inputs yet" notice) so the step is safe to wire
//! into bench-ci before the AB runner has produced any output.

const std = @import("std");
const Io = std.Io;
const framework = @import("framework");

const comptime_delta_ns_max: f64 = 2.0;
const level1_delta_ns_max: f64 = 5.0;
/// Per-op alloc rate tolerance for the comptime-disabled scenario.
/// The body constructs a TracerProvider once per iteration — that's a
/// fixed setup cost (a handful of allocations spread across the
/// 10_000-op loop). Anything below this rate counts as "effectively
/// zero" for the per-call hot path.
const comptime_alloc_per_op_max: f64 = 0.01;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const args = try init.minimal.args.toSlice(allocator);
    var ref_a_path: ?[]const u8 = null;
    var ref_b_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--ref-a") and i + 1 < args.len) {
            ref_a_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--ref-b") and i + 1 < args.len) {
            ref_b_path = args[i + 1];
            i += 1;
        }
    }

    if (ref_a_path == null or ref_b_path == null) {
        try stderr.writeAll("hard-criterion-check: no --ref-a / --ref-b paths supplied; skipping\n");
        try stderr.flush();
        return;
    }
    if (!fileExists(init.io, ref_a_path.?) or !fileExists(init.io, ref_b_path.?)) {
        try stderr.print("hard-criterion-check: one or both ref files missing ({s}, {s}); skipping\n", .{ ref_a_path.?, ref_b_path.? });
        try stderr.flush();
        return;
    }

    const ref_a = try readDocument(allocator, init.io, ref_a_path.?);
    const ref_b = try readDocument(allocator, init.io, ref_b_path.?);

    var failures: u32 = 0;

    // Rule 1: comptime-disabled must be ~free under flag=true.
    if (try checkRule(
        stderr,
        "comptime-disabled (flag=true) ≤ baseline-no-call (flag=true) + 2 ns",
        ref_b.value.rows,
        "comptime-disabled",
        "baseline-no-call",
        comptime_delta_ns_max,
        comptime_alloc_per_op_max,
    )) |violated| if (violated) {
        failures += 1;
    };

    // Rule 2: level-1-tracer-noop must be ~free under flag=false.
    if (try checkRule(
        stderr,
        "level-1-tracer-noop (flag=false) ≤ baseline-no-call (flag=false) + 5 ns",
        ref_a.value.rows,
        "level-1-tracer-noop",
        "baseline-no-call",
        level1_delta_ns_max,
        0.0,
    )) |violated| if (violated) {
        failures += 1;
    };

    if (failures != 0) {
        try stderr.print("hard-criterion-check: {d} criteria FAILED\n", .{failures});
        try stderr.flush();
        return error.HardCriterionFailed;
    }
    try stderr.writeAll("hard-criterion-check: all criteria PASS\n");
    try stderr.flush();
}

/// Returns `true` if the rule was violated, `false` if it passed.
/// `max_alloc_per_op == 0.0` means the strict "literally no allocs"
/// criterion (used by level-1, which has no provider setup).
fn checkRule(
    out: *Io.Writer,
    label: []const u8,
    rows: []const framework.ResultRow,
    target_scenario: []const u8,
    baseline_scenario: []const u8,
    max_delta_ns: f64,
    max_alloc_per_op: f64,
) !?bool {
    const target = findRow(rows, target_scenario) orelse {
        try out.print("  [SKIP] {s}: scenario '{s}' missing from results\n", .{ label, target_scenario });
        try out.flush();
        return null;
    };
    const baseline = findRow(rows, baseline_scenario) orelse {
        try out.print("  [SKIP] {s}: scenario '{s}' missing from results\n", .{ label, baseline_scenario });
        try out.flush();
        return null;
    };

    const target_ns_per_op = nsPerOp(target);
    const baseline_ns_per_op = nsPerOp(baseline);
    const delta = target_ns_per_op - baseline_ns_per_op;
    const alloc_per_op = allocPerOp(target);

    var ok = true;
    if (delta > max_delta_ns) ok = false;
    if (max_alloc_per_op == 0.0) {
        if (target.alloc_count > 0) ok = false;
    } else {
        if (alloc_per_op > max_alloc_per_op) ok = false;
    }

    try out.print(
        "  [{s}] {s}: target={d:.3} ns/op  baseline={d:.3} ns/op  Δ={s}{d:.3} ns  allocs/op={d:.5}  ({d} allocs over {d} ops/iter)\n",
        .{
            if (ok) "PASS" else "FAIL",
            label,
            target_ns_per_op,
            baseline_ns_per_op,
            if (delta >= 0) "+" else "",
            delta,
            alloc_per_op,
            target.alloc_count,
            target.ops_per_iteration,
        },
    );
    try out.flush();
    return !ok;
}

fn allocPerOp(row: framework.ResultRow) f64 {
    if (row.ops_per_iteration == 0) return 0;
    return @as(f64, @floatFromInt(row.alloc_count)) / @as(f64, @floatFromInt(row.ops_per_iteration));
}

fn nsPerOp(row: framework.ResultRow) f64 {
    if (row.ops_per_iteration == 0) return 0;
    return @as(f64, @floatFromInt(row.wall_ns_p50)) / @as(f64, @floatFromInt(row.ops_per_iteration));
}

fn findRow(rows: []const framework.ResultRow, name: []const u8) ?framework.ResultRow {
    for (rows) |r| {
        if (std.mem.eql(u8, r.scenario_name, name)) return r;
    }
    return null;
}

fn readDocument(
    allocator: std.mem.Allocator,
    io: Io,
    path: []const u8,
) !std.json.Parsed(framework.ResultDocument) {
    const bytes = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
    return std.json.parseFromSlice(
        framework.ResultDocument,
        allocator,
        bytes,
        .{ .ignore_unknown_fields = true },
    );
}

fn fileExists(io: Io, path: []const u8) bool {
    var f = Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    f.close(io);
    return true;
}
