// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// GAP-EXPORTER-FACTORY (#4) — end-to-end coverage for the
// `OTEL_TRACES_EXPORTER` / `OTEL_METRICS_EXPORTER` / `OTEL_LOGS_EXPORTER`
// → typed-exporter dispatch. The factory itself lives in
// `src/sdk/exporter_factory.zig`; the inline tests there cover the
// `none` short-circuit and protocol normalisation. This file pins the
// integration with each provider's `initFromConfig` helper, the env-var
// pipeline (`applyEnvFromMap`), and the lifecycle contract (factory-
// allocated exporters are freed by `provider.deinit()`).

const std = @import("std");
const otel = @import("otel");

const cfg_mod = otel.sdk.config;
const factory = otel.sdk.exporter_factory;

// ----------------------------------------------------------------------
// Per-signal env-var → ExporterKind dispatch
// ----------------------------------------------------------------------

test "OTEL_TRACES_EXPORTER=otlp_http selects http span exporter" {
    var env_map = cfg_mod.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_TRACES_EXPORTER", "otlp_http");

    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    try cfg_mod.applyEnvFromMap(&cfg, std.testing.allocator, &env_map);
    try std.testing.expectEqual(cfg_mod.ExporterKind.otlp_http, cfg.traces.exporter);

    var bundle = (try factory.spanExporterFromConfig(std.testing.allocator, &cfg)).?;
    defer bundle.deinit();
    // Any spanExporter exposes the typed handle.
    try bundle.exporter.forceFlush(0);
}

test "OTEL_TRACES_EXPORTER=otlp_grpc selects grpc span exporter" {
    var env_map = cfg_mod.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_TRACES_EXPORTER", "otlp_grpc");

    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    try cfg_mod.applyEnvFromMap(&cfg, std.testing.allocator, &env_map);
    try std.testing.expectEqual(cfg_mod.ExporterKind.otlp_grpc, cfg.traces.exporter);

    // AS-1: the zero-config default endpoint (localhost) is grandfathered
    // past the loopback opt-in, so default gRPC construction still works.
    var bundle = (try factory.spanExporterFromConfig(std.testing.allocator, &cfg)).?;
    defer bundle.deinit();
}

test "OTEL_TRACES_EXPORTER=otlp defaults to HTTP/protobuf per spec" {
    var env_map = cfg_mod.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_TRACES_EXPORTER", "otlp");

    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    try cfg_mod.applyEnvFromMap(&cfg, std.testing.allocator, &env_map);
    // `ExporterKind.fromString("otlp")` resolves to `.otlp_http` per
    // OTel spec — gRPC requires explicit `otlp_grpc`.
    try std.testing.expectEqual(cfg_mod.ExporterKind.otlp_http, cfg.traces.exporter);

    var bundle = (try factory.spanExporterFromConfig(std.testing.allocator, &cfg)).?;
    defer bundle.deinit();
}

test "OTEL_TRACES_EXPORTER=otlp + OTEL_EXPORTER_OTLP_PROTOCOL=grpc still picks otlp_http kind" {
    // Per OTel spec, the exporter selector and protocol selector are
    // independent dials. Setting `OTEL_TRACES_EXPORTER=otlp` keeps the
    // exporter kind at `.otlp_http`; the gRPC protocol on its own does
    // NOT flip the kind. Callers who want gRPC must set
    // `OTEL_TRACES_EXPORTER=otlp_grpc` explicitly. The factory still
    // honours that contract: kind is .otlp_http even though protocol
    // says grpc. The factory then normalises the wire protocol back to
    // http_protobuf since the otlp_http transport doesn't speak gRPC.
    var env_map = cfg_mod.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_TRACES_EXPORTER", "otlp");
    try env_map.put("OTEL_EXPORTER_OTLP_PROTOCOL", "grpc");

    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    try cfg_mod.applyEnvFromMap(&cfg, std.testing.allocator, &env_map);
    try std.testing.expectEqual(cfg_mod.ExporterKind.otlp_http, cfg.traces.exporter);
    try std.testing.expectEqual(cfg_mod.Protocol.grpc, cfg.traces.otlp.protocol);

    var bundle = (try factory.spanExporterFromConfig(std.testing.allocator, &cfg)).?;
    defer bundle.deinit();
    // Survives the build: the factory's `normalizeForHttp` downgrades
    // protocol back to http_protobuf so OtlpHttpExporter.init accepts
    // the input.
}

test "OTEL_TRACES_EXPORTER=none returns null bundle" {
    var env_map = cfg_mod.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_TRACES_EXPORTER", "none");

    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    try cfg_mod.applyEnvFromMap(&cfg, std.testing.allocator, &env_map);
    try std.testing.expectEqual(cfg_mod.ExporterKind.none, cfg.traces.exporter);

    const got = try factory.spanExporterFromConfig(std.testing.allocator, &cfg);
    try std.testing.expect(got == null);
}

test "OTEL_LOGS_EXPORTER=otlp picks log exporter" {
    var env_map = cfg_mod.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_LOGS_EXPORTER", "otlp");

    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    try cfg_mod.applyEnvFromMap(&cfg, std.testing.allocator, &env_map);
    try std.testing.expectEqual(cfg_mod.ExporterKind.otlp_http, cfg.logs.exporter);

    var bundle = (try factory.logExporterFromConfig(std.testing.allocator, &cfg)).?;
    defer bundle.deinit();
    try bundle.exporter.forceFlush(0);
}

test "OTEL_METRICS_EXPORTER=otlp_grpc picks grpc metric exporter" {
    var env_map = cfg_mod.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_METRICS_EXPORTER", "otlp_grpc");

    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    try cfg_mod.applyEnvFromMap(&cfg, std.testing.allocator, &env_map);
    try std.testing.expectEqual(cfg_mod.ExporterKind.otlp_grpc, cfg.metrics.exporter);

    // AS-1: the zero-config default endpoint (localhost) is grandfathered
    // past the loopback opt-in, so default gRPC construction still works.
    var bundle = (try factory.metricExporterFromConfig(std.testing.allocator, &cfg)).?;
    defer bundle.deinit();
}

test "OTEL_TRACES_EXPORTER=prometheus returns InvalidExporterForSignal" {
    // Prometheus is metrics-only. The factory must refuse for traces /
    // logs rather than silently substituting another exporter.
    var env_map = cfg_mod.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_TRACES_EXPORTER", "prometheus");

    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    try cfg_mod.applyEnvFromMap(&cfg, std.testing.allocator, &env_map);
    try std.testing.expectEqual(cfg_mod.ExporterKind.prometheus, cfg.traces.exporter);

    try std.testing.expectError(
        factory.FactoryError.InvalidExporterForSignal,
        factory.spanExporterFromConfig(std.testing.allocator, &cfg),
    );
}

test "OTEL_LOGS_EXPORTER=prometheus returns InvalidExporterForSignal" {
    var env_map = cfg_mod.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_LOGS_EXPORTER", "prometheus");

    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    try cfg_mod.applyEnvFromMap(&cfg, std.testing.allocator, &env_map);

    try std.testing.expectError(
        factory.FactoryError.InvalidExporterForSignal,
        factory.logExporterFromConfig(std.testing.allocator, &cfg),
    );
}

test "OTEL_METRICS_EXPORTER=prometheus returns PrometheusRequiresPullEndpoint" {
    // Prometheus is valid for metrics — but the factory cannot build it
    // here because the constructor needs a `*MeterProvider` (pull
    // model). The factory documents this constraint via a sentinel
    // error rather than silently returning a no-op exporter.
    var env_map = cfg_mod.EnvMap.init(std.testing.allocator);
    defer env_map.deinit();
    try env_map.put("OTEL_METRICS_EXPORTER", "prometheus");

    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    try cfg_mod.applyEnvFromMap(&cfg, std.testing.allocator, &env_map);

    try std.testing.expectError(
        factory.FactoryError.PrometheusRequiresPullEndpoint,
        factory.metricExporterFromConfig(std.testing.allocator, &cfg),
    );
}

// ----------------------------------------------------------------------
// Provider integration: TracerProvider.initFromConfig
// ----------------------------------------------------------------------

test "TracerProvider.initFromConfig wires factory exporter and frees on deinit" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    // Pick stdout because it has no syscalls under the testing
    // allocator and its only state is the heap box.
    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    cfg.traces.exporter = .stdout;

    var tp = try otel.sdk.trace.TracerProvider.initFromConfig(std.testing.allocator, &cfg);
    defer tp.deinit();
    // The provider has a default-batch processor wired around the
    // factory exporter — proves the typed handle reached the existing
    // pipeline.
    try std.testing.expectEqual(@as(usize, 1), tp.processors.len);
}

test "TracerProvider.initFromConfig with .none exporter has no processors" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    cfg.traces.exporter = .none;

    var tp = try otel.sdk.trace.TracerProvider.initFromConfig(std.testing.allocator, &cfg);
    defer tp.deinit();
    try std.testing.expectEqual(@as(usize, 0), tp.processors.len);
    try std.testing.expect(tp.owned_exporter == null);
}

test "TracerProvider.initFromConfig accepts otlp_http and frees clean" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    cfg.traces.exporter = .otlp_http;

    var tp = try otel.sdk.trace.TracerProvider.initFromConfig(std.testing.allocator, &cfg);
    defer tp.deinit();
    try std.testing.expect(tp.owned_exporter != null);
    try std.testing.expectEqual(@as(usize, 1), tp.processors.len);
}

test "TracerProvider.initFromConfig wires bsp options from config" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    cfg.traces.exporter = .stdout;
    cfg.bsp.schedule_delay_ms = 7;
    cfg.bsp.max_queue_size = 33;
    cfg.bsp.max_export_batch_size = 11;
    cfg.bsp.export_timeout_ms = 1234;

    var tp = try otel.sdk.trace.TracerProvider.initFromConfig(std.testing.allocator, &cfg);
    defer tp.deinit();
    try std.testing.expectEqual(@as(u64, 7), tp.config.bsp_options.schedule_delay_ms);
    try std.testing.expectEqual(@as(usize, 33), tp.config.bsp_options.max_queue_size);
    try std.testing.expectEqual(@as(usize, 11), tp.config.bsp_options.max_export_batch_size);
    try std.testing.expectEqual(@as(u64, 1234), tp.config.bsp_options.export_timeout_ms);
}

// ----------------------------------------------------------------------
// Provider integration: LoggerProvider.initFromConfig
// ----------------------------------------------------------------------

test "LoggerProvider.initFromConfig wires factory exporter via SimpleLogProcessor" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    cfg.logs.exporter = .stdout;

    var lp = try otel.sdk.logs.LoggerProvider.initFromConfig(std.testing.allocator, &cfg);
    defer lp.deinit();
    try std.testing.expectEqual(@as(usize, 1), lp.processors.len);
    try std.testing.expect(lp.owned_exporter != null);
}

test "LoggerProvider.initFromConfig with none exporter has no processors" {
    if (@import("build_options").otel_disabled) return error.SkipZigTest;
    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    cfg.logs.exporter = .none;

    var lp = try otel.sdk.logs.LoggerProvider.initFromConfig(std.testing.allocator, &cfg);
    defer lp.deinit();
    try std.testing.expectEqual(@as(usize, 0), lp.processors.len);
    try std.testing.expect(lp.owned_exporter == null);
}

// ----------------------------------------------------------------------
// Provider integration: MeterProvider.initFromConfig
// ----------------------------------------------------------------------

test "MeterProvider.initFromConfig stores factory exporter on default_exporter" {
    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    cfg.metrics.exporter = .stdout;

    var mp = try otel.sdk.metrics.MeterProvider.initFromConfig(std.testing.allocator, &cfg);
    defer mp.deinit();
    // The reader pipeline (#29) hasn't landed yet — stash the typed
    // handle on `config.default_exporter` so the upcoming periodic
    // reader can pick it up. Pin the contract here so Stage G doesn't
    // accidentally rename or drop the field.
    try std.testing.expect(mp.config.default_exporter != null);
    try std.testing.expect(mp.owned_exporter != null);
}

test "MeterProvider.initFromConfig with prometheus surfaces sentinel error" {
    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    cfg.metrics.exporter = .prometheus;

    try std.testing.expectError(
        factory.FactoryError.PrometheusRequiresPullEndpoint,
        otel.sdk.metrics.MeterProvider.initFromConfig(std.testing.allocator, &cfg),
    );
}

test "MeterProvider.initFromConfig with none has no exporter" {
    var cfg: cfg_mod.Config = .{};
    defer cfg.deinit(std.testing.allocator);
    cfg.metrics.exporter = .none;

    var mp = try otel.sdk.metrics.MeterProvider.initFromConfig(std.testing.allocator, &cfg);
    defer mp.deinit();
    try std.testing.expect(mp.config.default_exporter == null);
    try std.testing.expect(mp.owned_exporter == null);
}

// ----------------------------------------------------------------------
// Lifecycle: testing-allocator catches a leak if any factory bundle
// gets dropped without a deinit. The build above already exercises
// each branch — these tests pin "no leaks" specifically so the failure
// mode shows up as `error.MemoryLeak` from `std.testing.allocator`
// rather than a vague missing-test.
// ----------------------------------------------------------------------

test "lifecycle: stdout factory bundle deinits without leaks" {
    var bundle = (try factory.spanExporterFor(std.testing.allocator, .stdout, .{})).?;
    bundle.deinit();
}

test "lifecycle: in_memory factory bundle deinits without leaks" {
    var bundle = (try factory.metricExporterFor(std.testing.allocator, .in_memory, .{})).?;
    bundle.deinit();
}

test "lifecycle: deinit is idempotent (double-call no-op)" {
    var bundle = (try factory.spanExporterFor(std.testing.allocator, .stdout, .{})).?;
    bundle.deinit();
    // Second call must be a no-op — mirrors the
    // `Config.deinit`/`PropagatorBundle.deinit` contracts elsewhere
    // in the SDK.
    bundle.deinit();
}
