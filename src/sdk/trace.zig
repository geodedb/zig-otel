// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Trace SDK — TracerProvider, samplers, and Span lifecycle.

const std = @import("std");
const trace_api = @import("../api/trace.zig");
const ctx_mod = @import("../api/context.zig");
const id_mod = @import("../internal/id.zig");
const clock_mod = @import("../internal/clock.zig");
const attrs_mod = @import("../internal/attributes.zig");
const Resource = @import("resource.zig").Resource;
const exp = @import("export.zig");
const span_pool = @import("span_pool.zig");

pub const SamplingDecision = enum {
    drop,
    record_only,
    record_and_sample,
};

pub const SamplingResult = struct {
    decision: SamplingDecision,
    /// Optional new tracestate to attach to the span context.
    trace_state: ?[]const u8 = null,
};

pub const Sampler = struct {
    ctx: ?*anyopaque = null,
    description: []const u8,
    sampleFn: *const fn (?*anyopaque, ctx_mod.Context, id_mod.TraceId, []const u8, trace_api.SpanKind) SamplingResult,

    pub fn shouldSample(self: Sampler, parent: ctx_mod.Context, trace_id: id_mod.TraceId, name: []const u8, kind: trace_api.SpanKind) SamplingResult {
        return self.sampleFn(self.ctx, parent, trace_id, name, kind);
    }
};

fn alwaysOnSample(_: ?*anyopaque, _: ctx_mod.Context, _: id_mod.TraceId, _: []const u8, _: trace_api.SpanKind) SamplingResult {
    return .{ .decision = .record_and_sample };
}

fn alwaysOffSample(_: ?*anyopaque, _: ctx_mod.Context, _: id_mod.TraceId, _: []const u8, _: trace_api.SpanKind) SamplingResult {
    return .{ .decision = .drop };
}

pub fn alwaysOn() Sampler {
    return .{ .description = "AlwaysOnSampler", .sampleFn = alwaysOnSample };
}

pub fn alwaysOff() Sampler {
    return .{ .description = "AlwaysOffSampler", .sampleFn = alwaysOffSample };
}

pub const ParentBased = struct {
    root_sampler: Sampler,

    pub fn init(root: Sampler) ParentBased {
        return .{ .root_sampler = root };
    }

    pub fn sampler(self: *const ParentBased) Sampler {
        return .{
            .ctx = @ptrCast(@constCast(self)),
            .description = "ParentBased",
            .sampleFn = parentBasedSample,
        };
    }
};

fn parentBasedSample(ctx: ?*anyopaque, parent: ctx_mod.Context, tid: id_mod.TraceId, name: []const u8, kind: trace_api.SpanKind) SamplingResult {
    const self: *const ParentBased = @ptrCast(@alignCast(ctx.?));
    if (parent.activeSpanContext()) |sc| {
        if (sc.flags.sampled) return .{ .decision = .record_and_sample };
        return .{ .decision = .drop };
    }
    return self.root_sampler.shouldSample(parent, tid, name, kind);
}

pub const TraceIdRatio = struct {
    threshold: u64,
    description_buf: [40]u8 = undefined,

    pub fn init(ratio: f64) TraceIdRatio {
        const clamped = std.math.clamp(ratio, 0.0, 1.0);
        const max: f64 = @floatFromInt(std.math.maxInt(u64));
        const t = @as(u64, @intFromFloat(@floor(clamped * max)));
        return .{ .threshold = t };
    }

    pub fn sampler(self: *TraceIdRatio) Sampler {
        const desc = std.fmt.bufPrint(self.description_buf[0..], "TraceIdRatioBased({d})", .{self.threshold}) catch self.description_buf[0..0];
        return .{
            .ctx = self,
            .description = desc,
            .sampleFn = ratioSample,
        };
    }
};

fn ratioSample(ctx: ?*anyopaque, _: ctx_mod.Context, tid: id_mod.TraceId, _: []const u8, _: trace_api.SpanKind) SamplingResult {
    const self: *TraceIdRatio = @ptrCast(@alignCast(ctx.?));
    // Use the low 8 bytes of the trace id as a u64.
    var lo: u64 = 0;
    for (tid.bytes[8..16], 0..) |b, i| {
        lo |= @as(u64, b) << @intCast(i * 8);
    }
    return if (lo < self.threshold) .{ .decision = .record_and_sample } else .{ .decision = .drop };
}

pub const TraceConfig = struct {
    resource: ?*Resource = null,
    sampler: ?Sampler = null,
    id_generator: ?id_mod.IdGenerator = null,
    clock: clock_mod.Clock = clock_mod.default,
    processors: []const exp.SpanProcessor = &.{},
    /// When `processors` is empty and a default exporter is supplied, the
    /// provider wraps it in a SimpleSpanProcessor.
    default_exporter: ?exp.SpanExporter = null,
    max_attributes: usize = attrs_mod.max_attributes,
    /// Runtime kill-switch. When `true`, `tracer()` returns an API-layer
    /// noop tracer so every `startSpan` call collapses to `Span.noop`
    /// without touching the SDK pipeline. Mirrors the behaviour of the
    /// comptime `-Dotel_disabled=true` build flag, but at runtime so
    /// callers can wire it from `OTEL_SDK_DISABLED` (`Config.disabled`)
    /// or any other policy. The comptime flag still wins when set.
    disabled: bool = false,
};

pub const TracerProvider = struct {
    allocator: std.mem.Allocator,
    config: TraceConfig,
    sampler: Sampler,
    id_generator: id_mod.IdGenerator,
    clock: clock_mod.Clock,
    resource: *Resource,
    /// The provider owns this when no caller-supplied resource is provided.
    owns_resource: bool,
    processors: []exp.SpanProcessor,
    /// Heap-allocated so the processor's internal `ctx` pointer stays
    /// valid even if the TracerProvider value is moved. Tagged union:
    /// `default_exporter` paths default to `.batch` per ADR-0003;
    /// callers who want the legacy synchronous Simple path provide
    /// their own SimpleSpanProcessor via the `processors` field.
    default_processor: DefaultProcessor = .none,
    default_random: ?*id_mod.Random = null,
    /// SpanState reuse pool. See ADR-0001. Heap-allocated so the
    /// recycler's `ctx` pointer stays valid if the TracerProvider
    /// value is moved.
    pool: *span_pool.Pool,

    pub const DefaultProcessor = union(enum) {
        none,
        simple: *exp.SimpleSpanProcessor,
        batch: *exp.BatchSpanProcessor,
    };

    pub fn init(allocator: std.mem.Allocator, config: TraceConfig) !TracerProvider {
        var owns_resource = false;
        var resource_ptr: *Resource = undefined;
        if (config.resource) |r| {
            resource_ptr = r;
        } else {
            const owned = try allocator.create(Resource);
            owned.* = try @import("resource.zig").defaultResource(allocator);
            resource_ptr = owned;
            owns_resource = true;
        }

        const pool_ptr = try allocator.create(span_pool.Pool);
        errdefer allocator.destroy(pool_ptr);
        pool_ptr.* = span_pool.Pool.init(allocator);

        var self: TracerProvider = .{
            .allocator = allocator,
            .config = config,
            .sampler = config.sampler orelse alwaysOn(),
            .id_generator = undefined,
            .clock = config.clock,
            .resource = resource_ptr,
            .owns_resource = owns_resource,
            .processors = &.{},
            .pool = pool_ptr,
        };

        if (config.id_generator) |g| {
            self.id_generator = g;
        } else {
            const random = try allocator.create(id_mod.Random);
            // GAP-SEC-H-5: seed from the OS CSPRNG so trace IDs are
            // unpredictable across processes and TracerProvider
            // instances. The previous hardcoded 0xC0DE_C0DE made every
            // run produce the same first ID stream, which lets an
            // observer correlate traces across deployments.
            random.* = id_mod.Random.initFromCsprng();
            self.default_random = random;
            self.id_generator = random.generator();
        }

        if (config.processors.len > 0) {
            const owned = try allocator.alloc(exp.SpanProcessor, config.processors.len);
            @memcpy(owned, config.processors);
            self.processors = owned;
        } else if (config.default_exporter) |exporter| {
            // ADR-0003: default to BatchSpanProcessor. Callers who
            // want the synchronous Simple path supply their own
            // SimpleSpanProcessor via `processors`.
            const bsp = try exp.BatchSpanProcessor.init(allocator, exporter, resource_ptr, .{
                .async_workers = 1,
            });
            errdefer bsp.deinit();
            self.default_processor = .{ .batch = bsp };
            const owned = try allocator.alloc(exp.SpanProcessor, 1);
            owned[0] = bsp.processor();
            self.processors = owned;
        } else {
            self.processors = try allocator.alloc(exp.SpanProcessor, 0);
        }

        return self;
    }

    pub fn deinit(self: *TracerProvider) void {
        for (self.processors) |p| p.shutdown();
        // Drain the pool BEFORE freeing the pool struct so any
        // pooled SpanStates run their final deinit while the
        // child allocator is still valid.
        self.pool.deinit();
        self.allocator.destroy(self.pool);
        self.allocator.free(self.processors);
        switch (self.default_processor) {
            .none => {},
            .simple => |sp| self.allocator.destroy(sp),
            .batch => |bsp| bsp.deinit(),
        }
        if (self.default_random) |r| self.allocator.destroy(r);
        if (self.owns_resource) {
            self.resource.deinit();
            self.allocator.destroy(self.resource);
        }
    }

    pub fn shutdown(self: *TracerProvider) void {
        for (self.processors) |p| p.shutdown();
    }

    pub fn forceFlush(self: *TracerProvider, timeout_ms: u64) !void {
        for (self.processors) |p| try p.forceFlush(timeout_ms);
    }

    pub fn tracer(self: *TracerProvider, scope: trace_api.InstrumentationScope) trace_api.Tracer {
        if (comptime @import("build_options").otel_disabled) return .{ .scope = scope };
        if (self.config.disabled) return .{ .scope = scope };
        return .{
            .ctx = self,
            .scope = scope,
            .startSpanFn = startSpan,
        };
    }
};

fn startSpan(ctx: ?*anyopaque, scope: trace_api.InstrumentationScope, parent: ctx_mod.Context, name: []const u8, opts: trace_api.SpanOptions) anyerror!trace_api.Span {
    const self: *TracerProvider = @ptrCast(@alignCast(ctx.?));

    // Inherit trace id from parent when present, otherwise generate a fresh one.
    const parent_sc = parent.activeSpanContext();
    const trace_id = if (parent_sc) |psc| psc.trace_id else self.id_generator.nextTraceId();
    const span_id = self.id_generator.nextSpanId();

    const decision = self.sampler.shouldSample(parent, trace_id, name, opts.kind);
    var sc: ctx_mod.SpanContext = .{
        .trace_id = trace_id,
        .span_id = span_id,
        .flags = .{ .sampled = decision.decision == .record_and_sample },
    };
    if (decision.trace_state) |ts| sc.trace_state = ts;

    if (decision.decision == .drop) {
        return trace_api.Span{ .state = null, .sc = sc };
    }

    const start_ns = opts.start_unix_nano orelse self.clock.now();
    var state = blk: {
        if (self.pool.tryAcquire()) |reused| {
            // Reseat fields that are bound to this span's identity.
            // The `recycle()` path already cleared the previous
            // span's transient state and reset the arena/attributes,
            // so we just need to re-prime them.
            const child = reused.arena.child_allocator;
            reused.name = try child.dupe(u8, name);
            reused.sc = sc;
            reused.start_unix_nano = start_ns;
            reused.instrumentation_scope = scope;
            // Pool entries already have recycler set; no change needed.
            break :blk reused;
        }
        const fresh = try trace_api.SpanState.init(self.allocator, name, sc, scope, start_ns);
        fresh.recycler = self.pool.recycler();
        break :blk fresh;
    };
    state.kind = opts.kind;
    if (parent_sc) |psc| state.parent_span_id = psc.span_id;

    for (opts.initial_attributes) |entry| {
        state.attributes.put(entry.key, entry.value) catch {};
    }
    for (opts.links) |link| {
        try state.links.append(self.allocator, link);
    }

    // Wire processors via the `on_end` callback.
    if (self.processors.len > 0) {
        state.on_end_ctx = self;
        state.on_end = onSpanEnd;
    }

    return trace_api.Span{ .state = state, .sc = sc };
}

fn onSpanEnd(ctx: ?*anyopaque, span: *trace_api.SpanState) void {
    const self: *TracerProvider = @ptrCast(@alignCast(ctx.?));
    if (self.processors.len == 0) {
        span.recycle();
        return;
    }
    if (self.processors.len == 1) {
        // Hand ownership off to the single processor; processor frees the state.
        self.processors[0].onEnd(span);
        return;
    }
    // Multiple processors: each gets to read the span. The first processor
    // takes ownership; subsequent processors receive the same pointer but
    // must not free it. (Per spec, processors are read-only after the
    // first.) The exporter pipeline frees state once exported.
    for (self.processors[1..]) |p| p.onEnd(span);
    self.processors[0].onEnd(span);
}

test "alwaysOff sampler returns a non-recording span" {
    var resource = try @import("resource.zig").defaultResource(std.testing.allocator);
    defer resource.deinit();
    var tp = try TracerProvider.init(std.testing.allocator, .{
        .sampler = alwaysOff(),
        .resource = &resource,
    });
    defer tp.deinit();
    const t = tp.tracer(.{ .name = "test" });
    const s = try t.startSpan(.empty(), "ignored", .{});
    try std.testing.expect(!s.isRecording());
    s.end(null);
}

test "trace id ratio sampler boundaries" {
    var ratio_zero = TraceIdRatio.init(0.0);
    const s_zero = ratio_zero.sampler();
    try std.testing.expectEqual(SamplingDecision.drop, s_zero.shouldSample(.empty(), id_mod.TraceId.invalid, "x", .internal).decision);

    var ratio_one = TraceIdRatio.init(1.0);
    const s_one = ratio_one.sampler();
    const tid: id_mod.TraceId = .{ .bytes = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x7f } };
    try std.testing.expectEqual(SamplingDecision.record_and_sample, s_one.shouldSample(.empty(), tid, "x", .internal).decision);
}
