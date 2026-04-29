// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Exporter contracts and processor primitives shared across signals.
//
// Each signal (traces, metrics, logs, profiles) has its own typed exporter
// that wraps a vtable. Processors own buffering, retries, and worker
// lifecycles; exporters only encode and ship a single batch.

const std = @import("std");
const trace_api = @import("../api/trace.zig");
const metrics_api = @import("../api/metrics.zig");
const logs_api = @import("../api/logs.zig");
const attrs_mod = @import("../internal/attributes.zig");
const Resource = @import("resource.zig").Resource;
const clock_mod = @import("../internal/clock.zig");
const build_options = @import("build_options");

// Comptime-conditional thread-pool import. Mirrors the slog/metrics
// pattern: when the build flag is off the alias is an empty struct so
// every reference in this file is gated behind the same `if` check and
// dead-code-eliminated.
const tp = if (build_options.use_devnw_pool) @import("thread_pool") else struct {};
const internal_sync = @import("../internal/sync.zig");

// ---------------------------------------------------------------- Span export

pub const SpanData = struct {
    name: []const u8,
    span_context: @import("../api/context.zig").SpanContext,
    parent_span_id: @import("../internal/id.zig").SpanId = .invalid,
    kind: trace_api.SpanKind = .internal,
    start_unix_nano: u64,
    end_unix_nano: u64,
    status_code: trace_api.StatusCode = .unset,
    status_description: []const u8 = "",
    attributes: *const attrs_mod.AttributeSet,
    events: []const trace_api.Event,
    links: []const trace_api.Link,
    instrumentation_scope: trace_api.InstrumentationScope,
    resource: *const Resource,
    dropped_attributes_count: u32 = 0,
    dropped_events_count: u32 = 0,
    dropped_links_count: u32 = 0,
};

pub const SpanExportResult = enum { success, partial_success, failure };

pub const SpanExporter = struct {
    ctx: ?*anyopaque,
    exportFn: *const fn (?*anyopaque, []const SpanData) anyerror!SpanExportResult,
    shutdownFn: *const fn (?*anyopaque) void,
    forceFlushFn: *const fn (?*anyopaque, u64) anyerror!void,

    pub fn exportSpans(self: SpanExporter, items: []const SpanData) !SpanExportResult {
        return try self.exportFn(self.ctx, items);
    }

    pub fn shutdown(self: SpanExporter) void {
        self.shutdownFn(self.ctx);
    }

    pub fn forceFlush(self: SpanExporter, timeout_ms: u64) !void {
        try self.forceFlushFn(self.ctx, timeout_ms);
    }
};

pub const SpanProcessor = struct {
    ctx: ?*anyopaque,
    onEndFn: *const fn (?*anyopaque, *trace_api.SpanState) void,
    forceFlushFn: *const fn (?*anyopaque, u64) anyerror!void,
    shutdownFn: *const fn (?*anyopaque) void,

    pub fn onEnd(self: SpanProcessor, span: *trace_api.SpanState) void {
        self.onEndFn(self.ctx, span);
    }

    pub fn forceFlush(self: SpanProcessor, timeout_ms: u64) !void {
        try self.forceFlushFn(self.ctx, timeout_ms);
    }

    pub fn shutdown(self: SpanProcessor) void {
        self.shutdownFn(self.ctx);
    }
};

/// Synchronous span processor — calls the exporter inline on `onEnd`.
/// Suitable for tests, the in-memory exporter, and short-lived CLIs.
pub const SimpleSpanProcessor = struct {
    allocator: std.mem.Allocator,
    exporter: SpanExporter,
    resource_ref: *const Resource,

    pub fn init(allocator: std.mem.Allocator, exporter: SpanExporter, resource_ref: *const Resource) SimpleSpanProcessor {
        return .{ .allocator = allocator, .exporter = exporter, .resource_ref = resource_ref };
    }

    pub fn processor(self: *SimpleSpanProcessor) SpanProcessor {
        return .{ .ctx = self, .onEndFn = simpleOnEnd, .forceFlushFn = simpleForceFlush, .shutdownFn = simpleShutdown };
    }
};

fn simpleOnEnd(ctx: ?*anyopaque, span: *trace_api.SpanState) void {
    const self: *SimpleSpanProcessor = @ptrCast(@alignCast(ctx.?));
    defer span.recycle();
    const data: SpanData = .{
        .name = span.name,
        .span_context = span.sc,
        .parent_span_id = span.parent_span_id,
        .kind = span.kind,
        .start_unix_nano = span.start_unix_nano,
        .end_unix_nano = span.end_unix_nano orelse span.start_unix_nano,
        .status_code = span.status_code,
        .status_description = span.status_description,
        .attributes = &span.attributes,
        .events = span.events.items,
        .links = span.links.items,
        .instrumentation_scope = span.instrumentation_scope,
        .resource = self.resource_ref,
        .dropped_attributes_count = span.attributes.dropped,
    };
    _ = self.exporter.exportSpans(&[_]SpanData{data}) catch {};
}

fn simpleForceFlush(ctx: ?*anyopaque, timeout_ms: u64) anyerror!void {
    const self: *SimpleSpanProcessor = @ptrCast(@alignCast(ctx.?));
    try self.exporter.forceFlush(timeout_ms);
}

fn simpleShutdown(ctx: ?*anyopaque) void {
    const self: *SimpleSpanProcessor = @ptrCast(@alignCast(ctx.?));
    self.exporter.shutdown();
}

/// Batched span processor — buffers spans and dispatches them on
/// `forceFlush` or when the queue reaches `max_export_batch_size`. The
/// 0.16 stdlib moved background coordination behind the `std.Io`
/// interface; until callers wire an `Io` instance through, the processor
/// runs synchronously on the producer thread. Spec ordering and
/// drop-count semantics are preserved.
pub const BatchSpanProcessorOptions = struct {
    max_queue_size: usize = 2048,
    max_export_batch_size: usize = 512,
    schedule_delay_ms: u64 = 5_000,
    /// Maximum time (ms) to wait for any single export call before
    /// returning `error.ExportTimeout`. Mirrors the spec's
    /// `OTEL_BSP_EXPORT_TIMEOUT` knob and the runtime `forceFlush`
    /// timeout used by callers. Default 30_000ms per the spec.
    /// GAP-ENV-BSP (#33).
    export_timeout_ms: u64 = 30_000,
    /// 0 keeps the synchronous drain. >0 spawns a DevNW thread-pool with
    /// the given worker count when `-Dotel_use_devnw_pool=true`. The
    /// option is silently ignored (synchronous drain stays in effect)
    /// when the build flag is off so callers can set it unconditionally.
    async_workers: u32 = 0,
};

/// Optional thread-pool handle. Only present when
/// `build_options.use_devnw_pool == true` and `options.async_workers > 0`.
/// The conditional type keeps the `?*tp.ThreadPool` field absent (well,
/// `?*void`-sized) in builds compiled with the flag off so the
/// synchronous-drain hot path is untouched.
const PoolHandle = if (build_options.use_devnw_pool) ?*tp.ThreadPool else ?*void;

/// Queue mutex. Real on both build paths because `onEnd` can be called
/// concurrently from many producer threads (e.g. a shard-worker pool
/// fanning span emission across cores) regardless of whether the BSP
/// drains synchronously or via the DevNW thread-pool. The previous
/// no-op fallback assumed a single producer thread and let
/// `std.ArrayList(...).append` race on the synchronous-drain path,
/// corrupting `queue.items` and tearing the `@memcpy(out, items[0..n])`
/// inside `drainLocked`. The thread-pool's `sync.Mutex` wraps
/// `std.Io.Mutex` with the legacy zero-arg API so we don't have to
/// plumb an `io` through the processor surface; the no-pool path uses
/// `internal/sync.zig`'s `Mutex` (a thin local wrapper around
/// `std.Io.Mutex.lockUncancelable`) to keep the same zero-arg shape
/// without taking on the thread-pool import.
const QueueMutex = if (build_options.use_devnw_pool) tp.sync.Mutex else internal_sync.Mutex;

/// Flush-completion condition variable. `batchForceFlush` waits on it
/// instead of busy-polling; workers broadcast when they decrement
/// `pending_tasks`. Reduces wake-up latency from the legacy 200µs poll
/// floor (F-3) to whatever the OS futex round-trip costs (low µs on
/// Linux). Compiles to an empty stub when the async pool is off, since
/// the synchronous-drain path doesn't need to wait on workers.
const FlushCond = if (build_options.use_devnw_pool) tp.sync.Condition else struct {};

pub const BatchSpanProcessor = struct {
    allocator: std.mem.Allocator,
    exporter: SpanExporter,
    resource_ref: *const Resource,
    options: BatchSpanProcessorOptions,
    queue: std.ArrayList(*trace_api.SpanState),
    /// Guards `queue` + `dropped` when the async worker is enabled.
    /// Becomes a zero-cost no-op stub when the pool flag is off (only
    /// the producer thread touches the queue in that mode).
    mutex: QueueMutex = .{},
    /// Serializes exporter invocations across drain tasks. Many
    /// downstream `SpanExporter` impls (the in-memory recorder, the
    /// stdout JSON writer, the OTLP/HTTP path) are not thread-safe, and
    /// the spec only requires that batch ordering be preserved per
    /// export call — concurrent exports would also break per-attempt
    /// retry accounting. The mutex is uncontended in single-worker
    /// configurations and only guards the cross-thread fan-out case.
    export_mutex: QueueMutex = .{},
    /// In-flight drain tasks. Incremented on submit, decremented at the
    /// tail of every worker drain. `forceFlush` waits on `flush_cond`
    /// (signaled by every drain completion) until both this counter and
    /// the queue reach zero, bounded by the timeout.
    pending_tasks: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Broadcast by every worker as it decrements `pending_tasks`.
    /// Replaces the F-3 busy-poll: `batchForceFlush` waits on this
    /// against the remaining timeout budget instead of sleeping
    /// 200µs and re-checking.
    flush_cond: FlushCond = .{},
    dropped: u32 = 0,
    /// Active iff `build_options.use_devnw_pool` *and*
    /// `options.async_workers > 0`. Owned and torn down by `deinit`.
    pool: PoolHandle = null,
    /// Periodic-drain timer thread. Spawned in `init` when
    /// `use_devnw_pool && async_workers > 0 && schedule_delay_ms > 0`;
    /// joined in `deinit`. See ADR-0002.
    timer_thread: ?std.Thread = null,
    /// Latched true by `deinit` to signal the timer thread to exit.
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Pair used to interrupt the timer's `timedWait` on shutdown so
    /// `deinit` doesn't wait for the next tick.
    shutdown_mu: QueueMutex = .{},
    shutdown_cond: FlushCond = .{},

    pub fn init(allocator: std.mem.Allocator, exporter: SpanExporter, resource_ref: *const Resource, options: BatchSpanProcessorOptions) !*BatchSpanProcessor {
        const self = try allocator.create(BatchSpanProcessor);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .exporter = exporter,
            .resource_ref = resource_ref,
            .options = options,
            .queue = .empty,
        };
        if (build_options.use_devnw_pool) {
            if (options.async_workers > 0) {
                const pool = try allocator.create(tp.ThreadPool);
                errdefer allocator.destroy(pool);
                // Configure a small pool sized to the caller's
                // `async_workers`. `default_backpressure = .block` makes
                // `submit()` wait on a full queue rather than dropping
                // spans on the producer side; the bounded-queue contract
                // (`max_queue_size`) is still enforced before we enqueue
                // a drain task, so the producer never blocks past one
                // task scheduling latency under steady-state load.
                pool.* = try tp.ThreadPool.init(allocator, .{
                    .max_threads = options.async_workers,
                    .min_threads = options.async_workers,
                    .queue_capacity = 1024,
                    .default_backpressure = .block,
                });
                self.pool = pool;

                // Start the periodic-drain timer (ADR-0002). Bound by
                // `schedule_delay_ms`; opt out by setting that to 0.
                if (options.schedule_delay_ms > 0) {
                    self.timer_thread = std.Thread.spawn(.{}, timerLoop, .{self}) catch null;
                }
            }
        }
        return self;
    }

    fn timerLoop(self: *BatchSpanProcessor) void {
        if (!build_options.use_devnw_pool) return;
        const delay_ns: u64 = self.options.schedule_delay_ms * std.time.ns_per_ms;
        while (!self.shutdown_requested.load(.acquire)) {
            self.shutdown_mu.lock();
            // timedWait may return early via spurious wakeup or a
            // shutdown broadcast. The shutdown flag check on every
            // outer-loop iteration handles both.
            self.shutdown_cond.timedWait(&self.shutdown_mu, delay_ns) catch {};
            self.shutdown_mu.unlock();

            if (self.shutdown_requested.load(.acquire)) return;

            // If the queue has anything in it, kick a drain. The
            // queue-fill trigger in `batchOnEnd` is unchanged; this
            // timer only catches under-batch-size queues that would
            // otherwise sit until the next forceFlush.
            self.mutex.lock();
            const has_items = self.queue.items.len > 0;
            self.mutex.unlock();
            if (has_items) async_pool.submitDrain(self);
        }
    }

    pub fn deinit(self: *BatchSpanProcessor) void {
        // Stop the timer first: set the shutdown flag, wake the
        // sleeping timer, and join. Order matters — the timer can
        // call `submitDrain` on the pool, so it must exit before
        // we tear the pool down.
        if (build_options.use_devnw_pool) {
            if (self.timer_thread) |t| {
                self.shutdown_requested.store(true, .release);
                self.shutdown_mu.lock();
                self.shutdown_cond.broadcast();
                self.shutdown_mu.unlock();
                t.join();
                self.timer_thread = null;
            }
        }
        // Tear down the pool next so no in-flight drain task can race
        // with the queue cleanup below. `.drain` waits for queued and
        // executing tasks; the timeout is a safety net.
        if (build_options.use_devnw_pool) {
            if (self.pool) |pool| {
                pool.shutdown(.drain, 5_000_000_000) catch {};
                pool.deinit();
                self.allocator.destroy(pool);
                self.pool = null;
            }
        }
        for (self.queue.items) |s| s.recycle();
        self.queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn processor(self: *BatchSpanProcessor) SpanProcessor {
        return .{ .ctx = self, .onEndFn = batchOnEnd, .forceFlushFn = batchForceFlush, .shutdownFn = batchShutdown };
    }

    /// Pop up to `max_export_batch_size` spans from the queue. Caller
    /// must hold `self.mutex`.
    fn drainLocked(self: *BatchSpanProcessor) ![]*trace_api.SpanState {
        const n = @min(self.queue.items.len, self.options.max_export_batch_size);
        if (n == 0) return &[_]*trace_api.SpanState{};
        const out = try self.allocator.alloc(*trace_api.SpanState, n);
        @memcpy(out, self.queue.items[0..n]);
        const rem = self.queue.items.len - n;
        std.mem.copyForwards(*trace_api.SpanState, self.queue.items[0..rem], self.queue.items[n..]);
        self.queue.shrinkRetainingCapacity(rem);
        return out;
    }

    fn exportBatch(self: *BatchSpanProcessor, batch: []*trace_api.SpanState) void {
        defer self.allocator.free(batch);
        if (batch.len == 0) return;
        const datas = self.allocator.alloc(SpanData, batch.len) catch {
            for (batch) |s| s.recycle();
            return;
        };
        defer self.allocator.free(datas);
        for (batch, 0..) |span, i| {
            datas[i] = .{
                .name = span.name,
                .span_context = span.sc,
                .parent_span_id = span.parent_span_id,
                .kind = span.kind,
                .start_unix_nano = span.start_unix_nano,
                .end_unix_nano = span.end_unix_nano orelse span.start_unix_nano,
                .status_code = span.status_code,
                .status_description = span.status_description,
                .attributes = &span.attributes,
                .events = span.events.items,
                .links = span.links.items,
                .instrumentation_scope = span.instrumentation_scope,
                .resource = self.resource_ref,
                .dropped_attributes_count = span.attributes.dropped,
            };
        }
        // Serialize the exporter call so two worker threads can't
        // simultaneously mutate a non-thread-safe `SpanExporter` (the
        // in-memory recorder, OTLP/HTTP, etc.). The lock is a no-op
        // when the pool flag is off — the producer thread is the only
        // caller in that mode.
        self.export_mutex.lock();
        _ = self.exporter.exportSpans(datas) catch {};
        self.export_mutex.unlock();
        for (batch) |s| s.recycle();
    }
};

/// Async-path helpers, lazily compiled. Referenced exclusively from
/// inside `if (build_options.use_devnw_pool)` blocks below; with the
/// flag off the namespace is empty and the symbols are never analyzed
/// (Zig 0.16's lazy evaluation of comptime-conditional branches keeps
/// the typed pool API out of the no-pool build graph).
const async_pool = if (build_options.use_devnw_pool) struct {
    /// Decrement the pending-tasks counter and wake any thread blocked
    /// in `batchForceFlush`. The `acq_rel` ordering on `fetchSub`
    /// publishes the worker's writes (queue mutations) to the waiter
    /// before the broadcast lets it observe the updated counter.
    fn drainCompleted(self: *BatchSpanProcessor) void {
        _ = self.pending_tasks.fetchSub(1, .acq_rel);
        self.flush_cond.broadcast();
    }

    fn drainTask(ctx: *anyopaque, _: *tp.TaskContext) void {
        const self: *BatchSpanProcessor = @ptrCast(@alignCast(ctx));
        self.mutex.lock();
        const batch = self.drainLocked() catch {
            self.mutex.unlock();
            drainCompleted(self);
            return;
        };
        self.mutex.unlock();
        self.exportBatch(batch);
        drainCompleted(self);
    }

    /// Submit a drain task. The pending-counter bump and decrement are
    /// always paired: bump here on the producer side, decrement at the
    /// tail of `drainTask` (or in the inline-fallback branch when
    /// `submit` fails). Both decrement paths route through
    /// `drainCompleted` so the flush waiter is always woken.
    fn submitDrain(self: *BatchSpanProcessor) void {
        const pool = self.pool orelse return;
        _ = self.pending_tasks.fetchAdd(1, .acq_rel);
        _ = pool.submit(drainTask, @ptrCast(self), .{}) catch {
            // Inline-drain fallback so the bounded queue can't grow
            // unbounded if the pool's queue is full or the descriptor
            // pool is exhausted.
            self.mutex.lock();
            const batch = self.drainLocked() catch {
                self.mutex.unlock();
                drainCompleted(self);
                return;
            };
            self.mutex.unlock();
            self.exportBatch(batch);
            drainCompleted(self);
        };
    }
} else struct {};

fn batchOnEnd(ctx: ?*anyopaque, span: *trace_api.SpanState) void {
    const self: *BatchSpanProcessor = @ptrCast(@alignCast(ctx.?));
    self.mutex.lock();
    if (self.queue.items.len >= self.options.max_queue_size) {
        self.dropped +%= 1;
        self.mutex.unlock();
        span.recycle();
        return;
    }
    self.queue.append(self.allocator, span) catch {
        self.dropped +%= 1;
        self.mutex.unlock();
        span.recycle();
        return;
    };
    const should_flush = self.queue.items.len >= self.options.max_export_batch_size;
    self.mutex.unlock();

    if (!should_flush) return;

    if (build_options.use_devnw_pool) {
        if (self.pool != null) {
            async_pool.submitDrain(self);
            return;
        }
    }

    // Synchronous drain path.
    self.mutex.lock();
    const batch = self.drainLocked() catch {
        self.mutex.unlock();
        return;
    };
    self.mutex.unlock();
    self.exportBatch(batch);
}

fn batchForceFlush(ctx: ?*anyopaque, timeout_ms: u64) anyerror!void {
    const self: *BatchSpanProcessor = @ptrCast(@alignCast(ctx.?));

    if (build_options.use_devnw_pool) {
        if (self.pool != null) {
            // Drain whatever is queued by submitting tasks, then sleep
            // on `flush_cond` until both the queue and the in-flight
            // task counter reach zero. Workers broadcast the cond at
            // the tail of every drain (see `drainCompleted`), so this
            // wakes within one futex round-trip of completion rather
            // than the legacy 200µs poll floor (F-3). Inner
            // `pool.submit` uses `.block` backpressure so submission
            // itself doesn't spin.
            const deadline_ns: i128 = @as(i128, timeout_ms) * std.time.ns_per_ms;
            const start: i128 = tp.clock.nanoTimestamp();

            self.mutex.lock();
            while (true) {
                const remaining_in_queue = self.queue.items.len;
                const pending = self.pending_tasks.load(.acquire);
                if (remaining_in_queue == 0 and pending == 0) break;

                if (remaining_in_queue > 0) {
                    // Submit drain off-lock — `submitDrain` reacquires
                    // `self.mutex` internally on the inline-fallback
                    // path, which would deadlock if we still held it.
                    self.mutex.unlock();
                    async_pool.submitDrain(self);
                    self.mutex.lock();
                    continue;
                }

                const elapsed: i128 = tp.clock.nanoTimestamp() - start;
                const remaining_ns: i128 = deadline_ns - elapsed;
                if (remaining_ns <= 0) {
                    self.mutex.unlock();
                    return error.ExportTimeout;
                }
                self.flush_cond.timedWait(&self.mutex, @intCast(remaining_ns)) catch |e| {
                    self.mutex.unlock();
                    switch (e) {
                        error.Timeout => return error.ExportTimeout,
                    }
                };
            }
            self.mutex.unlock();
            try self.exporter.forceFlush(timeout_ms);
            return;
        }
    }

    // Synchronous-drain path.
    self.mutex.lock();
    while (self.queue.items.len > 0) {
        const batch = self.drainLocked() catch {
            self.mutex.unlock();
            return error.ExportTimeout;
        };
        self.mutex.unlock();
        self.exportBatch(batch);
        self.mutex.lock();
    }
    self.mutex.unlock();
    try self.exporter.forceFlush(timeout_ms);
}

fn batchShutdown(ctx: ?*anyopaque) void {
    const self: *BatchSpanProcessor = @ptrCast(@alignCast(ctx.?));
    // Best-effort flush; ignore timeout errors — shutdown is final.
    batchForceFlush(ctx, 5_000) catch {};
    self.exporter.shutdown();
}

// ---------------------------------------------------------------- Metric export

pub const NumberValue = union(enum) {
    int: i64,
    double: f64,
};

pub const HistogramPoint = struct {
    bounds: []const f64,
    counts: []const u64,
    sum: f64,
    count: u64,
    min: ?f64,
    max: ?f64,
};

pub const DataPoint = struct {
    attributes: ?*const attrs_mod.AttributeSet = null,
    start_unix_nano: u64,
    time_unix_nano: u64,
    value: union(enum) {
        number: NumberValue,
        histogram: HistogramPoint,
    },
};

pub const MetricData = struct {
    name: []const u8,
    description: []const u8,
    unit: []const u8,
    kind: metrics_api.InstrumentKind,
    temporality: metrics_api.Temporality,
    is_monotonic: bool = true,
    points: []const DataPoint,
    instrumentation_scope: trace_api.InstrumentationScope,
    resource: *const Resource,
};

pub const MetricExporter = struct {
    ctx: ?*anyopaque,
    exportFn: *const fn (?*anyopaque, []const MetricData) anyerror!SpanExportResult,
    shutdownFn: *const fn (?*anyopaque) void,
    forceFlushFn: *const fn (?*anyopaque, u64) anyerror!void,

    pub fn exportMetrics(self: MetricExporter, items: []const MetricData) !SpanExportResult {
        return try self.exportFn(self.ctx, items);
    }

    pub fn shutdown(self: MetricExporter) void {
        self.shutdownFn(self.ctx);
    }

    pub fn forceFlush(self: MetricExporter, timeout_ms: u64) !void {
        try self.forceFlushFn(self.ctx, timeout_ms);
    }
};

// ---------------------------------------------------------------- Log export

pub const LogData = struct {
    record: logs_api.LogRecord,
    instrumentation_scope: trace_api.InstrumentationScope,
    resource: *const Resource,
};

pub const LogExporter = struct {
    ctx: ?*anyopaque,
    exportFn: *const fn (?*anyopaque, []const LogData) anyerror!SpanExportResult,
    shutdownFn: *const fn (?*anyopaque) void,
    forceFlushFn: *const fn (?*anyopaque, u64) anyerror!void,

    pub fn exportLogs(self: LogExporter, items: []const LogData) !SpanExportResult {
        return try self.exportFn(self.ctx, items);
    }

    pub fn shutdown(self: LogExporter) void {
        self.shutdownFn(self.ctx);
    }

    pub fn forceFlush(self: LogExporter, timeout_ms: u64) !void {
        try self.forceFlushFn(self.ctx, timeout_ms);
    }
};

pub const LogProcessor = struct {
    ctx: ?*anyopaque,
    onEmitFn: *const fn (?*anyopaque, logs_api.LogRecord) void,
    forceFlushFn: *const fn (?*anyopaque, u64) anyerror!void,
    shutdownFn: *const fn (?*anyopaque) void,

    pub fn onEmit(self: LogProcessor, record: logs_api.LogRecord) void {
        self.onEmitFn(self.ctx, record);
    }

    pub fn forceFlush(self: LogProcessor, timeout_ms: u64) !void {
        try self.forceFlushFn(self.ctx, timeout_ms);
    }

    pub fn shutdown(self: LogProcessor) void {
        self.shutdownFn(self.ctx);
    }
};

// ---------------------------------------------------------------- Retry helper

pub const RetryPolicy = struct {
    initial_backoff_ms: u64 = 100,
    multiplier: u64 = 2,
    max_backoff_ms: u64 = 5_000,
    max_elapsed_ms: u64 = 30_000,
    seed: u64 = 0xC0FFEE,
};

/// Returns the next backoff delay in nanoseconds, applying full jitter.
/// `attempt` starts at 0.
pub fn nextBackoff(policy: RetryPolicy, attempt: u32, prng: *std.Random.DefaultPrng) u64 {
    var delay_ms = policy.initial_backoff_ms;
    var i: u32 = 0;
    while (i < attempt) : (i += 1) {
        const next = std.math.mul(u64, delay_ms, policy.multiplier) catch policy.max_backoff_ms;
        delay_ms = if (next > policy.max_backoff_ms) policy.max_backoff_ms else next;
    }
    const jittered = prng.random().uintAtMost(u64, delay_ms);
    return jittered * std.time.ns_per_ms;
}

/// State carried across iterations of an exporter retry loop. Keeps the
/// per-attempt accounting and the actual sleep in one place so HTTP and
/// gRPC exporters share the bounded-retry contract instead of each
/// reimplementing it (and forgetting to sleep, which was P-N1 / P-N2).
pub const RetryState = struct {
    attempt: u32 = 0,
    elapsed_ms: u64 = 0,
    policy: RetryPolicy = .{},
    max_attempts: u32 = 5,

    /// Increment the attempt counter, compute backoff, and sleep the
    /// calling thread for that backoff. Returns `true` when the caller
    /// should continue the retry loop, `false` when the budget is
    /// exhausted (in which case the caller should return
    /// `error.RetryExhausted`). Does not sleep on the exhaustion path.
    pub fn shouldRetry(self: *RetryState, prng: *std.Random.DefaultPrng) bool {
        self.attempt += 1;
        const backoff_ns = nextBackoff(self.policy, self.attempt, prng);
        self.elapsed_ms += backoff_ns / std.time.ns_per_ms;
        if (self.attempt >= self.max_attempts or self.elapsed_ms >= self.policy.max_elapsed_ms) return false;
        clock_mod.sleepNs(backoff_ns);
        return true;
    }
};

test "retry backoff scales with attempt" {
    var prng = std.Random.DefaultPrng.init(1);
    const p = RetryPolicy{};
    const a = nextBackoff(p, 0, &prng);
    const b = nextBackoff(p, 4, &prng);
    try std.testing.expect(b >= a or a == 0);
}

test "retry state honors max_attempts" {
    var prng = std.Random.DefaultPrng.init(1);
    var st: RetryState = .{
        .max_attempts = 2,
        .policy = .{ .initial_backoff_ms = 0, .max_backoff_ms = 0, .max_elapsed_ms = 1_000_000 },
    };
    try std.testing.expect(st.shouldRetry(&prng));
    try std.testing.expect(!st.shouldRetry(&prng));
    try std.testing.expectEqual(@as(u32, 2), st.attempt);
}
