// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Trace API surface — the value types callers touch and the lightweight
// vtables that connect them to the SDK. No allocations happen here; the
// SDK side (see `src/sdk/trace.zig`) owns the heavy state.

const std = @import("std");
const id = @import("../internal/id.zig");
const attrs = @import("../internal/attributes.zig");
const SpanContext = @import("context.zig").SpanContext;
const Context = @import("context.zig").Context;
const build_options = @import("build_options");

pub const SpanKind = enum {
    unspecified,
    internal,
    server,
    client,
    producer,
    consumer,

    pub fn toString(self: SpanKind) []const u8 {
        return switch (self) {
            .unspecified => "unspecified",
            .internal => "internal",
            .server => "server",
            .client => "client",
            .producer => "producer",
            .consumer => "consumer",
        };
    }
};

pub const StatusCode = enum {
    unset,
    ok,
    @"error",

    pub fn toString(self: StatusCode) []const u8 {
        return switch (self) {
            .unset => "unset",
            .ok => "ok",
            .@"error" => "error",
        };
    }
};

pub const Status = struct {
    code: StatusCode = .unset,
    description: []const u8 = "",
};

pub const InstrumentationScope = struct {
    name: []const u8,
    version: []const u8 = "",
    schema_url: []const u8 = "",
};

pub const Link = struct {
    span_context: SpanContext,
    attributes: ?*attrs.AttributeSet = null,
};

pub const Event = struct {
    name: []const u8,
    time_unix_nano: u64,
    attributes: ?*attrs.AttributeSet = null,
};

pub const SpanOptions = struct {
    kind: SpanKind = .internal,
    parent: ?Context = null,
    links: []const Link = &.{},
    start_unix_nano: ?u64 = null,
    initial_attributes: []const attrs.Entry = &.{},
};

/// Heavy backing for a Span. Allocated and owned by the SDK; Span is just
/// a handle pointing at it.
pub const SpanState = struct {
    arena: std.heap.ArenaAllocator,
    name: []u8,
    sc: SpanContext,
    parent_span_id: id.SpanId = .invalid,
    kind: SpanKind = .internal,
    start_unix_nano: u64,
    end_unix_nano: ?u64 = null,
    status_code: StatusCode = .unset,
    status_description: []u8 = &.{},
    attributes: attrs.AttributeSet,
    events: std.ArrayList(Event),
    links: std.ArrayList(Link),
    instrumentation_scope: InstrumentationScope,
    /// Set by the SDK; called once on `end()` so processors can take ownership.
    on_end_ctx: ?*anyopaque = null,
    on_end: ?*const fn (?*anyopaque, *SpanState) void = null,
    /// Recording guards setStatus/addEvent so callers can opt-in to a
    /// non-recording span without paying for mutation work.
    recording: bool = true,
    ended: bool = false,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, sc: SpanContext, scope: InstrumentationScope, start_ns: u64) !*SpanState {
        const self = try allocator.create(SpanState);
        errdefer allocator.destroy(self);
        const name_copy = try allocator.dupe(u8, name);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .name = name_copy,
            .sc = sc,
            .start_unix_nano = start_ns,
            .attributes = attrs.AttributeSet.init(allocator),
            .events = .empty,
            .links = .empty,
            .instrumentation_scope = scope,
        };
        return self;
    }

    pub fn deinit(self: *SpanState) void {
        const child = self.arena.child_allocator;
        child.free(self.name);
        if (self.status_description.len != 0) child.free(self.status_description);
        self.attributes.deinit();
        self.events.deinit(child);
        self.links.deinit(child);
        self.arena.deinit();
        child.destroy(self);
    }
};

pub const Span = struct {
    state: ?*SpanState = null,
    sc: SpanContext = .{},

    /// Returns the SpanContext (W3C identity portion).
    pub fn context(self: Span) SpanContext {
        return self.sc;
    }

    pub fn isRecording(self: Span) bool {
        const s = self.state orelse return false;
        return s.recording and !s.ended;
    }

    pub fn end(self: Span, end_unix_nano: ?u64) void {
        const s = self.state orelse return;
        if (s.ended) return;
        s.ended = true;
        s.end_unix_nano = end_unix_nano orelse posixNow(s.start_unix_nano);
        if (s.on_end) |cb| cb(s.on_end_ctx, s);
    }

    fn posixNow(fallback: u64) u64 {
        const v = @import("../internal/clock.zig").unixNanoNow();
        return if (v == 0) fallback else v;
    }

    pub fn setName(self: Span, name: []const u8) void {
        const s = self.state orelse return;
        if (!s.recording or s.ended) return;
        const child = s.arena.child_allocator;
        child.free(s.name);
        s.name = child.dupe(u8, name) catch return;
    }

    pub fn setStatus(self: Span, code: StatusCode, description: []const u8) void {
        const s = self.state orelse return;
        if (!s.recording or s.ended) return;
        // Spec: setStatus(Ok) ignores any description; setStatus(Error) keeps it.
        const child = s.arena.child_allocator;
        if (s.status_description.len != 0) child.free(s.status_description);
        s.status_description = &.{};
        s.status_code = code;
        if (code == .@"error" and description.len != 0) {
            s.status_description = child.dupe(u8, description) catch &.{};
        }
    }

    pub fn setAttribute(self: Span, key: []const u8, value: attrs.Value) !void {
        const s = self.state orelse return;
        if (!s.recording or s.ended) return;
        try s.attributes.put(key, value);
    }

    pub fn setStringAttribute(self: Span, key: []const u8, value: []const u8) !void {
        try self.setAttribute(key, .{ .string = value });
    }

    pub fn setIntAttribute(self: Span, key: []const u8, value: i64) !void {
        try self.setAttribute(key, .{ .int = value });
    }

    pub fn recordException(self: Span, message: []const u8, exception_type: []const u8, time_unix_nano: ?u64) !void {
        // Bridged to logs in SDK; here we just stash a synthetic event so
        // golden-style tests can observe it without log plumbing.
        const s = self.state orelse return;
        if (!s.recording or s.ended) return;
        const child = s.arena.child_allocator;
        const arena = self.eventArena(s);
        const ev_attrs = arena.create(attrs.AttributeSet) catch return;
        ev_attrs.* = attrs.AttributeSet.init(child);
        ev_attrs.putString("exception.message", message) catch {};
        ev_attrs.putString("exception.type", exception_type) catch {};
        const t = time_unix_nano orelse posixNow(s.start_unix_nano);
        s.events.append(child, .{ .name = "exception", .time_unix_nano = t, .attributes = ev_attrs }) catch return;
    }

    fn eventArena(_: Span, s: *SpanState) std.mem.Allocator {
        return s.arena.allocator();
    }

    /// Deprecated. Use the logs API. Compiled only when
    /// `-Ddeprecated_span_events=true`.
    pub fn addEvent(self: Span, name: []const u8, time_unix_nano: ?u64) !void {
        if (!build_options.deprecated_span_events) {
            @compileError("Span.addEvent requires -Ddeprecated_span_events=true; use the logs API instead");
        }
        const s = self.state orelse return;
        if (!s.recording or s.ended) return;
        const child = s.arena.child_allocator;
        const t = time_unix_nano orelse posixNow(s.start_unix_nano);
        try s.events.append(child, .{ .name = name, .time_unix_nano = t, .attributes = null });
    }

    /// Used by Context.activeSpan. Round-trips the underlying state pointer.
    pub fn handle(self: Span) ?*anyopaque {
        return @ptrCast(self.state);
    }

    pub fn fromHandle(ptr: *anyopaque, sc: SpanContext) Span {
        return .{ .state = @ptrCast(@alignCast(ptr)), .sc = sc };
    }

    pub const noop: Span = .{};
};

/// Tracer — a value handle into a TracerProvider scope. The SDK fills in
/// the vtable; the no-op variant returns a non-recording Span.
pub const Tracer = struct {
    ctx: ?*anyopaque = null,
    scope: InstrumentationScope,
    startSpanFn: *const fn (?*anyopaque, Context, []const u8, SpanOptions) anyerror!Span = noopStart,

    pub fn startSpan(self: Tracer, ctx: Context, name: []const u8, opts: SpanOptions) !Span {
        return try self.startSpanFn(self.ctx, ctx, name, opts);
    }
};

fn noopStart(_: ?*anyopaque, _: Context, _: []const u8, _: SpanOptions) anyerror!Span {
    return .noop;
}

test "no-op tracer returns no-op span" {
    const t: Tracer = .{ .scope = .{ .name = "test" } };
    const s = try t.startSpan(.empty(), "x", .{});
    try std.testing.expect(!s.isRecording());
    s.end(null);
}

test "span context survives round-trip" {
    var dummy: u8 = 0;
    const sc: SpanContext = .{
        .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
        .span_id = .{ .bytes = .{ 17, 18, 19, 20, 21, 22, 23, 24 } },
    };
    const ptr: *anyopaque = @ptrCast(&dummy);
    const span = Span.fromHandle(ptr, sc);
    try std.testing.expectEqualSlices(u8, sc.trace_id.bytes[0..], span.context().trace_id.bytes[0..]);
    try std.testing.expect(span.handle() == ptr);
}
