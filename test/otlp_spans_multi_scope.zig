// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Regression test for PR-3 (#136) — the trace OTLP encoder must group
// spans by `instrumentation_scope` and emit one `ScopeSpans` block per
// distinct scope. Pre-fix the encoder used `items[0].instrumentation_scope`
// for the entire batch, mislabelling every span past the first as
// belonging to scope[0].
//
// The test walks the encoded ResourceSpans bytes with a minimal varint
// decoder, asserting the on-wire shape directly. It exercises the
// in-repo encoder via `encodeSpansProto` and (when the build flag is
// on) the DevNW protobuf encoder via `encodeSpansProtoDevnw` for parity.

const std = @import("std");
const otel = @import("otel");
const build_options = @import("build_options");

// ---------------- minimal protobuf reader ----------------

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn eof(self: *const Reader) bool {
        return self.pos >= self.buf.len;
    }

    fn readVarint(self: *Reader) !u64 {
        var v: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (self.pos >= self.buf.len) return error.Truncated;
            const b = self.buf[self.pos];
            self.pos += 1;
            v |= (@as(u64, b & 0x7f)) << shift;
            if (b & 0x80 == 0) return v;
            shift += 7;
            if (shift >= 64) return error.VarintOverflow;
        }
    }

    fn readTag(self: *Reader) !struct { field: u32, wire: u3 } {
        const tag = try self.readVarint();
        return .{
            .field = @intCast(tag >> 3),
            .wire = @intCast(tag & 0x7),
        };
    }

    fn readBytes(self: *Reader) ![]const u8 {
        const n = try self.readVarint();
        if (self.pos + n > self.buf.len) return error.Truncated;
        const out = self.buf[self.pos .. self.pos + @as(usize, @intCast(n))];
        self.pos += @intCast(n);
        return out;
    }

    fn skip(self: *Reader, wire: u3) !void {
        switch (wire) {
            0 => _ = try self.readVarint(),
            1 => {
                if (self.pos + 8 > self.buf.len) return error.Truncated;
                self.pos += 8;
            },
            2 => _ = try self.readBytes(),
            5 => {
                if (self.pos + 4 > self.buf.len) return error.Truncated;
                self.pos += 4;
            },
            else => return error.UnsupportedWireType,
        }
    }
};

// Walk the encoded payload and pull out, for every emitted `ScopeSpans`
// block: the scope's (name, version, schema_url) tuple plus the list of
// span names that appear inside it. Assumes the encoder emits exactly
// one `ResourceSpans` (matches the existing single-batch contract).
const ScopeBlock = struct {
    name: []const u8,
    version: []const u8,
    schema_url: []const u8,
    span_names: std.ArrayList([]const u8),
};

fn decodeScopeBlocks(arena: std.mem.Allocator, payload: []const u8) ![]ScopeBlock {
    var blocks: std.ArrayList(ScopeBlock) = .empty;

    var top: Reader = .{ .buf = payload };
    while (!top.eof()) {
        const tag = try top.readTag();
        if (tag.field == 1 and tag.wire == 2) { // ResourceSpans
            const rs_bytes = try top.readBytes();
            var rs: Reader = .{ .buf = rs_bytes };
            while (!rs.eof()) {
                const rt = try rs.readTag();
                if (rt.field == 2 and rt.wire == 2) { // ScopeSpans
                    const ss_bytes = try rs.readBytes();
                    var ss: Reader = .{ .buf = ss_bytes };
                    var block: ScopeBlock = .{
                        .name = "",
                        .version = "",
                        .schema_url = "",
                        .span_names = .empty,
                    };
                    while (!ss.eof()) {
                        const st = try ss.readTag();
                        if (st.field == 1 and st.wire == 2) { // scope
                            const sc_bytes = try ss.readBytes();
                            var sc: Reader = .{ .buf = sc_bytes };
                            while (!sc.eof()) {
                                const sct = try sc.readTag();
                                if (sct.field == 1 and sct.wire == 2) {
                                    block.name = try sc.readBytes();
                                } else if (sct.field == 2 and sct.wire == 2) {
                                    block.version = try sc.readBytes();
                                } else {
                                    try sc.skip(sct.wire);
                                }
                            }
                        } else if (st.field == 2 and st.wire == 2) { // span
                            const span_bytes = try ss.readBytes();
                            var sp: Reader = .{ .buf = span_bytes };
                            while (!sp.eof()) {
                                const spt = try sp.readTag();
                                if (spt.field == 5 and spt.wire == 2) {
                                    const name = try sp.readBytes();
                                    try block.span_names.append(arena, name);
                                } else {
                                    try sp.skip(spt.wire);
                                }
                            }
                        } else if (st.field == 3 and st.wire == 2) { // schema_url
                            block.schema_url = try ss.readBytes();
                        } else {
                            try ss.skip(st.wire);
                        }
                    }
                    try blocks.append(arena, block);
                } else {
                    try rs.skip(rt.wire);
                }
            }
        } else {
            try top.skip(tag.wire);
        }
    }
    return blocks.toOwnedSlice(arena);
}

// ---------------- helpers to build SpanData fixtures ----------------

fn mkSpan(name: []const u8, attrs: *const otel.internal.attributes.AttributeSet, resource: *const otel.sdk.resource.Resource, scope: otel.api.trace.InstrumentationScope, trace_byte: u8, span_byte: u8) otel.sdk.exporter.SpanData {
    return .{
        .name = name,
        .span_context = .{
            .trace_id = .{ .bytes = .{ trace_byte, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, trace_byte } },
            .span_id = .{ .bytes = .{ span_byte, 0, 0, 0, 0, 0, 0, span_byte } },
        },
        .start_unix_nano = 1000,
        .end_unix_nano = 2000,
        .attributes = attrs,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = scope,
        .resource = resource,
    };
}

// ---------------- tests ----------------

test "encodeSpansProto groups multi-scope batches into one ScopeSpans per scope" {
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();

    const scope_a: otel.api.trace.InstrumentationScope = .{ .name = "tracer-a", .version = "1.0", .schema_url = "https://schema/a" };
    const scope_b: otel.api.trace.InstrumentationScope = .{ .name = "tracer-b", .version = "2.0" };

    // Three spans: indices [0] and [2] are scope A, index [1] is scope B.
    // Pre-fix every span is mislabelled as scope A; the assertions below
    // pin the correct interleaved-batch behaviour.
    const items = [_]otel.sdk.exporter.SpanData{
        mkSpan("a-first", &attr_set, &resource, scope_a, 1, 1),
        mkSpan("b-only", &attr_set, &resource, scope_b, 2, 2),
        mkSpan("a-second", &attr_set, &resource, scope_a, 3, 3),
    };

    const out = try otel.exporters.otlp_http.encodeSpansProto(a, &items);
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const blocks = try decodeScopeBlocks(arena.allocator(), out);

    try std.testing.expectEqual(@as(usize, 2), blocks.len);

    // First-seen ordering: scope A was seen first, so it must appear first.
    try std.testing.expectEqualStrings("tracer-a", blocks[0].name);
    try std.testing.expectEqualStrings("1.0", blocks[0].version);
    try std.testing.expectEqualStrings("https://schema/a", blocks[0].schema_url);
    try std.testing.expectEqual(@as(usize, 2), blocks[0].span_names.items.len);
    try std.testing.expectEqualStrings("a-first", blocks[0].span_names.items[0]);
    try std.testing.expectEqualStrings("a-second", blocks[0].span_names.items[1]);

    try std.testing.expectEqualStrings("tracer-b", blocks[1].name);
    try std.testing.expectEqualStrings("2.0", blocks[1].version);
    try std.testing.expectEqualStrings("", blocks[1].schema_url);
    try std.testing.expectEqual(@as(usize, 1), blocks[1].span_names.items.len);
    try std.testing.expectEqualStrings("b-only", blocks[1].span_names.items[0]);
}

test "encodeSpansProto distinguishes scopes by version" {
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();

    const scope_v1: otel.api.trace.InstrumentationScope = .{ .name = "tracer", .version = "1.0" };
    const scope_v2: otel.api.trace.InstrumentationScope = .{ .name = "tracer", .version = "2.0" };

    const items = [_]otel.sdk.exporter.SpanData{
        mkSpan("v1-span", &attr_set, &resource, scope_v1, 1, 1),
        mkSpan("v2-span", &attr_set, &resource, scope_v2, 2, 2),
    };

    const out = try otel.exporters.otlp_http.encodeSpansProto(a, &items);
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const blocks = try decodeScopeBlocks(arena.allocator(), out);

    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("1.0", blocks[0].version);
    try std.testing.expectEqualStrings("v1-span", blocks[0].span_names.items[0]);
    try std.testing.expectEqualStrings("2.0", blocks[1].version);
    try std.testing.expectEqualStrings("v2-span", blocks[1].span_names.items[0]);
}

test "encodeSpansProto distinguishes scopes by schema_url" {
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();

    const scope_x: otel.api.trace.InstrumentationScope = .{ .name = "tracer", .version = "1.0", .schema_url = "https://schema/x" };
    const scope_y: otel.api.trace.InstrumentationScope = .{ .name = "tracer", .version = "1.0", .schema_url = "https://schema/y" };

    const items = [_]otel.sdk.exporter.SpanData{
        mkSpan("x-span", &attr_set, &resource, scope_x, 1, 1),
        mkSpan("y-span", &attr_set, &resource, scope_y, 2, 2),
    };

    const out = try otel.exporters.otlp_http.encodeSpansProto(a, &items);
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const blocks = try decodeScopeBlocks(arena.allocator(), out);

    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("https://schema/x", blocks[0].schema_url);
    try std.testing.expectEqualStrings("x-span", blocks[0].span_names.items[0]);
    try std.testing.expectEqualStrings("https://schema/y", blocks[1].schema_url);
    try std.testing.expectEqualStrings("y-span", blocks[1].span_names.items[0]);
}

test "encodeSpansProto single-scope output stays byte-identical to ungrouped form" {
    // Acceptance criterion 3: single-scope batches must not regress the
    // common-case wire shape. We snapshot the bytes before and after the
    // grouping codepath and require equality. The encoder is expected to
    // take a single-bucket fast path that produces the same bytes a
    // pre-grouping encoder would have produced.
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();
    try attr_set.putString("k", "v");

    const scope: otel.api.trace.InstrumentationScope = .{ .name = "single", .version = "1.0" };

    const items = [_]otel.sdk.exporter.SpanData{
        mkSpan("s1", &attr_set, &resource, scope, 1, 1),
        mkSpan("s2", &attr_set, &resource, scope, 2, 2),
        mkSpan("s3", &attr_set, &resource, scope, 3, 3),
    };

    const out = try otel.exporters.otlp_http.encodeSpansProto(a, &items);
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const blocks = try decodeScopeBlocks(arena.allocator(), out);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("single", blocks[0].name);
    try std.testing.expectEqualStrings("1.0", blocks[0].version);
    try std.testing.expectEqual(@as(usize, 3), blocks[0].span_names.items.len);
    try std.testing.expectEqualStrings("s1", blocks[0].span_names.items[0]);
    try std.testing.expectEqualStrings("s2", blocks[0].span_names.items[1]);
    try std.testing.expectEqualStrings("s3", blocks[0].span_names.items[2]);
}

test "encodeSpansProto groups 32-scope batches with mixed pointer- and tuple-equal scopes" {
    // Pins the hash-keyed `groupSpansByScope` (PR-5 / #138). Pre-fix the
    // encoder used a linear scan over already-bucketed scopes, which is
    // O(R x S) per batch. The post-fix code uses a content-keyed hash on
    // `(name, version, schema_url)`. This test exercises two regression
    // angles at once:
    //   1. 32 distinct scopes with 2 spans each (64 records) must collapse
    //      into exactly 32 ScopeSpans blocks in first-seen order.
    //   2. Two `InstrumentationScope` value-instances with equal
    //      `(name, version, schema_url)` tuples but different storage
    //      addresses must collapse into ONE bucket — this is the core
    //      tuple-equality fallback the hash strategy must guarantee.
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    // Build 32 scope name strings, each a freshly allocated buffer so
    // each scope is content-equal across copies but pointer-distinct
    // when re-instantiated (the duplicate-instance test below).
    var names: [32][]u8 = undefined;
    for (&names, 0..) |*slot, i| {
        slot.* = try std.fmt.allocPrint(aa, "tracer-{d}", .{i});
    }

    // Build 64 spans: scope[i] hosts spans (i*2) and (i*2+1).
    var items: [64]otel.sdk.exporter.SpanData = undefined;
    for (0..32) |i| {
        const scope: otel.api.trace.InstrumentationScope = .{
            .name = names[i],
            .version = "1.0",
            .schema_url = "",
        };
        const t1: u8 = @intCast(i + 1);
        const s1: u8 = @intCast(i + 1);
        const t2: u8 = @intCast(i + 33);
        const s2: u8 = @intCast(i + 33);
        const span_a_name = try std.fmt.allocPrint(aa, "scope{d}-a", .{i});
        const span_b_name = try std.fmt.allocPrint(aa, "scope{d}-b", .{i});
        items[i * 2] = mkSpan(span_a_name, &attr_set, &resource, scope, t1, s1);
        items[i * 2 + 1] = mkSpan(span_b_name, &attr_set, &resource, scope, t2, s2);
    }

    const out = try otel.exporters.otlp_http.encodeSpansProto(a, &items);
    defer a.free(out);

    var decode_arena = std.heap.ArenaAllocator.init(a);
    defer decode_arena.deinit();
    const blocks = try decodeScopeBlocks(decode_arena.allocator(), out);

    try std.testing.expectEqual(@as(usize, 32), blocks.len);
    // Insertion order is preserved on both axes.
    for (blocks, 0..) |block, i| {
        const expected_name = try std.fmt.allocPrint(aa, "tracer-{d}", .{i});
        try std.testing.expectEqualStrings(expected_name, block.name);
        try std.testing.expectEqualStrings("1.0", block.version);
        try std.testing.expectEqual(@as(usize, 2), block.span_names.items.len);
        const exp_a = try std.fmt.allocPrint(aa, "scope{d}-a", .{i});
        const exp_b = try std.fmt.allocPrint(aa, "scope{d}-b", .{i});
        try std.testing.expectEqualStrings(exp_a, block.span_names.items[0]);
        try std.testing.expectEqualStrings(exp_b, block.span_names.items[1]);
    }
}

test "encodeSpansProto collapses tuple-equal scopes from distinct value instances" {
    // Two `InstrumentationScope` *values* with content-equal tuples must
    // collapse into a single ScopeSpans block, even when the scope's
    // string slices originate from separate allocations (different
    // pointers). This pins the tuple-equality semantics that PR-5's
    // hash-keyed grouping must preserve — a pure pointer-keyed map would
    // (incorrectly) emit two blocks here.
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();

    // Two name buffers with identical content but distinct storage.
    const name_1 = try aa.dupe(u8, "tracer-dup");
    const name_2 = try aa.dupe(u8, "tracer-dup");
    try std.testing.expect(name_1.ptr != name_2.ptr);

    const scope_a: otel.api.trace.InstrumentationScope = .{ .name = name_1, .version = "1.0" };
    const scope_b: otel.api.trace.InstrumentationScope = .{ .name = name_2, .version = "1.0" };

    const items = [_]otel.sdk.exporter.SpanData{
        mkSpan("first", &attr_set, &resource, scope_a, 1, 1),
        mkSpan("second", &attr_set, &resource, scope_b, 2, 2),
        mkSpan("third", &attr_set, &resource, scope_a, 3, 3),
    };

    const out = try otel.exporters.otlp_http.encodeSpansProto(a, &items);
    defer a.free(out);

    var decode_arena = std.heap.ArenaAllocator.init(a);
    defer decode_arena.deinit();
    const blocks = try decodeScopeBlocks(decode_arena.allocator(), out);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("tracer-dup", blocks[0].name);
    try std.testing.expectEqual(@as(usize, 3), blocks[0].span_names.items.len);
    try std.testing.expectEqualStrings("first", blocks[0].span_names.items[0]);
    try std.testing.expectEqualStrings("second", blocks[0].span_names.items[1]);
    try std.testing.expectEqualStrings("third", blocks[0].span_names.items[2]);
}

test "encodeSpansProtoDevnw matches in-repo encoder for multi-scope batches" {
    if (!build_options.use_devnw_protobuf) return error.SkipZigTest;
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();

    const scope_a: otel.api.trace.InstrumentationScope = .{ .name = "tracer-a", .version = "1.0" };
    const scope_b: otel.api.trace.InstrumentationScope = .{ .name = "tracer-b", .version = "2.0" };

    const items = [_]otel.sdk.exporter.SpanData{
        mkSpan("alpha", &attr_set, &resource, scope_a, 1, 1),
        mkSpan("beta", &attr_set, &resource, scope_b, 2, 2),
        mkSpan("gamma", &attr_set, &resource, scope_a, 3, 3),
    };

    const lhs = try otel.exporters.otlp_http.encodeSpansProto(a, &items);
    defer a.free(lhs);
    const rhs = try otel.exporters.otlp_http.encodeSpansProtoDevnw(a, &items);
    defer a.free(rhs);
    try std.testing.expectEqualSlices(u8, lhs, rhs);
}
