// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Exporter factory — turns the parsed `ExporterKind` enum (sourced from
// `OTEL_TRACES_EXPORTER` / `OTEL_METRICS_EXPORTER` / `OTEL_LOGS_EXPORTER`)
// plus the per-signal `OtlpConfig` into a concrete typed exporter.
//
// GAP-EXPORTER-FACTORY (#4). Before this file landed, the env-vars were
// parsed into `cfg.{traces,metrics,logs}.exporter` but nothing read the
// field — every caller had to wire the exporter manually, which made
// `OTEL_TRACES_EXPORTER=otlp_grpc` indistinguishable from `=stdout` at
// runtime.
//
// The factory returns an *owned* bundle (`Owned{Span,Metric,Log}Exporter`)
// — the heap-allocated underlying exporter (e.g. `*OtlpHttpExporter`,
// `*StdoutJson`, `*in_memory.Recorder`) plus the typed `*Exporter` handle
// derived from it. Bundles carry a `deinit_fn` so the provider that owns
// them tears the right backing memory down without each provider knowing
// every concrete exporter type.
//
// Lifecycle: the bundle owns its backing exporter for the bundle's
// lifetime. `Owned*.deinit()` frees the backing storage. Providers built
// via `*Provider.initFromConfig` take ownership of the bundle and free it
// on `provider.deinit()`. Callers who want the manual-wiring path
// (existing tests + every example) keep using the `default_exporter`
// field directly, unchanged.
//
// Signal-vs-exporter compatibility: prometheus is metrics-only (it's a
// pull-model exporter that surfaces a different shape than push). For
// traces / logs the factory returns `error.InvalidExporterForSignal`. For
// metrics the factory currently returns `error.PrometheusRequiresPullEndpoint`
// because the prometheus exporter constructor needs a `*MeterProvider` —
// the consumer has to wire `Prometheus.init(allocator, &meter_provider)`
// after the provider exists. Documented constraint, not a TODO.

const std = @import("std");
const config_mod = @import("config.zig");
const exp = @import("export.zig");
const otlp_http_mod = @import("../exporters/otlp_http.zig");
const otlp_grpc_mod = @import("../exporters/otlp_grpc.zig");
const stdout_mod = @import("../exporters/stdout_json.zig");
const in_memory_mod = @import("../exporters/in_memory.zig");

pub const ExporterKind = config_mod.ExporterKind;
pub const Protocol = config_mod.Protocol;
pub const OtlpConfig = config_mod.OtlpConfig;

/// Errors the factory may surface.
///
///   - `InvalidExporterForSignal` — caller asked for an exporter kind
///     that doesn't make sense for the signal (e.g. `prometheus` on
///     traces or logs).
///   - `PrometheusRequiresPullEndpoint` — `prometheus` on metrics is
///     valid but the constructor needs a `*MeterProvider` (pull model);
///     the caller has to wire `exporters.prometheus.Prometheus.init` by
///     hand after building the provider. The factory refuses to elide
///     that wiring silently.
///   - Plus any error returned by the underlying exporter constructor
///     (e.g. `error.InvalidEndpoint`, `error.InvalidConfig`).
pub const FactoryError = error{
    InvalidExporterForSignal,
    PrometheusRequiresPullEndpoint,
};

/// Bundle that owns a heap-allocated `SpanExporter` backing.
///
/// Construction: returned by `spanExporterFromConfig`. The bundle's
/// `exporter` field is the public typed exporter; pass it to
/// `TraceConfig.default_exporter` (or store it on a provider that owns
/// the bundle).
///
/// Ownership: `deinit()` frees the heap allocations the factory made.
/// Safe to call multiple times — the second call is a no-op once the
/// bundle is consumed.
pub const OwnedSpanExporter = struct {
    exporter: exp.SpanExporter,
    state: ?*anyopaque,
    deinit_fn: ?*const fn (std.mem.Allocator, ?*anyopaque) void,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OwnedSpanExporter) void {
        if (self.deinit_fn) |f| f(self.allocator, self.state);
        self.deinit_fn = null;
        self.state = null;
    }
};

pub const OwnedMetricExporter = struct {
    exporter: exp.MetricExporter,
    state: ?*anyopaque,
    deinit_fn: ?*const fn (std.mem.Allocator, ?*anyopaque) void,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OwnedMetricExporter) void {
        if (self.deinit_fn) |f| f(self.allocator, self.state);
        self.deinit_fn = null;
        self.state = null;
    }
};

pub const OwnedLogExporter = struct {
    exporter: exp.LogExporter,
    state: ?*anyopaque,
    deinit_fn: ?*const fn (std.mem.Allocator, ?*anyopaque) void,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OwnedLogExporter) void {
        if (self.deinit_fn) |f| f(self.allocator, self.state);
        self.deinit_fn = null;
        self.state = null;
    }
};

// ---- Per-signal factories ----

/// Build a span exporter from `cfg.traces`.
///
/// Returns `null` when `cfg.traces.exporter == .none`.
/// Returns `error.InvalidExporterForSignal` when the configured kind is
/// `prometheus` (prometheus is metrics-only).
///
/// On success the caller must `deinit()` the returned bundle once the
/// provider that consumes its `exporter` field is itself torn down.
pub fn spanExporterFromConfig(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
) !?OwnedSpanExporter {
    return spanExporterFor(allocator, cfg.traces.exporter, cfg.traces.otlp);
}

/// Lower-level helper — build a span exporter from a `(kind, otlp)` pair
/// without a full `Config`. Useful for tests that bypass the env-var
/// pipeline.
pub fn spanExporterFor(
    allocator: std.mem.Allocator,
    kind: ExporterKind,
    otlp: OtlpConfig,
) !?OwnedSpanExporter {
    return switch (kind) {
        .none => null,
        .stdout => try buildSpanStdout(allocator),
        .in_memory => try buildSpanInMemory(allocator),
        .otlp_http => try buildSpanOtlpHttp(allocator, normalizeForHttp(otlp)),
        .otlp_grpc => try buildSpanOtlpGrpc(allocator, normalizeForGrpc(otlp)),
        .file => return error.InvalidExporterForSignal,
        .prometheus => return error.InvalidExporterForSignal,
    };
}

/// Build a metric exporter from `cfg.metrics`.
///
/// Returns `null` when `cfg.metrics.exporter == .none`.
/// Returns `error.PrometheusRequiresPullEndpoint` for the prometheus
/// kind — see the file header for rationale (prometheus is pull-model
/// and needs `*MeterProvider` plumbing the factory cannot perform).
pub fn metricExporterFromConfig(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
) !?OwnedMetricExporter {
    return metricExporterFor(allocator, cfg.metrics.exporter, cfg.metrics.otlp);
}

pub fn metricExporterFor(
    allocator: std.mem.Allocator,
    kind: ExporterKind,
    otlp: OtlpConfig,
) !?OwnedMetricExporter {
    return switch (kind) {
        .none => null,
        .stdout => try buildMetricStdout(allocator),
        .in_memory => try buildMetricInMemory(allocator),
        .otlp_http => try buildMetricOtlpHttp(allocator, normalizeForHttp(otlp)),
        .otlp_grpc => try buildMetricOtlpGrpc(allocator, normalizeForGrpc(otlp)),
        .file => return error.InvalidExporterForSignal,
        .prometheus => return error.PrometheusRequiresPullEndpoint,
    };
}

/// Build a log exporter from `cfg.logs`.
pub fn logExporterFromConfig(
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
) !?OwnedLogExporter {
    return logExporterFor(allocator, cfg.logs.exporter, cfg.logs.otlp);
}

pub fn logExporterFor(
    allocator: std.mem.Allocator,
    kind: ExporterKind,
    otlp: OtlpConfig,
) !?OwnedLogExporter {
    return switch (kind) {
        .none => null,
        .stdout => try buildLogStdout(allocator),
        .in_memory => try buildLogInMemory(allocator),
        .otlp_http => try buildLogOtlpHttp(allocator, normalizeForHttp(otlp)),
        .otlp_grpc => try buildLogOtlpGrpc(allocator, normalizeForGrpc(otlp)),
        .file => return error.InvalidExporterForSignal,
        .prometheus => return error.InvalidExporterForSignal,
    };
}

// ---- Protocol normalization ------------------------------------------
//
// `ExporterKind = .otlp_http` forces protocol to `.http_protobuf` (or
// `.http_json` if already set to that). `.otlp_grpc` forces `.grpc`.
// This makes `OTEL_TRACES_EXPORTER=otlp_grpc` work even when
// `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf` is also set — the
// exporter kind is the more specific signal and wins for protocol
// resolution. Per OTel spec (Environment Variables — exporter
// selection), the exporter selector implicitly fixes the wire protocol.

fn normalizeForHttp(otlp: OtlpConfig) OtlpConfig {
    var out = otlp;
    if (out.protocol == .grpc) out.protocol = .http_protobuf;
    return out;
}

fn normalizeForGrpc(otlp: OtlpConfig) OtlpConfig {
    var out = otlp;
    out.protocol = .grpc;
    return out;
}

// ---- Span constructors -----------------------------------------------

fn buildSpanOtlpHttp(allocator: std.mem.Allocator, otlp: OtlpConfig) !OwnedSpanExporter {
    const ptr = try allocator.create(otlp_http_mod.OtlpHttpExporter);
    errdefer allocator.destroy(ptr);
    ptr.* = try otlp_http_mod.OtlpHttpExporter.init(allocator, otlp);
    return .{
        .exporter = ptr.spanExporter(),
        .state = ptr,
        .deinit_fn = deinitOtlpHttp,
        .allocator = allocator,
    };
}

fn buildSpanOtlpGrpc(allocator: std.mem.Allocator, otlp: OtlpConfig) !OwnedSpanExporter {
    const ptr = try allocator.create(otlp_grpc_mod.OtlpGrpcExporter);
    errdefer allocator.destroy(ptr);
    ptr.* = try otlp_grpc_mod.OtlpGrpcExporter.init(allocator, otlp);
    return .{
        .exporter = ptr.spanExporter(),
        .state = ptr,
        .deinit_fn = deinitOtlpGrpc,
        .allocator = allocator,
    };
}

fn buildSpanStdout(allocator: std.mem.Allocator) !OwnedSpanExporter {
    const ptr = try allocator.create(stdout_mod.StdoutJson);
    errdefer allocator.destroy(ptr);
    ptr.* = stdout_mod.StdoutJson.init(allocator);
    return .{
        .exporter = ptr.spanExporter(),
        .state = ptr,
        .deinit_fn = deinitStdout,
        .allocator = allocator,
    };
}

fn buildSpanInMemory(allocator: std.mem.Allocator) !OwnedSpanExporter {
    const ptr = try allocator.create(in_memory_mod.Recorder);
    errdefer allocator.destroy(ptr);
    ptr.* = in_memory_mod.Recorder.init(allocator);
    return .{
        .exporter = ptr.spanExporter(),
        .state = ptr,
        .deinit_fn = deinitInMemory,
        .allocator = allocator,
    };
}

// ---- Metric constructors ---------------------------------------------

fn buildMetricOtlpHttp(allocator: std.mem.Allocator, otlp: OtlpConfig) !OwnedMetricExporter {
    const ptr = try allocator.create(otlp_http_mod.OtlpHttpExporter);
    errdefer allocator.destroy(ptr);
    ptr.* = try otlp_http_mod.OtlpHttpExporter.init(allocator, otlp);
    return .{
        .exporter = ptr.metricExporter(),
        .state = ptr,
        .deinit_fn = deinitOtlpHttp,
        .allocator = allocator,
    };
}

fn buildMetricOtlpGrpc(allocator: std.mem.Allocator, otlp: OtlpConfig) !OwnedMetricExporter {
    const ptr = try allocator.create(otlp_grpc_mod.OtlpGrpcExporter);
    errdefer allocator.destroy(ptr);
    ptr.* = try otlp_grpc_mod.OtlpGrpcExporter.init(allocator, otlp);
    return .{
        .exporter = ptr.metricExporter(),
        .state = ptr,
        .deinit_fn = deinitOtlpGrpc,
        .allocator = allocator,
    };
}

fn buildMetricStdout(allocator: std.mem.Allocator) !OwnedMetricExporter {
    const ptr = try allocator.create(stdout_mod.StdoutJson);
    errdefer allocator.destroy(ptr);
    ptr.* = stdout_mod.StdoutJson.init(allocator);
    return .{
        .exporter = ptr.metricExporter(),
        .state = ptr,
        .deinit_fn = deinitStdout,
        .allocator = allocator,
    };
}

fn buildMetricInMemory(allocator: std.mem.Allocator) !OwnedMetricExporter {
    const ptr = try allocator.create(in_memory_mod.Recorder);
    errdefer allocator.destroy(ptr);
    ptr.* = in_memory_mod.Recorder.init(allocator);
    return .{
        .exporter = ptr.metricExporter(),
        .state = ptr,
        .deinit_fn = deinitInMemory,
        .allocator = allocator,
    };
}

// ---- Log constructors ------------------------------------------------

fn buildLogOtlpHttp(allocator: std.mem.Allocator, otlp: OtlpConfig) !OwnedLogExporter {
    const ptr = try allocator.create(otlp_http_mod.OtlpHttpExporter);
    errdefer allocator.destroy(ptr);
    ptr.* = try otlp_http_mod.OtlpHttpExporter.init(allocator, otlp);
    return .{
        .exporter = ptr.logExporter(),
        .state = ptr,
        .deinit_fn = deinitOtlpHttp,
        .allocator = allocator,
    };
}

fn buildLogOtlpGrpc(allocator: std.mem.Allocator, otlp: OtlpConfig) !OwnedLogExporter {
    const ptr = try allocator.create(otlp_grpc_mod.OtlpGrpcExporter);
    errdefer allocator.destroy(ptr);
    ptr.* = try otlp_grpc_mod.OtlpGrpcExporter.init(allocator, otlp);
    return .{
        .exporter = ptr.logExporter(),
        .state = ptr,
        .deinit_fn = deinitOtlpGrpc,
        .allocator = allocator,
    };
}

fn buildLogStdout(allocator: std.mem.Allocator) !OwnedLogExporter {
    const ptr = try allocator.create(stdout_mod.StdoutJson);
    errdefer allocator.destroy(ptr);
    ptr.* = stdout_mod.StdoutJson.init(allocator);
    return .{
        .exporter = ptr.logExporter(),
        .state = ptr,
        .deinit_fn = deinitStdout,
        .allocator = allocator,
    };
}

fn buildLogInMemory(allocator: std.mem.Allocator) !OwnedLogExporter {
    const ptr = try allocator.create(in_memory_mod.Recorder);
    errdefer allocator.destroy(ptr);
    ptr.* = in_memory_mod.Recorder.init(allocator);
    return .{
        .exporter = ptr.logExporter(),
        .state = ptr,
        .deinit_fn = deinitInMemory,
        .allocator = allocator,
    };
}

// ---- Deinit helpers --------------------------------------------------

fn deinitOtlpHttp(allocator: std.mem.Allocator, state: ?*anyopaque) void {
    if (state) |s| {
        const ptr: *otlp_http_mod.OtlpHttpExporter = @ptrCast(@alignCast(s));
        ptr.deinit();
        allocator.destroy(ptr);
    }
}

fn deinitOtlpGrpc(allocator: std.mem.Allocator, state: ?*anyopaque) void {
    if (state) |s| {
        const ptr: *otlp_grpc_mod.OtlpGrpcExporter = @ptrCast(@alignCast(s));
        ptr.deinit();
        allocator.destroy(ptr);
    }
}

fn deinitStdout(allocator: std.mem.Allocator, state: ?*anyopaque) void {
    if (state) |s| {
        const ptr: *stdout_mod.StdoutJson = @ptrCast(@alignCast(s));
        // StdoutJson holds no per-instance allocations; just free the
        // heap box the factory allocated.
        allocator.destroy(ptr);
    }
}

fn deinitInMemory(allocator: std.mem.Allocator, state: ?*anyopaque) void {
    if (state) |s| {
        const ptr: *in_memory_mod.Recorder = @ptrCast(@alignCast(s));
        ptr.deinit();
        allocator.destroy(ptr);
    }
}

// ----------------------------------------------------------------------
// Inline tests — `none` short-circuit + protocol normalisation. Larger
// end-to-end coverage lives under `test/exporter_factory.zig`.
// ----------------------------------------------------------------------

test "spanExporterFor returns null for ExporterKind.none" {
    const got = try spanExporterFor(std.testing.allocator, .none, .{});
    try std.testing.expect(got == null);
}

test "metricExporterFor returns null for ExporterKind.none" {
    const got = try metricExporterFor(std.testing.allocator, .none, .{});
    try std.testing.expect(got == null);
}

test "logExporterFor returns null for ExporterKind.none" {
    const got = try logExporterFor(std.testing.allocator, .none, .{});
    try std.testing.expect(got == null);
}

test "spanExporterFor rejects prometheus with InvalidExporterForSignal" {
    try std.testing.expectError(
        FactoryError.InvalidExporterForSignal,
        spanExporterFor(std.testing.allocator, .prometheus, .{}),
    );
}

test "logExporterFor rejects prometheus with InvalidExporterForSignal" {
    try std.testing.expectError(
        FactoryError.InvalidExporterForSignal,
        logExporterFor(std.testing.allocator, .prometheus, .{}),
    );
}

test "metricExporterFor rejects prometheus with PrometheusRequiresPullEndpoint" {
    try std.testing.expectError(
        FactoryError.PrometheusRequiresPullEndpoint,
        metricExporterFor(std.testing.allocator, .prometheus, .{}),
    );
}

test "normalizeForGrpc forces protocol to grpc" {
    const otlp_in: OtlpConfig = .{ .protocol = .http_protobuf };
    const out = normalizeForGrpc(otlp_in);
    try std.testing.expectEqual(Protocol.grpc, out.protocol);
}

test "normalizeForHttp downgrades grpc to http_protobuf" {
    const otlp_in: OtlpConfig = .{ .protocol = .grpc };
    const out = normalizeForHttp(otlp_in);
    try std.testing.expectEqual(Protocol.http_protobuf, out.protocol);
}

test "normalizeForHttp preserves http_json" {
    const otlp_in: OtlpConfig = .{ .protocol = .http_json };
    const out = normalizeForHttp(otlp_in);
    try std.testing.expectEqual(Protocol.http_json, out.protocol);
}

test "spanExporterFor stdout builds and frees clean" {
    var bundle = (try spanExporterFor(std.testing.allocator, .stdout, .{})).?;
    defer bundle.deinit();
    // Smoke-test: forceFlush is a no-op on stdout.
    try bundle.exporter.forceFlush(0);
}

test "metricExporterFor in_memory builds and frees clean" {
    var bundle = (try metricExporterFor(std.testing.allocator, .in_memory, .{})).?;
    defer bundle.deinit();
    try bundle.exporter.forceFlush(0);
}

test "logExporterFor stdout builds and frees clean" {
    var bundle = (try logExporterFor(std.testing.allocator, .stdout, .{})).?;
    defer bundle.deinit();
    try bundle.exporter.forceFlush(0);
}

test "spanExporterFor otlp_http builds with valid endpoint" {
    var bundle = (try spanExporterFor(std.testing.allocator, .otlp_http, .{})).?;
    defer bundle.deinit();
}

test "spanExporterFor otlp_grpc builds with valid endpoint and forces grpc protocol" {
    // OtlpGrpcExporter.init refuses non-grpc protocol — normalizeForGrpc
    // is what makes `OTEL_TRACES_EXPORTER=otlp_grpc` work even when
    // `OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf`. The endpoint stays at
    // the spec default `http://localhost:4318`.
    var bundle = (try spanExporterFor(std.testing.allocator, .otlp_grpc, .{
        .protocol = .http_protobuf,
        // AS-1: default endpoint (localhost) is grandfathered past the
        // loopback opt-in, so zero-config gRPC construction still works.
    })).?;
    defer bundle.deinit();
}
