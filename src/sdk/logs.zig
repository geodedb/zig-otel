// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Logs SDK — LoggerProvider, simple/batch processors, and trace
// correlation. Records flow Logger -> LogProcessor -> LogExporter.

const std = @import("std");
const logs_api = @import("../api/logs.zig");
const trace_api = @import("../api/trace.zig");
const ctx_mod = @import("../api/context.zig");
const Resource = @import("resource.zig").Resource;
const exp = @import("export.zig");
const config_mod = @import("config.zig");
const exporter_factory = @import("exporter_factory.zig");

pub const LogsConfig = struct {
    resource: ?*Resource = null,
    processors: []const exp.LogProcessor = &.{},
    default_exporter: ?exp.LogExporter = null,
    /// Runtime kill-switch. When `true`, `logger()` returns an API-layer
    /// noop Logger so every `emit` call collapses to a no-op without
    /// hitting the processor chain. Mirrors the comptime
    /// `-Dotel_disabled=true` flag at runtime; the comptime flag still
    /// wins when set.
    disabled: bool = false,
};

pub const SimpleLogProcessor = struct {
    allocator: std.mem.Allocator,
    exporter: exp.LogExporter,
    resource_ref: *const Resource,

    pub fn init(allocator: std.mem.Allocator, exporter: exp.LogExporter, resource_ref: *const Resource) SimpleLogProcessor {
        return .{ .allocator = allocator, .exporter = exporter, .resource_ref = resource_ref };
    }

    pub fn processor(self: *SimpleLogProcessor) exp.LogProcessor {
        return .{ .ctx = self, .onEmitFn = simpleEmit, .forceFlushFn = simpleFlush, .shutdownFn = simpleShutdown };
    }
};

fn simpleEmit(ctx: ?*anyopaque, record: logs_api.LogRecord) void {
    const self: *SimpleLogProcessor = @ptrCast(@alignCast(ctx.?));
    var data = [1]exp.LogData{.{ .record = record, .instrumentation_scope = record.scope, .resource = self.resource_ref }};
    _ = self.exporter.exportLogs(&data) catch {};
}

fn simpleFlush(ctx: ?*anyopaque, timeout_ms: u64) anyerror!void {
    const self: *SimpleLogProcessor = @ptrCast(@alignCast(ctx.?));
    try self.exporter.forceFlush(timeout_ms);
}

fn simpleShutdown(ctx: ?*anyopaque) void {
    const self: *SimpleLogProcessor = @ptrCast(@alignCast(ctx.?));
    self.exporter.shutdown();
}

pub const LoggerProvider = struct {
    allocator: std.mem.Allocator,
    config: LogsConfig,
    resource: *Resource,
    owns_resource: bool,
    processors: []exp.LogProcessor,
    /// Heap-allocated so its internal `ctx` pointer survives the
    /// `LoggerProvider` value being moved by the caller.
    default_processor: ?*SimpleLogProcessor = null,
    /// GAP-EXPORTER-FACTORY (#4): when the provider is built via
    /// `initFromConfig`, the factory-allocated exporter is stored here
    /// so `deinit` can free it. Stays `null` for the legacy
    /// manually-wired path so existing callers don't see a behaviour
    /// change.
    owned_exporter: ?exporter_factory.OwnedLogExporter = null,

    pub fn init(allocator: std.mem.Allocator, config: LogsConfig) !LoggerProvider {
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
        var self: LoggerProvider = .{
            .allocator = allocator,
            .config = config,
            .resource = resource_ptr,
            .owns_resource = owns,
            .processors = &.{},
        };
        if (config.processors.len > 0) {
            const owned = try allocator.alloc(exp.LogProcessor, config.processors.len);
            @memcpy(owned, config.processors);
            self.processors = owned;
        } else if (config.default_exporter) |exporter| {
            const lp = try allocator.create(SimpleLogProcessor);
            lp.* = SimpleLogProcessor.init(allocator, exporter, resource_ptr);
            self.default_processor = lp;
            const owned = try allocator.alloc(exp.LogProcessor, 1);
            owned[0] = lp.processor();
            self.processors = owned;
        } else {
            self.processors = try allocator.alloc(exp.LogProcessor, 0);
        }
        return self;
    }

    pub fn deinit(self: *LoggerProvider) void {
        for (self.processors) |p| p.shutdown();
        self.allocator.free(self.processors);
        if (self.default_processor) |lp| self.allocator.destroy(lp);
        // Free the factory-allocated exporter LAST so processors can
        // observe a live exporter through their `shutdown` path.
        if (self.owned_exporter) |*owned| owned.deinit();
        self.owned_exporter = null;
        if (self.owns_resource) {
            self.resource.deinit();
            self.allocator.destroy(self.resource);
        }
    }

    /// Build a `LoggerProvider` from a resolved `Config`.
    ///
    /// GAP-EXPORTER-FACTORY (#4). Constructs the right exporter from
    /// `cfg.logs.exporter` + `cfg.logs.otlp` via the `exporter_factory`,
    /// then runs the standard `init` path which wires a
    /// `SimpleLogProcessor` around the exporter when `processors` is
    /// empty. The provider owns the factory-allocated exporter and
    /// frees it on `deinit`.
    ///
    /// When `cfg.logs.exporter == .none`, the provider has no
    /// processors and emits become a runtime no-op (matches the
    /// behaviour of leaving `default_exporter = null` on a manual
    /// `init` call).
    pub fn initFromConfig(allocator: std.mem.Allocator, cfg: *const config_mod.Config) !LoggerProvider {
        var owned = try exporter_factory.logExporterFromConfig(allocator, cfg);
        errdefer if (owned) |*o| o.deinit();

        const logs_cfg: LogsConfig = .{
            .default_exporter = if (owned) |o| o.exporter else null,
            .disabled = cfg.disabled,
        };
        var self = try init(allocator, logs_cfg);
        self.owned_exporter = owned;
        owned = null;
        return self;
    }

    pub fn forceFlush(self: *LoggerProvider, timeout_ms: u64) !void {
        for (self.processors) |p| try p.forceFlush(timeout_ms);
    }

    pub fn logger(self: *LoggerProvider, scope: trace_api.InstrumentationScope) logs_api.Logger {
        if (comptime @import("build_options").otel_disabled) return .{ .scope = scope };
        if (self.config.disabled) return .{ .scope = scope };
        return .{
            .ctx = self,
            .scope = scope,
            .emitFn = onEmit,
        };
    }
};

fn onEmit(ctx: ?*anyopaque, record: logs_api.LogRecord) void {
    const self: *LoggerProvider = @ptrCast(@alignCast(ctx.?));
    for (self.processors) |p| p.onEmit(record);
}

/// Apply trace correlation — copies the active span's IDs into the record.
pub fn correlate(parent: ctx_mod.Context, record: *logs_api.LogRecord) void {
    if (parent.activeSpanContext()) |sc| {
        record.trace_id = sc.trace_id;
        record.span_id = sc.span_id;
        record.flags = sc.flags;
    }
}

test "logger provider dispatches to processor" {
    const Captured = struct {
        var records: std.ArrayList(logs_api.LogRecord) = .empty;
        var alloc: std.mem.Allocator = undefined;

        fn capture(_: ?*anyopaque, items: []const exp.LogData) anyerror!exp.SpanExportResult {
            for (items) |it| try records.append(alloc, it.record);
            return .success;
        }

        fn shutdown(_: ?*anyopaque) void {}
        fn flush(_: ?*anyopaque, _: u64) anyerror!void {}
    };
    Captured.alloc = std.testing.allocator;
    Captured.records = .empty;
    defer Captured.records.deinit(std.testing.allocator);

    var resource = try @import("resource.zig").defaultResource(std.testing.allocator);
    defer resource.deinit();
    const exporter: exp.LogExporter = .{
        .ctx = null,
        .exportFn = Captured.capture,
        .shutdownFn = Captured.shutdown,
        .forceFlushFn = Captured.flush,
    };
    var lp = try LoggerProvider.init(std.testing.allocator, .{ .resource = &resource, .default_exporter = exporter });
    defer lp.deinit();
    const lg = lp.logger(.{ .name = "test" });
    lg.emit(.{ .severity = .info, .body = .{ .string = "hello" } });
    try std.testing.expectEqual(@as(usize, 1), Captured.records.items.len);
}
