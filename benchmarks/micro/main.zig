// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

//! Micro-benchmark suite for the zero-overhead-when-disabled bench
//! system. Each scenario isolates one hot path; zero-alloc scenarios
//! assert their contract via `framework.Scenario.zero_alloc_expected`.
//!
//! See docs/performance/2026-04-26-zero-overhead-when-disabled/plan.json
//! for the full scenario catalog and intent.

const std = @import("std");
const Io = std.Io;
const otel = @import("otel");
const framework = @import("framework");

const attrs = otel.internal.attributes;
const id_mod = otel.internal.id;
const clock_mod = otel.internal.clock;
const redact = otel.internal.redact;
const json_codec = otel.internal.json_codec;
const trace_api = otel.api.trace;

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const scenarios = [_]framework.Scenario{
        .{ .name = "micro_attr_put_new", .layer = .micro, .ops_per_iteration = 100, .run = benchAttrPutNew },
        .{ .name = "micro_attr_put_update", .layer = .micro, .ops_per_iteration = 10_000, .run = benchAttrPutUpdate },
        .{ .name = "micro_attr_put_near_limit", .layer = .micro, .ops_per_iteration = 5_000, .run = benchAttrPutNearLimit },
        .{ .name = "micro_counter_add_no_attrs", .layer = .micro, .ops_per_iteration = 10_000, .run = benchCounterAddNoAttrs },
        .{ .name = "micro_counter_add_4_attrs_hit", .layer = .micro, .ops_per_iteration = 10_000, .run = benchCounterAdd4AttrsHit },
        .{ .name = "micro_histogram_record_4_attrs_hit", .layer = .micro, .ops_per_iteration = 10_000, .run = benchHistogramRecord4AttrsHit },
        .{ .name = "micro_span_record_steady_state", .layer = .micro, .ops_per_iteration = 1_000, .run = benchSpanRecordSteadyState },
        .{ .name = "micro_next_trace_id", .layer = .micro, .ops_per_iteration = 100_000, .zero_alloc_expected = true, .run = benchNextTraceId },
        .{ .name = "micro_next_span_id", .layer = .micro, .ops_per_iteration = 100_000, .zero_alloc_expected = true, .run = benchNextSpanId },
        .{ .name = "micro_clock_unix_nano", .layer = .micro, .ops_per_iteration = 100_000, .zero_alloc_expected = true, .run = benchClockUnixNano },
        .{ .name = "micro_redact_is_sensitive_miss", .layer = .micro, .ops_per_iteration = 100_000, .zero_alloc_expected = true, .run = benchRedactMiss },
        .{ .name = "micro_redact_is_sensitive_hit", .layer = .micro, .ops_per_iteration = 100_000, .zero_alloc_expected = true, .run = benchRedactHit },
        .{ .name = "micro_json_write_attrs_4", .layer = .micro, .ops_per_iteration = 10_000, .run = benchJsonWriteAttrs4 },
        .{ .name = "micro_json_write_attrs_32", .layer = .micro, .ops_per_iteration = 5_000, .run = benchJsonWriteAttrs32 },
        .{ .name = "micro_noop_vtable_dispatch", .layer = .micro, .ops_per_iteration = 1_000_000, .zero_alloc_expected = true, .run = benchNoopVtable },
        // PR-2 (#36): nested-encode scaling probe. ops_per_iteration here
        // is the batch size handed to `encodeSpansProto`; one iteration
        // is one encode call producing one ResourceSpans payload. The
        // three sizes pin O(N) wall-clock behaviour of the deferred-
        // compaction encoder against the old quadratic `copyForwards`.
        .{ .name = "micro_encode_spans_proto_64", .layer = .micro, .ops_per_iteration = 64, .run = benchEncodeSpansProto64 },
        .{ .name = "micro_encode_spans_proto_512", .layer = .micro, .ops_per_iteration = 512, .run = benchEncodeSpansProto512 },
        .{ .name = "micro_encode_spans_proto_4096", .layer = .micro, .ops_per_iteration = 4096, .run = benchEncodeSpansProto4096 },
    };

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench-micro"),
        .list_only => try framework.printScenarios(stderr, &scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, &scenarios, opts),
    }
}

// ----------------------------------------------------------------------------
// AttributeSet
// ----------------------------------------------------------------------------

fn benchAttrPutNew(ctx: *framework.Context) anyerror!void {
    // Each op inserts one unique key into a fresh set. Measures the
    // (init + put + deinit) cost of a single new-key insertion.
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        var set = attrs.AttributeSet.init(ctx.allocator);
        defer set.deinit();
        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "k{d}", .{i}) catch unreachable;
        try set.put(key, .{ .int = @intCast(i) });
        std.mem.doNotOptimizeAway(set.entries.items.len);
    }
}

fn benchAttrPutUpdate(ctx: *framework.Context) anyerror!void {
    // Same key written `ops` times into one set. First put inserts;
    // subsequent puts walk the linear scan and arena-dup the new value.
    var set = attrs.AttributeSet.init(ctx.allocator);
    defer set.deinit();
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        try set.put("k", .{ .int = @intCast(i) });
    }
    std.mem.doNotOptimizeAway(set.entries.items.len);
}

fn benchAttrPutNearLimit(ctx: *framework.Context) anyerror!void {
    // Pre-fill near `max_attributes` so the linear scan walks ~120
    // entries on every put. Measures scan cost in the worst case
    // before drops kick in.
    var set = attrs.AttributeSet.init(ctx.allocator);
    defer set.deinit();
    var pre: u32 = 0;
    while (pre < 120) : (pre += 1) {
        var buf: [16]u8 = undefined;
        const k = std.fmt.bufPrint(&buf, "pre{d}", .{pre}) catch unreachable;
        try set.put(k, .{ .int = @intCast(pre) });
    }
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        try set.put("hot", .{ .int = @intCast(i) });
    }
    std.mem.doNotOptimizeAway(set.entries.items.len);
}

// ----------------------------------------------------------------------------
// Metrics — pointFor hit path
// ----------------------------------------------------------------------------

fn benchCounterAddNoAttrs(ctx: *framework.Context) anyerror!void {
    if (@import("build_options").otel_disabled) return;
    var resource = try otel.sdk.resource.defaultResource(ctx.allocator);
    defer resource.deinit();
    var mp = try otel.sdk.metrics.MeterProvider.init(ctx.allocator, .{ .resource = &resource });
    defer mp.deinit();
    const m = mp.meter(.{ .name = "bench" });
    const c = try m.counter(.{ .name = "ops", .kind = .counter });
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        c.add(1, &.{});
    }
}

fn benchCounterAdd4AttrsHit(ctx: *framework.Context) anyerror!void {
    if (@import("build_options").otel_disabled) return;
    var resource = try otel.sdk.resource.defaultResource(ctx.allocator);
    defer resource.deinit();
    var mp = try otel.sdk.metrics.MeterProvider.init(ctx.allocator, .{ .resource = &resource });
    defer mp.deinit();
    const m = mp.meter(.{ .name = "bench" });
    const c = try m.counter(.{ .name = "requests", .kind = .counter });
    const attributes = [_]attrs.Entry{
        .{ .key = "http.method", .value = .{ .string = "GET" } },
        .{ .key = "http.status_code", .value = .{ .int = 200 } },
        .{ .key = "http.route", .value = .{ .string = "/api/v1/items" } },
        .{ .key = "service.name", .value = .{ .string = "demo" } },
    };
    // Prime the point so we measure the hit path.
    c.add(1, attributes[0..]);
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        c.add(1, attributes[0..]);
    }
}

fn benchHistogramRecord4AttrsHit(ctx: *framework.Context) anyerror!void {
    if (@import("build_options").otel_disabled) return;
    var resource = try otel.sdk.resource.defaultResource(ctx.allocator);
    defer resource.deinit();
    var mp = try otel.sdk.metrics.MeterProvider.init(ctx.allocator, .{ .resource = &resource });
    defer mp.deinit();
    const m = mp.meter(.{ .name = "bench" });
    const h = try m.histogram(.{ .name = "latency_ms", .kind = .histogram });
    const attributes = [_]attrs.Entry{
        .{ .key = "http.method", .value = .{ .string = "GET" } },
        .{ .key = "http.status_code", .value = .{ .int = 200 } },
        .{ .key = "http.route", .value = .{ .string = "/api/v1/items" } },
        .{ .key = "service.name", .value = .{ .string = "demo" } },
    };
    h.record(12.5, attributes[0..]);
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        h.record(@floatFromInt(i % 1000), attributes[0..]);
    }
}

// ----------------------------------------------------------------------------
// ID generation (zero-alloc)
// ----------------------------------------------------------------------------

fn benchNextTraceId(ctx: *framework.Context) anyerror!void {
    var random = id_mod.Random.initFromCsprng();
    const gen = random.generator();
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const tid = gen.nextTraceId();
        std.mem.doNotOptimizeAway(tid.bytes[0]);
    }
}

fn benchNextSpanId(ctx: *framework.Context) anyerror!void {
    var random = id_mod.Random.initFromCsprng();
    const gen = random.generator();
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const sid = gen.nextSpanId();
        std.mem.doNotOptimizeAway(sid.bytes[0]);
    }
}

// ----------------------------------------------------------------------------
// Clock (zero-alloc)
// ----------------------------------------------------------------------------

fn benchClockUnixNano(ctx: *framework.Context) anyerror!void {
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const t = clock_mod.unixNanoNow();
        std.mem.doNotOptimizeAway(t);
    }
}

// ----------------------------------------------------------------------------
// Redact (zero-alloc)
// ----------------------------------------------------------------------------

fn benchRedactMiss(ctx: *framework.Context) anyerror!void {
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const r = redact.isSensitive("ordinary.attribute.name");
        std.mem.doNotOptimizeAway(r);
    }
}

fn benchRedactHit(ctx: *framework.Context) anyerror!void {
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const r = redact.isSensitive("X-Authorization-Token");
        std.mem.doNotOptimizeAway(r);
    }
}

// ----------------------------------------------------------------------------
// JSON codec
// ----------------------------------------------------------------------------

fn benchJsonWriteAttrs4(ctx: *framework.Context) anyerror!void {
    return jsonWriteAttrs(ctx, 4);
}

fn benchJsonWriteAttrs32(ctx: *framework.Context) anyerror!void {
    return jsonWriteAttrs(ctx, 32);
}

fn jsonWriteAttrs(ctx: *framework.Context, attr_count: u32) !void {
    var set = attrs.AttributeSet.init(ctx.allocator);
    defer set.deinit();
    var k: u32 = 0;
    while (k < attr_count) : (k += 1) {
        var buf: [16]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "k{d}", .{k});
        try set.putString(key, "value-string-of-modest-length");
    }
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(ctx.allocator);
        try json_codec.writeAttributes(ctx.allocator, &out, &set);
        std.mem.doNotOptimizeAway(out.items.len);
    }
}

// ----------------------------------------------------------------------------
// SpanState steady-state recording
// ----------------------------------------------------------------------------

fn benchSpanRecordSteadyState(ctx: *framework.Context) anyerror!void {
    if (@import("build_options").otel_disabled) return;
    var resource = try otel.sdk.resource.defaultResource(ctx.allocator);
    defer resource.deinit();
    var rec = otel.exporters.in_memory.Recorder.init(ctx.allocator);
    defer rec.deinit();
    // Explicit Simple processor — this scenario isolates the SDK's
    // span-lifecycle cost; using the default (BSP per ADR-0003) would
    // also amortise queue + batch overhead and answer a different
    // question. See PERF_GAP_ANALYSIS Top-5 risks for the BSP-vs-
    // Simple trade-off.
    const sp = try ctx.allocator.create(otel.sdk.exporter.SimpleSpanProcessor);
    defer ctx.allocator.destroy(sp);
    sp.* = otel.sdk.exporter.SimpleSpanProcessor.init(ctx.allocator, rec.spanExporter(), &resource);
    var tp = try otel.sdk.trace.TracerProvider.init(ctx.allocator, .{
        .resource = &resource,
        .processors = &.{sp.processor()},
    });
    defer tp.deinit();
    const t = tp.tracer(.{ .name = "bench" });
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const span = try t.startSpan(.empty(), "op", .{});
        try span.setStringAttribute("k", "v");
        span.end(null);
    }
    std.mem.doNotOptimizeAway(rec.spans.items.len);
}

// ----------------------------------------------------------------------------
// Noop vtable dispatch (zero-alloc)
// ----------------------------------------------------------------------------

fn benchNoopVtable(ctx: *framework.Context) anyerror!void {
    // Construct an API-layer Tracer with the default (noop) vtable.
    // `startSpan` dispatches through the function pointer to noopStart,
    // which returns Span.noop. No allocations — exercises the vtable
    // indirection cost in isolation.
    const tracer: trace_api.Tracer = .{ .scope = .{ .name = "bench" } };
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        const span = try tracer.startSpan(.empty(), "x", .{});
        std.mem.doNotOptimizeAway(span.state);
    }
}

// ----------------------------------------------------------------------------
// PR-2 (#36) — encodeSpansProto nested-encode scaling
// ----------------------------------------------------------------------------
//
// `Writer.commitSubMessage` used to `copyForwards`-shift the payload tail
// every time a submessage closed; nested OTLP messages (ResourceSpans →
// ScopeSpans → Span → Event/Link/Status) made this O(N²) in body bytes.
// The three sizes 64 / 512 / 4096 frame the regression: pre-fix the per-
// span ns/op grew super-linearly with batch size; post-fix it is flat.
// Each scenario runs a single `encodeSpansProto` call per iteration with
// `ops_per_iteration = batch_size`, so `ns/op` reads as ns/span.

fn benchEncodeSpansProto64(ctx: *framework.Context) anyerror!void {
    return encodeSpansProtoBatch(ctx, 64);
}

fn benchEncodeSpansProto512(ctx: *framework.Context) anyerror!void {
    return encodeSpansProtoBatch(ctx, 512);
}

fn benchEncodeSpansProto4096(ctx: *framework.Context) anyerror!void {
    return encodeSpansProtoBatch(ctx, 4096);
}

fn encodeSpansProtoBatch(ctx: *framework.Context, batch: usize) !void {
    var resource = try otel.sdk.resource.defaultResource(ctx.allocator);
    defer resource.deinit();
    var attr_set = attrs.AttributeSet.init(ctx.allocator);
    defer attr_set.deinit();
    try attr_set.putString("http.method", "GET");
    try attr_set.putString("http.route", "/api/v1/items");
    try attr_set.putInt("http.status_code", 200);
    try attr_set.putString("service.name", "demo");

    var spans = try ctx.allocator.alloc(otel.sdk.exporter.SpanData, batch);
    defer ctx.allocator.free(spans);
    var i: usize = 0;
    while (i < batch) : (i += 1) {
        spans[i] = .{
            .name = "bench-span",
            .span_context = .{
                .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
                .span_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8 } },
            },
            .start_unix_nano = @intCast(1_000 + i),
            .end_unix_nano = @intCast(2_000 + i),
            .attributes = &attr_set,
            .events = &.{},
            .links = &.{},
            .instrumentation_scope = .{ .name = "bench" },
            .resource = &resource,
        };
    }

    // One encode call per iteration; the framework's `ops_per_iteration`
    // is `batch`, so the reported ns/op equals ns-per-span. Sample
    // multiple iterations for noise tolerance.
    const out = try otel.exporters.otlp_http.encodeSpansProto(ctx.allocator, spans);
    defer ctx.allocator.free(out);
    std.mem.doNotOptimizeAway(out.len);
}
