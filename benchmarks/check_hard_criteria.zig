// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

//! Hard-criterion check for the zero-overhead-when-disabled bench
//! system **and** the runtime hot-path SLO gate. Reads up to three
//! ResultDocument JSON files:
//!
//!   --ref-a   produced by `-Dotel_disabled=false` (comparison layer)
//!   --ref-b   produced by `-Dotel_disabled=true`  (comparison layer)
//!   --micro   produced by `zig build bench-micro` (micro layer)
//!
//! Verifies the architecture-document hard criteria:
//!
//!   1. `comptime-disabled` ns/op (in ref-B) is within `+2 ns` of
//!      `baseline-no-call` ns/op (in ref-B). Per-op allocations in the
//!      timed loop must be `~0` (allowed setup tolerance: 100 bytes
//!      across all sampled rounds, since the body still constructs a
//!      provider once per iteration).
//!   2. `level-1-tracer-noop` ns/op (in ref-A) is within `+5 ns` of
//!      `baseline-no-call` ns/op (in ref-A). alloc_count must be 0.
//!
//! And the runtime SLO criteria from `docs/performance/SLO.md`
//! (PERF-SLO-DEFINE, gitlab #167) — gated against the `--micro` JSON
//! when supplied:
//!
//!   3. `micro_attr_put_update` p99 ≤ 50 ns/op. Current floor is
//!      ~32 ns/op (post-P0-1); the gate carries ~1.6× headroom over
//!      the verified baseline at
//!      `docs/performance/2026-04-26-p0-4-pointfor/results/after.json`
//!      (319 234 ns p99 / 10 000 ops). Trips on a regression that
//!      doubles per-attr-update cost.
//!   4. `micro_counter_add_4_attrs_hit` allocs/op ≤ 0.005. Current
//!      floor is 0.0015 allocs/op (15 setup allocs amortized over
//!      10 000 record calls — same baseline file). Trips if the
//!      MeterProvider.pointFor hit-path regresses back to per-op
//!      allocations (PR-1, gitlab #135).
//!
//! Exits non-zero on any violation. Missing input files are tolerated
//! (each missing path skips its rules, exits 0 with a "no inputs yet"
//! notice for *each* skipped group) so the step is safe to wire into
//! bench-ci before the AB runner has produced any output.

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

/// Runtime SLO: per-attr-update p99 latency ceiling. Post-P0-1
/// measured baseline is ~31.9 ns/op
/// (`micro_attr_put_update`: p99 = 319 234 ns at 10 000 ops/iter).
/// The 50 ns/op gate carries ~1.6× headroom — strict enough to catch
/// a real regression, loose enough to absorb noise from a shared
/// runner. See `docs/performance/SLO.md` row "attr-update p99".
const attr_put_update_max_ns_per_op: f64 = 50.0;

/// Runtime SLO: counter-add hot path alloc/op ceiling. Post-PR-1 +
/// post-P0-4 measured baseline is 0.0015 allocs/op
/// (15 setup-amortized allocs across 10 000 `Counter.add` ops in the
/// `micro_counter_add_4_attrs_hit` scenario). 0.005 caps regressions
/// that push the call-site itself back to per-op allocation.
const counter_add_4_attrs_hit_max_alloc_per_op: f64 = 0.005;

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
    var micro_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--ref-a") and i + 1 < args.len) {
            ref_a_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--ref-b") and i + 1 < args.len) {
            ref_b_path = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--micro") and i + 1 < args.len) {
            micro_path = args[i + 1];
            i += 1;
        }
    }

    var failures: u32 = 0;
    var any_inputs: bool = false;

    // ------------------------------------------------------------------
    // Comptime / level-1 rules — gated on ref-A + ref-B.
    // ------------------------------------------------------------------
    if (ref_a_path != null and ref_b_path != null and
        fileExists(init.io, ref_a_path.?) and fileExists(init.io, ref_b_path.?))
    {
        any_inputs = true;
        const ref_a = try readDocument(allocator, init.io, ref_a_path.?);
        const ref_b = try readDocument(allocator, init.io, ref_b_path.?);

        // Rule 1: comptime-disabled must be ~free under flag=true.
        if (try checkDeltaRule(
            stderr,
            "comptime-disabled (flag=true) <= baseline-no-call (flag=true) + 2 ns",
            ref_b.value.rows,
            "comptime-disabled",
            "baseline-no-call",
            comptime_delta_ns_max,
            comptime_alloc_per_op_max,
        )) |violated| if (violated) {
            failures += 1;
        };

        // Rule 2: level-1-tracer-noop must be ~free under flag=false.
        if (try checkDeltaRule(
            stderr,
            "level-1-tracer-noop (flag=false) <= baseline-no-call (flag=false) + 5 ns",
            ref_a.value.rows,
            "level-1-tracer-noop",
            "baseline-no-call",
            level1_delta_ns_max,
            0.0,
        )) |violated| if (violated) {
            failures += 1;
        };
    } else if (ref_a_path != null or ref_b_path != null) {
        try stderr.print("hard-criterion-check: ref-A/ref-B inputs incomplete (a={?s}, b={?s}); skipping comptime + level-1 rules\n", .{ ref_a_path, ref_b_path });
        try stderr.flush();
    }

    // ------------------------------------------------------------------
    // Runtime SLO rules — gated on the bench-micro JSON.
    // PERF-SLO-DEFINE (gitlab #167): see docs/performance/SLO.md.
    // ------------------------------------------------------------------
    if (micro_path != null and fileExists(init.io, micro_path.?)) {
        any_inputs = true;
        const micro = try readDocument(allocator, init.io, micro_path.?);

        // Rule 3: attr-update p99 latency ceiling.
        if (try checkLatencyRule(
            stderr,
            "micro_attr_put_update p99 <= 50 ns/op (PERF-SLO #167)",
            micro.value.rows,
            "micro_attr_put_update",
            attr_put_update_max_ns_per_op,
        )) |violated| if (violated) {
            failures += 1;
        };

        // Rule 4: counter-add hit-path alloc/op ceiling.
        if (try checkAllocRule(
            stderr,
            "micro_counter_add_4_attrs_hit allocs/op <= 0.005 (PERF-SLO #167)",
            micro.value.rows,
            "micro_counter_add_4_attrs_hit",
            counter_add_4_attrs_hit_max_alloc_per_op,
        )) |violated| if (violated) {
            failures += 1;
        };
    } else if (micro_path != null) {
        try stderr.print("hard-criterion-check: --micro path missing ({s}); skipping runtime SLO rules\n", .{micro_path.?});
        try stderr.flush();
    }

    if (!any_inputs) {
        try stderr.writeAll("hard-criterion-check: no --ref-a / --ref-b / --micro paths supplied; skipping\n");
        try stderr.flush();
        return;
    }

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
fn checkDeltaRule(
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
        "  [{s}] {s}: target={d:.3} ns/op  baseline={d:.3} ns/op  delta={s}{d:.3} ns  allocs/op={d:.5}  ({d} allocs over {d} ops/iter)\n",
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

/// PERF-SLO #167: absolute latency ceiling against the p99 wall time
/// per op. Returns `true` if violated, `false` if passed, `null` if
/// the scenario is not present in `rows`.
fn checkLatencyRule(
    out: *Io.Writer,
    label: []const u8,
    rows: []const framework.ResultRow,
    target_scenario: []const u8,
    max_p99_ns_per_op: f64,
) !?bool {
    const target = findRow(rows, target_scenario) orelse {
        try out.print("  [SKIP] {s}: scenario '{s}' missing from results\n", .{ label, target_scenario });
        try out.flush();
        return null;
    };

    const p99_ns_per_op = p99NsPerOp(target);
    const ok = p99_ns_per_op <= max_p99_ns_per_op;

    try out.print(
        "  [{s}] {s}: p99={d:.3} ns/op  ceiling={d:.3} ns/op  ({d} ns p99 over {d} ops/iter)\n",
        .{
            if (ok) "PASS" else "FAIL",
            label,
            p99_ns_per_op,
            max_p99_ns_per_op,
            target.wall_ns_p99,
            target.ops_per_iteration,
        },
    );
    try out.flush();
    return !ok;
}

/// PERF-SLO #167: absolute alloc-per-op ceiling. Returns `true` if
/// violated, `false` if passed, `null` if the scenario is not present
/// in `rows`.
fn checkAllocRule(
    out: *Io.Writer,
    label: []const u8,
    rows: []const framework.ResultRow,
    target_scenario: []const u8,
    max_alloc_per_op: f64,
) !?bool {
    const target = findRow(rows, target_scenario) orelse {
        try out.print("  [SKIP] {s}: scenario '{s}' missing from results\n", .{ label, target_scenario });
        try out.flush();
        return null;
    };

    const alloc_per_op = allocPerOp(target);
    const ok = alloc_per_op <= max_alloc_per_op;

    try out.print(
        "  [{s}] {s}: allocs/op={d:.5}  ceiling={d:.5}  ({d} allocs over {d} ops/iter)\n",
        .{
            if (ok) "PASS" else "FAIL",
            label,
            alloc_per_op,
            max_alloc_per_op,
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

fn p99NsPerOp(row: framework.ResultRow) f64 {
    if (row.ops_per_iteration == 0) return 0;
    return @as(f64, @floatFromInt(row.wall_ns_p99)) / @as(f64, @floatFromInt(row.ops_per_iteration));
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
