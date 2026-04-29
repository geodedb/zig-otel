// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Regression coverage for the BatchSpanProcessor concurrent-producer
// race exposed in the synchronous-drain (default `-Dotel_use_devnw_pool=false`)
// build.
//
// On `main` (pre-fix), `BatchSpanProcessor.QueueMutex` collapsed to a
// no-op stub when the async pool was off — based on the assumption that
// only a single producer thread ever calls `onEnd`. Real consumers
// (e.g. geode's shard-worker pool) violate that: many threads call
// `Span.end()` concurrently, and `batchOnEnd` then races on:
//
//   - `self.queue.append(self.allocator, span)` — two writers can
//     observe the same `len`, write past `capacity`, or race the
//     realloc that grows the backing buffer (UAF on the loser's
//     items pointer).
//   - The synchronous drain `drainLocked()` at export.zig:330
//     (`@memcpy(out, self.queue.items[0..n])`) reads the items array
//     while another producer is appending — torn read of the slice.
//   - `self.exportBatch(batch)` calls `self.exporter.exportSpans()`
//     concurrently for unrelated batches when `export_mutex` is also
//     a no-op, breaking the per-call serialization that downstream
//     non-thread-safe exporters (the in-memory recorder, OTLP/HTTP,
//     etc.) rely on.
//
// Post-fix the invariant is: with N producer threads × M spans each,
// every span reaches the exporter exactly once after `forceFlush`.
// The test runs without `-Dotel_use_devnw_pool` (default off) so it
// pins the synchronous-drain code path that geode actually compiles.

const std = @import("std");
const otel = @import("otel");
const build_options = @import("build_options");

const ProducerArgs = struct {
    tracer: otel.api.trace.Tracer,
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
        span.end(null);
    }
}

// 8 producer threads × 250 spans each = 2000 spans total. The batch
// size (64) and queue size (4096) are picked so the synchronous-drain
// path triggers many times during the run — that is the pre-fix race
// window. `forceFlush` must observe every span post-fix.
test "BatchSpanProcessor: concurrent producers do not lose or duplicate spans" {
    if (build_options.otel_disabled) return error.SkipZigTest;
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();

    var rec = otel.exporters.in_memory.Recorder.init(std.testing.allocator);
    defer rec.deinit();

    const exporter = rec.spanExporter();
    var bsp = try otel.sdk.exporter.BatchSpanProcessor.init(std.testing.allocator, exporter, &resource, .{
        .max_queue_size = 4096,
        .max_export_batch_size = 64,
        .schedule_delay_ms = 0,
        // Default async_workers = 0 — synchronous drain on the producer thread.
        // This is the path that geode and other no-pool consumers compile.
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
    const per_thread: u32 = 250;
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
    try std.testing.expectEqual(@as(usize, thread_count * per_thread), rec.spans.items.len);
}
