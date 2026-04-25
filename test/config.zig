// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");

test "config validates endpoint" {
    var cfg: otel.sdk.config.Config = .{};
    cfg.traces.otlp.endpoint = "";
    try std.testing.expectError(error.InvalidEndpoint, cfg.validate());
}

test "config rejects out-of-range sampler ratio" {
    var cfg: otel.sdk.config.Config = .{};
    cfg.traces.sampler_arg = 1.5;
    try std.testing.expectError(error.InvalidConfig, cfg.validate());
}

test "exporter kind parsing" {
    try std.testing.expectEqual(otel.sdk.config.ExporterKind.otlp_http, otel.sdk.config.ExporterKind.fromString("otlp"));
    try std.testing.expectEqual(otel.sdk.config.ExporterKind.stdout, otel.sdk.config.ExporterKind.fromString("console"));
    try std.testing.expectEqual(otel.sdk.config.ExporterKind.in_memory, otel.sdk.config.ExporterKind.fromString("memory"));
    try std.testing.expectEqual(otel.sdk.config.ExporterKind.none, otel.sdk.config.ExporterKind.fromString("nope"));
}

test "protocol parsing" {
    try std.testing.expectEqual(otel.sdk.config.Protocol.http_protobuf, otel.sdk.config.Protocol.fromString("http/protobuf").?);
    try std.testing.expectEqual(otel.sdk.config.Protocol.grpc, otel.sdk.config.Protocol.fromString("grpc").?);
    try std.testing.expect(otel.sdk.config.Protocol.fromString("invalid") == null);
}

test "DevNW yaml parser handles nested mappings" {
    if (!@import("build_options").use_devnw_config) return error.SkipZigTest;
    const src =
        \\file_format: 1.0.0
        \\tracer_provider:
        \\  exporter: otlp
        \\  endpoint: "http://collector:4318"
        \\  protocol: http/protobuf
    ;
    var cfg: otel.sdk.config.Config = .{};
    try otel.sdk.config.applyYamlStringDevnw(&cfg, std.testing.allocator, src);
    // The DevNW loader allocates new buffers for string fields; release
    // them so leak detection stays clean.
    defer {
        std.testing.allocator.free(cfg.file_format);
        std.testing.allocator.free(cfg.traces.otlp.endpoint);
    }
    try std.testing.expectEqual(otel.sdk.config.ExporterKind.otlp_http, cfg.traces.exporter);
    try std.testing.expectEqualStrings("http://collector:4318", cfg.traces.otlp.endpoint);
    try std.testing.expectEqual(otel.sdk.config.Protocol.http_protobuf, cfg.traces.otlp.protocol);
}
