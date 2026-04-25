// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Event builder. Events are log-shaped records with a name attribute,
// emitted via the Logger pipeline (per spec: events are logs).

const std = @import("std");
const attrs = @import("../internal/attributes.zig");
const logs = @import("logs.zig");
const id = @import("../internal/id.zig");
const SpanContext = @import("context.zig").SpanContext;

/// Builder for the well-known `event.name` log shape. Construct with
/// `init`, fill in attributes, then `emit` against a Logger.
pub const EventBuilder = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    severity: logs.Severity = .info,
    attributes: attrs.AttributeSet,
    body: logs.Body = .none,
    timestamp_unix_nano: u64 = 0,
    span_context: ?SpanContext = null,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) EventBuilder {
        return .{
            .allocator = allocator,
            .name = name,
            .attributes = attrs.AttributeSet.init(allocator),
        };
    }

    pub fn deinit(self: *EventBuilder) void {
        self.attributes.deinit();
    }

    pub fn withSpanContext(self: *EventBuilder, sc: SpanContext) void {
        self.span_context = sc;
    }

    pub fn setSeverity(self: *EventBuilder, sev: logs.Severity) void {
        self.severity = sev;
    }

    pub fn setBodyString(self: *EventBuilder, s: []const u8) void {
        self.body = .{ .string = s };
    }

    pub fn putAttribute(self: *EventBuilder, key: []const u8, value: attrs.Value) !void {
        try self.attributes.put(key, value);
    }

    pub fn emit(self: *EventBuilder, logger: logs.Logger) void {
        // Inject the canonical `event.name` attribute so collectors can
        // identify event-shaped logs.
        self.attributes.putString("event.name", self.name) catch {};
        var record: logs.LogRecord = .{
            .timestamp_unix_nano = self.timestamp_unix_nano,
            .severity = self.severity,
            .severity_text = self.severity.shortText(),
            .body = self.body,
            .attributes = &self.attributes,
            .event_name = self.name,
        };
        if (self.span_context) |sc| {
            record.trace_id = sc.trace_id;
            record.span_id = sc.span_id;
            record.flags = sc.flags;
        }
        logger.emit(record);
    }
};

test "event builder injects event.name" {
    var ev = EventBuilder.init(std.testing.allocator, "user.login");
    defer ev.deinit();
    try ev.putAttribute("user.id", .{ .string = "u-1" });
    const Captured = struct {
        var emitted: ?logs.LogRecord = null;
        fn cb(_: ?*anyopaque, r: logs.LogRecord) void {
            emitted = r;
        }
    };
    Captured.emitted = null;
    const logger: logs.Logger = .{
        .scope = .{ .name = "test" },
        .emitFn = Captured.cb,
    };
    ev.emit(logger);
    try std.testing.expectEqualStrings("user.login", Captured.emitted.?.event_name);
    try std.testing.expectEqualStrings("user.login", ev.attributes.getString("event.name").?);
}
