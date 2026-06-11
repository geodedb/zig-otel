// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Pluggable TextMapPropagator interface and runtime-dispatched
// Composite. The W3C tracecontext + baggage propagators expose
// function-level inject/extract helpers (see `trace_context.zig` and
// `baggage.zig`); this module wraps them, plus the B3 / Jaeger
// propagators that follow, behind a small vtable so the SDK can
// build a propagator at provider-build time from the parsed
// `OTEL_PROPAGATORS` enum value.
//
// The vtable design intentionally mirrors the OTel spec
// `TextMapPropagator` interface: `inject` writes whatever fields a
// given propagator owns from the supplied `Fields` envelope, and
// `extract` returns whatever it could parse out of the carrier.
// Composite dispatch invokes every member on inject (each writes the
// fields it owns) and merges results on extract — first non-null
// span context wins, baggage entries are unioned in propagator order
// (later wins on collision, matching the spec's "last-write-wins"
// reading of composite extract).

const std = @import("std");
const tc = @import("trace_context.zig");
const bp = @import("baggage.zig");
const ctx_mod = @import("../api/context.zig");
const baggage_api = @import("../api/baggage.zig");

pub const Carrier = tc.Carrier;
pub const MapCarrier = tc.MapCarrier;

/// Inject envelope. A single propagator may consume the span context
/// portion (tracecontext, B3, Jaeger), the baggage portion (W3C
/// baggage, Jaeger uberctx), or both (Jaeger).
pub const Fields = struct {
    span_context: ?ctx_mod.SpanContext = null,
    baggage: ?*const baggage_api.Baggage = null,
};

pub const ExtractResult = struct {
    span_context: ?ctx_mod.SpanContext = null,
    baggage: ?baggage_api.Baggage = null,

    pub fn deinit(self: *ExtractResult) void {
        if (self.baggage) |*b| b.deinit();
    }
};

/// Vtable-backed propagator handle. Concrete propagators register
/// themselves by populating `inject_fn` / `extract_fn` and, optionally,
/// a borrowed `ctx` pointer. Both function pointers are required —
/// extracting-only or injecting-only propagators can return a no-op /
/// null result from the unused side.
pub const TextMapPropagator = struct {
    ctx: ?*anyopaque = null,
    inject_fn: *const fn (?*anyopaque, std.mem.Allocator, Carrier, Fields) anyerror!void,
    extract_fn: *const fn (?*anyopaque, std.mem.Allocator, std.mem.Allocator, Carrier) anyerror!ExtractResult,

    pub fn inject(self: TextMapPropagator, arena: std.mem.Allocator, carrier: Carrier, fields: Fields) !void {
        try self.inject_fn(self.ctx, arena, carrier, fields);
    }

    pub fn extract(self: TextMapPropagator, allocator: std.mem.Allocator, arena: std.mem.Allocator, carrier: Carrier) !ExtractResult {
        return self.extract_fn(self.ctx, allocator, arena, carrier);
    }
};

// ---------------------------------------------------------------- //
// Built-in propagator wrappers.
// ---------------------------------------------------------------- //

fn traceContextInject(_: ?*anyopaque, arena: std.mem.Allocator, carrier: Carrier, fields: Fields) !void {
    const sc = fields.span_context orelse return;
    try tc.inject(arena, carrier, sc);
}

fn traceContextExtract(_: ?*anyopaque, _: std.mem.Allocator, arena: std.mem.Allocator, carrier: Carrier) !ExtractResult {
    var out: ExtractResult = .{};
    out.span_context = tc.extract(arena, carrier) catch |err| switch (err) {
        // Spec: malformed traceparent doesn't poison sibling propagators.
        error.InvalidTraceParent, error.InvalidTraceState => null,
        else => return err,
    };
    return out;
}

pub const trace_context: TextMapPropagator = .{
    .inject_fn = traceContextInject,
    .extract_fn = traceContextExtract,
};

fn baggageInject(_: ?*anyopaque, arena: std.mem.Allocator, carrier: Carrier, fields: Fields) !void {
    const b = fields.baggage orelse return;
    try bp.inject(arena, carrier, b);
}

fn baggageExtract(_: ?*anyopaque, allocator: std.mem.Allocator, _: std.mem.Allocator, carrier: Carrier) !ExtractResult {
    var out: ExtractResult = .{};
    out.baggage = bp.extract(allocator, carrier) catch |err| switch (err) {
        error.InvalidBaggageKey, error.InvalidBaggageValue, error.BaggageTooLarge => null,
        else => return err,
    };
    return out;
}

pub const baggage: TextMapPropagator = .{
    .inject_fn = baggageInject,
    .extract_fn = baggageExtract,
};

// ---------------------------------------------------------------- //
// Composite — dispatches inject/extract to every member propagator.
// ---------------------------------------------------------------- //

pub const Composite = struct {
    members: []const TextMapPropagator,

    pub fn init(members: []const TextMapPropagator) Composite {
        return .{ .members = members };
    }

    /// Forward `fields` to every member. Each writes the headers it
    /// owns; the spec is silent on order, but we emit in declaration
    /// order so test snapshots remain deterministic.
    pub fn inject(self: Composite, arena: std.mem.Allocator, carrier: Carrier, fields: Fields) !void {
        for (self.members) |p| try p.inject(arena, carrier, fields);
    }

    /// Pull from every member. Per spec:
    ///   - span_context: first non-null wins (declaration order).
    ///   - baggage: union across members; on key collision the later
    ///     propagator's value wins (matches the W3C composite spec's
    ///     last-write-wins behaviour).
    pub fn extract(self: Composite, allocator: std.mem.Allocator, arena: std.mem.Allocator, carrier: Carrier) !ExtractResult {
        var out: ExtractResult = .{};
        errdefer out.deinit();

        var merged_baggage: ?baggage_api.Baggage = null;
        errdefer if (merged_baggage) |*b| b.deinit();

        for (self.members) |p| {
            var part = try p.extract(allocator, arena, carrier);
            // QN-NEW-9: free whatever `part` still owns when this iteration
            // ends, on EVERY path — including the merge-into-existing branch
            // where `merged.put` can fail (error.BaggageFull / OOM) and
            // would otherwise early-return past an explicit `part.deinit()`.
            // The first-member branch transfers `part.baggage` ownership into
            // `merged_baggage` and nulls it, so this defer then only frees an
            // already-empty `ExtractResult` (no double-free).
            defer part.deinit();
            // Adopt the first span context that surfaces.
            if (out.span_context == null and part.span_context != null) {
                out.span_context = part.span_context;
            }
            if (part.baggage) |*pb| {
                if (merged_baggage == null) {
                    merged_baggage = pb.*;
                    part.baggage = null; // ownership transferred
                } else {
                    var merged = &merged_baggage.?;
                    for (pb.iter()) |entry| {
                        try merged.put(entry.key, entry.value, entry.metadata);
                    }
                }
            }
        }
        out.baggage = merged_baggage;
        return out;
    }
};

// Tests live in `test/propagator.zig` (the in-repo convention is that
// `test/` is the only place where suites are wired through `build.zig`;
// inline tests in `src/**/*.zig` aren't run by the unit harness).
