// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Context — the OpenTelemetry-defined immutable propagation envelope.
//
// Zig has no implicit context, so callers pass Context explicitly. The
// type is small and copyable: it holds a SpanContext value and an
// optional Baggage borrow. `with*` returns a new Context, leaving the
// original untouched.

const std = @import("std");
const id = @import("../internal/id.zig");
const Baggage = @import("baggage.zig").Baggage;

pub const SpanContext = struct {
    trace_id: id.TraceId = .invalid,
    span_id: id.SpanId = .invalid,
    flags: id.TraceFlags = .{},
    is_remote: bool = false,
    /// Pointer-borrowed; the owner (usually a propagator-decoded buffer or
    /// a Span's tracestate slot) outlives the SpanContext.
    trace_state: ?[]const u8 = null,

    pub fn isValid(self: SpanContext) bool {
        return self.trace_id.isValid() and self.span_id.isValid();
    }
};

/// Imported lazily to avoid an api/trace.zig <-> api/context.zig cycle.
const trace_module = @import("trace.zig");

pub const Context = struct {
    span_context: ?SpanContext = null,
    /// Live Span handle, if any. Stored as opaque pointer to dodge the
    /// import cycle; cast back via `activeSpan()`.
    active_span: ?*anyopaque = null,
    baggage: ?*const Baggage = null,

    pub fn empty() Context {
        return .{};
    }

    pub fn withSpan(self: Context, span: trace_module.Span) Context {
        var c = self;
        c.span_context = span.context();
        c.active_span = span.handle();
        return c;
    }

    pub fn withSpanContext(self: Context, sc: SpanContext) Context {
        var c = self;
        c.span_context = sc;
        c.active_span = null;
        return c;
    }

    pub fn withBaggage(self: Context, baggage: Baggage) Context {
        var c = self;
        // The caller owns `baggage`; the Context borrows its address.
        c.baggage = &storageOf(baggage);
        return c;
    }

    /// Variant that stores a borrowed Baggage pointer directly. Use this
    /// when the lifetime/ownership of the baggage value is non-trivial.
    pub fn withBaggageRef(self: Context, baggage_ref: *const Baggage) Context {
        var c = self;
        c.baggage = baggage_ref;
        return c;
    }

    pub fn activeSpanContext(self: Context) ?SpanContext {
        return self.span_context;
    }

    pub fn activeSpan(self: Context) ?trace_module.Span {
        const ptr = self.active_span orelse return null;
        const sc = self.span_context orelse return null;
        return trace_module.Span.fromHandle(ptr, sc);
    }

    pub fn activeBaggage(self: Context) ?*const Baggage {
        return self.baggage;
    }
};

/// Internal pin so `withBaggage(value)` returns something with a stable
/// address. Test harnesses that rely on this should prefer `withBaggageRef`.
threadlocal var pinned: ?Baggage = null;

fn storageOf(b: Baggage) *const Baggage {
    pinned = b;
    return &pinned.?;
}

/// Ambient (thread-local) current Context.
///
/// Zig has no implicit context, so the canonical path is to pass Context
/// explicitly. This thread-local provides the OTel `Context.current()`
/// affordance for code paths that cannot thread a Context through their
/// signature — most importantly the logs emit path (`Logger.emit` takes
/// only a `LogRecord`), so the SDK reads `current()` to correlate emitted
/// records with the active span. Defaults to an empty Context (no active
/// span), so reading it before any `attach` is a safe no-op.
threadlocal var current_ctx: Context = .{};

/// A restore token returned by `attach`. Hold it and pass it to `restore`
/// to pop back to the previously-active Context (LIFO scope discipline).
pub const Token = struct {
    previous: Context,
};

/// Returns the ambient current Context for this thread.
pub fn current() Context {
    return current_ctx;
}

/// Make `ctx` the ambient current Context for this thread, returning a
/// `Token` that restores the prior Context. Pair every `attach` with a
/// `restore(token)` (typically `defer`) to keep scopes balanced.
pub fn attach(ctx: Context) Token {
    const tok: Token = .{ .previous = current_ctx };
    current_ctx = ctx;
    return tok;
}

/// Restore the ambient current Context to what it was before the matching
/// `attach`.
pub fn restore(token: Token) void {
    current_ctx = token.previous;
}

test "empty context has no span or baggage" {
    const c = Context.empty();
    try std.testing.expect(c.activeSpanContext() == null);
    try std.testing.expect(c.activeSpan() == null);
    try std.testing.expect(c.activeBaggage() == null);
}

test "withSpanContext stores the context" {
    const sc: SpanContext = .{
        .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
        .span_id = .{ .bytes = .{ 17, 18, 19, 20, 21, 22, 23, 24 } },
        .flags = .{ .sampled = true },
    };
    const c = Context.empty().withSpanContext(sc);
    const got = c.activeSpanContext().?;
    try std.testing.expectEqualSlices(u8, sc.trace_id.bytes[0..], got.trace_id.bytes[0..]);
    try std.testing.expect(got.flags.sampled);
}

test "withBaggageRef preserves caller-owned baggage" {
    var bag = Baggage.init(std.testing.allocator);
    defer bag.deinit();
    try bag.put("user.id", "u-1", null);
    const c = Context.empty().withBaggageRef(&bag);
    const got = c.activeBaggage().?;
    try std.testing.expectEqualStrings("u-1", got.get("user.id").?);
}
