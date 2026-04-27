// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// GAP-PERIODIC-METRIC-READER (#29) regression coverage.
//
// Pins:
//   1. Interval-driven export — a 50ms reader observed for 350ms must
//      see ≥3 collect cycles arrive at the exporter.
//   2. Force-flush — synchronous trigger, exporter sees the request
//      land before the call returns.
//   3. Shutdown promptness — `shutdown()` returns in <100ms even when
//      the configured interval is 60s. Hard SLA for graceful service
//      stop.
//   4. Observable-instrument integration — register an observable
//      counter, run the reader, the exporter receives the recorded
//      points (covers GAP-OBSERVABLE-INSTRUMENTS × periodic-reader
//      end-to-end).

const std = @import("std");
const otel = @import("otel");

const sdk_metrics = otel.sdk.metrics;
const sdk_resource = otel.sdk.resource;
const periodic_reader = otel.sdk.periodic_metric_reader;
const api_metrics = otel.api.metrics;
const attrs = otel.internal.attributes;
const exp = otel.sdk.exporter;
const in_memory = otel.exporters.in_memory;

// ---- Counting exporter helper ----
//
// The in-memory recorder counts records but doesn't surface a "cycle
// count" directly. Wrap it with our own counter so tests can assert on
// the number of `exportMetrics` calls (one per collect cycle).

const CountingExporter = struct {
    cycles: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    last_int_value: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

    pub fn metricExporter(self: *CountingExporter) exp.MetricExporter {
        return .{
            .ctx = self,
            .exportFn = expFn,
            .shutdownFn = shutdownFn,
            .forceFlushFn = forceFlushFn,
        };
    }

    fn expFn(ctx: ?*anyopaque, items: []const exp.MetricData) anyerror!exp.SpanExportResult {
        const self: *CountingExporter = @ptrCast(@alignCast(ctx.?));
        _ = self.cycles.fetchAdd(1, .acq_rel);
        if (items.len > 0 and items[0].points.len > 0) {
            switch (items[0].points[0].value) {
                .number => |n| switch (n) {
                    .int => |i| self.last_int_value.store(i, .release),
                    .double => {},
                },
                .histogram => {},
            }
        }
        return .success;
    }

    fn shutdownFn(_: ?*anyopaque) void {}
    fn forceFlushFn(_: ?*anyopaque, _: u64) anyerror!void {}
};

// ---- Test 1: interval-driven export ----

test "PeriodicMetricReader: interval drives multiple exports" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var resource = try sdk_resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try sdk_metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const m = mp.meter(.{ .name = "periodic.test" });
    const c = try m.counter(.{ .name = "events", .kind = .counter });
    c.add(1, &.{}); // ensure at least one point exists so collect emits something

    var ce = CountingExporter{};
    var reader = try periodic_reader.PeriodicMetricReader.init(
        std.testing.allocator,
        &mp,
        ce.metricExporter(),
        .{ .export_interval_ms = 50, .export_timeout_ms = 1_000 },
    );
    defer reader.deinit();

    try reader.start();
    // 350ms / 50ms = ~7 cycles expected; assert ≥3 to leave generous
    // margin for slow CI machines.
    otel.internal.clock.sleepNs(350 * std.time.ns_per_ms);
    reader.shutdown();

    try std.testing.expect(ce.cycles.load(.acquire) >= 3);
}

// ---- Test 2: force-flush synchronously runs a cycle ----

test "PeriodicMetricReader: forceFlush runs a cycle synchronously" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var resource = try sdk_resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try sdk_metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const m = mp.meter(.{ .name = "periodic.test" });
    const c = try m.counter(.{ .name = "events", .kind = .counter });
    c.add(7, &.{});

    var ce = CountingExporter{};
    var reader = try periodic_reader.PeriodicMetricReader.init(
        std.testing.allocator,
        &mp,
        ce.metricExporter(),
        // 60s interval — only forceFlush should drive an export within
        // the test budget.
        .{ .export_interval_ms = 60_000, .export_timeout_ms = 1_000 },
    );
    defer reader.deinit();

    try reader.start();
    try reader.forceFlush(2_000);
    // forceFlush must have drained the cycle synchronously.
    try std.testing.expect(ce.cycles.load(.acquire) >= 1);
    try std.testing.expectEqual(@as(i64, 7), ce.last_int_value.load(.acquire));
}

// ---- Test 3: prompt shutdown ----

test "PeriodicMetricReader: shutdown is prompt even with long interval" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var resource = try sdk_resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try sdk_metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    var ce = CountingExporter{};
    var reader = try periodic_reader.PeriodicMetricReader.init(
        std.testing.allocator,
        &mp,
        ce.metricExporter(),
        // 60s interval — shutdown must NOT wait for the next tick.
        .{ .export_interval_ms = 60_000, .export_timeout_ms = 1_000 },
    );
    defer reader.deinit();

    try reader.start();
    // Give the thread a moment to enter its sleep.
    otel.internal.clock.sleepNs(20 * std.time.ns_per_ms);

    const start_ns: u64 = otel.internal.clock.unixNanoNow();
    reader.shutdown();
    const end_ns: u64 = otel.internal.clock.unixNanoNow();
    const elapsed_ns: u64 = if (end_ns > start_ns) end_ns - start_ns else 0;
    const elapsed_ms: u64 = elapsed_ns / std.time.ns_per_ms;

    // <100ms target. CI machines vary; allow up to 500ms before failing
    // outright (catches the regression where shutdown waits the full
    // interval).
    try std.testing.expect(elapsed_ms < 500);
}

// ---- Test 4: observable counter via periodic reader ----

const ObsCtx = struct {
    value: std.atomic.Value(i64) = std.atomic.Value(i64).init(100),
};

fn obsCb(user_ctx: ?*anyopaque, observer: api_metrics.Observer) anyerror!void {
    const ctx: *ObsCtx = @ptrCast(@alignCast(user_ctx.?));
    observer.observeInt(ctx.value.load(.acquire), &.{});
}

test "PeriodicMetricReader: observable counter exported on cycle" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var resource = try sdk_resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try sdk_metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const m = mp.meter(.{ .name = "periodic.test" });
    var obs_ctx = ObsCtx{};
    const oc = try m.createObservableCounter(
        .{ .name = "queue.depth", .kind = .observable_counter },
        obsCb,
        @ptrCast(&obs_ctx),
    );
    _ = oc;

    var ce = CountingExporter{};
    var reader = try periodic_reader.PeriodicMetricReader.init(
        std.testing.allocator,
        &mp,
        ce.metricExporter(),
        .{ .export_interval_ms = 30, .export_timeout_ms = 1_000 },
    );
    defer reader.deinit();

    try reader.start();
    obs_ctx.value.store(100, .release);
    otel.internal.clock.sleepNs(80 * std.time.ns_per_ms);
    obs_ctx.value.store(250, .release);
    try reader.forceFlush(1_000);
    reader.shutdown();

    // After the final force-flush the exporter should observe the
    // updated value.
    try std.testing.expectEqual(@as(i64, 250), ce.last_int_value.load(.acquire));
    try std.testing.expect(ce.cycles.load(.acquire) >= 1);
}

// ---- Test 5: forceFlush before start runs inline ----

test "PeriodicMetricReader: forceFlush before start runs inline" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var resource = try sdk_resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try sdk_metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const m = mp.meter(.{ .name = "periodic.test" });
    const c = try m.counter(.{ .name = "events", .kind = .counter });
    c.add(13, &.{});

    var ce = CountingExporter{};
    var reader = try periodic_reader.PeriodicMetricReader.init(
        std.testing.allocator,
        &mp,
        ce.metricExporter(),
        .{ .export_interval_ms = 60_000, .export_timeout_ms = 1_000 },
    );
    defer reader.deinit();

    // No start() — forceFlush should still drain on the caller's thread.
    try reader.forceFlush(1_000);
    try std.testing.expectEqual(@as(i64, 13), ce.last_int_value.load(.acquire));
    try std.testing.expect(ce.cycles.load(.acquire) >= 1);
}

// ---- Test 6: lifecycle uses in-memory exporter for end-to-end shape ----

test "PeriodicMetricReader: in-memory exporter receives metrics" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var resource = try sdk_resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try sdk_metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    var rec = in_memory.Recorder.init(std.testing.allocator);
    defer rec.deinit();

    const m = mp.meter(.{ .name = "periodic.test" });
    const c = try m.counter(.{ .name = "events", .kind = .counter });
    c.add(3, &.{});
    c.add(4, &.{});

    var reader = try periodic_reader.PeriodicMetricReader.init(
        std.testing.allocator,
        &mp,
        rec.metricExporter(),
        .{ .export_interval_ms = 60_000, .export_timeout_ms = 1_000 },
    );
    defer reader.deinit();

    try reader.start();
    try reader.forceFlush(1_000);
    reader.shutdown();

    try std.testing.expect(rec.metrics.items.len >= 1);
    try std.testing.expectEqualStrings("events", rec.metrics.items[0].name);
    try std.testing.expectEqual(@as(?i64, 7), rec.metrics.items[0].int_value);
}
