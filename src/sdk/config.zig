// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Configuration plumbing — environment variables, declarative YAML, and
// precedence resolution. The precedence rule, top-down: code overrides
// declarative, declarative overrides environment, environment overrides
// defaults. Failures fail closed (return error) so misconfigurations
// never silently degrade telemetry.

const std = @import("std");
const build_options = @import("build_options");
const devnw_yaml = if (build_options.use_devnw_config) @import("yaml") else struct {};

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
    /// Internal: marks endpoint as allocator-owned (set by env/YAML loaders
    /// after duping). Defaults remain static literals.
    endpoint_owned: bool = false,
    /// Internal: marks headers as allocator-owned.
    headers_owned: bool = false,
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

    // Ownership bookkeeping — set by loaders that duped from env / YAML.
    // Default Config{} uses static literals everywhere so the defaults
    // remain copy-free; only loaders that actually allocate flip these.
    file_format_owned: bool = false,
    service_name_owned: bool = false,
    resource_attributes_owned: bool = false,

    pub fn validate(self: *const Config) !void {
        if (self.file_format.len == 0) return error.InvalidConfig;
        if (self.traces.sampler_arg < 0 or self.traces.sampler_arg > 1.0) return error.InvalidConfig;
        if (self.traces.otlp.endpoint.len == 0) return error.InvalidEndpoint;
    }

    /// Frees every string field that a loader (env / YAML) allocated. Safe
    /// to call on a default Config{} (no-op because every `*_owned` flag is
    /// false). Idempotent: clears the flags as it goes so a double-free
    /// never happens.
    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        if (self.file_format_owned) {
            allocator.free(self.file_format);
            self.file_format = "";
            self.file_format_owned = false;
        }
        if (self.service_name_owned) {
            allocator.free(self.service_name);
            self.service_name = "";
            self.service_name_owned = false;
        }
        if (self.resource_attributes_owned) {
            allocator.free(self.resource_attributes);
            self.resource_attributes = "";
            self.resource_attributes_owned = false;
        }
        deinitOtlp(&self.traces.otlp, allocator);
        deinitOtlp(&self.metrics.otlp, allocator);
        deinitOtlp(&self.logs.otlp, allocator);
    }
};

fn deinitOtlp(o: *OtlpConfig, allocator: std.mem.Allocator) void {
    if (o.endpoint_owned) {
        allocator.free(o.endpoint);
        o.endpoint = "";
        o.endpoint_owned = false;
    }
    if (o.headers_owned) {
        if (o.headers) |h| allocator.free(h);
        o.headers = null;
        o.headers_owned = false;
    }
}

/// Free `dst`'s current value (if owned) and replace it with an
/// allocator-owned copy of `value`. Use whenever a loader writes a
/// string that may have been previously set by an earlier layer.
fn setOwnedString(dst: *[]const u8, owned_flag: *bool, allocator: std.mem.Allocator, value: []const u8) !void {
    const dup = try allocator.dupe(u8, value);
    if (owned_flag.*) allocator.free(dst.*);
    dst.* = dup;
    owned_flag.* = true;
}

fn setOwnedOptionalString(dst: *?[]const u8, owned_flag: *bool, allocator: std.mem.Allocator, value: []const u8) !void {
    const dup = try allocator.dupe(u8, value);
    if (owned_flag.* and dst.* != null) allocator.free(dst.*.?);
    dst.* = dup;
    owned_flag.* = true;
}

fn setOwnedEndpoint(otlp: *OtlpConfig, allocator: std.mem.Allocator, value: []const u8) !void {
    try setOwnedString(&otlp.endpoint, &otlp.endpoint_owned, allocator, value);
}

fn setOwnedHeaders(otlp: *OtlpConfig, allocator: std.mem.Allocator, value: []const u8) !void {
    try setOwnedOptionalString(&otlp.headers, &otlp.headers_owned, allocator, value);
}

/// Re-export of the process environment map type. Zig 0.16 publishes it
/// as `std.process.Environ.Map`; we alias here so tests and callers can
/// reference `otel.sdk.config.EnvMap` without coupling to that path.
pub const EnvMap = std.process.Environ.Map;

/// Build a Config by layering: defaults → env → YAML file → caller overrides.
///
/// Ownership: every string field that env or YAML populates becomes
/// allocator-owned. Callers MUST call `cfg.deinit(allocator)` to free.
pub fn resolve(allocator: std.mem.Allocator, user_overrides: ?Config) !Config {
    var cfg: Config = .{};
    errdefer cfg.deinit(allocator);

    var env_map = try captureEnvironment(allocator);
    defer env_map.deinit();
    try applyEnvFromMap(&cfg, allocator, &env_map);

    if (env_map.get("OTEL_CONFIG_FILE")) |path| {
        const data = try std.fs.cwd().readFileAlloc(allocator, path, 1 << 20);
        defer allocator.free(data);
        if (build_options.use_devnw_config) {
            try applyYamlStringDevnw(&cfg, allocator, data);
        } else {
            try applyYamlString(&cfg, allocator, data);
        }
    }

    if (user_overrides) |o| try applyOverrides(&cfg, allocator, o);

    try cfg.validate();
    return cfg;
}

/// Snapshot the current process environment into an owned `EnvMap`.
/// Wraps `std.process.Environ.createMap` against the global block, so
/// callers stay agnostic to host OS (POSIX / Windows / WASI).
fn captureEnvironment(allocator: std.mem.Allocator) !EnvMap {
    return std.process.Environ.createMap(.{ .block = std.process.Environ.Block.global }, allocator);
}

/// Populate `cfg` from a process EnvMap. Every string slice stored on
/// `cfg` is duped from the map and tracked as allocator-owned, so a
/// subsequent map mutation or free leaves `cfg` intact.
///
/// Test-friendly: callers that don't want the live process environment
/// can pass a synthetic `EnvMap`.
pub fn applyEnvFromMap(cfg: *Config, allocator: std.mem.Allocator, env_map: *const EnvMap) !void {
    if (env_map.get("OTEL_SDK_DISABLED")) |v| {
        cfg.disabled = parseBool(v) orelse cfg.disabled;
    }
    if (env_map.get("OTEL_LOG_LEVEL")) |v| applyLogLevel(cfg, v);
    if (env_map.get("OTEL_TRACES_SAMPLER")) |v| {
        if (std.mem.eql(u8, v, "always_on")) cfg.traces.sampler = .always_on;
        if (std.mem.eql(u8, v, "always_off")) cfg.traces.sampler = .always_off;
        if (std.mem.eql(u8, v, "parentbased_always_on") or std.mem.eql(u8, v, "parentbased_always_off")) cfg.traces.sampler = .parent_based;
        if (std.mem.eql(u8, v, "traceidratio") or std.mem.eql(u8, v, "parentbased_traceidratio")) cfg.traces.sampler = .traceidratio;
    }
    if (env_map.get("OTEL_TRACES_SAMPLER_ARG")) |v| {
        cfg.traces.sampler_arg = std.fmt.parseFloat(f64, v) catch cfg.traces.sampler_arg;
    }
    if (env_map.get("OTEL_TRACES_EXPORTER")) |v| {
        cfg.traces.exporter = ExporterKind.fromString(v);
    }
    if (env_map.get("OTEL_METRICS_EXPORTER")) |v| {
        cfg.metrics.exporter = ExporterKind.fromString(v);
    }
    if (env_map.get("OTEL_LOGS_EXPORTER")) |v| {
        cfg.logs.exporter = ExporterKind.fromString(v);
    }
    if (env_map.get("OTEL_EXPORTER_OTLP_ENDPOINT")) |v| {
        try setOwnedEndpoint(&cfg.traces.otlp, allocator, v);
        try setOwnedEndpoint(&cfg.metrics.otlp, allocator, v);
        try setOwnedEndpoint(&cfg.logs.otlp, allocator, v);
    }
    if (env_map.get("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")) |v| try setOwnedEndpoint(&cfg.traces.otlp, allocator, v);
    if (env_map.get("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT")) |v| try setOwnedEndpoint(&cfg.metrics.otlp, allocator, v);
    if (env_map.get("OTEL_EXPORTER_OTLP_LOGS_ENDPOINT")) |v| try setOwnedEndpoint(&cfg.logs.otlp, allocator, v);

    if (env_map.get("OTEL_EXPORTER_OTLP_PROTOCOL")) |v| {
        if (Protocol.fromString(v)) |p| {
            cfg.traces.otlp.protocol = p;
            cfg.metrics.otlp.protocol = p;
            cfg.logs.otlp.protocol = p;
        }
    }
    if (env_map.get("OTEL_EXPORTER_OTLP_TIMEOUT")) |v| {
        const ms = std.fmt.parseInt(u64, v, 10) catch null;
        if (ms) |m| {
            cfg.traces.otlp.timeout_ms = m;
            cfg.metrics.otlp.timeout_ms = m;
            cfg.logs.otlp.timeout_ms = m;
        }
    }
    if (env_map.get("OTEL_EXPORTER_OTLP_HEADERS")) |v| {
        try setOwnedHeaders(&cfg.traces.otlp, allocator, v);
        try setOwnedHeaders(&cfg.metrics.otlp, allocator, v);
        try setOwnedHeaders(&cfg.logs.otlp, allocator, v);
    }
    if (env_map.get("OTEL_SERVICE_NAME")) |v| {
        try setOwnedString(&cfg.service_name, &cfg.service_name_owned, allocator, v);
    }
    if (env_map.get("OTEL_RESOURCE_ATTRIBUTES")) |v| {
        try setOwnedString(&cfg.resource_attributes, &cfg.resource_attributes_owned, allocator, v);
    }
    if (env_map.get("OTEL_PROPAGATORS")) |v| {
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

/// Minimal YAML subset: top-level mapping plus one level of nesting.
/// Sufficient for the OpenTelemetry declarative config schema's shallow
/// scenarios. Documented as a strict subset in docs/SPEC_COMPLIANCE.md.
///
/// Ownership: every string field copied into `cfg` is duped with
/// `allocator`. The `source` slice may be freed immediately after this
/// returns; `Config.deinit(allocator)` releases the duped strings.
pub fn applyYamlString(cfg: *Config, allocator: std.mem.Allocator, source: []const u8) !void {
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
                try applyKv(cfg, allocator, current_section, "", value);
                current_section = "";
            }
        } else {
            const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return error.InvalidConfig;
            const key = std.mem.trim(u8, trimmed[0..colon], " \t");
            const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
            try applyKv(cfg, allocator, current_section, key, value);
        }
    }
}

fn applyKv(cfg: *Config, allocator: std.mem.Allocator, section: []const u8, key: []const u8, value: []const u8) !void {
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
        applyLogLevel(cfg, value);
        return;
    }
    if (std.mem.eql(u8, section, "file_format")) {
        try setOwnedString(&cfg.file_format, &cfg.file_format_owned, allocator, unquote(value));
        return;
    }
    if (std.mem.eql(u8, section, "service_name")) {
        try setOwnedString(&cfg.service_name, &cfg.service_name_owned, allocator, unquote(value));
        return;
    }

    if (std.mem.eql(u8, section, "tracer_provider") or std.mem.eql(u8, section, "traces")) {
        try applyTraceKey(cfg, allocator, key, value);
        return;
    }
    if (std.mem.eql(u8, section, "meter_provider") or std.mem.eql(u8, section, "metrics")) {
        try applyMetricKey(cfg, allocator, key, value);
        return;
    }
    if (std.mem.eql(u8, section, "logger_provider") or std.mem.eql(u8, section, "logs")) {
        try applyLogKey(cfg, allocator, key, value);
        return;
    }
}

fn applyTraceKey(cfg: *Config, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
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
        try setOwnedEndpoint(&cfg.traces.otlp, allocator, unquote(value));
    } else if (std.mem.eql(u8, key, "protocol")) {
        if (Protocol.fromString(unquote(value))) |p| cfg.traces.otlp.protocol = p;
    } else if (std.mem.eql(u8, key, "timeout")) {
        if (std.fmt.parseInt(u64, value, 10)) |m| cfg.traces.otlp.timeout_ms = m else |_| {}
    }
}

fn applyMetricKey(cfg: *Config, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "exporter")) {
        cfg.metrics.exporter = ExporterKind.fromString(unquote(value));
    } else if (std.mem.eql(u8, key, "interval")) {
        if (std.fmt.parseInt(u64, value, 10)) |ms| cfg.metrics.interval_ms = ms else |_| {}
    } else if (std.mem.eql(u8, key, "endpoint")) {
        try setOwnedEndpoint(&cfg.metrics.otlp, allocator, unquote(value));
    }
}

fn applyLogKey(cfg: *Config, allocator: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "exporter")) {
        cfg.logs.exporter = ExporterKind.fromString(unquote(value));
    } else if (std.mem.eql(u8, key, "endpoint")) {
        try setOwnedEndpoint(&cfg.logs.otlp, allocator, unquote(value));
    }
}

fn applyOverrides(cfg: *Config, allocator: std.mem.Allocator, o: Config) !void {
    // Code-supplied overrides are total: any field set to a non-default
    // value wins. We treat empty strings/zero as "not set" for the
    // ergonomically common cases. The override slices belong to the
    // caller; we always dupe so `Config.deinit` can free uniformly.
    if (o.disabled) cfg.disabled = true;
    if (o.service_name.len > 0) {
        try setOwnedString(&cfg.service_name, &cfg.service_name_owned, allocator, o.service_name);
    }
    if (o.resource_attributes.len > 0) {
        try setOwnedString(&cfg.resource_attributes, &cfg.resource_attributes_owned, allocator, o.resource_attributes);
    }
    if (o.traces.otlp.endpoint.len > 0 and !std.mem.eql(u8, o.traces.otlp.endpoint, "http://localhost:4318")) {
        try setOwnedEndpoint(&cfg.traces.otlp, allocator, o.traces.otlp.endpoint);
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

/// DevNW yaml-backed loader. Active only when the `otel_use_devnw_config`
/// build option is true; otherwise it returns `error.UnsupportedTransport`
/// so callers can detect the misconfiguration. The DevNW yaml package
/// surfaces a typed `Value` union (null/bool/int/float/str/seq/map) via
/// `loadAll` + `resolveToValue`; we walk the top-level map and the three
/// known provider sub-maps to populate the in-repo `Config`.
pub fn applyYamlStringDevnw(cfg: *Config, allocator: std.mem.Allocator, source: []const u8) !void {
    // The comptime branch in `devnw_loader` materialises the off-branch
    // implementation when the flag is off, so callers always see the same
    // signature and the dep is never resolved.
    return devnw_loader.apply(cfg, allocator, source);
}

fn applyLogLevel(cfg: *Config, s: []const u8) void {
    if (std.mem.eql(u8, s, "trace")) cfg.log_level = .trace;
    if (std.mem.eql(u8, s, "debug")) cfg.log_level = .debug;
    if (std.mem.eql(u8, s, "info")) cfg.log_level = .info;
    if (std.mem.eql(u8, s, "warn")) cfg.log_level = .warn;
    if (std.mem.eql(u8, s, "error")) cfg.log_level = .err;
}

// ----- DevNW yaml Value helpers (compiled only when the dep is wired). -----
//
// Wrapping the helpers in a comptime-gated namespace keeps every reference
// to `devnw_yaml.Value` (and its `.map` payload type) out of the compile
// graph when `use_devnw_config` is false. The empty-namespace branch keeps
// the symbol resolvable so the dispatch above type-checks in either mode.

const devnw_loader = if (build_options.use_devnw_config) struct {
    const Pairs = @TypeOf(@as(devnw_yaml.Value, .{ .map = &.{} }).map);

    fn apply(cfg: *Config, allocator: std.mem.Allocator, source: []const u8) !void {
        var docs = try devnw_yaml.loadAll(allocator, source, .{});
        defer {
            for (docs) |*d| d.deinit();
            allocator.free(docs);
        }
        if (docs.len == 0) return;

        var root = try devnw_yaml.resolveToValue(allocator, &docs[0], .{});
        defer devnw_yaml.freeValue(allocator, &root);

        const top = mapOf(root) orelse return;

        if (lookupString(top, "file_format")) |s| try setOwnedString(&cfg.file_format, &cfg.file_format_owned, allocator, s);
        if (lookupBool(top, "disabled")) |b| cfg.disabled = b;
        if (lookupString(top, "log_level")) |s| applyLogLevel(cfg, s);

        if (lookupTable(top, "tracer_provider") orelse lookupTable(top, "traces")) |t| {
            if (lookupString(t, "exporter")) |s| cfg.traces.exporter = ExporterKind.fromString(s);
            if (lookupString(t, "endpoint")) |s| try setOwnedEndpoint(&cfg.traces.otlp, allocator, s);
            if (lookupString(t, "protocol")) |s| {
                if (Protocol.fromString(s)) |p| cfg.traces.otlp.protocol = p;
            }
            if (lookupInt(t, "timeout")) |ms| cfg.traces.otlp.timeout_ms = @intCast(ms);
        }
        if (lookupTable(top, "meter_provider") orelse lookupTable(top, "metrics")) |t| {
            if (lookupString(t, "exporter")) |s| cfg.metrics.exporter = ExporterKind.fromString(s);
            if (lookupString(t, "endpoint")) |s| try setOwnedEndpoint(&cfg.metrics.otlp, allocator, s);
            if (lookupInt(t, "interval")) |ms| cfg.metrics.interval_ms = @intCast(ms);
        }
        if (lookupTable(top, "logger_provider") orelse lookupTable(top, "logs")) |t| {
            if (lookupString(t, "exporter")) |s| cfg.logs.exporter = ExporterKind.fromString(s);
            if (lookupString(t, "endpoint")) |s| try setOwnedEndpoint(&cfg.logs.otlp, allocator, s);
        }
    }

    fn mapOf(v: devnw_yaml.Value) ?Pairs {
        return switch (v) {
            .map => |m| m,
            else => null,
        };
    }

    fn lookupValue(pairs: Pairs, key: []const u8) ?devnw_yaml.Value {
        for (pairs) |kv| {
            switch (kv.k) {
                .str => |s| if (std.mem.eql(u8, s, key)) return kv.v,
                else => {},
            }
        }
        return null;
    }

    fn lookupString(pairs: Pairs, key: []const u8) ?[]const u8 {
        const v = lookupValue(pairs, key) orelse return null;
        return switch (v) {
            .str => |s| s,
            else => null,
        };
    }

    fn lookupBool(pairs: Pairs, key: []const u8) ?bool {
        const v = lookupValue(pairs, key) orelse return null;
        return switch (v) {
            .bool => |b| b,
            else => null,
        };
    }

    fn lookupInt(pairs: Pairs, key: []const u8) ?i64 {
        const v = lookupValue(pairs, key) orelse return null;
        return switch (v) {
            .int => |n| n,
            else => null,
        };
    }

    fn lookupTable(pairs: Pairs, key: []const u8) ?Pairs {
        const v = lookupValue(pairs, key) orelse return null;
        return switch (v) {
            .map => |m| m,
            else => null,
        };
    }
} else struct {
    fn apply(_: *Config, _: std.mem.Allocator, _: []const u8) !void {
        return error.UnsupportedTransport;
    }
};

test "validate rejects empty endpoint" {
    var cfg: Config = .{};
    cfg.traces.otlp.endpoint = "";
    try std.testing.expectError(error.InvalidEndpoint, cfg.validate());
}

test "applyYamlString parses basic mapping" {
    var cfg: Config = .{};
    defer cfg.deinit(std.testing.allocator);
    const src =
        \\disabled: false
        \\log_level: warn
        \\tracer_provider:
        \\  exporter: otlp
        \\  endpoint: "http://collector:4318"
        \\  protocol: http/protobuf
    ;
    try applyYamlString(&cfg, std.testing.allocator, src);
    try std.testing.expectEqual(@as(@TypeOf(cfg.log_level), .warn), cfg.log_level);
    try std.testing.expectEqual(ExporterKind.otlp_http, cfg.traces.exporter);
    try std.testing.expectEqualStrings("http://collector:4318", cfg.traces.otlp.endpoint);
    try std.testing.expectEqual(Protocol.http_protobuf, cfg.traces.otlp.protocol);
}
