// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// PeriodicExportingMetricReader — drives `MeterProvider.collect` on a
// fixed cadence and hands the snapshot to a `MetricExporter`.
//
// GAP-PERIODIC-METRIC-READER (#29). Until this file landed, metrics were
// only exposed via on-demand `MeterProvider.collect` calls; long-running
// services that never call it shipped no metrics until shutdown. The
// reader closes that gap.
//
// Lifecycle:
//   1. `init(allocator, *MeterProvider, *MetricExporter, MetricReaderConfig)`
//      builds the struct and stores its dependencies.
//   2. `start()` spawns the timer thread.
//   3. `forceFlush(timeout_ms)` triggers a synchronous collect+export
//      and waits for it to complete.
//   4. `shutdown()` signals the timer to exit, joins it, then calls
//      `exporter.shutdown()`. The condvar wake-up makes shutdown
//      latency a futex round-trip rather than the full export interval.
//   5. `deinit()` releases the heap allocations.
//
// Concurrency: the periodic loop calls `MeterProvider.collect()` which
// already takes per-instrument `InstrumentMutex` locks (PR-1, gitlab
// #135) for every snapshot copy. The reader holds no provider-side
// locks of its own — its mutex only guards the shutdown / flush
// signalling pair. Multiple readers on one provider are supported.

const std = @import("std");
const exp = @import("export.zig");
const sdk_metrics = @import("metrics.zig");
const config_mod = @import("config.zig");
const clock_mod = @import("../internal/clock.zig");
const internal_sync = @import("../internal/sync.zig");

/// Zero-arg `Mutex` used to guard the reader's shutdown / flush
/// signalling. This is the shared `internal/sync.zig` `Mutex` — a thin
/// wrapper around `std.Io.Mutex`'s `*Uncancelable` API on the global
/// single-threaded I/O instance — so the reader takes no build-flag
/// dependency on the DevNW thread-pool's `tp.sync` shim and works in
/// every build configuration. `ReaderCondition` reaches into `.inner`
/// directly, which the shared wrapper exposes with the same shape.
const ReaderMutex = internal_sync.Mutex;

/// Condition variable with `wait` and `timedWait` plus `signal` /
/// `broadcast`, built directly on top of `std.Io`'s futex primitive
/// using the same `global_single_threaded` instance. Same shape as
/// `tp.sync.Condition` (zero-arg API on top of std.Io) but local so the
/// reader is independent of the thread-pool build flag.
const ReaderCondition = struct {
    state: std.atomic.Value(State) = .init(.{ .waiters = 0, .signals = 0 }),
    epoch: std.atomic.Value(u32) = .init(0),

    const State = packed struct(u32) {
        waiters: u16,
        signals: u16,
    };

    inline fn io() std.Io {
        return std.Io.Threaded.global_single_threaded.io();
    }

    pub fn timedWait(self: *ReaderCondition, m: *ReaderMutex, timeout_ns: u64) error{Timeout}!void {
        return self.waitInner(m, .{ .duration = .{
            .raw = .fromNanoseconds(@intCast(timeout_ns)),
            .clock = .real,
        } });
    }

    pub fn signal(self: *ReaderCondition) void {
        var prev = self.state.load(.monotonic);
        while (prev.waiters > prev.signals) {
            prev = self.state.cmpxchgWeak(prev, .{
                .waiters = prev.waiters,
                .signals = prev.signals + 1,
            }, .release, .monotonic) orelse {
                _ = self.epoch.fetchAdd(1, .release);
                io().futexWake(u32, &self.epoch.raw, 1);
                return;
            };
        }
    }

    pub fn broadcast(self: *ReaderCondition) void {
        var prev = self.state.load(.monotonic);
        while (prev.waiters > prev.signals) {
            prev = self.state.cmpxchgWeak(prev, .{
                .waiters = prev.waiters,
                .signals = prev.waiters,
            }, .release, .monotonic) orelse {
                _ = self.epoch.fetchAdd(1, .release);
                io().futexWake(u32, &self.epoch.raw, prev.waiters - prev.signals);
                return;
            };
        }
    }

    fn waitInner(self: *ReaderCondition, m: *ReaderMutex, timeout: std.Io.Timeout) error{Timeout}!void {
        var epoch = self.epoch.load(.acquire);
        {
            const prev = self.state.fetchAdd(.{ .waiters = 1, .signals = 0 }, .monotonic);
            std.debug.assert(prev.waiters < std.math.maxInt(u16));
        }

        m.inner.unlock(io());
        defer m.inner.lockUncancelable(io());

        const deadline: std.Io.Timeout = switch (timeout) {
            .none => .none,
            else => timeout.toDeadline(io()),
        };

        while (true) {
            switch (deadline) {
                .none => io().futexWaitUncancelable(u32, &self.epoch.raw, epoch),
                else => io().futexWaitTimeout(u32, &self.epoch.raw, epoch, deadline) catch {},
            }

            epoch = self.epoch.load(.acquire);

            // Try to consume a pending signal first.
            {
                var prev = self.state.load(.monotonic);
                while (prev.signals > 0) {
                    prev = self.state.cmpxchgWeak(prev, .{
                        .waiters = prev.waiters - 1,
                        .signals = prev.signals - 1,
                    }, .acquire, .monotonic) orelse return;
                }
            }

            // No signal: decide whether to loop or give up on timeout.
            switch (deadline) {
                .none => {}, // spurious wake; loop
                else => {
                    const remaining = deadline.toDurationFromNow(io()) orelse break;
                    if (remaining.raw.nanoseconds <= 0) break;
                },
            }
        }

        const prev = self.state.fetchSub(.{ .waiters = 1, .signals = 0 }, .monotonic);
        std.debug.assert(prev.waiters > 0);
        return error.Timeout;
    }
};

const ReaderState = enum(u8) {
    idle = 0,
    running = 1,
    stopped = 2,
};

pub const PeriodicMetricReader = struct {
    allocator: std.mem.Allocator,
    provider: *sdk_metrics.MeterProvider,
    exporter: exp.MetricExporter,
    interval_ms: u64,
    export_timeout_ms: u64,

    /// Guards `state` + `flush_pending` + `flush_completed_seq` + the
    /// shutdown wake-up signalling. Held only briefly; the long-running
    /// collect+export runs OFF this lock so periodic-export latency
    /// doesn't block shutdown.
    mu: ReaderMutex = .{},
    cond: ReaderCondition = .{},
    /// Bumped every time the worker finishes an export cycle. `forceFlush`
    /// captures the current value, signals `flush_pending`, then waits
    /// until the worker's counter advances past it.
    flush_completed_seq: u64 = 0,
    /// Set by `forceFlush`; cleared by the worker after it runs.
    flush_pending: bool = false,
    /// Set by `shutdown`; cleared on join.
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    state: ReaderState = .idle,
    thread: ?std.Thread = null,

    /// QN-NEW-5: export-failure surfacing. `collectAndExport` records the
    /// last export error here and bumps `failed_exports` instead of
    /// silently swallowing it. `forceFlush` reads these back so a caller
    /// learns the collector rejected the export. Both are guarded by `mu`
    /// on the threaded path; the inline path also returns the error
    /// directly. `last_export_error` is `?anyerror`, latest-wins.
    last_export_error: ?anyerror = null,
    failed_exports: u64 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        provider: *sdk_metrics.MeterProvider,
        exporter: exp.MetricExporter,
        cfg: config_mod.MetricReaderConfig,
    ) !PeriodicMetricReader {
        return .{
            .allocator = allocator,
            .provider = provider,
            .exporter = exporter,
            .interval_ms = cfg.export_interval_ms,
            .export_timeout_ms = cfg.export_timeout_ms,
        };
    }

    /// Spawn the timer thread. Idempotent — calling on an already-running
    /// reader is a no-op so callers can plumb start() through builders
    /// without extra bookkeeping.
    pub fn start(self: *PeriodicMetricReader) !void {
        self.mu.lock();
        if (self.state == .running) {
            self.mu.unlock();
            return;
        }
        if (self.state == .stopped) {
            self.mu.unlock();
            return error.ReaderShutDown;
        }
        self.state = .running;
        self.mu.unlock();
        self.thread = try std.Thread.spawn(.{}, timerLoop, .{self});
    }

    /// Synchronously trigger a collect+export and wait for it to
    /// complete. Returns `error.ExportTimeout` if `timeout_ms` elapses
    /// before the worker drains the request. Safe to call before
    /// `start()` — runs the cycle inline on the calling thread.
    pub fn forceFlush(self: *PeriodicMetricReader, timeout_ms: u64) !void {
        self.mu.lock();
        if (self.state != .running or self.thread == null) {
            // Inline path: run the cycle on the caller's thread so
            // `forceFlush` works even when `start()` hasn't been called.
            self.mu.unlock();
            try self.collectAndExport();
            return;
        }
        const target_seq = self.flush_completed_seq + 1;
        // QN-NEW-5: snapshot the failure count under `mu` so we can tell
        // whether THIS flush cycle's export failed once the worker bumps
        // the completion seq. The worker records any export error
        // (recordExportError) before advancing flush_completed_seq, so the
        // ordering is safe: seq advance implies the error field is set.
        const failed_before = self.failed_exports;
        self.flush_pending = true;
        self.cond.signal();

        const deadline_ns: u64 = timeout_ms * std.time.ns_per_ms;
        var elapsed_ns: u64 = 0;
        const start_ns: u64 = nanosNow();
        while (self.flush_completed_seq < target_seq) {
            if (timeout_ms == 0) {
                self.mu.unlock();
                return error.ExportTimeout;
            }
            const remaining: u64 = if (deadline_ns > elapsed_ns) deadline_ns - elapsed_ns else 0;
            if (remaining == 0) {
                self.mu.unlock();
                return error.ExportTimeout;
            }
            self.cond.timedWait(&self.mu, remaining) catch {};
            elapsed_ns = nanosNow() - start_ns;
        }
        // Cycle completed. If the worker's export failed during it, surface
        // the captured error rather than reporting success.
        const export_err: ?anyerror = if (self.failed_exports > failed_before)
            self.last_export_error
        else
            null;
        self.mu.unlock();
        if (export_err) |err| return err;
    }

    /// Stop the timer thread and shut the exporter down. After this
    /// returns the reader is permanently inert. Idempotent.
    pub fn shutdown(self: *PeriodicMetricReader) void {
        self.mu.lock();
        if (self.state == .stopped) {
            self.mu.unlock();
            return;
        }
        self.state = .stopped;
        self.shutdown_requested.store(true, .release);
        self.cond.broadcast();
        self.mu.unlock();

        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }

        // One last best-effort flush so any final aggregations make it
        // out before the exporter closes.
        self.collectAndExport() catch {};
        self.exporter.shutdown();
    }

    pub fn deinit(self: *PeriodicMetricReader) void {
        // Idempotent shutdown so callers that wire `defer reader.deinit()`
        // before calling `start()` still tear down cleanly.
        self.shutdown();
    }

    fn timerLoop(self: *PeriodicMetricReader) void {
        const interval_ns: u64 = self.interval_ms * std.time.ns_per_ms;
        while (true) {
            self.mu.lock();
            if (self.shutdown_requested.load(.acquire)) {
                self.mu.unlock();
                return;
            }
            // Edge-trigger fix: check `flush_pending` BEFORE blocking so
            // a `forceFlush` that fires before the thread enters the
            // wait isn't lost. Same for shutdown — the requested-flag is
            // already checked above.
            if (!self.flush_pending) {
                // Wait up to `interval_ns` for either a forceFlush
                // request or a shutdown broadcast.
                self.cond.timedWait(&self.mu, interval_ns) catch {};
            }
            const stop = self.shutdown_requested.load(.acquire);
            const flush_request = self.flush_pending;
            self.flush_pending = false;
            self.mu.unlock();

            if (stop) return;

            self.collectAndExport() catch {};

            if (flush_request) {
                self.mu.lock();
                self.flush_completed_seq += 1;
                self.cond.broadcast();
                self.mu.unlock();
            }
        }
    }

    /// Drive `MeterProvider.collect()` and pipe the snapshot through
    /// the exporter. Honors `export_timeout_ms` via the exporter's own
    /// `forceFlush` deadline knob (the OTLP exporters propagate the
    /// timeout into the underlying HTTP/gRPC client; the in-memory
    /// recorder is synchronous and the timeout is a no-op for it).
    fn collectAndExport(self: *PeriodicMetricReader) !void {
        const snap = sdk_metrics.collect(self.provider, self.allocator) catch |err| {
            // collect() can OOM; surface the error to forceFlush
            // callers but don't take the timer thread down.
            return err;
        };
        defer sdk_metrics.freeSnapshot(self.allocator, snap);
        if (snap.len == 0) return;

        // QN-NEW-5: capture export failures instead of swallowing them so
        // `forceFlush` can surface the underlying rejection (the collector
        // refused the data) rather than only ever reporting timeouts.
        if (self.exporter.exportMetrics(snap)) |_| {
            // exported (the in-memory recorder / OTLP path returned a
            // result); fall through to the flush below.
        } else |err| {
            self.recordExportError(err);
            return err;
        }
        // `forceFlush` propagates the export_timeout_ms budget to the
        // exporter so HTTP/gRPC clients can short-circuit hung calls.
        self.exporter.forceFlush(self.export_timeout_ms) catch |err| {
            self.recordExportError(err);
            return err;
        };
    }

    /// Record an export failure under `mu` so the threaded path's
    /// `forceFlush` (which reads these fields after the seq advances) sees
    /// a consistent view. Latest error wins; `failed_exports` is a running
    /// count.
    fn recordExportError(self: *PeriodicMetricReader, err: anyerror) void {
        self.mu.lock();
        self.last_export_error = err;
        self.failed_exports += 1;
        self.mu.unlock();
    }
};

/// Read the wall clock as nanoseconds. Used only for `forceFlush`
/// deadline accounting — no metric data uses this clock.
fn nanosNow() u64 {
    return clock_mod.unixNanoNow();
}

// ----------------------------------------------------------------------
// Inline tests — start/shutdown lifecycle, force-flush before start, and
// the prompt-shutdown invariant. End-to-end coverage with observable
// instruments lives under `test/periodic_metric_reader.zig`.
// ----------------------------------------------------------------------

test "PeriodicMetricReader: idempotent shutdown" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var resource = try @import("resource.zig").defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try sdk_metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    var rec = @import("../exporters/in_memory.zig").Recorder.init(std.testing.allocator);
    defer rec.deinit();

    var reader = try PeriodicMetricReader.init(
        std.testing.allocator,
        &mp,
        rec.metricExporter(),
        .{ .export_interval_ms = 1_000_000, .export_timeout_ms = 1_000 },
    );
    reader.shutdown();
    reader.shutdown(); // double-shutdown is a no-op.
}
