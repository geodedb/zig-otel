// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Profiles API surface — experimental. The whole module is gated by
// `-Dotel_profiles=true`; with the option off, every public type is an
// inert stub that returns `error.UnsupportedTransport`.

const std = @import("std");
const build_options = @import("build_options");
const attrs = @import("../internal/attributes.zig");
const InstrumentationScope = @import("trace.zig").InstrumentationScope;

pub const enabled: bool = build_options.otel_profiles;

pub const SampleType = struct {
    type_name: []const u8,
    unit: []const u8,
};

pub const Sample = struct {
    /// Stack frames addressed by frame index (0-based) into `Profile.locations`.
    location_indexes: []const u64,
    /// Per-sample-type values, parallel to Profile.sample_types.
    values: []const i64,
    attributes: ?*attrs.AttributeSet = null,
    timestamps_unix_nano: []const u64 = &.{},
};

pub const Function = struct {
    name: []const u8,
    system_name: []const u8 = "",
    filename: []const u8 = "",
    start_line: i64 = 0,
};

pub const Location = struct {
    address: u64,
    function_index: ?u64 = null,
};

pub const Profile = struct {
    sample_types: []const SampleType,
    samples: []const Sample,
    locations: []const Location,
    functions: []const Function,
    start_unix_nano: u64,
    duration_nanos: u64,
    period_nanos: u64 = 0,
    attributes: ?*attrs.AttributeSet = null,
    scope: InstrumentationScope = .{ .name = "" },
};

pub const Profiler = struct {
    ctx: ?*anyopaque = null,
    scope: InstrumentationScope,
    emitFn: *const fn (?*anyopaque, Profile) anyerror!void = noopEmit,

    pub fn emit(self: Profiler, profile: Profile) !void {
        if (!enabled) return error.UnsupportedTransport;
        try self.emitFn(self.ctx, profile);
    }
};

fn noopEmit(_: ?*anyopaque, _: Profile) anyerror!void {
    return error.UnsupportedTransport;
}

test "profiler stub returns UnsupportedTransport when disabled or no-op" {
    const p: Profiler = .{ .scope = .{ .name = "test" } };
    const profile: Profile = .{
        .sample_types = &.{},
        .samples = &.{},
        .locations = &.{},
        .functions = &.{},
        .start_unix_nano = 0,
        .duration_nanos = 0,
    };
    try std.testing.expectError(error.UnsupportedTransport, p.emit(profile));
}
