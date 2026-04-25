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
    defer span.deinit();
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
};

pub const BatchSpanProcessor = struct {
    allocator: std.mem.Allocator,
    exporter: SpanExporter,
    resource_ref: *const Resource,
    options: BatchSpanProcessorOptions,
    queue: std.ArrayList(*trace_api.SpanState),
    dropped: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, exporter: SpanExporter, resource_ref: *const Resource, options: BatchSpanProcessorOptions) !*BatchSpanProcessor {
        const self = try allocator.create(BatchSpanProcessor);
        self.* = .{
            .allocator = allocator,
            .exporter = exporter,
            .resource_ref = resource_ref,
            .options = options,
            .queue = .empty,
        };
        return self;
    }

    pub fn deinit(self: *BatchSpanProcessor) void {
        for (self.queue.items) |s| s.deinit();
        self.queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn processor(self: *BatchSpanProcessor) SpanProcessor {
        return .{ .ctx = self, .onEndFn = batchOnEnd, .forceFlushFn = batchForceFlush, .shutdownFn = batchShutdown };
    }

    fn drain(self: *BatchSpanProcessor) ![]*trace_api.SpanState {
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
            for (batch) |s| s.deinit();
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
        _ = self.exporter.exportSpans(datas) catch {};
        for (batch) |s| s.deinit();
    }
};

fn batchOnEnd(ctx: ?*anyopaque, span: *trace_api.SpanState) void {
    const self: *BatchSpanProcessor = @ptrCast(@alignCast(ctx.?));
    if (self.queue.items.len >= self.options.max_queue_size) {
        self.dropped +%= 1;
        span.deinit();
        return;
    }
    self.queue.append(self.allocator, span) catch {
        self.dropped +%= 1;
        span.deinit();
        return;
    };
    if (self.queue.items.len >= self.options.max_export_batch_size) {
        const batch = self.drain() catch return;
        self.exportBatch(batch);
    }
}

fn batchForceFlush(ctx: ?*anyopaque, timeout_ms: u64) anyerror!void {
    const self: *BatchSpanProcessor = @ptrCast(@alignCast(ctx.?));
    while (self.queue.items.len > 0) {
        const batch = self.drain() catch return error.ExportTimeout;
        self.exportBatch(batch);
    }
    try self.exporter.forceFlush(timeout_ms);
}

fn batchShutdown(ctx: ?*anyopaque) void {
    const self: *BatchSpanProcessor = @ptrCast(@alignCast(ctx.?));
    while (self.queue.items.len > 0) {
        const batch = self.drain() catch break;
        self.exportBatch(batch);
    }
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

test "retry backoff scales with attempt" {
    var prng = std.Random.DefaultPrng.init(1);
    const p = RetryPolicy{};
    const a = nextBackoff(p, 0, &prng);
    const b = nextBackoff(p, 4, &prng);
    try std.testing.expect(b >= a or a == 0);
}
