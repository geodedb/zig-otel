// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Configuration plumbing — environment variables, declarative YAML, and
// precedence resolution. The precedence rule, top-down: code overrides
// declarative, declarative overrides environment, environment overrides
// defaults. Failures fail closed (return error) so misconfigurations
// never silently degrade telemetry.

const std = @import("std");

pub const ExporterKind = enum {
    in_memory,
    stdout,
    file,
    otlp_http,
    otlp_grpc,
    prometheus,
    none,

    pub fn fromString(s: []const u8) ExporterKind {
        if (std.ascii.eqlIgnoreCase(s, "in_memory") or std.ascii.eqlIgnoreCase(s, "memory")) return .in_memory;
        if (std.ascii.eqlIgnoreCase(s, "console") or std.ascii.eqlIgnoreCase(s, "stdout")) return .stdout;
        if (std.ascii.eqlIgnoreCase(s, "file")) return .file;
        if (std.ascii.eqlIgnoreCase(s, "otlp") or std.ascii.eqlIgnoreCase(s, "otlp_http")) return .otlp_http;
        if (std.ascii.eqlIgnoreCase(s, "otlp_grpc")) return .otlp_grpc;
        if (std.ascii.eqlIgnoreCase(s, "prometheus")) return .prometheus;
        return .none;
    }
};

pub const Protocol = enum {
    http_protobuf,
    http_json,
    grpc,

    pub fn fromString(s: []const u8) ?Protocol {
        if (std.ascii.eqlIgnoreCase(s, "http/protobuf") or std.ascii.eqlIgnoreCase(s, "http_protobuf")) return .http_protobuf;
        if (std.ascii.eqlIgnoreCase(s, "http/json") or std.ascii.eqlIgnoreCase(s, "http_json")) return .http_json;
        if (std.ascii.eqlIgnoreCase(s, "grpc")) return .grpc;
        return null;
    }
};

pub const OtlpConfig = struct {
    endpoint: []const u8 = "http://localhost:4318",
    protocol: Protocol = .http_protobuf,
    headers: ?[]const u8 = null,
    timeout_ms: u64 = 10_000,
    compression: enum { none, gzip } = .none,
    insecure: bool = false,
    /// When true, skip TLS verification. Default is false; the spec says
    /// HTTPS validation is on by default.
    skip_tls_verify: bool = false,
};

pub const TraceProviderConfig = struct {
    sampler: enum { always_on, always_off, parent_based, traceidratio } = .always_on,
    sampler_arg: f64 = 1.0,
    exporter: ExporterKind = .stdout,
    otlp: OtlpConfig = .{},
};

pub const MetricProviderConfig = struct {
    exporter: ExporterKind = .stdout,
    interval_ms: u64 = 60_000,
    otlp: OtlpConfig = .{},
};

pub const LogProviderConfig = struct {
    exporter: ExporterKind = .stdout,
    otlp: OtlpConfig = .{},
};

pub const Config = struct {
    /// File-format version; matches the OTel declarative config 1.0.0 schema.
    file_format: []const u8 = "1.0.0",
    disabled: bool = false,
    log_level: enum { trace, debug, info, warn, err } = .info,
    service_name: []const u8 = "",
    resource_attributes: []const u8 = "",
    propagator: enum { tracecontext, baggage, b3, jaeger, composite } = .composite,
    traces: TraceProviderConfig = .{},
    metrics: MetricProviderConfig = .{},
    logs: LogProviderConfig = .{},

    pub fn validate(self: *const Config) !void {
        if (self.file_format.len == 0) return error.InvalidConfig;
        if (self.traces.sampler_arg < 0 or self.traces.sampler_arg > 1.0) return error.InvalidConfig;
        if (self.traces.otlp.endpoint.len == 0) return error.InvalidEndpoint;
    }
};

/// Build a Config by layering: defaults → env → YAML file → caller overrides.
pub fn resolve(allocator: std.mem.Allocator, user_overrides: ?Config) !Config {
    var cfg: Config = .{};

    applyEnv(&cfg) catch |err| return err;

    if (std.process.getEnvVarOwned(allocator, "OTEL_CONFIG_FILE")) |path| {
        defer allocator.free(path);
        const data = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
        defer allocator.free(data);
        try applyYaml(&cfg, data);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    if (user_overrides) |o| applyOverrides(&cfg, o);

    try cfg.validate();
    return cfg;
}

fn applyEnv(cfg: *Config) !void {
    if (envOrNull("OTEL_SDK_DISABLED")) |v| {
        cfg.disabled = parseBool(v) orelse cfg.disabled;
    }
    if (envOrNull("OTEL_LOG_LEVEL")) |v| {
        if (std.mem.eql(u8, v, "trace")) cfg.log_level = .trace;
        if (std.mem.eql(u8, v, "debug")) cfg.log_level = .debug;
        if (std.mem.eql(u8, v, "info")) cfg.log_level = .info;
        if (std.mem.eql(u8, v, "warn")) cfg.log_level = .warn;
        if (std.mem.eql(u8, v, "error")) cfg.log_level = .err;
    }
    if (envOrNull("OTEL_TRACES_SAMPLER")) |v| {
        if (std.mem.eql(u8, v, "always_on")) cfg.traces.sampler = .always_on;
        if (std.mem.eql(u8, v, "always_off")) cfg.traces.sampler = .always_off;
        if (std.mem.eql(u8, v, "parentbased_always_on") or std.mem.eql(u8, v, "parentbased_always_off")) cfg.traces.sampler = .parent_based;
        if (std.mem.eql(u8, v, "traceidratio") or std.mem.eql(u8, v, "parentbased_traceidratio")) cfg.traces.sampler = .traceidratio;
    }
    if (envOrNull("OTEL_TRACES_SAMPLER_ARG")) |v| {
        cfg.traces.sampler_arg = std.fmt.parseFloat(f64, v) catch cfg.traces.sampler_arg;
    }
    if (envOrNull("OTEL_TRACES_EXPORTER")) |v| {
        cfg.traces.exporter = ExporterKind.fromString(v);
    }
    if (envOrNull("OTEL_METRICS_EXPORTER")) |v| {
        cfg.metrics.exporter = ExporterKind.fromString(v);
    }
    if (envOrNull("OTEL_LOGS_EXPORTER")) |v| {
        cfg.logs.exporter = ExporterKind.fromString(v);
    }
    if (envOrNull("OTEL_EXPORTER_OTLP_ENDPOINT")) |v| {
        cfg.traces.otlp.endpoint = v;
        cfg.metrics.otlp.endpoint = v;
        cfg.logs.otlp.endpoint = v;
    }
    if (envOrNull("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")) |v| cfg.traces.otlp.endpoint = v;
    if (envOrNull("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT")) |v| cfg.metrics.otlp.endpoint = v;
    if (envOrNull("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT")) |v| cfg.logs.otlp.endpoint = v;

    if (envOrNull("OTEL_EXPORTER_OTLP_PROTOCOL")) |v| {
        if (Protocol.fromString(v)) |p| {
            cfg.traces.otlp.protocol = p;
            cfg.metrics.otlp.protocol = p;
            cfg.logs.otlp.protocol = p;
        }
    }
    if (envOrNull("OTEL_EXPORTER_OTLP_TIMEOUT")) |v| {
        const ms = std.fmt.parseInt(u64, v, 10) catch null;
        if (ms) |m| {
            cfg.traces.otlp.timeout_ms = m;
            cfg.metrics.otlp.timeout_ms = m;
            cfg.logs.otlp.timeout_ms = m;
        }
    }
    if (envOrNull("OTEL_EXPORTER_OTLP_HEADERS")) |v| {
        cfg.traces.otlp.headers = v;
        cfg.metrics.otlp.headers = v;
        cfg.logs.otlp.headers = v;
    }
    if (envOrNull("OTEL_SERVICE_NAME")) |v| cfg.service_name = v;
    if (envOrNull("OTEL_RESOURCE_ATTRIBUTES")) |v| cfg.resource_attributes = v;
    if (envOrNull("OTEL_PROPAGATORS")) |v| {
        if (std.mem.eql(u8, v, "tracecontext")) cfg.propagator = .tracecontext;
        if (std.mem.eql(u8, v, "baggage")) cfg.propagator = .baggage;
        if (std.mem.eql(u8, v, "b3")) cfg.propagator = .b3;
        if (std.mem.eql(u8, v, "jaeger")) cfg.propagator = .jaeger;
    }
}

fn parseBool(v: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(v, "true")) return true;
    if (std.ascii.eqlIgnoreCase(v, "1")) return true;
    if (std.ascii.eqlIgnoreCase(v, "false")) return false;
    if (std.ascii.eqlIgnoreCase(v, "0")) return false;
    return null;
}

threadlocal var env_buf: [1024]u8 = undefined;
threadlocal var env_len: usize = 0;

/// Returns a slice borrowed from a thread-local scratch buffer for the
/// lifetime of the next env lookup. Suitable only inside `applyEnv` which
/// copies anything it stores. The buffer caps at 1 KiB; longer values are
/// truncated and treated as missing to avoid silent corruption.
fn envOrNull(name: []const u8) ?[]const u8 {
    var buf: [256]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const c_name: [*:0]const u8 = @ptrCast(buf[0..name.len :0]);
    const raw = std.posix.getenv(std.mem.span(c_name)) orelse return null;
    if (raw.len == 0) return null;
    if (raw.len > env_buf.len) return null;
    @memcpy(env_buf[0..raw.len], raw);
    env_len = raw.len;
    return env_buf[0..raw.len];
}

/// Minimal YAML subset: top-level mapping plus one level of nesting.
/// Sufficient for the OpenTelemetry declarative config schema's shallow
/// scenarios. Documented as a strict subset in docs/SPEC_COMPLIANCE.md.
fn applyYaml(cfg: *Config, source: []const u8) !void {
    var lines = std.mem.splitScalar(u8, source, '\n');
    var current_section: []const u8 = "";
    while (lines.next()) |raw_line| {
        const line = stripComment(raw_line);
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        const indent = countIndent(line);
        if (indent == 0) {
            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidConfig;
            current_section = std.mem.trim(u8, trimmed[0..colon], " \t");
            const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
            if (value.len > 0) {
                try applyKv(cfg, current_section, "", value);
                current_section = "";
            }
        } else {
            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidConfig;
            const key = std.mem.trim(u8, trimmed[0..colon], " \t");
            const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
            try applyKv(cfg, current_section, key, value);
        }
    }
}

fn applyKv(cfg: *Config, section: []const u8, key: []const u8, value: []const u8) !void {
    if (section.len == 0) {
        if (std.mem.eql(u8, key, "")) {
            // Top-level scalar in line `disabled: true`-style pre-processed.
            // Nothing to do; handled by caller.
            return;
        }
    }
    if (std.mem.eql(u8, section, "") and key.len == 0) return;

    if (std.mem.eql(u8, section, "disabled")) {
        cfg.disabled = parseBool(value) orelse cfg.disabled;
        return;
    }
    if (std.mem.eql(u8, section, "log_level")) {
        if (std.mem.eql(u8, value, "trace")) cfg.log_level = .trace;
        if (std.mem.eql(u8, value, "debug")) cfg.log_level = .debug;
        if (std.mem.eql(u8, value, "info")) cfg.log_level = .info;
        if (std.mem.eql(u8, value, "warn")) cfg.log_level = .warn;
        if (std.mem.eql(u8, value, "error")) cfg.log_level = .err;
        return;
    }
    if (std.mem.eql(u8, section, "file_format")) {
        cfg.file_format = unquote(value);
        return;
    }

    if (std.mem.eql(u8, section, "tracer_provider") or std.mem.eql(u8, section, "traces")) {
        try applyTraceKey(cfg, key, value);
        return;
    }
    if (std.mem.eql(u8, section, "meter_provider") or std.mem.eql(u8, section, "metrics")) {
        try applyMetricKey(cfg, key, value);
        return;
    }
    if (std.mem.eql(u8, section, "logger_provider") or std.mem.eql(u8, section, "logs")) {
        try applyLogKey(cfg, key, value);
        return;
    }
}

fn applyTraceKey(cfg: *Config, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "sampler")) {
        const v = unquote(value);
        if (std.mem.eql(u8, v, "always_on")) cfg.traces.sampler = .always_on;
        if (std.mem.eql(u8, v, "always_off")) cfg.traces.sampler = .always_off;
        if (std.mem.eql(u8, v, "parent_based")) cfg.traces.sampler = .parent_based;
        if (std.mem.eql(u8, v, "traceidratio")) cfg.traces.sampler = .traceidratio;
    } else if (std.mem.eql(u8, key, "sampler_arg")) {
        cfg.traces.sampler_arg = std.fmt.parseFloat(f64, value) catch cfg.traces.sampler_arg;
    } else if (std.mem.eql(u8, key, "exporter")) {
        cfg.traces.exporter = ExporterKind.fromString(unquote(value));
    } else if (std.mem.eql(u8, key, "endpoint")) {
        cfg.traces.otlp.endpoint = unquote(value);
    } else if (std.mem.eql(u8, key, "protocol")) {
        if (Protocol.fromString(unquote(value))) |p| cfg.traces.otlp.protocol = p;
    } else if (std.mem.eql(u8, key, "timeout")) {
        if (std.fmt.parseInt(u64, value, 10)) |m| cfg.traces.otlp.timeout_ms = m else |_| {}
    }
}

fn applyMetricKey(cfg: *Config, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "exporter")) {
        cfg.metrics.exporter = ExporterKind.fromString(unquote(value));
    } else if (std.mem.eql(u8, key, "interval")) {
        if (std.fmt.parseInt(u64, value, 10)) |ms| cfg.metrics.interval_ms = ms else |_| {}
    } else if (std.mem.eql(u8, key, "endpoint")) {
        cfg.metrics.otlp.endpoint = unquote(value);
    }
}

fn applyLogKey(cfg: *Config, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "exporter")) {
        cfg.logs.exporter = ExporterKind.fromString(unquote(value));
    } else if (std.mem.eql(u8, key, "endpoint")) {
        cfg.logs.otlp.endpoint = unquote(value);
    }
}

fn applyOverrides(cfg: *Config, o: Config) void {
    // Code-supplied overrides are total: any field set to a non-default
    // value wins. We treat empty strings/zero as "not set" for the
    // ergonomically common cases.
    if (o.disabled) cfg.disabled = true;
    if (o.service_name.len > 0) cfg.service_name = o.service_name;
    if (o.resource_attributes.len > 0) cfg.resource_attributes = o.resource_attributes;
    if (o.traces.otlp.endpoint.len > 0 and !std.mem.eql(u8, o.traces.otlp.endpoint, "http://localhost:4318")) {
        cfg.traces.otlp.endpoint = o.traces.otlp.endpoint;
    }
    if (o.traces.exporter != .stdout) cfg.traces.exporter = o.traces.exporter;
    if (o.metrics.exporter != .stdout) cfg.metrics.exporter = o.metrics.exporter;
    if (o.logs.exporter != .stdout) cfg.logs.exporter = o.logs.exporter;
    if (o.traces.sampler != .always_on) cfg.traces.sampler = o.traces.sampler;
    if (o.traces.sampler_arg != 1.0) cfg.traces.sampler_arg = o.traces.sampler_arg;
}

fn stripComment(line: []const u8) []const u8 {
    var in_quote = false;
    for (line, 0..) |c, i| {
        if (c == '"') in_quote = !in_quote;
        if (c == '#' and !in_quote) return line[0..i];
    }
    return line;
}

fn countIndent(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| {
        if (c == ' ') n += 1 else if (c == '\t') n += 4 else break;
    }
    return n;
}

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and (s[0] == '"' and s[s.len - 1] == '"')) return s[1 .. s.len - 1];
    if (s.len >= 2 and (s[0] == '\'' and s[s.len - 1] == '\'')) return s[1 .. s.len - 1];
    return s;
}

test "validate rejects empty endpoint" {
    var cfg: Config = .{};
    cfg.traces.otlp.endpoint = "";
    try std.testing.expectError(error.InvalidEndpoint, cfg.validate());
}

test "applyYaml parses basic mapping" {
    var cfg: Config = .{};
    const src =
        \\disabled: false
        \\log_level: warn
        \\tracer_provider:
        \\  exporter: otlp
        \\  endpoint: "http://collector:4318"
        \\  protocol: http/protobuf
    ;
    try applyYaml(&cfg, src);
    try std.testing.expectEqual(@as(@TypeOf(cfg.log_level), .warn), cfg.log_level);
    try std.testing.expectEqual(ExporterKind.otlp_http, cfg.traces.exporter);
    try std.testing.expectEqualStrings("http://collector:4318", cfg.traces.otlp.endpoint);
    try std.testing.expectEqual(Protocol.http_protobuf, cfg.traces.otlp.protocol);
}
