// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Resource — owned attribute set describing the entity producing
// telemetry. Built once at startup, merged from a stack of detectors,
// and shared by reference across the SDK.

const std = @import("std");
const attrs = @import("../internal/attributes.zig");
const semconv = @import("../generated/semconv.zig");
const build_options = @import("build_options");

pub const Resource = struct {
    attributes: attrs.AttributeSet,
    schema_url: []const u8 = "",
    /// Internal flag — true when this resource was assembled from one or
    /// more detectors. The SDK uses it to skip re-detection.
    detected: bool = false,

    pub fn init(allocator: std.mem.Allocator) Resource {
        return .{ .attributes = attrs.AttributeSet.init(allocator) };
    }

    pub fn deinit(self: *Resource) void {
        self.attributes.deinit();
    }

    /// Merge `other` into a copy of `self`. `other` wins on conflicts,
    /// matching the spec's "newer resource overrides older".
    pub fn merge(allocator: std.mem.Allocator, self: *const Resource, other: *const Resource) !Resource {
        var out = Resource.init(allocator);
        errdefer out.deinit();
        for (self.attributes.entries.items) |e| try out.attributes.put(e.key, e.value);
        for (other.attributes.entries.items) |e| try out.attributes.put(e.key, e.value);
        out.schema_url = if (other.schema_url.len != 0) other.schema_url else self.schema_url;
        out.detected = self.detected or other.detected;
        return out;
    }
};

pub const Detector = struct {
    ctx: ?*anyopaque,
    detectFn: *const fn (?*anyopaque, std.mem.Allocator) anyerror!Resource,

    pub fn detect(self: Detector, allocator: std.mem.Allocator) !Resource {
        return try self.detectFn(self.ctx, allocator);
    }
};

/// Default attribute set seeded by every otel SDK instance.
pub fn defaultResource(allocator: std.mem.Allocator) !Resource {
    var r = Resource.init(allocator);
    errdefer r.deinit();
    try r.attributes.putString(semconv.telemetry_sdk_name, "otel");
    try r.attributes.putString(semconv.telemetry_sdk_language, "zig");
    try r.attributes.putString(semconv.telemetry_sdk_version, build_options.version);
    return r;
}

/// Reads `service.name` from `OTEL_SERVICE_NAME` and the resource attrs
/// list from `OTEL_RESOURCE_ATTRIBUTES`. Missing vars produce an empty
/// resource.
pub fn envDetector() Detector {
    return .{ .ctx = null, .detectFn = envDetect };
}

fn envDetect(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror!Resource {
    var r = Resource.init(allocator);
    errdefer r.deinit();
    if (std.process.getEnvVarOwned(allocator, "OTEL_SERVICE_NAME")) |val| {
        defer allocator.free(val);
        try r.attributes.putString(semconv.service_name, val);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }
    if (std.process.getEnvVarOwned(allocator, "OTEL_RESOURCE_ATTRIBUTES")) |val| {
        defer allocator.free(val);
        try parseResourceAttributes(&r, val);
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }
    return r;
}

fn parseResourceAttributes(r: *Resource, raw: []const u8) !void {
    var iter = std.mem.splitScalar(u8, raw, ',');
    while (iter.next()) |pair_raw| {
        const pair = std.mem.trim(u8, pair_raw, " \t");
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        const key = std.mem.trim(u8, pair[0..eq], " \t");
        const value = std.mem.trim(u8, pair[eq + 1 ..], " \t");
        try r.attributes.putString(key, value);
    }
}

pub fn processDetector() Detector {
    return .{ .ctx = null, .detectFn = processDetect };
}

fn processDetect(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror!Resource {
    var r = Resource.init(allocator);
    errdefer r.deinit();
    const pid = std.os.linux.getpid();
    try r.attributes.putInt(semconv.process_pid, @intCast(pid));
    try r.attributes.putString(semconv.process_runtime_name, "zig");
    try r.attributes.putString(semconv.process_runtime_version, @import("builtin").zig_version_string);
    return r;
}

pub fn osDetector() Detector {
    return .{ .ctx = null, .detectFn = osDetect };
}

fn osDetect(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror!Resource {
    var r = Resource.init(allocator);
    errdefer r.deinit();
    const tag = @tagName(@import("builtin").os.tag);
    try r.attributes.putString(semconv.os_type, tag);
    return r;
}

pub fn hostDetector() Detector {
    return .{ .ctx = null, .detectFn = hostDetect };
}

fn hostDetect(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror!Resource {
    var r = Resource.init(allocator);
    errdefer r.deinit();
    var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    if (std.posix.gethostname(&hostname_buf)) |hostname| {
        try r.attributes.putString(semconv.host_name, hostname);
    } else |_| {}
    const arch = @tagName(@import("builtin").cpu.arch);
    try r.attributes.putString(semconv.host_arch, arch);
    return r;
}

/// Compose `detectors` into a single Resource, layering with the SDK
/// defaults. Detectors are applied in order; later detectors override
/// earlier ones on conflicts.
pub fn compose(allocator: std.mem.Allocator, detectors: []const Detector) !Resource {
    var current = try defaultResource(allocator);
    errdefer current.deinit();
    for (detectors) |d| {
        var detected = try d.detect(allocator);
        defer detected.deinit();
        var merged = try Resource.merge(allocator, &current, &detected);
        current.deinit();
        current = merged;
        merged = undefined;
    }
    current.detected = true;
    return current;
}

test "merge prefers the right-hand side" {
    var a = Resource.init(std.testing.allocator);
    defer a.deinit();
    try a.attributes.putString("service.name", "old");
    try a.attributes.putString("kept", "yes");

    var b = Resource.init(std.testing.allocator);
    defer b.deinit();
    try b.attributes.putString("service.name", "new");

    var merged = try Resource.merge(std.testing.allocator, &a, &b);
    defer merged.deinit();
    try std.testing.expectEqualStrings("new", merged.attributes.getString("service.name").?);
    try std.testing.expectEqualStrings("yes", merged.attributes.getString("kept").?);
}

test "default resource includes telemetry.sdk.* attrs" {
    var r = try defaultResource(std.testing.allocator);
    defer r.deinit();
    try std.testing.expectEqualStrings("otel", r.attributes.getString(semconv.telemetry_sdk_name).?);
    try std.testing.expectEqualStrings("zig", r.attributes.getString(semconv.telemetry_sdk_language).?);
}

test "parseResourceAttributes splits k=v pairs" {
    var r = Resource.init(std.testing.allocator);
    defer r.deinit();
    try parseResourceAttributes(&r, "service.namespace=demo, deployment.environment=prod");
    try std.testing.expectEqualStrings("demo", r.attributes.getString("service.namespace").?);
    try std.testing.expectEqualStrings("prod", r.attributes.getString("deployment.environment").?);
}
