// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// PR-1 (#135) regression coverage for `MeterProvider.pointFor` /
// `collect()` concurrency.
//
// On `main` (pre-fix), `pointFor` mutates `inst.points` and
// `inst.points_index` without any synchronisation. Two writers racing
// on a fingerprint miss can:
//   - Tear the underlying ArrayList during `append` (header observed
//     mid-grow by a second writer).
//   - Leave one writer holding `&inst.points.items[idx]` after the
//     other writer's append moved the backing memory (UAF on the
//     subsequent `pt.value` mutation).
//   - Double-insert the same fingerprint into `points_index`, producing
//     two AggregatedPoints for one attribute set and silently splitting
//     totals.
//
// `collect()` reading `inst.points.items` while a writer is mid-grow
// is the third axis of the same race.
//
// These tests pin the post-fix invariants:
//   1. Single-threaded shape stability across many fingerprint
//      insertions (catches any regression of the in-place grow
//      sequencing inside `pointFor`).
//   2. Two-writer stress: two threads × N records on disjoint
//      attribute sets, total count must equal 2*N with no panics or
//      memory corruption.
//   3. Writer + collector stress: one writer thread records while the
//      main thread repeatedly snapshots via `collect()`. The terminal
//      snapshot must observe every record, no torn AttributeSet, and
//      no use-after-free on the snapshot pointers.

const std = @import("std");
const otel = @import("otel");

const sdk_metrics = otel.sdk.metrics;
const sdk_resource = otel.sdk.resource;
const attrs = otel.internal.attributes;

// Single-threaded baseline. Without the fix this still passes (the bug
// is purely concurrent), but it locks down the shape so later edits to
// `pointFor` cannot accidentally regress the fingerprint-index
// bookkeeping. The acceptance criteria explicitly call out a
// "shape-stable" floor test.
test "pointFor: shape stable across many fingerprint inserts" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var resource = try sdk_resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try sdk_metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const m = mp.meter(.{ .name = "shape" });
    const c = try m.counter(.{ .name = "events", .kind = .counter });

    // 256 distinct attribute sets, each recorded twice. Every record
    // path must end with exactly 256 points and the per-point sum of 2.
    var i: u32 = 0;
    while (i < 256) : (i += 1) {
        var key_buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "k{d}", .{i});
        const e: attrs.Entry = .{ .key = key, .value = .{ .int = @intCast(i) } };
        c.add(1, &.{e});
        c.add(1, &.{e});
    }

    const snap = try sdk_metrics.collect(&mp, std.testing.allocator);
    defer sdk_metrics.freeSnapshot(std.testing.allocator, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqual(@as(usize, 256), snap[0].points.len);
    var total: i64 = 0;
    for (snap[0].points) |p| total += p.value.number.int;
    try std.testing.expectEqual(@as(i64, 512), total);
}

const RecorderArgs = struct {
    counter: otel.api.metrics.Counter,
    iterations: u64,
    thread_id: u32,
    failures: *std.atomic.Value(u32),
};

fn recorderThread(args: RecorderArgs) void {
    var i: u64 = 0;
    while (i < args.iterations) : (i += 1) {
        // Disjoint attribute sets per thread so post-fix the points
        // slice grows from both writers without contention on the same
        // fingerprint. This is the harder case for the race: every
        // call goes down the miss path and exercises the append +
        // index insert.
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "t{d}-k{d}", .{ args.thread_id, i }) catch {
            _ = args.failures.fetchAdd(1, .seq_cst);
            return;
        };
        const e: attrs.Entry = .{ .key = key, .value = .{ .int = @intCast(i) } };
        args.counter.add(1, &.{e});
    }
}

// Two-writer stress. Without the fix this regularly trips one of:
//   - `panic: index out of bounds` inside ArrayList.append when both
//     threads observe the same `len` and write past `capacity`.
//   - Lost increments (final point count < 2*N) because the
//     fingerprint index map dropped a write under concurrent put.
//   - Test allocator double-free at deinit because two AggregatedPoint
//     entries shared an `attribute_key` slice.
// Post-fix the invariant is: no panic, exactly 2*N points, sum == 2*N.
test "pointFor: two writers no torn state" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    if (!std.Thread.use_pthreads and @import("builtin").single_threaded) return error.SkipZigTest;

    var resource = try sdk_resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try sdk_metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const m = mp.meter(.{ .name = "race" });
    const c = try m.counter(.{ .name = "events", .kind = .counter });

    const iters: u64 = 512;
    var failures = std.atomic.Value(u32).init(0);

    var t0 = try std.Thread.spawn(.{}, recorderThread, .{RecorderArgs{
        .counter = c,
        .iterations = iters,
        .thread_id = 0,
        .failures = &failures,
    }});
    var t1 = try std.Thread.spawn(.{}, recorderThread, .{RecorderArgs{
        .counter = c,
        .iterations = iters,
        .thread_id = 1,
        .failures = &failures,
    }});
    t0.join();
    t1.join();

    try std.testing.expectEqual(@as(u32, 0), failures.load(.seq_cst));

    const snap = try sdk_metrics.collect(&mp, std.testing.allocator);
    defer sdk_metrics.freeSnapshot(std.testing.allocator, snap);
    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqual(@as(usize, 2 * iters), snap[0].points.len);

    var total: i64 = 0;
    for (snap[0].points) |p| total += p.value.number.int;
    try std.testing.expectEqual(@as(i64, 2 * iters), total);
}

const WriterCtx = struct {
    counter: otel.api.metrics.Counter,
    iterations: u64,
    stop: *std.atomic.Value(bool),
};

fn writerLoop(ctx: WriterCtx) void {
    var i: u64 = 0;
    while (i < ctx.iterations) : (i += 1) {
        if (ctx.stop.load(.seq_cst)) break;
        var key_buf: [32]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "w-k{d}", .{i}) catch return;
        const e: attrs.Entry = .{ .key = key, .value = .{ .int = @intCast(i) } };
        ctx.counter.add(1, &.{e});
    }
}

// Writer + collector stress. Without the fix `collect()` walks
// `inst.points.items` while a writer can grow the slice — the loop
// reads through dangling memory and either panics or returns a
// snapshot with corrupted attribute sets. Post-fix `collect()` takes
// the per-instrument lock, snapshots the points (deep-copying any
// borrow-sensitive payload), then releases it before encoding.
test "pointFor: collect concurrent with record observes consistent points" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var resource = try sdk_resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try sdk_metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const m = mp.meter(.{ .name = "race" });
    const c = try m.counter(.{ .name = "events", .kind = .counter });

    const iters: u64 = 1024;
    var stop = std.atomic.Value(bool).init(false);

    var writer = try std.Thread.spawn(.{}, writerLoop, .{WriterCtx{
        .counter = c,
        .iterations = iters,
        .stop = &stop,
    }});

    // Drive ~50 collect snapshots while the writer races. Each must
    // succeed (the points may be at any intermediate count) and must
    // not crash, double-free, or report a torn point count.
    var rounds: u32 = 0;
    while (rounds < 50) : (rounds += 1) {
        const snap = try sdk_metrics.collect(&mp, std.testing.allocator);
        defer sdk_metrics.freeSnapshot(std.testing.allocator, snap);
        if (snap.len > 0) {
            // Every observed point must have a non-null attributes
            // borrow and a coherent value tag (int variant for a
            // counter). A torn read on `main` shows up here as a
            // segfault dereferencing a moved AttributeSet pointer or
            // an unreachable union tag.
            for (snap[0].points) |p| {
                try std.testing.expect(p.attributes != null);
                try std.testing.expectEqual(@as(i64, 1), p.value.number.int);
            }
        }
        std.Thread.yield() catch {};
    }

    writer.join();

    const final = try sdk_metrics.collect(&mp, std.testing.allocator);
    defer sdk_metrics.freeSnapshot(std.testing.allocator, final);
    try std.testing.expectEqual(@as(usize, 1), final.len);
    try std.testing.expectEqual(@as(usize, iters), final[0].points.len);
    var total: i64 = 0;
    for (final[0].points) |p| total += p.value.number.int;
    try std.testing.expectEqual(@as(i64, iters), total);
}
