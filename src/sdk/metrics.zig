// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Metrics SDK — MeterProvider, instrument aggregation, and a periodic
// reader that drives exporters on a schedule (or only on-demand via
// `collect()`).

const std = @import("std");
const build_options = @import("build_options");
const metrics_api = @import("../api/metrics.zig");
const attrs_mod = @import("../internal/attributes.zig");
const clock_mod = @import("../internal/clock.zig");
const trace_api = @import("../api/trace.zig");
const Resource = @import("resource.zig").Resource;
const exp = @import("export.zig");
const config_mod = @import("config.zig");
const exporter_factory = @import("exporter_factory.zig");
const internal_sync = @import("../internal/sync.zig");

/// DevNW metrics module — only resolved when the build flag is on. The
/// in-repo aggregation pipeline owns the OpenTelemetry data-point shape;
/// when `Backend.devnw` is selected the SDK *additionally* mirrors writes
/// into a DevNW `Registry` so Prometheus-shaped exposure is available
/// alongside OTLP. See docs/DEPENDENCIES.md for the rationale.
const devnw_metrics = if (build_options.use_devnw_metrics) @import("devnw_metrics") else struct {};

/// Zero-arg mutex used to guard per-instrument aggregation state. This
/// is the shared `internal/sync.zig` `Mutex` (a thin local wrapper around
/// `std.Io.Mutex`'s `*Uncancelable` API on the global single-threaded I/O
/// instance) — the same primitive `export.zig` and `span_pool.zig` use.
/// Safe to call from any thread regardless of whether the caller is
/// registered with a `Threaded` runtime.
///
/// PR-1 / gitlab #135: this lock is intentionally *unconditional* (not a
/// flag-gated no-op) because the race it closes is triggered by any
/// external `std.Thread.spawn` caller, regardless of whether the
/// `-Dotel_use_devnw_pool` build flag is set.
const InstrumentMutex = internal_sync.Mutex;

/// Selects the aggregation backend. The in-repo backend is always
/// available; `devnw` mirrors counter/up-down/histogram/gauge writes
/// into a DevNW `metrics.Registry` while the in-repo aggregation
/// continues to own the OpenTelemetry data-point shape returned by
/// `collect()`.
pub const Backend = enum { in_repo, devnw };

pub const MetricsConfig = struct {
    resource: ?*Resource = null,
    clock: clock_mod.Clock = clock_mod.default,
    readers: []const MetricReader = &.{},
    backend: Backend = .in_repo,
    /// Default metric exporter. Stored on the provider so callers wiring
    /// a reader (PeriodicExportingMetricReader, #29 Stage G) can read
    /// it back via `MeterProvider.default_exporter`. Without a reader
    /// the exporter sits idle — symmetry with `TraceConfig` /
    /// `LogsConfig` is preserved so `OTEL_METRICS_EXPORTER=otlp_http`
    /// constructs an exporter even before the periodic reader lands.
    default_exporter: ?exp.MetricExporter = null,
    /// Runtime kill-switch. When `true`, `meter()` returns an API-layer
    /// noop Meter so every `counter`/`histogram`/`gauge` call collapses
    /// to a no-op without touching the aggregation pipeline. Mirrors the
    /// comptime `-Dotel_disabled=true` flag at runtime; the comptime
    /// flag still wins when set.
    disabled: bool = false,
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
    /// Hot-path lookup: fingerprint of the canonical (sorted) attribute
    /// set -> index into `points`. Built lazily on the first miss for
    /// each unique attribute combination. Hit-path lookup is O(1) and
    /// does not allocate. See `attrFingerprint`.
    points_index: std.AutoHashMapUnmanaged(u64, u32) = .empty,
    /// Per-instrument writer/collector mutex (PR-1, gitlab #135).
    ///
    /// Every mutation of `points` / `points_index`, every read of an
    /// `AggregatedPoint` from `points.items`, and the per-instrument
    /// snapshot loop in `collect()` must run under this lock. The lock
    /// is intentionally per-instrument (not provider-wide) so concurrent
    /// counters/histograms on different instruments stay independent.
    /// Holding it covers (a) the racing-grow on `points.append`, (b)
    /// the dangling `&items[idx]` after a re-grow, and (c) the
    /// torn read in `collect()` walking a slice whose `.items.ptr` is
    /// being moved by a concurrent recorder.
    mu: InstrumentMutex = .{},
    is_monotonic: bool = true,
    /// Back-pointer so instrument operations can route through the
    /// provider without a threadlocal.
    provider: *MeterProvider,
    /// Registered observable callbacks. Empty for synchronous
    /// instruments. Populated by `Meter.createObservable*` and
    /// `Meter.registerCallback`. `MeterProvider.collect()` invokes every
    /// callback in registration order under `mu` before snapshotting,
    /// per the OTel asynchronous-instrument contract.
    /// GAP-OBSERVABLE-INSTRUMENTS (#30).
    callbacks: std.ArrayList(ObservableCallbackEntry) = .empty,
    /// Monotonic registration counter. Each `Meter.createObservable*` /
    /// `Meter.registerCallback` increments this; the new entry's
    /// `callback_id` lets `unregisterCallback` find and remove it
    /// idempotently.
    next_callback_id: u32 = 1,
    /// Mirror handle into the DevNW `metrics.Registry` when the
    /// `Backend.devnw` aggregation is selected. Counters and observable
    /// counters mirror to a DevNW Counter; up/down counters and gauges
    /// mirror to a DevNW Gauge (the only signed primitive); histograms
    /// mirror to a DevNW Histogram. The mirror is owned by the
    /// Registry — we hold a borrowed pointer here and the Registry
    /// frees the underlying metric on `deinit`.
    devnw_mirror: DevnwMirror = .none,
    /// Sanitized name handed to the DevNW registry. Owned by the
    /// instrument; freed on `deinit`.
    devnw_name: ?[]u8 = null,

    pub fn deinit(self: *InstrumentBackend, allocator: std.mem.Allocator) void {
        for (self.points.items) |*pt| pt.deinit(allocator);
        self.points.deinit(allocator);
        self.points_index.deinit(allocator);
        self.callbacks.deinit(allocator);
        if (self.devnw_name) |n| allocator.free(n);
    }
};

/// One registered observable callback. The `id` lets unregister be
/// idempotent — passing a stale id matches no entry. `user_ctx` is
/// passed through to the callback verbatim.
const ObservableCallbackEntry = struct {
    id: u32,
    callback: metrics_api.ObservableCallback,
    user_ctx: ?*anyopaque,
};

/// Tagged borrowed handle into the DevNW registry. `none` for the
/// in-repo backend or for instruments whose DevNW registration failed
/// (e.g. duplicate name after sanitisation) — failure is non-fatal so
/// the OTLP path keeps working.
const DevnwMirror = if (build_options.use_devnw_metrics) union(enum) {
    none,
    counter: *devnw_metrics.Counter,
    gauge: *devnw_metrics.Gauge,
    histogram: *devnw_metrics.Histogram,
} else union(enum) {
    none,
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

/// DevNW Registry storage. When the build flag is off the type collapses
/// to a zero-size struct so MeterProvider stays the same shape.
const DevnwRegistryHolder = if (build_options.use_devnw_metrics) struct {
    registry: ?devnw_metrics.Registry = null,
} else struct {};

pub const MeterProvider = struct {
    allocator: std.mem.Allocator,
    config: MetricsConfig,
    resource: *Resource,
    owns_resource: bool,
    instruments: std.ArrayList(*InstrumentBackend),
    clock: clock_mod.Clock,
    devnw: DevnwRegistryHolder = .{},
    /// GAP-EXPORTER-FACTORY (#4): when the provider is built via
    /// `initFromConfig`, the factory-allocated exporter is stored here
    /// so `deinit` can free it. Stays `null` for the legacy
    /// manually-wired path so existing callers don't see a behaviour
    /// change.
    owned_exporter: ?exporter_factory.OwnedMetricExporter = null,

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
        var self: MeterProvider = .{
            .allocator = allocator,
            .config = config,
            .resource = resource_ptr,
            .owns_resource = owns,
            .instruments = .empty,
            .clock = config.clock,
        };
        if (build_options.use_devnw_metrics and config.backend == .devnw) {
            self.devnw.registry = devnw_metrics.Registry.init(allocator);
        }
        return self;
    }

    pub fn deinit(self: *MeterProvider) void {
        for (self.config.readers) |r| r.shutdownFn(r.ctx);
        // Deinit the DevNW registry BEFORE freeing instrument-owned
        // sanitized names — counters/gauges hold those slices by
        // reference, so dropping them while the registry is still alive
        // would be a UAF the moment DevNW grows a key-iterating shutdown
        // path.
        if (build_options.use_devnw_metrics) {
            if (self.devnw.registry) |*r| r.deinit();
        }
        for (self.instruments.items) |inst| {
            inst.deinit(self.allocator);
            self.allocator.destroy(inst);
        }
        self.instruments.deinit(self.allocator);
        // Free the factory-allocated exporter (if any) AFTER the
        // readers have been shut down — readers may still hold the
        // exporter handle through their `forceFlush` path.
        if (self.owned_exporter) |*owned| owned.deinit();
        self.owned_exporter = null;
        if (self.owns_resource) {
            self.resource.deinit();
            self.allocator.destroy(self.resource);
        }
    }

    /// Build a `MeterProvider` from a resolved `Config`.
    ///
    /// GAP-EXPORTER-FACTORY (#4). Constructs the right exporter from
    /// `cfg.metrics.exporter` + `cfg.metrics.otlp` via the
    /// `exporter_factory` and stores it on `config.default_exporter`.
    /// Until the periodic reader (#29 Stage G) lands the exporter sits
    /// idle; the cleanup path still frees it on `deinit`.
    ///
    /// `cfg.metrics.exporter == .prometheus` returns
    /// `error.PrometheusRequiresPullEndpoint` per the factory contract
    /// — prometheus is a pull exporter and must be wired against an
    /// already-built `*MeterProvider` via
    /// `exporters.prometheus.Prometheus.init`.
    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: *const config_mod.Config) !MeterProvider {
        var owned = try exporter_factory.metricExporterFromConfig(allocator, cfg);
        errdefer if (owned) |*o| o.deinit();

        const metrics_cfg: MetricsConfig = .{
            .default_exporter = if (owned) |o| o.exporter else null,
            .disabled = cfg.disabled,
        };
        var self = try init(allocator, metrics_cfg);
        self.owned_exporter = owned;
        owned = null;
        return self;
    }

    pub fn meter(self: *MeterProvider, scope: trace_api.InstrumentationScope) metrics_api.Meter {
        if (comptime build_options.otel_disabled) return .{ .scope = scope };
        if (self.config.disabled) return .{ .scope = scope };
        return .{
            .ctx = self,
            .scope = scope,
            .counterFn = makeCounter,
            .upDownCounterFn = makeUpDownCounter,
            .histogramFn = makeHistogram,
            .gaugeFn = makeGauge,
            .observableCounterFn = makeObservableCounter,
            .observableUpDownCounterFn = makeObservableUpDownCounter,
            .observableGaugeFn = makeObservableGauge,
            .registerCallbackFn = registerExtraCallback,
            .unregisterCallbackFn = unregisterCallback,
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
        if (build_options.use_devnw_metrics and self.config.backend == .devnw) {
            self.registerDevnwMirror(inst) catch {
                // Mirror registration is best-effort: a duplicate name
                // (post-sanitisation) or OOM in the registry must not
                // break the OpenTelemetry write path. Leave the mirror
                // tagged `.none` so writes skip the duplicate side.
            };
        }
        return inst;
    }

    fn registerDevnwMirror(self: *MeterProvider, inst: *InstrumentBackend) !void {
        if (!build_options.use_devnw_metrics) return;
        const reg_ptr = if (self.devnw.registry) |*r| r else return;
        const sanitized = try sanitizeMetricName(self.allocator, inst.descriptor.name);
        errdefer self.allocator.free(sanitized);
        const help = if (inst.descriptor.description.len > 0) inst.descriptor.description else inst.descriptor.name;
        switch (inst.descriptor.kind) {
            .counter, .observable_counter => {
                const c = try reg_ptr.counter(sanitized, help);
                inst.devnw_mirror = .{ .counter = c };
            },
            .up_down_counter, .observable_up_down_counter, .gauge, .observable_gauge => {
                // DevNW exposes a signed 64-bit Gauge; re-use it for
                // both up/down counters and gauges. f64 gauges round to
                // i64 on the mirror side — the OTLP path keeps the
                // double precision.
                const g = try reg_ptr.gauge(sanitized, help);
                inst.devnw_mirror = .{ .gauge = g };
            },
            .histogram => {
                const bounds = if (inst.descriptor.explicit_buckets) |b|
                    b.boundaries
                else
                    &default_histogram_bounds;
                const h = try reg_ptr.histogram(sanitized, help, bounds);
                inst.devnw_mirror = .{ .histogram = h };
            },
        }
        inst.devnw_name = sanitized;
    }

    /// Resolve (or create) the storage index for the point that owns
    /// `attributes` on this instrument.
    ///
    /// **Caller must hold `inst.mu`** for the entire window between the
    /// call and the last access to `inst.points.items[idx]`. The
    /// returned index is only stable while the lock is held: a
    /// concurrent recorder that triggers `points.append` invalidates
    /// every cached `&items[i]` pointer. See PR-1 / gitlab #135.
    fn pointIndexFor(self: *MeterProvider, inst: *InstrumentBackend, attributes: []const attrs_mod.Entry, now: u64) !u32 {
        // Hit path: zero-alloc canonical fingerprint -> O(1) index lookup.
        const fp = attrFingerprint(attributes);
        if (inst.points_index.get(fp)) |idx| return idx;

        // Miss path: build the formatted key for storage and append a
        // new point. attribute_key remains useful for stable
        // diagnostics and Prometheus exposition; only this path pays
        // the allocation cost. Allocations happen *after* we've
        // committed to the miss branch but *before* the index insert
        // so a partial failure doesn't leak an entry into
        // `points_index` that points at a non-existent slot.
        const key = try attributeKey(self.allocator, attributes);
        errdefer self.allocator.free(key);
        var attr_set = attrs_mod.AttributeSet.init(self.allocator);
        errdefer attr_set.deinit();
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
                    errdefer self.allocator.free(owned_bounds);
                    const counts = try self.allocator.alloc(u64, owned_bounds.len + 1);
                    @memset(counts, 0);
                    break :blk .{ .histogram = .{ .bounds = owned_bounds, .counts = counts } };
                },
            },
        };

        try inst.points.append(self.allocator, pt);
        const idx: u32 = @intCast(inst.points.items.len - 1);
        inst.points_index.put(self.allocator, fp, idx) catch |err| {
            // Roll the append back so the slice and the index stay in
            // sync. The just-appended point still owns its
            // `attribute_key`/`attributes`/histogram buffers, so we
            // explicitly tear those down before truncating.
            var dropped = inst.points.pop().?;
            dropped.deinit(self.allocator);
            return err;
        };
        return idx;
    }
};

const default_histogram_bounds = [_]f64{ 0, 5, 10, 25, 50, 75, 100, 250, 500, 750, 1000, 2500, 5000, 7500, 10000 };

/// Coerce an OpenTelemetry instrument name (which permits `.`, `-`, and
/// `/` per the spec) into the Prometheus-flavoured identifier the DevNW
/// `Registry` validates against (`[a-zA-Z_:][a-zA-Z0-9_:]*`). All
/// disallowed bytes collapse to `_`. A leading digit is prefixed with
/// `_` so the resulting string passes `validateName`. The caller owns
/// the returned slice.
fn sanitizeMetricName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (name.len == 0) return try allocator.dupe(u8, "_");
    const needs_prefix = name[0] >= '0' and name[0] <= '9';
    const out_len = name.len + @as(usize, if (needs_prefix) 1 else 0);
    const out = try allocator.alloc(u8, out_len);
    var off: usize = 0;
    if (needs_prefix) {
        out[0] = '_';
        off = 1;
    }
    for (name, 0..) |c, i| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == ':' or
            ((c >= '0' and c <= '9') and (i > 0 or needs_prefix));
        out[off + i] = if (ok) c else '_';
    }
    return out;
}

/// Compute a 64-bit canonical fingerprint of an attribute set without
/// allocating. The fingerprint is order-independent: the entries are
/// hashed in key-sorted order, so two equal sets in different
/// insertion orders produce the same value. Keys are case-sensitive,
/// and value bytes are mixed in via `Wyhash.update`. With ≤1024
/// distinct points per instrument the birthday-collision probability
/// is < 2^-44; we accept this as the bound on the hit-path's fast
/// integer lookup. The expensive verification (deep `attribute_key`
/// equality) is deliberately skipped on the hit path.
fn attrFingerprint(entries: []const attrs_mod.Entry) u64 {
    if (entries.len == 0) return 0;
    var idx_buf: [attrs_mod.max_attributes]u8 = undefined;
    const n = @min(entries.len, attrs_mod.max_attributes);
    for (idx_buf[0..n], 0..) |*slot, i| slot.* = @intCast(i);
    const Less = struct {
        e: []const attrs_mod.Entry,
        pub fn lt(ctx: @This(), a: u8, b: u8) bool {
            return std.mem.order(u8, ctx.e[a].key, ctx.e[b].key) == .lt;
        }
    };
    std.sort.pdq(u8, idx_buf[0..n], Less{ .e = entries }, Less.lt);

    // fips-exempt: non-security — attribute-set hashmap key hashing for metric
    // aggregation; not a secret.
    var hasher = std.hash.Wyhash.init(0xC0FFEE);
    for (idx_buf[0..n]) |i| {
        const e = entries[i];
        hasher.update(e.key);
        hasher.update("=");
        hashValue(&hasher, e.value);
        hasher.update("|");
    }
    return hasher.final();
}

// fips-exempt: non-security — attribute-value contribution to the metric-key hash.
fn hashValue(h: *std.hash.Wyhash, v: attrs_mod.Value) void {
    switch (v) {
        .string => |s| {
            h.update("s:");
            h.update(s);
        },
        .bool => |b| {
            h.update("b:");
            h.update(if (b) "1" else "0");
        },
        .int => |i| {
            h.update("i:");
            h.update(std.mem.asBytes(&i));
        },
        .double => |d| {
            h.update("d:");
            h.update(std.mem.asBytes(&d));
        },
        .string_array => |arr| {
            h.update("S:");
            for (arr) |s| {
                h.update(s);
                h.update(",");
            }
        },
        .bool_array => |arr| {
            h.update("B:");
            for (arr) |b| h.update(if (b) "1" else "0");
        },
        .int_array => |arr| {
            h.update("I:");
            h.update(std.mem.sliceAsBytes(arr));
        },
        .double_array => |arr| {
            h.update("D:");
            h.update(std.mem.sliceAsBytes(arr));
        },
    }
}

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
    const now = provider_ptr.clock.now();

    inst.mu.lock();
    defer inst.mu.unlock();
    const idx = provider_ptr.pointIndexFor(inst, attributes, now) catch return;
    const pt = &inst.points.items[idx];
    switch (pt.value) {
        .sum_uint => |*v| v.* +%= value,
        else => {},
    }
    // PR-8 (#141): reuse the timestamp captured before the lock — calling
    // `clock.now()` a second time here doubled the syscall budget per
    // record op without changing semantics (the lock holder's view of
    // "now" is monotonic from `pointIndexFor`'s perspective anyway).
    pt.last_unix_nano = now;

    mirrorCounterAdd(inst, value);
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
    const now = provider_ptr.clock.now();

    inst.mu.lock();
    defer inst.mu.unlock();
    const idx = provider_ptr.pointIndexFor(inst, attributes, now) catch return;
    const pt = &inst.points.items[idx];
    switch (pt.value) {
        .sum_int => |*v| v.* +%= value,
        else => {},
    }
    // PR-8 (#141): single `clock.now()` per record path — see counterAdd.
    pt.last_unix_nano = now;

    mirrorGaugeAdd(inst, value);
}

fn makeHistogram(ctx: ?*anyopaque, d: metrics_api.InstrumentDescriptor) anyerror!metrics_api.Histogram {
    const provider: *MeterProvider = @ptrCast(@alignCast(ctx.?));
    const inst = try provider.newInstrument(d, .{ .name = "" });
    return .{ .ctx = inst, .descriptor = d, .recordFn = histRecord };
}

fn histRecord(ctx: ?*anyopaque, value: f64, attributes: []const attrs_mod.Entry) void {
    const inst: *InstrumentBackend = @ptrCast(@alignCast(ctx.?));
    const provider_ptr = providerOf(inst);
    const now = provider_ptr.clock.now();

    inst.mu.lock();
    defer inst.mu.unlock();
    const idx = provider_ptr.pointIndexFor(inst, attributes, now) catch return;
    const pt = &inst.points.items[idx];
    switch (pt.value) {
        .histogram => |*h| {
            h.sum += value;
            h.count += 1;
            h.min = if (h.min) |m| @min(m, value) else value;
            h.max = if (h.max) |m| @max(m, value) else value;
            var bucket: usize = 0;
            for (h.bounds) |b| {
                if (value <= b) break;
                bucket += 1;
            }
            h.counts[bucket] += 1;
        },
        else => {},
    }
    // PR-8 (#141): single `clock.now()` per record path — see counterAdd.
    pt.last_unix_nano = now;

    mirrorHistogramObserve(inst, value);
}

fn makeGauge(ctx: ?*anyopaque, d: metrics_api.InstrumentDescriptor) anyerror!metrics_api.Gauge {
    const provider: *MeterProvider = @ptrCast(@alignCast(ctx.?));
    const inst = try provider.newInstrument(d, .{ .name = "" });
    return .{ .ctx = inst, .descriptor = d, .setFn = gaugeSet };
}

fn gaugeSet(ctx: ?*anyopaque, value: f64, attributes: []const attrs_mod.Entry) void {
    const inst: *InstrumentBackend = @ptrCast(@alignCast(ctx.?));
    const provider_ptr = providerOf(inst);
    const now = provider_ptr.clock.now();

    inst.mu.lock();
    defer inst.mu.unlock();
    const idx = provider_ptr.pointIndexFor(inst, attributes, now) catch return;
    const pt = &inst.points.items[idx];
    switch (pt.value) {
        .gauge_double => |*v| v.* = value,
        else => {},
    }
    // PR-8 (#141): single `clock.now()` per record path — see counterAdd.
    pt.last_unix_nano = now;

    mirrorGaugeSet(inst, value);
}

// -------------------------------------------------------------- Observable instruments
//
// GAP-OBSERVABLE-INSTRUMENTS (#30). Asynchronous instruments register a
// callback that is invoked under `inst.mu` at the start of each
// `MeterProvider.collect()` call. The callback receives an Observer that
// pumps `(value, attributes)` tuples through `pointIndexFor` — the same
// hash-indexed path the synchronous record-side uses (P0-1) so we never
// duplicate the points map.
//
// Concurrency: the callbacks list is mutated under `inst.mu`. Readers in
// `collect()` walk it under the same lock, so callback registration /
// unregistration is safe to interleave with concurrent sync writers and
// in-flight collects (the lock serialises everything).

fn makeObservableCounter(
    ctx: ?*anyopaque,
    d: metrics_api.InstrumentDescriptor,
    callback: metrics_api.ObservableCallback,
    user_ctx: ?*anyopaque,
) anyerror!metrics_api.ObservableCounter {
    const provider: *MeterProvider = @ptrCast(@alignCast(ctx.?));
    var descriptor = d;
    descriptor.kind = .observable_counter;
    const inst = try provider.newInstrument(descriptor, .{ .name = "" });
    const reg = try appendCallback(provider.allocator, inst, callback, user_ctx);
    return .{ .ctx = inst, .descriptor = descriptor, .registration = reg };
}

fn makeObservableUpDownCounter(
    ctx: ?*anyopaque,
    d: metrics_api.InstrumentDescriptor,
    callback: metrics_api.ObservableCallback,
    user_ctx: ?*anyopaque,
) anyerror!metrics_api.ObservableUpDownCounter {
    const provider: *MeterProvider = @ptrCast(@alignCast(ctx.?));
    var descriptor = d;
    descriptor.kind = .observable_up_down_counter;
    const inst = try provider.newInstrument(descriptor, .{ .name = "" });
    const reg = try appendCallback(provider.allocator, inst, callback, user_ctx);
    return .{ .ctx = inst, .descriptor = descriptor, .registration = reg };
}

fn makeObservableGauge(
    ctx: ?*anyopaque,
    d: metrics_api.InstrumentDescriptor,
    callback: metrics_api.ObservableCallback,
    user_ctx: ?*anyopaque,
) anyerror!metrics_api.ObservableGauge {
    const provider: *MeterProvider = @ptrCast(@alignCast(ctx.?));
    var descriptor = d;
    descriptor.kind = .observable_gauge;
    const inst = try provider.newInstrument(descriptor, .{ .name = "" });
    const reg = try appendCallback(provider.allocator, inst, callback, user_ctx);
    return .{ .ctx = inst, .descriptor = descriptor, .registration = reg };
}

fn appendCallback(
    allocator: std.mem.Allocator,
    inst: *InstrumentBackend,
    callback: metrics_api.ObservableCallback,
    user_ctx: ?*anyopaque,
) !metrics_api.ObservableRegistration {
    inst.mu.lock();
    defer inst.mu.unlock();
    const id = inst.next_callback_id;
    inst.next_callback_id += 1;
    try inst.callbacks.append(allocator, .{
        .id = id,
        .callback = callback,
        .user_ctx = user_ctx,
    });
    return .{ .instrument = inst, .callback_id = id };
}

fn registerExtraCallback(
    ctx: ?*anyopaque,
    on: metrics_api.ObservableRegistration,
    callback: metrics_api.ObservableCallback,
    user_ctx: ?*anyopaque,
) anyerror!metrics_api.ObservableRegistration {
    const provider: *MeterProvider = @ptrCast(@alignCast(ctx.?));
    const inst_ptr = on.instrument orelse return error.InvalidRegistration;
    const inst: *InstrumentBackend = @ptrCast(@alignCast(inst_ptr));
    return try appendCallback(provider.allocator, inst, callback, user_ctx);
}

fn unregisterCallback(_: ?*anyopaque, registration: metrics_api.ObservableRegistration) void {
    const inst_ptr = registration.instrument orelse return;
    const inst: *InstrumentBackend = @ptrCast(@alignCast(inst_ptr));
    inst.mu.lock();
    defer inst.mu.unlock();
    var i: usize = 0;
    while (i < inst.callbacks.items.len) : (i += 1) {
        if (inst.callbacks.items[i].id == registration.callback_id) {
            _ = inst.callbacks.orderedRemove(i);
            return;
        }
    }
    // Idempotent: stale or already-unregistered ids are a no-op.
}

/// Observer state used while a single observable callback runs. Owns
/// nothing — borrows the instrument and the provider so the observe
/// helpers can route into `pointIndexFor`. The `inst.mu` is *already
/// held* by the caller (`invokeCallbacksLocked`), so the observe
/// helpers must not relock it.
const ObserverCtx = struct {
    inst: *InstrumentBackend,
    provider: *MeterProvider,
    now: u64,
};

fn observerObserveInt(ctx: ?*anyopaque, value: i64, attributes: []const attrs_mod.Entry) void {
    const oc: *ObserverCtx = @ptrCast(@alignCast(ctx.?));
    const idx = oc.provider.pointIndexFor(oc.inst, attributes, oc.now) catch return;
    const pt = &oc.inst.points.items[idx];
    switch (pt.value) {
        // Asynchronous counter / up-down counter callbacks report the
        // current cumulative value — last write wins for that attribute
        // set within a single collect cycle (per OTel spec).
        .sum_uint => |*v| {
            if (value < 0) return; // observable_counter is monotonic
            v.* = @intCast(value);
        },
        .sum_int => |*v| v.* = value,
        .gauge_double => |*v| v.* = @floatFromInt(value),
        else => {},
    }
    pt.last_unix_nano = oc.now;
}

fn observerObserveDouble(ctx: ?*anyopaque, value: f64, attributes: []const attrs_mod.Entry) void {
    const oc: *ObserverCtx = @ptrCast(@alignCast(ctx.?));
    const idx = oc.provider.pointIndexFor(oc.inst, attributes, oc.now) catch return;
    const pt = &oc.inst.points.items[idx];
    switch (pt.value) {
        .gauge_double => |*v| v.* = value,
        .sum_int => |*v| {
            // Reject non-finite (NaN/±Inf) and out-of-`i64`-range doubles
            // before `@intFromFloat`, which is illegal behavior (panic in
            // Debug/ReleaseSafe, garbage in ReleaseFast) on such inputs.
            // NB: `@floatFromInt(maxInt(i64))` rounds UP to 2^63 in f64, so
            // the upper bound must be `>=` — a value of exactly 2^63 is out
            // of i64 range and would still panic under a strict `>`.
            if (!std.math.isFinite(value)) return;
            if (value < @as(f64, @floatFromInt(std.math.minInt(i64))) or
                value >= @as(f64, @floatFromInt(std.math.maxInt(i64)))) return;
            v.* = @intFromFloat(value);
        },
        .sum_uint => |*v| {
            // Mirror the sum_int guard: reject negatives, non-finite, and
            // out-of-`u64`-range doubles before `@intFromFloat`. Same f64
            // rounding caveat as above — `@floatFromInt(maxInt(u64))` rounds
            // up to 2^64, so the bound is `>=` (exactly 2^64 is out of range).
            if (value < 0 or !std.math.isFinite(value)) return;
            if (value >= @as(f64, @floatFromInt(std.math.maxInt(u64)))) return;
            v.* = @intFromFloat(value);
        },
        else => {},
    }
    pt.last_unix_nano = oc.now;
}

/// Run every registered callback against `inst` while holding `inst.mu`.
/// Callbacks observe values via the supplied `Observer`; the `ObserverCtx`
/// routes those into `pointIndexFor` (same hash-indexed path as the
/// synchronous record side). Errors from any individual callback are
/// swallowed so a single bad callback can't take the whole collect cycle
/// down.
fn invokeCallbacksLocked(provider: *MeterProvider, inst: *InstrumentBackend, now: u64) void {
    if (inst.callbacks.items.len == 0) return;
    var oc = ObserverCtx{ .inst = inst, .provider = provider, .now = now };
    const observer = metrics_api.Observer{
        .ctx = &oc,
        .observeIntFn = observerObserveInt,
        .observeDoubleFn = observerObserveDouble,
    };
    for (inst.callbacks.items) |entry| {
        entry.callback(entry.user_ctx, observer) catch {
            // Swallowed: a bad callback cannot abort the collect cycle.
        };
    }
}

// ---------------------------------------------------------------- Mirror writes
//
// The mirror helpers fan-out updates into the DevNW `metrics.Registry`
// when `Backend.devnw` is selected. They are no-ops when the build
// option is off (the comptime branch is removed entirely) or when the
// instrument is unmirrored (registration failed). All writes are
// lock-free atomics on the DevNW side, so we don't take the provider
// lock here.

fn mirrorCounterAdd(inst: *InstrumentBackend, value: u64) void {
    if (!build_options.use_devnw_metrics) return;
    switch (inst.devnw_mirror) {
        .counter => |c| c.add(value),
        else => {},
    }
}

fn mirrorGaugeAdd(inst: *InstrumentBackend, value: i64) void {
    if (!build_options.use_devnw_metrics) return;
    switch (inst.devnw_mirror) {
        .gauge => |g| g.add(value),
        else => {},
    }
}

fn mirrorGaugeSet(inst: *InstrumentBackend, value: f64) void {
    if (!build_options.use_devnw_metrics) return;
    // DevNW Gauge stores i64; truncate fractional component to land in
    // the closest representable integer. Callers that care about double
    // precision should consume the OTLP path.
    const truncated: i64 = blk: {
        if (std.math.isNan(value) or std.math.isInf(value)) break :blk 0;
        const max_f: f64 = @floatFromInt(std.math.maxInt(i64));
        const min_f: f64 = @floatFromInt(std.math.minInt(i64));
        if (value >= max_f) break :blk std.math.maxInt(i64);
        if (value <= min_f) break :blk std.math.minInt(i64);
        break :blk @intFromFloat(value);
    };
    switch (inst.devnw_mirror) {
        .gauge => |g| g.set(truncated),
        else => {},
    }
}

fn mirrorHistogramObserve(inst: *InstrumentBackend, value: f64) void {
    if (!build_options.use_devnw_metrics) return;
    switch (inst.devnw_mirror) {
        .histogram => |h| h.observe(value),
        else => {},
    }
}

/// Snapshot every instrument into `out_alloc`-owned MetricData slices.
///
/// The returned snapshot is **owned, lock-free, and safe to consume
/// without further coordination** with concurrent record-paths. Per
/// PR-1 / gitlab #135, every per-instrument copy runs under
/// `inst.mu` and the result fully detaches from `inst.points`:
///   - `DataPoint.value.histogram.bounds`/`counts` are duped into
///     `out_alloc`.
///   - `DataPoint.attributes` is a freshly-allocated `AttributeSet`
///     in `out_alloc` (not a borrow into `inst.points.items[i]`).
///
/// **Free with `freeSnapshot(out_alloc, snap)`**, which deinits the
/// cloned attribute sets and the cloned histogram buffers before
/// releasing the slice. Tests / callers that previously used the
/// `for (snap) |s| free(s.points); free(snap);` pattern must migrate
/// — the old shape was only valid because `attributes` was a borrow
/// destroyed by `MeterProvider.deinit`; the post-fix snapshot owns
/// independent storage that needs an explicit free.
pub fn collect(provider: *MeterProvider, out_alloc: std.mem.Allocator) ![]exp.MetricData {
    var out: std.ArrayList(exp.MetricData) = .empty;
    errdefer {
        // Tear down already-cloned MetricData entries (per-point
        // attribute sets + histogram buffers) before releasing the
        // outer ArrayList. We do not call `freeSnapshot` here because
        // the slice still lives in `out.items`; freeing per-element
        // first then deinit-ing the ArrayList itself handles the
        // ownership cleanly even if `toOwnedSlice` would OOM.
        for (out.items) |m| {
            for (m.points) |*pt| freeDataPoint(out_alloc, pt);
            out_alloc.free(@as([]exp.DataPoint, @constCast(m.points)));
        }
        out.deinit(out_alloc);
    }

    const collect_now = provider.clock.now();
    for (provider.instruments.items) |inst| {
        // Take the per-instrument lock for the entire copy window so
        // (a) the source slice cannot grow underneath us, and
        // (b) concurrent recorders observe a consistent view of each
        // point's value/last_unix_nano.
        // GAP-OBSERVABLE-INSTRUMENTS (#30): observable callbacks run
        // BEFORE the empty/snapshot loop so they can populate the
        // points map for this collection cycle. Same lock window as
        // the snapshot so a concurrent sync writer can't race the
        // observe-or-snapshot ordering.
        inst.mu.lock();
        invokeCallbacksLocked(provider, inst, collect_now);
        const empty = inst.points.items.len == 0;
        if (empty) {
            inst.mu.unlock();
            continue;
        }

        const points = out_alloc.alloc(exp.DataPoint, inst.points.items.len) catch |err| {
            inst.mu.unlock();
            return err;
        };
        // How many entries in `points` have been fully populated;
        // used by the error path to roll back partial allocations
        // (cloned attribute sets / histogram buffers) without leaking.
        var populated: usize = 0;
        errdefer {
            // Lock is already released by the time errdefer runs in
            // the inner loop's error path; we reacquire it is not
            // necessary because `points` is `out_alloc`-owned and
            // `populated` tracks fully-cloned entries only.
            var k: usize = 0;
            while (k < populated) : (k += 1) freeDataPoint(out_alloc, &points[k]);
            out_alloc.free(points);
        }

        for (inst.points.items, 0..) |*pt, i| {
            // Clone the attribute set into out_alloc-owned storage
            // so the snapshot fully detaches from `inst.points`.
            const attr_clone = out_alloc.create(attrs_mod.AttributeSet) catch |err| {
                inst.mu.unlock();
                return err;
            };
            attr_clone.* = attrs_mod.AttributeSet.init(out_alloc);
            for (pt.attributes.entries.items) |entry| {
                attr_clone.put(entry.key, entry.value) catch |err| {
                    attr_clone.deinit();
                    out_alloc.destroy(attr_clone);
                    inst.mu.unlock();
                    return err;
                };
            }

            points[i] = switch (pt.value) {
                .sum_int => |v| .{
                    .start_unix_nano = pt.start_unix_nano,
                    .time_unix_nano = pt.last_unix_nano,
                    .attributes = attr_clone,
                    .value = .{ .number = .{ .int = v } },
                },
                .sum_uint => |v| .{
                    .start_unix_nano = pt.start_unix_nano,
                    .time_unix_nano = pt.last_unix_nano,
                    .attributes = attr_clone,
                    .value = .{ .number = .{ .int = @intCast(v) } },
                },
                .gauge_double => |v| .{
                    .start_unix_nano = pt.start_unix_nano,
                    .time_unix_nano = pt.last_unix_nano,
                    .attributes = attr_clone,
                    .value = .{ .number = .{ .double = v } },
                },
                .histogram => |h| blk: {
                    const bounds_copy = out_alloc.dupe(f64, h.bounds) catch |err| {
                        attr_clone.deinit();
                        out_alloc.destroy(attr_clone);
                        inst.mu.unlock();
                        return err;
                    };
                    const counts_copy = out_alloc.dupe(u64, h.counts) catch |err| {
                        out_alloc.free(bounds_copy);
                        attr_clone.deinit();
                        out_alloc.destroy(attr_clone);
                        inst.mu.unlock();
                        return err;
                    };
                    break :blk .{
                        .start_unix_nano = pt.start_unix_nano,
                        .time_unix_nano = pt.last_unix_nano,
                        .attributes = attr_clone,
                        .value = .{ .histogram = .{
                            .bounds = bounds_copy,
                            .counts = counts_copy,
                            .sum = h.sum,
                            .count = h.count,
                            .min = h.min,
                            .max = h.max,
                        } },
                    };
                },
            };
            populated = i + 1;
        }

        // Snapshot the metadata fields needed for the MetricData
        // envelope while we still hold the lock so a concurrent
        // descriptor mutation (none today, but future-proofing) is
        // observed coherently with the points.
        const md: exp.MetricData = .{
            .name = inst.descriptor.name,
            .description = inst.descriptor.description,
            .unit = inst.descriptor.unit,
            .kind = inst.descriptor.kind,
            .temporality = inst.descriptor.temporality,
            .is_monotonic = inst.is_monotonic,
            .points = points,
            .instrumentation_scope = inst.scope,
            .resource = provider.resource,
        };
        inst.mu.unlock();

        // Encode-side append happens outside the per-instrument
        // lock; on OOM the inner errdefer rolls the cloned points
        // back so we don't leak. Iteration scope ends on success and
        // the errdefer is discarded — `points` ownership transfers
        // to `out`.
        try out.append(out_alloc, md);
    }
    return out.toOwnedSlice(out_alloc);
}

/// Free a `[]MetricData` snapshot produced by `collect`. Tears down
/// the cloned attribute sets and histogram bounds/counts before
/// releasing the outer slice. PR-1 / gitlab #135.
pub fn freeSnapshot(allocator: std.mem.Allocator, snap: []const exp.MetricData) void {
    for (snap) |m| {
        for (m.points) |*pt| freeDataPoint(allocator, pt);
        // The points slice itself is `[]const`; the underlying
        // storage was allocated mutable, so we cast off `const` for
        // the free call.
        allocator.free(@as([]exp.DataPoint, @constCast(m.points)));
    }
    allocator.free(@as([]exp.MetricData, @constCast(snap)));
}

fn freeDataPoint(allocator: std.mem.Allocator, pt: *const exp.DataPoint) void {
    if (pt.attributes) |a| {
        // `attributes` is `?*const AttributeSet`; the snapshot owns
        // it but the field is typed const. Cast off const for the
        // deinit + destroy.
        const mutable: *attrs_mod.AttributeSet = @constCast(a);
        mutable.deinit();
        allocator.destroy(mutable);
    }
    switch (pt.value) {
        .histogram => |h| {
            allocator.free(@as([]f64, @constCast(h.bounds)));
            allocator.free(@as([]u64, @constCast(h.counts)));
        },
        else => {},
    }
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
    defer freeSnapshot(std.testing.allocator, datas);
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
    defer freeSnapshot(std.testing.allocator, datas);
    const hp = datas[0].points[0].value.histogram;
    try std.testing.expectEqual(@as(u64, 3), hp.count);
    try std.testing.expectEqualSlices(u64, &.{ 1, 1, 0, 1 }, hp.counts);
}
