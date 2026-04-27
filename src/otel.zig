// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
//! # otel
//!
//! Production-grade OpenTelemetry client library for Zig 0.16.
//!
//! - OpenTelemetry Specification 1.56.0
//! - OTLP Specification 1.10.0
//! - Semantic conventions 1.40.0
//! - Declarative configuration 1.0.0
//!
//! Quick start:
//!
//! ```zig
//! const otel = @import("otel");
//! const allocator = std.heap.page_allocator;
//!
//! var resource = try otel.sdk.resource.defaultResource(allocator);
//! defer resource.deinit();
//!
//! var stdout = otel.exporters.stdout_json.StdoutJson.init(allocator);
//! var tp = try otel.sdk.trace.TracerProvider.init(allocator, .{
//!     .resource = &resource,
//!     .default_exporter = stdout.spanExporter(),
//! });
//! defer tp.deinit();
//!
//! const tracer = tp.tracer(.{ .name = "demo" });
//! const span = try tracer.startSpan(.empty(), "hello", .{});
//! span.end(null);
//! ```

const std = @import("std");

pub const version: []const u8 = "0.1.0";
pub const build_options = @import("build_options");

pub const api = struct {
    pub const context = @import("api/context.zig");
    pub const baggage = @import("api/baggage.zig");
    pub const trace = @import("api/trace.zig");
    pub const metrics = @import("api/metrics.zig");
    pub const logs = @import("api/logs.zig");
    pub const events = @import("api/events.zig");
    pub const profiles = @import("api/profiles.zig");
};

pub const propagation = struct {
    pub const trace_context = @import("propagation/trace_context.zig");
    pub const baggage = @import("propagation/baggage.zig");
    pub const composite = @import("propagation/composite.zig");
    /// Pluggable TextMapPropagator interface + runtime-dispatched
    /// Composite. Used by the SDK to construct a propagator from
    /// `OTEL_PROPAGATORS` at provider-build time. See
    /// `sdk.config.propagatorFromConfig`.
    pub const propagator = @import("propagation/propagator.zig");
    /// B3 propagator (single + multi header forms). GAP-PROPAGATOR-B3
    /// (#23). See `propagator.single_header` / `propagator.multi_header`
    /// for the registered TextMapPropagator handles.
    pub const b3 = @import("propagation/b3.zig");
    /// Jaeger propagator: `uber-trace-id` for SpanContext + per-entry
    /// `uberctx-<key>` headers for baggage. GAP-PROPAGATOR-JAEGER (#24).
    pub const jaeger = @import("propagation/jaeger.zig");
};

pub const sdk = struct {
    pub const resource = @import("sdk/resource.zig");
    pub const trace = @import("sdk/trace.zig");
    pub const metrics = @import("sdk/metrics.zig");
    pub const logs = @import("sdk/logs.zig");
    pub const config = @import("sdk/config.zig");
    pub const exporter = @import("sdk/export.zig");
    pub const span_pool = @import("sdk/span_pool.zig");
    /// GAP-EXPORTER-FACTORY (#4): turns the parsed `ExporterKind` enum
    /// (sourced from `OTEL_TRACES_EXPORTER` / `OTEL_METRICS_EXPORTER`
    /// / `OTEL_LOGS_EXPORTER`) plus the per-signal `OtlpConfig` into a
    /// concrete typed exporter. See `sdk/exporter_factory.zig` for
    /// the contract.
    pub const exporter_factory = @import("sdk/exporter_factory.zig");
    /// GAP-PERIODIC-METRIC-READER (#29): timer-driven reader that calls
    /// `MeterProvider.collect()` on a fixed cadence and hands the
    /// snapshot to a `MetricExporter`. Honours
    /// `MetricReaderConfig.export_interval_ms` /
    /// `export_timeout_ms` (env: `OTEL_METRIC_EXPORT_INTERVAL` /
    /// `OTEL_METRIC_EXPORT_TIMEOUT`).
    pub const periodic_metric_reader = @import("sdk/periodic_metric_reader.zig");
};

pub const exporters = struct {
    pub const in_memory = @import("exporters/in_memory.zig");
    pub const stdout_json = @import("exporters/stdout_json.zig");
    pub const file = @import("exporters/file.zig");
    pub const prometheus = @import("exporters/prometheus.zig");
    pub const otlp_http = @import("exporters/otlp_http.zig");
    pub const otlp_grpc = @import("exporters/otlp_grpc.zig");
    /// Loopback gRPC server harness used by the integration test. Lives
    /// in the library tree (rather than under `test/`) so it can share
    /// the otel module's `grpc_server` import — Zig 0.16 forbids the
    /// same source file (e.g. grpc-zig's `proto/service.zig`) belonging
    /// to two distinct modules in the same compilation. See the file's
    /// doc comment for the full rationale.
    ///
    /// GAP-SEC-M-1: gated on `-Dotel_grpc_test_server=true` so the
    /// harness never ships in a production build. The off-branch
    /// resolves to a minimal stub that returns `error.SkipZigTest`
    /// from `startLoopbackGrpc` so consumers compile in either
    /// configuration.
    pub const otlp_grpc_test_server = if (build_options.grpc_test_server)
        @import("exporters/otlp_grpc_test_server.zig")
    else
        struct {
            pub const Server = struct {
                pub fn endpoint(_: *Server, _: []u8) ![]const u8 {
                    return error.SkipZigTest;
                }
                pub fn requestCount(_: *const Server) usize {
                    return 0;
                }
                pub fn shutdown(_: *Server) void {}
            };
            pub fn startLoopbackGrpc(_: anytype) !*Server {
                return error.SkipZigTest;
            }
        };
};

pub const instrumentation = struct {
    pub const std_log = @import("instrumentation/std_log.zig");
    pub const http = @import("instrumentation/http.zig");
    pub const runtime = @import("instrumentation/runtime.zig");
};

pub const semconv = @import("generated/semconv.zig");

pub const internal = struct {
    pub const attributes = @import("internal/attributes.zig");
    pub const clock = @import("internal/clock.zig");
    pub const id = @import("internal/id.zig");
    pub const redact = @import("internal/redact.zig");
    pub const ring_buffer = @import("internal/ring_buffer.zig");
    pub const json_codec = @import("internal/json_codec.zig");
};

pub const otlp_wire = @import("generated/otlp.zig");

// Hoisted error set so callers get one place to import from.
pub const Error = error{
    InvalidTraceParent,
    InvalidTraceState,
    InvalidBaggageKey,
    InvalidBaggageValue,
    BaggageTooLarge,
    InvalidConfig,
    InvalidEndpoint,
    ExportTimeout,
    RetryExhausted,
    PartialSuccess,
    UnsupportedTransport,
    TelemetryDropped,
};

test {
    std.testing.refAllDecls(@This());
}
