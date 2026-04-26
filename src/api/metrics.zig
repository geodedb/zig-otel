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

pub const Meter = struct {
    ctx: ?*anyopaque = null,
    scope: InstrumentationScope,
    counterFn: *const fn (?*anyopaque, InstrumentDescriptor) anyerror!Counter = noopCounter,
    upDownCounterFn: *const fn (?*anyopaque, InstrumentDescriptor) anyerror!UpDownCounter = noopUDC,
    histogramFn: *const fn (?*anyopaque, InstrumentDescriptor) anyerror!Histogram = noopHistogram,
    gaugeFn: *const fn (?*anyopaque, InstrumentDescriptor) anyerror!Gauge = noopGauge,

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

test "no-op meter returns no-op instruments" {
    const m: Meter = .{ .scope = .{ .name = "test" } };
    const c = try m.counter(.{ .name = "x", .kind = .counter });
    c.add(1, &.{});
    const h = try m.histogram(.{ .name = "y", .kind = .histogram });
    h.record(1.0, &.{});
}
