// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

//! Comparison-layer A/B harness for the zero-overhead-when-disabled
//! bench system. Built twice — once with `-Dotel_disabled=false`
//! (variant=default) and once with `-Dotel_disabled=true`
//! (variant=comptime_disabled) — and run by
//! `scripts/bench_ab_runner.sh`. The diff between the two output
//! documents proves (or refutes) the comptime-disabled hard pass
//! criterion: `comptime-disabled` ns/op must be within ±2 ns of
//! `baseline-no-call` ns/op AND have alloc_count == 0.
//!
//! Every scenario runs in BOTH builds. The body itself is unchanged;
//! the build flag flips what API methods compile to. Scenarios named
//! `comptime-disabled` and `level-0-disabled` are the load-bearing
//! axis-B measurements: under flag=true their bodies elide entirely,
//! under flag=false they exercise the real SDK code paths.

const std = @import("std");
const Io = std.Io;
const otel = @import("otel");
const framework = @import("framework");
const build_options = @import("build_options");

const variant_tag: []const u8 = if (build_options.otel_disabled) "comptime_disabled" else "default";

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const scenarios = [_]framework.Scenario{
        .{ .name = "baseline-no-call", .layer = .comparison, .variant = variant_tag, .ops_per_iteration = 10_000, .zero_alloc_expected = true, .run = benchBaseline },
        .{ .name = "noop-tracer-startend", .layer = .comparison, .variant = variant_tag, .ops_per_iteration = 10_000, .zero_alloc_expected = true, .run = benchNoopTracer },
        .{ .name = "runtime-disabled-alwaysOff", .layer = .comparison, .variant = variant_tag, .ops_per_iteration = 10_000, .run = benchRuntimeAlwaysOff },
        .{ .name = "fully-enabled-alwaysOn-inmemory", .layer = .comparison, .variant = variant_tag, .ops_per_iteration = 1_000, .run = benchFullyEnabled },
        .{ .name = "comptime-disabled", .layer = .comparison, .variant = variant_tag, .ops_per_iteration = 10_000, .run = benchComptimeDisabled },
        .{ .name = "runtime-disabled-noop", .layer = .comparison, .variant = variant_tag, .ops_per_iteration = 10_000, .zero_alloc_expected = true, .run = benchRuntimeNoop },
        .{ .name = "level-0-disabled", .layer = .comparison, .variant = variant_tag, .ops_per_iteration = 10_000, .run = benchLevel0Disabled },
        .{ .name = "level-1-tracer-noop", .layer = .comparison, .variant = variant_tag, .ops_per_iteration = 10_000, .zero_alloc_expected = true, .run = benchLevel1 },
        .{ .name = "level-2-tracer-alwaysoff", .layer = .comparison, .variant = variant_tag, .ops_per_iteration = 10_000, .run = benchLevel2 },
        .{ .name = "level-3-tracing-only", .layer = .comparison, .variant = variant_tag, .ops_per_iteration = 1_000, .run = benchLevel3 },
        .{ .name = "level-4-tracing-metrics", .layer = .comparison, .variant = variant_tag, .ops_per_iteration = 1_000, .run = benchLevel4 },
        .{ .name = "level-5-tracing-metrics-logs", .layer = .comparison, .variant = variant_tag, .ops_per_iteration = 1_000, .run = benchLevel5 },
        .{ .name = "level-6-full-otlp-http-loopback", .layer = .comparison, .variant = variant_tag, .ops_per_iteration = 100, .run = benchLevel6 },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench-ab"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| {
            var stamped = opts;
            // Stamp the variant into the command label so the output JSON
            // is self-describing without the runner script having to mutate
            // the file.
            if (stamped.command_label.len == 0) stamped.command_label = variant_tag;
            try framework.runScenarios(allocator, init.io, &scenarios, stamped);
        },
    }
}

// ============================================================================
// Axis A — runtime overhead
// ============================================================================

fn benchBaseline(ctx: *framework.Context) anyerror!void {
    // Control: no OTel call. The optimizer must not collapse the loop;
    // the doNotOptimizeAway sink keeps the loop body alive.
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        std.mem.doNotOptimizeAway(i);
    }
}

fn benchNoopTracer(ctx: *framework.Context) anyerror!void {
    // API-layer Tracer with default (noop) vtable. Measures the cost of
    // the vtable dispatch: function pointer load + branch on null state.
    const tracer: otel.api.trace.Tracer = .{ .scope = .{ .name = "bench" } };
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const span = try tracer.startSpan(.empty(), "x", .{});
        std.mem.doNotOptimizeAway(span.state);
    }
}

fn benchRuntimeAlwaysOff(ctx: *framework.Context) anyerror!void {
    // SDK provider with alwaysOff sampler. ID generation still runs (per
    // src/sdk/trace.zig:224-226) before the sampler decision drops the
    // span, so this is the worst-case cost of the "disabled but SDK
    // linked and initialised" path.
    var resource = try otel.sdk.resource.defaultResource(ctx.allocator);
    defer resource.deinit();
    var tp = try otel.sdk.trace.TracerProvider.init(ctx.allocator, .{
        .resource = &resource,
        .sampler = otel.sdk.trace.alwaysOff(),
    });
    defer tp.deinit();
    const tracer = tp.tracer(.{ .name = "bench" });

    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const span = try tracer.startSpan(.empty(), "x", .{});
        std.mem.doNotOptimizeAway(span.state);
        span.end(null);
    }
}

fn benchFullyEnabled(ctx: *framework.Context) anyerror!void {
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

    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const span = try tracer.startSpan(.empty(), "op", .{});
        try span.setIntAttribute("bench.iter", @intCast(i));
        span.end(null);
    }
    std.mem.doNotOptimizeAway(rec.spans.items.len);
}

fn benchRuntimeNoop(ctx: *framework.Context) anyerror!void {
    // No SDK provider at all; user code uses an API-layer Tracer
    // value directly. Same measured path as noop-tracer-startend; named
    // separately for the architect's symmetry.
    return benchNoopTracer(ctx);
}

// ============================================================================
// Axis B — comptime elision
// ============================================================================

fn benchComptimeDisabled(ctx: *framework.Context) anyerror!void {
    // Wires the SDK provider, then exercises tracer.startSpan() inside
    // the timed loop. Under -Dotel_disabled=true, every method call
    // collapses comptime to a no-op. Under -Dotel_disabled=false, the
    // full SDK pipeline runs (this row is then identical to the
    // fully-enabled-alwaysOn-inmemory scenario for that build, and the
    // hard-criterion check ignores it for the false build).
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

    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const span = try tracer.startSpan(.empty(), "op", .{});
        try span.setIntAttribute("bench.iter", @intCast(i));
        span.end(null);
    }
    std.mem.doNotOptimizeAway(rec.spans.items.len);
}

fn benchLevel0Disabled(ctx: *framework.Context) anyerror!void {
    // Identical body to comptime-disabled; named separately so the level
    // ladder report has a contiguous level-0..level-6 axis.
    return benchComptimeDisabled(ctx);
}

// ============================================================================
// Level ladder — measures incremental cost per telemetry layer
// ============================================================================

fn benchLevel1(ctx: *framework.Context) anyerror!void {
    return benchNoopTracer(ctx);
}

fn benchLevel2(ctx: *framework.Context) anyerror!void {
    return benchRuntimeAlwaysOff(ctx);
}

fn benchLevel3(ctx: *framework.Context) anyerror!void {
    return benchFullyEnabled(ctx);
}

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
    const histogram = try meter.histogram(.{ .name = "bench.latency", .kind = .histogram });

    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const span = try tracer.startSpan(.empty(), "op", .{});
        try span.setIntAttribute("bench.iter", @intCast(i));
        counter.add(1, &.{});
        histogram.record(1.5, &.{});
        span.end(null);
    }
    std.mem.doNotOptimizeAway(rec.spans.items.len);
}

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
    const histogram = try meter.histogram(.{ .name = "bench.latency", .kind = .histogram });
    const logger = lp.logger(.{ .name = "bench" });

    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const span = try tracer.startSpan(.empty(), "op", .{});
        try span.setIntAttribute("bench.iter", @intCast(i));
        counter.add(1, &.{});
        histogram.record(1.5, &.{});
        logger.emit(.{ .severity = .info, .body = .{ .string = "x" } });
        span.end(null);
    }
    std.mem.doNotOptimizeAway(rec.spans.items.len + rec.logs.items.len);
}

fn benchLevel6(ctx: *framework.Context) anyerror!void {
    var resource = try otel.sdk.resource.defaultResource(ctx.allocator);
    defer resource.deinit();

    var otlp_exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(ctx.allocator, .{
        .endpoint = "http://localhost:4318",
        .protocol = .http_protobuf,
    });
    defer otlp_exporter.deinit();
    otlp_exporter.transport = fakeTransport;

    var tp = try otel.sdk.trace.TracerProvider.init(ctx.allocator, .{
        .resource = &resource,
        .default_exporter = otlp_exporter.spanExporter(),
    });
    defer tp.deinit();
    var mp = try otel.sdk.metrics.MeterProvider.init(ctx.allocator, .{ .resource = &resource });
    defer mp.deinit();

    const tracer = tp.tracer(.{ .name = "bench" });
    const meter = mp.meter(.{ .name = "bench" });
    const counter = try meter.counter(.{ .name = "bench.requests", .kind = .counter });

    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const span = try tracer.startSpan(.empty(), "op", .{});
        try span.setIntAttribute("bench.iter", @intCast(i));
        counter.add(1, &.{});
        span.end(null);
    }
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
