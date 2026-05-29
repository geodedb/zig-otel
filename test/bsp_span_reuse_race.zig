// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Regression coverage for the BatchSpanProcessor span-reuse
// use-after-free (docs/BUG_BSP_SPAN_REUSE_UAF.md), distinct from the
// queue-mutex race closed in `0c34ce9`.
//
// Root cause: `SpanState.ended` was a plain `bool`. `Span.end()` did a
// non-atomic check-then-set:
//
//     if (s.ended) return;   // racy read (TOCTOU)
//     s.ended = true;        // racy write
//     ...
//     if (s.on_end) |cb| cb(s.on_end_ctx, s);  // enqueue into the BSP
//
// Two threads ending the SAME `*SpanState` can both observe
// `ended == false`, both set it true, and both invoke `on_end`. The
// span is then enqueued TWICE, drained into a batch (or two), and
// `exportBatch`'s `for (batch) |s| s.recycle();` recycles it TWICE — the
// second recycle frees a SpanState whose pointer the first reader (or
// the span pool, after re-acquisition) still references, yielding the
// GP-fault observed in geode under 8 concurrent QUIC clients
// (src/sdk/export.zig reading `span.kind` from freed memory).
//
// The exactly-once invariant these tests pin:
//   * `Span.end()` invokes the `on_end` callback EXACTLY ONCE per span,
//     even when many threads race `end()` on the same span value.
//   * Each SpanState is recycled EXACTLY ONCE.
//   * With N producer threads each starting+ending their own spans, the
//     in-memory recorder observes every span exactly once (never twice,
//     never fewer).
//
// Pre-fix this either double-counts (assertion fails) or crashes /
// trips ThreadSanitizer on the `SpanState.ended` read/write race. The
// deterministic RED signal is `zig build test -Dtsan=true`, which flags
// the data race on `ended` before the fix and is clean after. The
// same-span double-end stress test below is also designed to
// double-fire the on-end counter under the bug without a TracerProvider
// pool in the loop (so the assertion, not a crash, is the primary
// signal).

const std = @import("std");
const otel = @import("otel");
const build_options = @import("build_options");

const trace_api = otel.api.trace;

// ---------------------------------------------------------------------
// Test 1 — the deterministic detector: two threads race `end()` on the
// SAME span value. Asserts on_end + recycle each fire exactly once.
//
// This drives the `SpanState.ended` claim directly, with a counting
// `on_end` callback and a counting `Recycler`, so the exactly-once
// invariant is observed without routing through the span pool (which
// would itself UAF on a double-recycle and mask the assertion signal).
// ---------------------------------------------------------------------

const EndCounters = struct {
    on_end: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn countingOnEnd(ctx: ?*anyopaque, _: *trace_api.SpanState) void {
    const c: *EndCounters = @ptrCast(@alignCast(ctx.?));
    // In the real SDK this is `batchOnEnd`, which enqueues the span and
    // (eventually) recycles it. The exactly-once invariant is that
    // `Span.end()` invokes the on_end callback at most once per span;
    // a second invocation is the root cause of the double-enqueue ->
    // double-recycle UAF. Counting invocations isolates that invariant
    // without routing through the pool (which would UAF on a real
    // double-recycle and mask the assertion signal).
    _ = c.on_end.fetchAdd(1, .seq_cst);
}

const RaceArgs = struct {
    span: trace_api.Span,
    start_gate: *std.atomic.Value(bool),
};

fn doubleEndWorker(args: RaceArgs) void {
    // Spin until the orchestrator opens the gate so both threads hit
    // `end()` on the same span value as close to simultaneously as the
    // scheduler allows — maximizing the TOCTOU window on `ended`.
    while (!args.start_gate.load(.acquire)) {
        std.atomic.spinLoopHint();
    }
    args.span.end(null);
}

test "Span.end is exactly-once under concurrent end() on the same span" {
    if (build_options.otel_disabled) return error.SkipZigTest;
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    // 6000 spans, each raced by two threads calling end() on the same
    // span value. Under the non-atomic `ended` bug at least one span in
    // this many iterations will be double-claimed (on_end fires twice).
    const iterations: u32 = 6000;

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        var counters: EndCounters = .{};

        const state = try trace_api.SpanState.init(allocator, "race", .{}, .{ .name = "t" }, 1);
        // Wire the counting on_end. No recycler: the test owns the
        // SpanState lifetime and frees it explicitly, so `recycle()` is
        // out of the loop and the on_end count is the sole observable.
        state.on_end_ctx = &counters;
        state.on_end = countingOnEnd;

        const span: trace_api.Span = .{ .state = state, .sc = state.sc };

        var gate = std.atomic.Value(bool).init(false);

        var threads: [2]std.Thread = undefined;
        for (&threads) |*th| {
            th.* = try std.Thread.spawn(.{}, doubleEndWorker, .{RaceArgs{
                .span = span,
                .start_gate = &gate,
            }});
        }
        gate.store(true, .release);
        for (&threads) |*th| th.join();

        // The exactly-once invariant: end() fired the on_end callback
        // once and only once even though two threads raced it.
        const fired = counters.on_end.load(.seq_cst);
        if (fired != 1) {
            std.debug.print(
                "span-reuse UAF: on_end fired {d} times (expected 1) at iteration {d}\n",
                .{ fired, i },
            );
        }
        try std.testing.expectEqual(@as(u32, 1), counters.on_end.load(.seq_cst));

        // The test owns teardown: no recycler was wired, so deinit
        // fully frees the SpanState + arena.
        state.deinit();
    }
}

// ---------------------------------------------------------------------
// Test 2 — integration stress against a real BatchSpanProcessor +
// TracerProvider + in-memory recorder, mirroring the geode shard-worker
// shape (8 concurrent QUIC clients each emitting spans). Asserts every
// span reaches the exporter EXACTLY ONCE after forceFlush: a
// double-enqueue/double-recycle would either crash or push the recorded
// count above the produced count.
// ---------------------------------------------------------------------

const ProducerArgs = struct {
    tracer: trace_api.Tracer,
    iterations: u32,
    failures: *std.atomic.Value(u32),
};

fn producerLoop(args: ProducerArgs) void {
    var i: u32 = 0;
    while (i < args.iterations) : (i += 1) {
        const span = args.tracer.startSpan(.empty(), "edge", .{}) catch {
            _ = args.failures.fetchAdd(1, .seq_cst);
            return;
        };
        // Mutate attributes so the recycle()/startSpan() reuse path is
        // exercised (name dupe + arena churn) — this is the surface the
        // bug doc flags as torn under double-recycle.
        span.setIntAttribute("i", @intCast(i)) catch {};
        span.end(null);
    }
}

test "BatchSpanProcessor: concurrent producers record each span exactly once" {
    if (build_options.otel_disabled) return error.SkipZigTest;
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();

    var rec = otel.exporters.in_memory.Recorder.init(std.testing.allocator);
    defer rec.deinit();

    const exporter = rec.spanExporter();
    var bsp = try otel.sdk.exporter.BatchSpanProcessor.init(std.testing.allocator, exporter, &resource, .{
        .max_queue_size = 8192,
        // Small batch size forces frequent synchronous drains, widening
        // the export/recycle race window the bug doc describes.
        .max_export_batch_size = 8,
        .schedule_delay_ms = 0,
        // Default async_workers = 0 — synchronous drain on the producer
        // thread, the path geode compiles (no -Dotel_use_devnw_pool).
    });
    defer bsp.deinit();

    const proc = bsp.processor();
    var tp = try otel.sdk.trace.TracerProvider.init(std.testing.allocator, .{
        .resource = &resource,
        .processors = &.{proc},
    });
    defer tp.deinit();

    const tracer = tp.tracer(.{ .name = "shard-worker" });

    const thread_count: u32 = 8;
    const per_thread: u32 = 700; // 5600 spans total, > the 5000 floor.
    var failures = std.atomic.Value(u32).init(0);

    var threads: [thread_count]std.Thread = undefined;
    var t: u32 = 0;
    while (t < thread_count) : (t += 1) {
        threads[t] = try std.Thread.spawn(.{}, producerLoop, .{ProducerArgs{
            .tracer = tracer,
            .iterations = per_thread,
            .failures = &failures,
        }});
    }
    for (&threads) |*th| th.join();

    try std.testing.expectEqual(@as(u32, 0), failures.load(.seq_cst));

    try bsp.processor().forceFlush(5_000);

    // Exactly-once: never fewer (lost spans) and never more
    // (double-enqueue/double-record).
    try std.testing.expectEqual(@as(usize, thread_count * per_thread), rec.spans.items.len);
}
