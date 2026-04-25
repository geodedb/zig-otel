// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Metrics SDK — MeterProvider, instrument aggregation, and a periodic
// reader that drives exporters on a schedule (or only on-demand via
// `collect()`).

const std = @import("std");
const metrics_api = @import("../api/metrics.zig");
const attrs_mod = @import("../internal/attributes.zig");
const clock_mod = @import("../internal/clock.zig");
const trace_api = @import("../api/trace.zig");
const Resource = @import("resource.zig").Resource;
const exp = @import("export.zig");

pub const MetricsConfig = struct {
    resource: ?*Resource = null,
    clock: clock_mod.Clock = clock_mod.default,
    readers: []const MetricReader = &.{},
};

pub const MetricReader = struct {
    ctx: ?*anyopaque,
    collectFn: *const fn (?*anyopaque, std.mem.Allocator, *MeterProvider) anyerror!void,
    forceFlushFn: *const fn (?*anyopaque, u64) anyerror!void,
    shutdownFn: *const fn (?*anyopaque) void,

    pub fn collect(self: MetricReader, allocator: std.mem.Allocator, provider: *MeterProvider) !void {
        try self.collectFn(self.ctx, allocator, provider);
    }
};

const InstrumentBackend = struct {
    descriptor: metrics_api.InstrumentDescriptor,
    scope: trace_api.InstrumentationScope,
    /// Stable since this slice is owned by the provider's arena.
    points: std.ArrayList(AggregatedPoint),
    is_monotonic: bool = true,
    /// Back-pointer so instrument operations can route through the
    /// provider without a threadlocal.
    provider: *MeterProvider,

    pub fn deinit(self: *InstrumentBackend, allocator: std.mem.Allocator) void {
        for (self.points.items) |*pt| pt.deinit(allocator);
        self.points.deinit(allocator);
    }
};

const AggregatedPoint = struct {
    attribute_key: []u8,
    attributes: attrs_mod.AttributeSet,
    start_unix_nano: u64,
    last_unix_nano: u64,
    value: union(enum) {
        sum_int: i64,
        sum_uint: u64,
        gauge_double: f64,
        histogram: HistogramAcc,
    },

    pub fn deinit(self: *AggregatedPoint, allocator: std.mem.Allocator) void {
        allocator.free(self.attribute_key);
        self.attributes.deinit();
        switch (self.value) {
            .histogram => |*h| h.deinit(allocator),
            else => {},
        }
    }
};

const HistogramAcc = struct {
    bounds: []f64,
    counts: []u64,
    sum: f64 = 0.0,
    count: u64 = 0,
    min: ?f64 = null,
    max: ?f64 = null,

    pub fn deinit(self: *HistogramAcc, allocator: std.mem.Allocator) void {
        allocator.free(self.bounds);
        allocator.free(self.counts);
    }
};

pub const MeterProvider = struct {
    allocator: std.mem.Allocator,
    config: MetricsConfig,
    resource: *Resource,
    owns_resource: bool,
    instruments: std.ArrayList(*InstrumentBackend),
    clock: clock_mod.Clock,

    pub fn init(allocator: std.mem.Allocator, config: MetricsConfig) !MeterProvider {
        var owns = false;
        var resource_ptr: *Resource = undefined;
        if (config.resource) |r| {
            resource_ptr = r;
        } else {
            const owned = try allocator.create(Resource);
            owned.* = try @import("resource.zig").defaultResource(allocator);
            resource_ptr = owned;
            owns = true;
        }
        return .{
            .allocator = allocator,
            .config = config,
            .resource = resource_ptr,
            .owns_resource = owns,
            .instruments = .empty,
            .clock = config.clock,
        };
    }

    pub fn deinit(self: *MeterProvider) void {
        for (self.config.readers) |r| r.shutdownFn(r.ctx);
        for (self.instruments.items) |inst| {
            inst.deinit(self.allocator);
            self.allocator.destroy(inst);
        }
        self.instruments.deinit(self.allocator);
        if (self.owns_resource) {
            self.resource.deinit();
            self.allocator.destroy(self.resource);
        }
    }

    pub fn meter(self: *MeterProvider, scope: trace_api.InstrumentationScope) metrics_api.Meter {
        return .{
            .ctx = self,
            .scope = scope,
            .counterFn = makeCounter,
            .upDownCounterFn = makeUpDownCounter,
            .histogramFn = makeHistogram,
            .gaugeFn = makeGauge,
        };
    }

    pub fn forceFlush(self: *MeterProvider, timeout_ms: u64) !void {
        for (self.config.readers) |r| try r.forceFlushFn(r.ctx, timeout_ms);
    }

    fn newInstrument(self: *MeterProvider, descriptor: metrics_api.InstrumentDescriptor, scope: trace_api.InstrumentationScope) !*InstrumentBackend {
        const inst = try self.allocator.create(InstrumentBackend);
        inst.* = .{
            .descriptor = descriptor,
            .scope = scope,
            .points = .empty,
            .is_monotonic = descriptor.kind == .counter or descriptor.kind == .observable_counter,
            .provider = self,
        };
        try self.instruments.append(self.allocator, inst);
        return inst;
    }

    fn pointFor(self: *MeterProvider, inst: *InstrumentBackend, attributes: []const attrs_mod.Entry, now: u64) !*AggregatedPoint {
        const key = try attributeKey(self.allocator, attributes);
        for (inst.points.items) |*pt| {
            if (std.mem.eql(u8, pt.attribute_key, key)) {
                self.allocator.free(key);
                return pt;
            }
        }
        var attr_set = attrs_mod.AttributeSet.init(self.allocator);
        for (attributes) |entry| try attr_set.put(entry.key, entry.value);
        const pt: AggregatedPoint = .{
            .attribute_key = key,
            .attributes = attr_set,
            .start_unix_nano = now,
            .last_unix_nano = now,
            .value = switch (inst.descriptor.kind) {
                .counter => .{ .sum_uint = 0 },
                .up_down_counter, .observable_up_down_counter => .{ .sum_int = 0 },
                .observable_counter => .{ .sum_uint = 0 },
                .gauge, .observable_gauge => .{ .gauge_double = 0.0 },
                .histogram => blk: {
                    const bounds = inst.descriptor.explicit_buckets orelse metrics_api.ExplicitBuckets{ .boundaries = &default_histogram_bounds };
                    const owned_bounds = try self.allocator.dupe(f64, bounds.boundaries);
                    const counts = try self.allocator.alloc(u64, owned_bounds.len + 1);
                    @memset(counts, 0);
                    break :blk .{ .histogram = .{ .bounds = owned_bounds, .counts = counts } };
                },
            },
        };
        try inst.points.append(self.allocator, pt);
        return &inst.points.items[inst.points.items.len - 1];
    }
};

const default_histogram_bounds = [_]f64{ 0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000 };

fn attributeKey(allocator: std.mem.Allocator, entries: []const attrs_mod.Entry) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    // Sort a copy by key for stable identity.
    const sorted = try allocator.alloc(attrs_mod.Entry, entries.len);
    defer allocator.free(sorted);
    @memcpy(sorted, entries);
    std.mem.sort(attrs_mod.Entry, sorted, {}, lessThanEntry);
    for (sorted) |e| {
        try buf.appendSlice(allocator, e.key);
        try buf.append(allocator, '=');
        try formatValue(allocator, &buf, e.value);
        try buf.append(allocator, '|');
    }
    return try allocator.dupe(u8, buf.items);
}

fn lessThanEntry(_: void, a: attrs_mod.Entry, b: attrs_mod.Entry) bool {
    return std.mem.order(u8, a.key, b.key) == .lt;
}

fn formatValue(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), v: attrs_mod.Value) !void {
    switch (v) {
        .string => |s| try buf.appendSlice(allocator, s),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .int => |i| {
            var tmp: [24]u8 = undefined;
            const out = try std.fmt.bufPrint(tmp[0..], "{d}", .{i});
            try buf.appendSlice(allocator, out);
        },
        .double => |d| {
            var tmp: [40]u8 = undefined;
            const out = try std.fmt.bufPrint(tmp[0..], "{d}", .{d});
            try buf.appendSlice(allocator, out);
        },
        else => try buf.appendSlice(allocator, "<array>"),
    }
}

fn makeCounter(ctx: ?*anyopaque, d: metrics_api.InstrumentDescriptor) anyerror!metrics_api.Counter {
    const provider: *MeterProvider = @ptrCast(@alignCast(ctx.?));
    const inst = try provider.newInstrument(d, .{ .name = "" });
    return .{ .ctx = inst, .descriptor = d, .addFn = counterAdd };
}

fn counterAdd(ctx: ?*anyopaque, value: u64, attributes: []const attrs_mod.Entry) void {
    const inst: *InstrumentBackend = @ptrCast(@alignCast(ctx.?));
    const provider_ptr = providerOf(inst);
    const pt = provider_ptr.pointFor(inst, attributes, provider_ptr.clock.now()) catch return;
    switch (pt.value) {
        .sum_uint => |*v| v.* +%= value,
        else => {},
    }
    pt.last_unix_nano = provider_ptr.clock.now();
}

fn providerOf(inst: *InstrumentBackend) *MeterProvider {
    return inst.provider;
}

/// Compatibility shim retained for tests written against an earlier API.
/// New code does not need to call this — the instrument carries its own
/// provider pointer.
pub fn setActiveProvider(_: *MeterProvider) void {}

fn makeUpDownCounter(ctx: ?*anyopaque, d: metrics_api.InstrumentDescriptor) anyerror!metrics_api.UpDownCounter {
    const provider: *MeterProvider = @ptrCast(@alignCast(ctx.?));
    const inst = try provider.newInstrument(d, .{ .name = "" });
    return .{ .ctx = inst, .descriptor = d, .addFn = udcAdd };
}

fn udcAdd(ctx: ?*anyopaque, value: i64, attributes: []const attrs_mod.Entry) void {
    const inst: *InstrumentBackend = @ptrCast(@alignCast(ctx.?));
    const provider_ptr = providerOf(inst);
    const pt = provider_ptr.pointFor(inst, attributes, provider_ptr.clock.now()) catch return;
    switch (pt.value) {
        .sum_int => |*v| v.* +%= value,
        else => {},
    }
    pt.last_unix_nano = provider_ptr.clock.now();
}

fn makeHistogram(ctx: ?*anyopaque, d: metrics_api.InstrumentDescriptor) anyerror!metrics_api.Histogram {
    const provider: *MeterProvider = @ptrCast(@alignCast(ctx.?));
    const inst = try provider.newInstrument(d, .{ .name = "" });
    return .{ .ctx = inst, .descriptor = d, .recordFn = histRecord };
}

fn histRecord(ctx: ?*anyopaque, value: f64, attributes: []const attrs_mod.Entry) void {
    const inst: *InstrumentBackend = @ptrCast(@alignCast(ctx.?));
    const provider_ptr = providerOf(inst);
    const pt = provider_ptr.pointFor(inst, attributes, provider_ptr.clock.now()) catch return;
    switch (pt.value) {
        .histogram => |*h| {
            h.sum += value;
            h.count += 1;
            h.min = if (h.min) |m| @min(m, value) else value;
            h.max = if (h.max) |m| @max(m, value) else value;
            var idx: usize = 0;
            for (h.bounds) |b| {
                if (value <= b) break;
                idx += 1;
            }
            h.counts[idx] += 1;
        },
        else => {},
    }
    pt.last_unix_nano = provider_ptr.clock.now();
}

fn makeGauge(ctx: ?*anyopaque, d: metrics_api.InstrumentDescriptor) anyerror!metrics_api.Gauge {
    const provider: *MeterProvider = @ptrCast(@alignCast(ctx.?));
    const inst = try provider.newInstrument(d, .{ .name = "" });
    return .{ .ctx = inst, .descriptor = d, .setFn = gaugeSet };
}

fn gaugeSet(ctx: ?*anyopaque, value: f64, attributes: []const attrs_mod.Entry) void {
    const inst: *InstrumentBackend = @ptrCast(@alignCast(ctx.?));
    const provider_ptr = providerOf(inst);
    const pt = provider_ptr.pointFor(inst, attributes, provider_ptr.clock.now()) catch return;
    switch (pt.value) {
        .gauge_double => |*v| v.* = value,
        else => {},
    }
    pt.last_unix_nano = provider_ptr.clock.now();
}

/// Snapshot every instrument into `out_alloc`-owned MetricData slices.
/// The caller frees the returned slice and each element's points.
pub fn collect(provider: *MeterProvider, out_alloc: std.mem.Allocator) ![]exp.MetricData {
    var out: std.ArrayList(exp.MetricData) = .empty;
    errdefer {
        for (out.items) |m| out_alloc.free(m.points);
        out.deinit(out_alloc);
    }

    for (provider.instruments.items) |inst| {
        if (inst.points.items.len == 0) continue;
        const points = try out_alloc.alloc(exp.DataPoint, inst.points.items.len);
        for (inst.points.items, 0..) |*pt, i| {
            points[i] = switch (pt.value) {
                .sum_int => |v| .{
                    .start_unix_nano = pt.start_unix_nano,
                    .time_unix_nano = pt.last_unix_nano,
                    .attributes = &pt.attributes,
                    .value = .{ .number = .{ .int = v } },
                },
                .sum_uint => |v| .{
                    .start_unix_nano = pt.start_unix_nano,
                    .time_unix_nano = pt.last_unix_nano,
                    .attributes = &pt.attributes,
                    .value = .{ .number = .{ .int = @intCast(v) } },
                },
                .gauge_double => |v| .{
                    .start_unix_nano = pt.start_unix_nano,
                    .time_unix_nano = pt.last_unix_nano,
                    .attributes = &pt.attributes,
                    .value = .{ .number = .{ .double = v } },
                },
                .histogram => |h| .{
                    .start_unix_nano = pt.start_unix_nano,
                    .time_unix_nano = pt.last_unix_nano,
                    .attributes = &pt.attributes,
                    .value = .{ .histogram = .{
                        .bounds = h.bounds,
                        .counts = h.counts,
                        .sum = h.sum,
                        .count = h.count,
                        .min = h.min,
                        .max = h.max,
                    } },
                },
            };
        }
        try out.append(out_alloc, .{
            .name = inst.descriptor.name,
            .description = inst.descriptor.description,
            .unit = inst.descriptor.unit,
            .kind = inst.descriptor.kind,
            .temporality = inst.descriptor.temporality,
            .is_monotonic = inst.is_monotonic,
            .points = points,
            .instrumentation_scope = inst.scope,
            .resource = provider.resource,
        });
    }
    return out.toOwnedSlice(out_alloc);
}

test "counter aggregation" {
    var resource = try @import("resource.zig").defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();
    setActiveProvider(&mp);

    const m = mp.meter(.{ .name = "test" });
    const c = try m.counter(.{ .name = "events", .kind = .counter });
    c.add(1, &.{});
    c.add(2, &.{});

    const datas = try collect(&mp, std.testing.allocator);
    defer {
        for (datas) |d| std.testing.allocator.free(d.points);
        std.testing.allocator.free(datas);
    }
    try std.testing.expectEqual(@as(usize, 1), datas.len);
    try std.testing.expectEqual(@as(i64, 3), datas[0].points[0].value.number.int);
}

test "histogram bucket counts" {
    var resource = try @import("resource.zig").defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try MeterProvider.init(std.testing.allocator, .{ .resource = &resource });
    defer mp.deinit();
    setActiveProvider(&mp);

    const m = mp.meter(.{ .name = "test" });
    const h = try m.histogram(.{
        .name = "latency",
        .kind = .histogram,
        .explicit_buckets = .{ .boundaries = &.{ 1.0, 5.0, 10.0 } },
    });
    h.record(0.5, &.{});
    h.record(3.0, &.{});
    h.record(20.0, &.{});

    const datas = try collect(&mp, std.testing.allocator);
    defer {
        for (datas) |d| std.testing.allocator.free(d.points);
        std.testing.allocator.free(datas);
    }
    const hp = datas[0].points[0].value.histogram;
    try std.testing.expectEqual(@as(u64, 3), hp.count);
    try std.testing.expectEqualSlices(u64, &.{ 1, 1, 0, 1 }, hp.counts);
}
