// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// GAP-OBSERVABLE-INSTRUMENTS (#30) regression coverage.
//
// Pins:
//   1. `Meter.createObservableCounter / UpDownCounter / Gauge` build a
//      working asynchronous instrument; `MeterProvider.collect()`
//      invokes the registered callback under `inst.mu` and writes
//      through to the same `points`/`points_index` map the synchronous
//      record path uses (P0-1).
//   2. Multiple callbacks per instrument fire deterministically (in
//      registration order) on every collect.
//   3. `Meter.unregisterCallback` is idempotent — passing a stale
//      registration is a no-op.
//   4. Async-counter cumulative semantics: callback's reported value
//      replaces the previous absolute value (last-write-wins per
//      attribute set within a collect cycle).
//   5. Lifecycle: `MeterProvider.deinit()` frees per-instrument callback
//      lists with no leak (covered by the testing-allocator's
//      detectLeaks).

const std = @import("std");
const otel = @import("otel");

const sdk_metrics = otel.sdk.metrics;
const sdk_resource = otel.sdk.resource;
const api_metrics = otel.api.metrics;
const attrs = otel.internal.attributes;

// ---- Single-callback record-then-collect ----

const SingleCbCtx = struct {
    value: i64,
    attr_key: []const u8,
    attr_value: []const u8,
};

fn singleCb(user_ctx: ?*anyopaque, observer: api_metrics.Observer) anyerror!void {
    const ctx: *const SingleCbCtx = @ptrCast(@alignCast(user_ctx.?));
    const e: attrs.Entry = .{ .key = ctx.attr_key, .value = .{ .string = ctx.attr_value } };
    observer.observeInt(ctx.value, &.{e});
}

test "observable counter: single callback observed at collect time" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var resource = try sdk_resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try sdk_metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const m = mp.meter(.{ .name = "obs.test" });
    var cb_ctx = SingleCbCtx{ .value = 42, .attr_key = "service", .attr_value = "x" };
    var oc = try m.createObservableCounter(
        .{ .name = "queue.depth", .kind = .observable_counter },
        singleCb,
        @ptrCast(&cb_ctx),
    );
    _ = &oc;

    const snap = try sdk_metrics.collect(&mp, std.testing.allocator);
    defer sdk_metrics.freeSnapshot(std.testing.allocator, snap);

    try std.testing.expectEqual(@as(usize, 1), snap.len);
    try std.testing.expectEqual(@as(usize, 1), snap[0].points.len);
    try std.testing.expectEqual(@as(i64, 42), snap[0].points[0].value.number.int);

    // The cloned attribute set must round-trip the callback's record.
    const attr_set = snap[0].points[0].attributes orelse return error.TestFailed;
    try std.testing.expectEqual(@as(usize, 1), attr_set.entries.items.len);
    try std.testing.expectEqualStrings("service", attr_set.entries.items[0].key);
    try std.testing.expectEqualStrings("x", attr_set.entries.items[0].value.string);
}

test "observable up-down counter: signed values" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var resource = try sdk_resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try sdk_metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const m = mp.meter(.{ .name = "obs.test" });
    var cb_ctx = SingleCbCtx{ .value = -7, .attr_key = "queue", .attr_value = "main" };
    var oudc = try m.createObservableUpDownCounter(
        .{ .name = "balance", .kind = .observable_up_down_counter },
        singleCb,
        @ptrCast(&cb_ctx),
    );
    _ = &oudc;

    const snap = try sdk_metrics.collect(&mp, std.testing.allocator);
    defer sdk_metrics.freeSnapshot(std.testing.allocator, snap);
    try std.testing.expectEqual(@as(i64, -7), snap[0].points[0].value.number.int);
}

// ---- Observable gauge: double-precision ----

const DoubleCbCtx = struct {
    value: f64,
};

fn doubleCb(user_ctx: ?*anyopaque, observer: api_metrics.Observer) anyerror!void {
    const ctx: *const DoubleCbCtx = @ptrCast(@alignCast(user_ctx.?));
    observer.observeDouble(ctx.value, &.{});
}

test "observable gauge: double-precision value" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var resource = try sdk_resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try sdk_metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const m = mp.meter(.{ .name = "obs.test" });
    var cb_ctx = DoubleCbCtx{ .value = 3.14 };
    var og = try m.createObservableGauge(
        .{ .name = "temp", .kind = .observable_gauge },
        doubleCb,
        @ptrCast(&cb_ctx),
    );
    _ = &og;

    const snap = try sdk_metrics.collect(&mp, std.testing.allocator);
    defer sdk_metrics.freeSnapshot(std.testing.allocator, snap);
    try std.testing.expectEqual(@as(f64, 3.14), snap[0].points[0].value.number.double);
}

// ---- Multi-callback ordering ----

const OrderCtx = struct {
    fired_order: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    self_id: u8,
    value: i64,
    attr_value: []const u8,
};

fn orderCb(user_ctx: ?*anyopaque, observer: api_metrics.Observer) anyerror!void {
    const ctx: *OrderCtx = @ptrCast(@alignCast(user_ctx.?));
    try ctx.fired_order.append(ctx.allocator, ctx.self_id);
    const e: attrs.Entry = .{ .key = "tag", .value = .{ .string = ctx.attr_value } };
    observer.observeInt(ctx.value, &.{e});
}

test "observable counter: multiple callbacks fire in registration order" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var resource = try sdk_resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try sdk_metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const m = mp.meter(.{ .name = "obs.test" });
    var fired: std.ArrayList(u8) = .empty;
    defer fired.deinit(std.testing.allocator);

    var ctx_a = OrderCtx{
        .fired_order = &fired,
        .allocator = std.testing.allocator,
        .self_id = 1,
        .value = 10,
        .attr_value = "a",
    };
    var ctx_b = OrderCtx{
        .fired_order = &fired,
        .allocator = std.testing.allocator,
        .self_id = 2,
        .value = 20,
        .attr_value = "b",
    };

    const oc = try m.createObservableCounter(
        .{ .name = "events", .kind = .observable_counter },
        orderCb,
        @ptrCast(&ctx_a),
    );
    _ = try m.registerCallback(oc.registration, orderCb, @ptrCast(&ctx_b));

    // Force two collects to confirm both callbacks fire each cycle.
    {
        const snap = try sdk_metrics.collect(&mp, std.testing.allocator);
        defer sdk_metrics.freeSnapshot(std.testing.allocator, snap);
        try std.testing.expectEqual(@as(usize, 1), snap.len);
        try std.testing.expectEqual(@as(usize, 2), snap[0].points.len);
    }
    {
        const snap = try sdk_metrics.collect(&mp, std.testing.allocator);
        defer sdk_metrics.freeSnapshot(std.testing.allocator, snap);
        try std.testing.expectEqual(@as(usize, 2), snap[0].points.len);
    }

    // Two cycles × two callbacks = four entries, alternating 1,2,1,2.
    try std.testing.expectEqual(@as(usize, 4), fired.items.len);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 1, 2 }, fired.items);
}

// ---- Idempotent unregister ----

test "observable callback: unregister is idempotent" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var resource = try sdk_resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try sdk_metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const m = mp.meter(.{ .name = "obs.test" });
    var cb_ctx = SingleCbCtx{ .value = 5, .attr_key = "k", .attr_value = "v" };
    var oc = try m.createObservableCounter(
        .{ .name = "events", .kind = .observable_counter },
        singleCb,
        @ptrCast(&cb_ctx),
    );

    // Unregister once — subsequent collects should NOT pick the callback up.
    oc.unregister(m);
    {
        const snap = try sdk_metrics.collect(&mp, std.testing.allocator);
        defer sdk_metrics.freeSnapshot(std.testing.allocator, snap);
        // Instrument exists but has no points (callback didn't fire).
        try std.testing.expectEqual(@as(usize, 0), snap.len);
    }

    // Second unregister with the same registration is a no-op (no panic,
    // no double-free).
    oc.unregister(m);
    oc.unregister(m);

    // Stale registration with bogus id is also a no-op.
    var stale = oc.registration;
    stale.callback_id = 0xDEAD;
    m.unregisterCallback(stale);
}

// ---- Cross-attribute aggregation: last-write-wins per key per cycle ----

const PerCycleCtx = struct {
    cycle: *u32,
};

fn perCycleCb(user_ctx: ?*anyopaque, observer: api_metrics.Observer) anyerror!void {
    const ctx: *PerCycleCtx = @ptrCast(@alignCast(user_ctx.?));
    // Each cycle reports a different cumulative value for the same key.
    const v: i64 = @intCast(ctx.cycle.* * 100);
    const e: attrs.Entry = .{ .key = "shard", .value = .{ .string = "alpha" } };
    observer.observeInt(v, &.{e});
}

test "observable counter: cumulative semantics across cycles (last-write-wins)" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var resource = try sdk_resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try sdk_metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const m = mp.meter(.{ .name = "obs.test" });
    var cycle: u32 = 1;
    var ctx = PerCycleCtx{ .cycle = &cycle };
    var oc = try m.createObservableCounter(
        .{ .name = "rps", .kind = .observable_counter },
        perCycleCb,
        @ptrCast(&ctx),
    );
    _ = &oc;

    {
        const snap = try sdk_metrics.collect(&mp, std.testing.allocator);
        defer sdk_metrics.freeSnapshot(std.testing.allocator, snap);
        try std.testing.expectEqual(@as(i64, 100), snap[0].points[0].value.number.int);
    }
    cycle = 5;
    {
        const snap = try sdk_metrics.collect(&mp, std.testing.allocator);
        defer sdk_metrics.freeSnapshot(std.testing.allocator, snap);
        // Cumulative-replace: the 100 from the previous cycle is gone,
        // 500 (5 * 100) takes its place.
        try std.testing.expectEqual(@as(i64, 500), snap[0].points[0].value.number.int);
    }
}

// ---- Sync + async on the same provider don't collide ----

fn fixedFiveCb(_: ?*anyopaque, observer: api_metrics.Observer) anyerror!void {
    observer.observeInt(5, &.{});
}

test "observable + sync instruments coexist on one provider" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var resource = try sdk_resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try sdk_metrics.MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const m = mp.meter(.{ .name = "obs.test" });
    const sync_c = try m.counter(.{ .name = "sync_c", .kind = .counter });
    sync_c.add(7, &.{});

    var oc = try m.createObservableCounter(
        .{ .name = "obs_c", .kind = .observable_counter },
        fixedFiveCb,
        null,
    );
    _ = &oc;

    const snap = try sdk_metrics.collect(&mp, std.testing.allocator);
    defer sdk_metrics.freeSnapshot(std.testing.allocator, snap);
    try std.testing.expectEqual(@as(usize, 2), snap.len);

    // Find each by name.
    var got_sync: ?i64 = null;
    var got_obs: ?i64 = null;
    for (snap) |m_data| {
        if (std.mem.eql(u8, m_data.name, "sync_c")) {
            got_sync = m_data.points[0].value.number.int;
        } else if (std.mem.eql(u8, m_data.name, "obs_c")) {
            got_obs = m_data.points[0].value.number.int;
        }
    }
    try std.testing.expectEqual(@as(?i64, 7), got_sync);
    try std.testing.expectEqual(@as(?i64, 5), got_obs);
}
