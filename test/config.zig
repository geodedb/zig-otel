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

// -------------------------------------------------------------------------
// GAP-SEC-M-5 / GAP-SEC-L-6 / GAP-SEC-L-7: Config.validate hardening.
//
// Together these block SSRF (link-local / loopback-without-opt-in),
// runaway timeouts (must be capped), and NaN sampler ratios.
// -------------------------------------------------------------------------

test "M-5: validate rejects link-local IPv4 169.254.169.254 endpoint" {
    var cfg: otel.sdk.config.Config = .{};
    cfg.traces.otlp.endpoint = "http://169.254.169.254/v1/traces";
    try std.testing.expectError(error.InvalidEndpoint, cfg.validate());
}

test "M-5: validate rejects IPv6 link-local fe80:: endpoint" {
    var cfg: otel.sdk.config.Config = .{};
    cfg.traces.otlp.endpoint = "http://[fe80::1]:4318";
    try std.testing.expectError(error.InvalidEndpoint, cfg.validate());
}

test "M-5: validate rejects IPv4-mapped IPv6 link-local endpoint" {
    var cfg: otel.sdk.config.Config = .{};
    cfg.traces.otlp.endpoint = "http://[::ffff:169.254.169.254]:4318";
    try std.testing.expectError(error.InvalidEndpoint, cfg.validate());
}

test "M-5: validate rejects non-http(s) scheme" {
    var cfg: otel.sdk.config.Config = .{};
    cfg.traces.otlp.endpoint = "ftp://collector.example.com";
    try std.testing.expectError(error.InvalidEndpoint, cfg.validate());
}

test "M-5: validate rejects loopback by default" {
    var cfg: otel.sdk.config.Config = .{};
    cfg.traces.otlp.endpoint = "http://127.0.0.1:4318";
    try std.testing.expectError(error.InvalidEndpoint, cfg.validate());
}

test "M-5: validate accepts loopback when allow_loopback is set" {
    var cfg: otel.sdk.config.Config = .{};
    cfg.traces.otlp.endpoint = "http://127.0.0.1:4318";
    cfg.traces.otlp.allow_loopback = true;
    cfg.metrics.otlp.allow_loopback = true;
    cfg.logs.otlp.allow_loopback = true;
    // Other endpoints default to http://localhost:4318 — also loopback.
    cfg.metrics.otlp.endpoint = "http://127.0.0.1:4318";
    cfg.logs.otlp.endpoint = "http://127.0.0.1:4318";
    try cfg.validate();
}

test "M-5: validate accepts ordinary remote https endpoint" {
    var cfg: otel.sdk.config.Config = .{};
    cfg.traces.otlp.endpoint = "https://collector.example.com:4318";
    cfg.metrics.otlp.endpoint = "https://collector.example.com:4318";
    cfg.logs.otlp.endpoint = "https://collector.example.com:4318";
    try cfg.validate();
}

test "L-6: validate rejects timeout above 10 minutes" {
    var cfg: otel.sdk.config.Config = .{};
    cfg.traces.otlp.endpoint = "https://collector.example.com:4318";
    cfg.metrics.otlp.endpoint = "https://collector.example.com:4318";
    cfg.logs.otlp.endpoint = "https://collector.example.com:4318";
    cfg.traces.otlp.timeout_ms = 600_001;
    try std.testing.expectError(error.InvalidConfig, cfg.validate());
}

test "L-7: validate rejects NaN sampler_arg" {
    var cfg: otel.sdk.config.Config = .{};
    cfg.traces.otlp.endpoint = "https://collector.example.com:4318";
    cfg.metrics.otlp.endpoint = "https://collector.example.com:4318";
    cfg.logs.otlp.endpoint = "https://collector.example.com:4318";
    cfg.traces.sampler_arg = std.math.nan(f64);
    try std.testing.expectError(error.InvalidConfig, cfg.validate());
}

// -------------------------------------------------------------------------
// GAP-ENV-BSP (#33): OTEL_BSP_* env vars must be parsed and surfaced on
// `Config.bsp` so the BatchSpanProcessor can be reconfigured from the
// environment. Spec defaults: schedule_delay 5_000ms, export_timeout
// 30_000ms, max_queue_size 2048, max_export_batch_size 512.
// -------------------------------------------------------------------------

test "GAP-ENV-BSP: defaults when env unset" {
    var env_map = otel.sdk.config.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();

    var cfg: otel.sdk.config.Config = .{};
    try otel.sdk.config.applyEnvFromMap(&cfg, std.testing.allocator, &env_map);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 5_000), cfg.bsp.schedule_delay_ms);
    try std.testing.expectEqual(@as(u64, 30_000), cfg.bsp.export_timeout_ms);
    try std.testing.expectEqual(@as(u32, 2048), cfg.bsp.max_queue_size);
    try std.testing.expectEqual(@as(u32, 512), cfg.bsp.max_export_batch_size);
}

test "GAP-ENV-BSP: all four env vars parse to expected values" {
    var env_map = otel.sdk.config.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_BSP_SCHEDULE_DELAY", "1234");
    try env_map.put("OTEL_BSP_EXPORT_TIMEOUT", "9876");
    try env_map.put("OTEL_BSP_MAX_QUEUE_SIZE", "4096");
    try env_map.put("OTEL_BSP_MAX_EXPORT_BATCH_SIZE", "256");

    var cfg: otel.sdk.config.Config = .{};
    try otel.sdk.config.applyEnvFromMap(&cfg, std.testing.allocator, &env_map);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 1234), cfg.bsp.schedule_delay_ms);
    try std.testing.expectEqual(@as(u64, 9876), cfg.bsp.export_timeout_ms);
    try std.testing.expectEqual(@as(u32, 4096), cfg.bsp.max_queue_size);
    try std.testing.expectEqual(@as(u32, 256), cfg.bsp.max_export_batch_size);
}

test "GAP-ENV-BSP: invalid values fall back to defaults" {
    var env_map = otel.sdk.config.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_BSP_SCHEDULE_DELAY", "");
    try env_map.put("OTEL_BSP_EXPORT_TIMEOUT", "not-a-number");
    try env_map.put("OTEL_BSP_MAX_QUEUE_SIZE", "-99");
    try env_map.put("OTEL_BSP_MAX_EXPORT_BATCH_SIZE", "abc");

    var cfg: otel.sdk.config.Config = .{};
    try otel.sdk.config.applyEnvFromMap(&cfg, std.testing.allocator, &env_map);
    defer cfg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 5_000), cfg.bsp.schedule_delay_ms);
    try std.testing.expectEqual(@as(u64, 30_000), cfg.bsp.export_timeout_ms);
    try std.testing.expectEqual(@as(u32, 2048), cfg.bsp.max_queue_size);
    try std.testing.expectEqual(@as(u32, 512), cfg.bsp.max_export_batch_size);
}

test "GAP-ENV-BSP: BatchSpanProcessorOptions surface includes export_timeout_ms" {
    // The runtime BSP options struct must carry the new field so wiring
    // from Config.bsp -> BatchSpanProcessorOptions stays 1:1.
    const opts: otel.sdk.exporter.BatchSpanProcessorOptions = .{};
    try std.testing.expectEqual(@as(u64, 30_000), opts.export_timeout_ms);
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
