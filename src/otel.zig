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
};

pub const sdk = struct {
    pub const resource = @import("sdk/resource.zig");
    pub const trace = @import("sdk/trace.zig");
    pub const metrics = @import("sdk/metrics.zig");
    pub const logs = @import("sdk/logs.zig");
    pub const config = @import("sdk/config.zig");
    pub const exporter = @import("sdk/export.zig");
};

pub const exporters = struct {
    pub const in_memory = @import("exporters/in_memory.zig");
    pub const stdout_json = @import("exporters/stdout_json.zig");
    pub const file = @import("exporters/file.zig");
    pub const prometheus = @import("exporters/prometheus.zig");
    pub const otlp_http = @import("exporters/otlp_http.zig");
    pub const otlp_grpc = @import("exporters/otlp_grpc.zig");
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
