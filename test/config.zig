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
    defer cfg.deinit(std.testing.allocator);
    try std.testing.expectEqual(otel.sdk.config.ExporterKind.otlp_http, cfg.traces.exporter);
    try std.testing.expectEqualStrings("http://collector:4318", cfg.traces.otlp.endpoint);
    try std.testing.expectEqual(otel.sdk.config.Protocol.http_protobuf, cfg.traces.otlp.protocol);
}

// -------------------------------------------------------------------------
// GAP-SEC-C-1 / GAP-SEC-M-4: Config string ownership.
//
// Historical bug: applyEnv borrowed slices from a single threadlocal
// scratch buffer, so reading any later env var corrupted earlier slots.
// The in-repo YAML loader had a sibling defect — values were borrowed
// from the source buffer that callers were free to release immediately.
// Both are fixed by the new ownership contract: every string field on
// Config is allocator-owned, and Config.deinit must free them all.
// -------------------------------------------------------------------------

test "C-1: env headers survive a subsequent env read" {
    // Set both env vars before applying, then assert the headers slice
    // does not get clobbered by the later lookup.
    var env_map = otel.sdk.config.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_EXPORTER_OTLP_HEADERS", "Authorization=Bearer aaaaaaaaaaaaaaaa");
    try env_map.put("OTEL_SERVICE_NAME", "service-with-a-long-name-that-overlaps");

    var cfg: otel.sdk.config.Config = .{};
    try otel.sdk.config.applyEnvFromMap(&cfg, std.testing.allocator, &env_map);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Authorization=Bearer aaaaaaaaaaaaaaaa", cfg.traces.otlp.headers.?);
    try std.testing.expectEqualStrings("Authorization=Bearer aaaaaaaaaaaaaaaa", cfg.metrics.otlp.headers.?);
    try std.testing.expectEqualStrings("Authorization=Bearer aaaaaaaaaaaaaaaa", cfg.logs.otlp.headers.?);
    try std.testing.expectEqualStrings("service-with-a-long-name-that-overlaps", cfg.service_name);
}

test "C-1: applyEnvFromMap + deinit leaks nothing under testing allocator" {
    // The testing allocator panics on leak; this test passes only if
    // every field set by env is freed by Config.deinit.
    var env_map = otel.sdk.config.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_SERVICE_NAME", "leak-canary-service");
    try env_map.put("OTEL_RESOURCE_ATTRIBUTES", "k=v,k2=v2");
    try env_map.put("OTEL_EXPORTER_OTLP_ENDPOINT", "http://collector.example.com:4318");
    try env_map.put("OTEL_EXPORTER_OTLP_HEADERS", "Authorization=Bearer abcd");
    try env_map.put("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "http://traces.example.com:4318");

    var cfg: otel.sdk.config.Config = .{};
    try otel.sdk.config.applyEnvFromMap(&cfg, std.testing.allocator, &env_map);
    cfg.deinit(std.testing.allocator);
}

test "M-4: applyYamlString values survive source buffer free" {
    // Allocate a YAML source on the heap, copy it into another buffer,
    // free the original, then assert Config still holds the right strings.
    const source =
        \\file_format: 1.0.0
        \\tracer_provider:
        \\  exporter: otlp
        \\  endpoint: "http://collector:4318"
        \\  protocol: http/protobuf
    ;
    const buf = try std.testing.allocator.dupe(u8, source);

    var cfg: otel.sdk.config.Config = .{};
    try otel.sdk.config.applyYamlString(&cfg, std.testing.allocator, buf);

    // Free the source immediately. If the loader borrowed slices from
    // it, the next read of cfg.traces.otlp.endpoint will be a UAF.
    std.testing.allocator.free(buf);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("1.0.0", cfg.file_format);
    try std.testing.expectEqualStrings("http://collector:4318", cfg.traces.otlp.endpoint);
}
