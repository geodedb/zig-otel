// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Metrics API surface — value handles for instruments. The SDK side
// (`src/sdk/metrics.zig`) wires these to the actual aggregation pipeline.

const std = @import("std");
const attrs = @import("../internal/attributes.zig");
const InstrumentationScope = @import("trace.zig").InstrumentationScope;
const build_options = @import("build_options");

pub const Temporality = enum { cumulative, delta };

pub const InstrumentKind = enum {
    counter,
    up_down_counter,
    histogram,
    gauge,
    observable_counter,
    observable_up_down_counter,
    observable_gauge,
};

pub const ExplicitBuckets = struct {
    boundaries: []const f64,
};

pub const InstrumentDescriptor = struct {
    name: []const u8,
    description: []const u8 = "",
    unit: []const u8 = "",
    kind: InstrumentKind,
    temporality: Temporality = .cumulative,
    explicit_buckets: ?ExplicitBuckets = null,
};

pub const Counter = struct {
    ctx: ?*anyopaque = null,
    descriptor: InstrumentDescriptor,
    addFn: *const fn (?*anyopaque, u64, []const attrs.Entry) void = noopAdd,

    pub fn add(self: Counter, value: u64, attributes: []const attrs.Entry) void {
        if (comptime build_options.otel_disabled) return;
        self.addFn(self.ctx, value, attributes);
    }
};

pub const UpDownCounter = struct {
    ctx: ?*anyopaque = null,
    descriptor: InstrumentDescriptor,
    addFn: *const fn (?*anyopaque, i64, []const attrs.Entry) void = noopAddSigned,

    pub fn add(self: UpDownCounter, value: i64, attributes: []const attrs.Entry) void {
        if (comptime build_options.otel_disabled) return;
        self.addFn(self.ctx, value, attributes);
    }
};

pub const Histogram = struct {
    ctx: ?*anyopaque = null,
    descriptor: InstrumentDescriptor,
    recordFn: *const fn (?*anyopaque, f64, []const attrs.Entry) void = noopRecord,

    pub fn record(self: Histogram, value: f64, attributes: []const attrs.Entry) void {
        if (comptime build_options.otel_disabled) return;
        self.recordFn(self.ctx, value, attributes);
    }
};

pub const Gauge = struct {
    ctx: ?*anyopaque = null,
    descriptor: InstrumentDescriptor,
    setFn: *const fn (?*anyopaque, f64, []const attrs.Entry) void = noopRecord,

    pub fn set(self: Gauge, value: f64, attributes: []const attrs.Entry) void {
        if (comptime build_options.otel_disabled) return;
        self.setFn(self.ctx, value, attributes);
    }
};

pub const ObservableCallback = *const fn (
    user_ctx: ?*anyopaque,
    observer: Observer,
) anyerror!void;

pub const Observer = struct {
    ctx: ?*anyopaque = null,
    observeIntFn: *const fn (?*anyopaque, i64, []const attrs.Entry) void = noopAddSigned,
    observeDoubleFn: *const fn (?*anyopaque, f64, []const attrs.Entry) void = noopRecord,

    pub fn observeInt(self: Observer, value: i64, attributes: []const attrs.Entry) void {
        if (comptime build_options.otel_disabled) return;
        self.observeIntFn(self.ctx, value, attributes);
    }

    pub fn observeDouble(self: Observer, value: f64, attributes: []const attrs.Entry) void {
        if (comptime build_options.otel_disabled) return;
        self.observeDoubleFn(self.ctx, value, attributes);
    }
};

/// Token returned by `Meter.createObservable*` and `Meter.registerCallback`.
/// Carries enough state for `Meter.unregisterCallback` to find and remove
/// the callback. `unregisterCallback` is idempotent — passing a stale or
/// already-unregistered token is a no-op.
///
/// GAP-OBSERVABLE-INSTRUMENTS (#30).
pub const ObservableRegistration = struct {
    /// SDK-side instrument backend pointer (opaque to the API). Null for
    /// the no-op meter so `unregisterCallback` is a free no-op without
    /// the SDK.
    instrument: ?*anyopaque = null,
    /// Monotonic per-instrument id assigned at registration time. The SDK
    /// matches this against its callback list to make removal O(N) and
    /// idempotent.
    callback_id: u32 = 0,
};

/// Asynchronous Counter — a monotonic instrument whose current cumulative
/// value is observed lazily on each collection cycle. The callback is
/// invoked under the same `InstrumentMutex` discipline as synchronous
/// record paths (PR-1, gitlab #135) so concurrent sync writers cannot
/// race the snapshot.
///
/// GAP-OBSERVABLE-INSTRUMENTS (#30).
pub const ObservableCounter = struct {
    ctx: ?*anyopaque = null,
    descriptor: InstrumentDescriptor,
    registration: ObservableRegistration = .{},

    /// Idempotent. Safe to call after the parent meter is torn down — the
    /// ctx is null in that case and the call collapses to a no-op.
    pub fn unregister(self: *ObservableCounter, meter_ref: Meter) void {
        if (comptime build_options.otel_disabled) return;
        meter_ref.unregisterCallback(self.registration);
    }
};

/// Asynchronous UpDownCounter — a non-monotonic instrument whose current
/// cumulative signed value is observed lazily on each collection cycle.
/// GAP-OBSERVABLE-INSTRUMENTS (#30).
pub const ObservableUpDownCounter = struct {
    ctx: ?*anyopaque = null,
    descriptor: InstrumentDescriptor,
    registration: ObservableRegistration = .{},

    pub fn unregister(self: *ObservableUpDownCounter, meter_ref: Meter) void {
        if (comptime build_options.otel_disabled) return;
        meter_ref.unregisterCallback(self.registration);
    }
};

/// Asynchronous Gauge — observes the *current* value at each collection
/// cycle (last-write-wins per attribute set).
/// GAP-OBSERVABLE-INSTRUMENTS (#30).
pub const ObservableGauge = struct {
    ctx: ?*anyopaque = null,
    descriptor: InstrumentDescriptor,
    registration: ObservableRegistration = .{},

    pub fn unregister(self: *ObservableGauge, meter_ref: Meter) void {
        if (comptime build_options.otel_disabled) return;
        meter_ref.unregisterCallback(self.registration);
    }
};

pub const Meter = struct {
    ctx: ?*anyopaque = null,
    scope: InstrumentationScope,
    counterFn: *const fn (?*anyopaque, InstrumentDescriptor) anyerror!Counter = noopCounter,
    upDownCounterFn: *const fn (?*anyopaque, InstrumentDescriptor) anyerror!UpDownCounter = noopUDC,
    histogramFn: *const fn (?*anyopaque, InstrumentDescriptor) anyerror!Histogram = noopHistogram,
    gaugeFn: *const fn (?*anyopaque, InstrumentDescriptor) anyerror!Gauge = noopGauge,
    /// Construct an asynchronous Counter and register `callback` against
    /// it. GAP-OBSERVABLE-INSTRUMENTS (#30).
    observableCounterFn: *const fn (
        ?*anyopaque,
        InstrumentDescriptor,
        ObservableCallback,
        ?*anyopaque,
    ) anyerror!ObservableCounter = noopObservableCounter,
    observableUpDownCounterFn: *const fn (
        ?*anyopaque,
        InstrumentDescriptor,
        ObservableCallback,
        ?*anyopaque,
    ) anyerror!ObservableUpDownCounter = noopObservableUDC,
    observableGaugeFn: *const fn (
        ?*anyopaque,
        InstrumentDescriptor,
        ObservableCallback,
        ?*anyopaque,
    ) anyerror!ObservableGauge = noopObservableGauge,
    /// Register an additional callback against an existing observable
    /// instrument. Returns the registration token caller-side `unregister`
    /// uses. GAP-OBSERVABLE-INSTRUMENTS (#30).
    registerCallbackFn: *const fn (
        ?*anyopaque,
        ObservableRegistration,
        ObservableCallback,
        ?*anyopaque,
    ) anyerror!ObservableRegistration = noopRegisterCallback,
    /// Idempotent — passing a stale or already-unregistered token is a
    /// no-op so callers can wire `defer` safely.
    unregisterCallbackFn: *const fn (?*anyopaque, ObservableRegistration) void = noopUnregisterCallback,

    pub fn counter(self: Meter, descriptor: InstrumentDescriptor) !Counter {
        return try self.counterFn(self.ctx, descriptor);
    }
    pub fn upDownCounter(self: Meter, descriptor: InstrumentDescriptor) !UpDownCounter {
        return try self.upDownCounterFn(self.ctx, descriptor);
    }
    pub fn histogram(self: Meter, descriptor: InstrumentDescriptor) !Histogram {
        return try self.histogramFn(self.ctx, descriptor);
    }
    pub fn gauge(self: Meter, descriptor: InstrumentDescriptor) !Gauge {
        return try self.gaugeFn(self.ctx, descriptor);
    }
    pub fn createObservableCounter(
        self: Meter,
        descriptor: InstrumentDescriptor,
        callback: ObservableCallback,
        user_ctx: ?*anyopaque,
    ) !ObservableCounter {
        return try self.observableCounterFn(self.ctx, descriptor, callback, user_ctx);
    }
    pub fn createObservableUpDownCounter(
        self: Meter,
        descriptor: InstrumentDescriptor,
        callback: ObservableCallback,
        user_ctx: ?*anyopaque,
    ) !ObservableUpDownCounter {
        return try self.observableUpDownCounterFn(self.ctx, descriptor, callback, user_ctx);
    }
    pub fn createObservableGauge(
        self: Meter,
        descriptor: InstrumentDescriptor,
        callback: ObservableCallback,
        user_ctx: ?*anyopaque,
    ) !ObservableGauge {
        return try self.observableGaugeFn(self.ctx, descriptor, callback, user_ctx);
    }
    pub fn registerCallback(
        self: Meter,
        on: ObservableRegistration,
        callback: ObservableCallback,
        user_ctx: ?*anyopaque,
    ) !ObservableRegistration {
        return try self.registerCallbackFn(self.ctx, on, callback, user_ctx);
    }
    pub fn unregisterCallback(self: Meter, registration: ObservableRegistration) void {
        if (comptime build_options.otel_disabled) return;
        self.unregisterCallbackFn(self.ctx, registration);
    }
};

fn noopAdd(_: ?*anyopaque, _: u64, _: []const attrs.Entry) void {}
fn noopAddSigned(_: ?*anyopaque, _: i64, _: []const attrs.Entry) void {}
fn noopRecord(_: ?*anyopaque, _: f64, _: []const attrs.Entry) void {}
fn noopCounter(_: ?*anyopaque, d: InstrumentDescriptor) anyerror!Counter {
    return .{ .descriptor = d };
}
fn noopUDC(_: ?*anyopaque, d: InstrumentDescriptor) anyerror!UpDownCounter {
    return .{ .descriptor = d };
}
fn noopHistogram(_: ?*anyopaque, d: InstrumentDescriptor) anyerror!Histogram {
    return .{ .descriptor = d };
}
fn noopGauge(_: ?*anyopaque, d: InstrumentDescriptor) anyerror!Gauge {
    return .{ .descriptor = d };
}
fn noopObservableCounter(
    _: ?*anyopaque,
    d: InstrumentDescriptor,
    _: ObservableCallback,
    _: ?*anyopaque,
) anyerror!ObservableCounter {
    return .{ .descriptor = d };
}
fn noopObservableUDC(
    _: ?*anyopaque,
    d: InstrumentDescriptor,
    _: ObservableCallback,
    _: ?*anyopaque,
) anyerror!ObservableUpDownCounter {
    return .{ .descriptor = d };
}
fn noopObservableGauge(
    _: ?*anyopaque,
    d: InstrumentDescriptor,
    _: ObservableCallback,
    _: ?*anyopaque,
) anyerror!ObservableGauge {
    return .{ .descriptor = d };
}
fn noopRegisterCallback(
    _: ?*anyopaque,
    on: ObservableRegistration,
    _: ObservableCallback,
    _: ?*anyopaque,
) anyerror!ObservableRegistration {
    return on;
}
fn noopUnregisterCallback(_: ?*anyopaque, _: ObservableRegistration) void {}

test "no-op meter returns no-op instruments" {
    const m: Meter = .{ .scope = .{ .name = "test" } };
    const c = try m.counter(.{ .name = "x", .kind = .counter });
    c.add(1, &.{});
    const h = try m.histogram(.{ .name = "y", .kind = .histogram });
    h.record(1.0, &.{});
}

test "no-op meter returns no-op observable instruments" {
    const m: Meter = .{ .scope = .{ .name = "test" } };
    const dummyCb = struct {
        fn cb(_: ?*anyopaque, _: Observer) anyerror!void {}
    }.cb;
    var oc = try m.createObservableCounter(.{ .name = "ox", .kind = .observable_counter }, dummyCb, null);
    var oudc = try m.createObservableUpDownCounter(.{ .name = "ou", .kind = .observable_up_down_counter }, dummyCb, null);
    var og = try m.createObservableGauge(.{ .name = "og", .kind = .observable_gauge }, dummyCb, null);
    // Idempotent unregister against the no-op meter.
    oc.unregister(m);
    oudc.unregister(m);
    og.unregister(m);
    oc.unregister(m); // double-unregister is a no-op.
}
