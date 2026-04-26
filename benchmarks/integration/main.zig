// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

//! Integration-benchmark suite. End-to-end pipeline scenarios at
//! ascending telemetry levels (L3-L6 per the architecture document).
//!
//! Each scenario constructs a fresh provider chain inside the timed
//! body. The init/deinit cost is included in the measurement; for the
//! 100- and 10000-span sweeps this is a small fraction of the total,
//! and for the 1-span scenario it dominates (intentional — that's the
//! cold-start cost a real consumer pays).
//!
//! L6 uses a fake transport plumbed into `OtlpHttpExporter.transport`
//! that returns a 200 OK without networking. This measures the OTLP
//! encode pipeline (protobuf or JSON) but does NOT measure socket I/O.
//! The real-network cost is captured in a follow-up scenario when the
//! loopback discard server lands.

const std = @import("std");
const Io = std.Io;
const otel = @import("otel");
const framework = @import("framework");
const build_options = @import("build_options");
const loopback_server = @import("loopback_server.zig");

/// Hoisted outside the timed loop per architect Decision D-3. Started
/// in `main()` when `-Dotel_use_devnw_tls=true`; consulted by
/// `benchLevel6` to decide between real-loopback and fakeTransport
/// modes. Null when the build flag is off, so the default
/// `zig build bench-integration` continues to measure encode-only L6
/// cost (current behaviour).
var g_loopback_server: ?*loopback_server.LoopbackServer = null;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    // Async-drain scenarios are gated on -Dotel_use_devnw_pool=true so
    // the synchronous default build doesn't list rows it can't actually
    // exercise. Compiled out entirely when the flag is off (F-4).
    const async_scenarios: []const framework.Scenario = if (build_options.use_devnw_pool) &.{
        .{ .name = "integ_level3_async_100spans", .layer = .integration, .ops_per_iteration = 100, .run = benchLevel3Async },
        .{ .name = "integ_level3_async_10kspans", .layer = .integration, .ops_per_iteration = 10_000, .run = benchLevel3Async },
    } else &.{};

    const sync_scenarios = [_]framework.Scenario{
        .{ .name = "integ_level3_sync_1span", .layer = .integration, .ops_per_iteration = 1, .run = benchLevel3 },
        .{ .name = "integ_level3_sync_100spans", .layer = .integration, .ops_per_iteration = 100, .run = benchLevel3 },
        .{ .name = "integ_level3_sync_10kspans", .layer = .integration, .ops_per_iteration = 10_000, .run = benchLevel3 },
        .{ .name = "integ_level4_sync_100spans", .layer = .integration, .ops_per_iteration = 100, .run = benchLevel4 },
        .{ .name = "integ_level5_sync_100spans", .layer = .integration, .ops_per_iteration = 100, .run = benchLevel5 },
        .{ .name = "integ_level6_otlp_loopback_100spans", .layer = .integration, .ops_per_iteration = 100, .run = benchLevel6 },
    };

    const scenarios = blk: {
        var combined: [sync_scenarios.len + 16]framework.Scenario = undefined;
        @memcpy(combined[0..sync_scenarios.len], &sync_scenarios);
        for (async_scenarios, 0..) |s, i| combined[sync_scenarios.len + i] = s;
        break :blk combined[0 .. sync_scenarios.len + async_scenarios.len];
    };

    if (build_options.use_devnw_tls) {
        g_loopback_server = try loopback_server.start(init.gpa);
    }
    defer if (g_loopback_server) |srv| {
        srv.stop();
        g_loopback_server = null;
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench-integration"),
        .list_only => try framework.printScenarios(stderr, scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, scenarios, opts),
    }
}

// ----------------------------------------------------------------------------
// Level 3 — tracing only, in-memory exporter
// ----------------------------------------------------------------------------

fn benchLevel3(ctx: *framework.Context) anyerror!void {
    var resource = try otel.sdk.resource.defaultResource(ctx.allocator);
    defer resource.deinit();
    var rec = otel.exporters.in_memory.Recorder.init(ctx.allocator);
    defer rec.deinit();

    var tp = try otel.sdk.trace.TracerProvider.init(ctx.allocator, .{
        .resource = &resource,
        .default_exporter = rec.spanExporter(),
    });
    defer tp.deinit();
    const tracer = tp.tracer(.{ .name = "bench" });

    try emitSpans(tracer, ctx.scenario.ops_per_iteration);
    std.mem.doNotOptimizeAway(rec.spans.items.len);
}

// ----------------------------------------------------------------------------
// Level 4 — tracing + metrics
// ----------------------------------------------------------------------------

fn benchLevel4(ctx: *framework.Context) anyerror!void {
    var resource = try otel.sdk.resource.defaultResource(ctx.allocator);
    defer resource.deinit();
    var rec = otel.exporters.in_memory.Recorder.init(ctx.allocator);
    defer rec.deinit();

    var tp = try otel.sdk.trace.TracerProvider.init(ctx.allocator, .{
        .resource = &resource,
        .default_exporter = rec.spanExporter(),
    });
    defer tp.deinit();
    var mp = try otel.sdk.metrics.MeterProvider.init(ctx.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const tracer = tp.tracer(.{ .name = "bench" });
    const meter = mp.meter(.{ .name = "bench" });
    const counter = try meter.counter(.{ .name = "bench.requests", .kind = .counter });
    const histogram = try meter.histogram(.{ .name = "bench.latency_ms", .kind = .histogram });

    try emitSpansAndMetrics(tracer, counter, histogram, ctx.scenario.ops_per_iteration);
    std.mem.doNotOptimizeAway(rec.spans.items.len);
}

// ----------------------------------------------------------------------------
// Level 5 — tracing + metrics + logs
// ----------------------------------------------------------------------------

fn benchLevel5(ctx: *framework.Context) anyerror!void {
    var resource = try otel.sdk.resource.defaultResource(ctx.allocator);
    defer resource.deinit();
    var rec = otel.exporters.in_memory.Recorder.init(ctx.allocator);
    defer rec.deinit();

    var tp = try otel.sdk.trace.TracerProvider.init(ctx.allocator, .{
        .resource = &resource,
        .default_exporter = rec.spanExporter(),
    });
    defer tp.deinit();
    var mp = try otel.sdk.metrics.MeterProvider.init(ctx.allocator, .{ .resource = &resource });
    defer mp.deinit();
    var lp = try otel.sdk.logs.LoggerProvider.init(ctx.allocator, .{
        .resource = &resource,
        .default_exporter = rec.logExporter(),
    });
    defer lp.deinit();

    const tracer = tp.tracer(.{ .name = "bench" });
    const meter = mp.meter(.{ .name = "bench" });
    const counter = try meter.counter(.{ .name = "bench.requests", .kind = .counter });
    const histogram = try meter.histogram(.{ .name = "bench.latency_ms", .kind = .histogram });
    const logger = lp.logger(.{ .name = "bench" });

    try emitFullPipeline(tracer, counter, histogram, logger, ctx.scenario.ops_per_iteration);
    std.mem.doNotOptimizeAway(rec.spans.items.len + rec.logs.items.len);
}

// ----------------------------------------------------------------------------
// Level 6 — full pipeline with OTLP/HTTP exporter (fake transport)
// ----------------------------------------------------------------------------

fn benchLevel6(ctx: *framework.Context) anyerror!void {
    var resource = try otel.sdk.resource.defaultResource(ctx.allocator);
    defer resource.deinit();

    // F-5: when the bench is built with -Dotel_use_devnw_tls=true and
    // the loopback server was started in main(), use the real
    // std.http.Client transport against the in-process server. When
    // the flag is off, fall back to the fakeTransport (encode-only)
    // so the default `zig build bench-integration` numbers stay
    // comparable across runs.
    var endpoint_buf: [64]u8 = undefined;
    const endpoint: []const u8 = if (build_options.use_devnw_tls and g_loopback_server != null)
        try g_loopback_server.?.endpoint(&endpoint_buf)
    else
        "http://localhost:4318";

    var otlp_exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(ctx.allocator, .{
        .endpoint = endpoint,
        .protocol = .http_protobuf,
        .allow_loopback = true,
    });
    defer otlp_exporter.deinit();

    if (build_options.use_devnw_tls and g_loopback_server != null) {
        // Plumb the std.Io view so httpTransportImpl (sentinel-routed
        // from expSpans) can drive std.http.Client over the real
        // socket. Leaving `transport` at the default sentinel value
        // is the trigger for the real path.
        otlp_exporter.io = ctx.io;
    } else {
        // Encode-only fallback: no network, returns 200 immediately.
        otlp_exporter.transport = fakeTransport;
    }

    var tp = try otel.sdk.trace.TracerProvider.init(ctx.allocator, .{
        .resource = &resource,
        .default_exporter = otlp_exporter.spanExporter(),
    });
    defer tp.deinit();

    var mp = try otel.sdk.metrics.MeterProvider.init(ctx.allocator, .{ .resource = &resource });
    defer mp.deinit();
    var rec = otel.exporters.in_memory.Recorder.init(ctx.allocator);
    defer rec.deinit();
    var lp = try otel.sdk.logs.LoggerProvider.init(ctx.allocator, .{
        .resource = &resource,
        .default_exporter = rec.logExporter(),
    });
    defer lp.deinit();

    const tracer = tp.tracer(.{ .name = "bench" });
    const meter = mp.meter(.{ .name = "bench" });
    const counter = try meter.counter(.{ .name = "bench.requests", .kind = .counter });
    const histogram = try meter.histogram(.{ .name = "bench.latency_ms", .kind = .histogram });
    const logger = lp.logger(.{ .name = "bench" });

    try emitFullPipeline(tracer, counter, histogram, logger, ctx.scenario.ops_per_iteration);
    std.mem.doNotOptimizeAway(rec.logs.items.len);
}

// ----------------------------------------------------------------------------
// Async-drain (F-4) — only compiled when -Dotel_use_devnw_pool=true
// ----------------------------------------------------------------------------

fn benchLevel3Async(ctx: *framework.Context) anyerror!void {
    var resource = try otel.sdk.resource.defaultResource(ctx.allocator);
    defer resource.deinit();
    var rec = otel.exporters.in_memory.Recorder.init(ctx.allocator);
    defer rec.deinit();

    const exporter = rec.spanExporter();
    var bsp = try otel.sdk.exporter.BatchSpanProcessor.init(ctx.allocator, exporter, &resource, .{
        .max_queue_size = 8192,
        .max_export_batch_size = 256,
        .schedule_delay_ms = 5,
        .async_workers = 2,
    });
    defer bsp.deinit();

    const proc = bsp.processor();
    var tp = try otel.sdk.trace.TracerProvider.init(ctx.allocator, .{
        .resource = &resource,
        .processors = &.{proc},
    });
    defer tp.deinit();

    const tracer = tp.tracer(.{ .name = "bench" });
    try emitSpans(tracer, ctx.scenario.ops_per_iteration);
    // Force the drain workers to converge before we deinit. F-3's
    // condition variable means this exits as soon as the workers
    // signal completion, instead of waiting on the legacy 200µs
    // poll floor.
    try bsp.processor().forceFlush(5_000);
    std.mem.doNotOptimizeAway(rec.spans.items.len);
}

fn fakeTransport(
    _: std.mem.Allocator,
    _: []const u8,
    _: []const u8,
    _: ?[]const u8,
    _: []const u8,
    _: []const u8,
    _: u64,
) anyerror!otel.exporters.otlp_http.TransportResult {
    return .{ .status = 200, .body = "" };
}

// ----------------------------------------------------------------------------
// Helpers
// ----------------------------------------------------------------------------

fn emitSpans(tracer: otel.api.trace.Tracer, ops: u64) !void {
    var i: u64 = 0;
    while (i < ops) : (i += 1) {
        const span = try tracer.startSpan(.empty(), "op", .{});
        try span.setStringAttribute("http.method", "GET");
        try span.setStringAttribute("http.url", "/v1/widgets");
        try span.setIntAttribute("http.status_code", 200);
        try span.setIntAttribute("bench.iter", @intCast(i));
        span.end(null);
    }
}

fn emitSpansAndMetrics(
    tracer: otel.api.trace.Tracer,
    counter: otel.api.metrics.Counter,
    histogram: otel.api.metrics.Histogram,
    ops: u64,
) !void {
    var i: u64 = 0;
    while (i < ops) : (i += 1) {
        const span = try tracer.startSpan(.empty(), "op", .{});
        try span.setStringAttribute("http.method", "GET");
        try span.setStringAttribute("http.url", "/v1/widgets");
        try span.setIntAttribute("http.status_code", 200);
        try span.setIntAttribute("bench.iter", @intCast(i));
        counter.add(1, &.{
            .{ .key = "method", .value = .{ .string = "GET" } },
            .{ .key = "status", .value = .{ .int = 200 } },
        });
        histogram.record(1.5, &.{
            .{ .key = "method", .value = .{ .string = "GET" } },
            .{ .key = "status", .value = .{ .int = 200 } },
        });
        span.end(null);
    }
}

fn emitFullPipeline(
    tracer: otel.api.trace.Tracer,
    counter: otel.api.metrics.Counter,
    histogram: otel.api.metrics.Histogram,
    logger: otel.api.logs.Logger,
    ops: u64,
) !void {
    var i: u64 = 0;
    while (i < ops) : (i += 1) {
        const span = try tracer.startSpan(.empty(), "op", .{});
        try span.setStringAttribute("http.method", "GET");
        try span.setStringAttribute("http.url", "/v1/widgets");
        try span.setIntAttribute("http.status_code", 200);
        try span.setIntAttribute("bench.iter", @intCast(i));
        counter.add(1, &.{
            .{ .key = "method", .value = .{ .string = "GET" } },
            .{ .key = "status", .value = .{ .int = 200 } },
        });
        histogram.record(1.5, &.{
            .{ .key = "method", .value = .{ .string = "GET" } },
            .{ .key = "status", .value = .{ .int = 200 } },
        });
        logger.emit(.{
            .severity = .info,
            .body = .{ .string = "request handled" },
        });
        span.end(null);
    }
}
