// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");

test "baggage rejects empty key" {
    var b = otel.api.baggage.Baggage.init(std.testing.allocator);
    defer b.deinit();
    try std.testing.expectError(error.InvalidBaggageKey, b.put("", "v", null));
}

test "baggage rejects bad value separators" {
    var b = otel.api.baggage.Baggage.init(std.testing.allocator);
    defer b.deinit();
    try std.testing.expectError(error.InvalidBaggageValue, b.put("k", "a,b", null));
}

test "baggage put then get round trips" {
    var b = otel.api.baggage.Baggage.init(std.testing.allocator);
    defer b.deinit();
    try b.put("user.id", "u-7", null);
    try std.testing.expectEqualStrings("u-7", b.get("user.id").?);
}

test "baggage propagator round-trip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var bag = otel.api.baggage.Baggage.init(std.testing.allocator);
    defer bag.deinit();
    try bag.put("k1", "v1", null);
    try bag.put("k2", "value with spaces", null);

    var map = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer map.deinit();
    var mc: otel.propagation.trace_context.MapCarrier = .{ .map = &map };
    try otel.propagation.baggage.inject(arena.allocator(), mc.carrier(), &bag);

    var decoded = (try otel.propagation.baggage.extract(std.testing.allocator, mc.carrier())).?;
    defer decoded.deinit();
    try std.testing.expectEqualStrings("v1", decoded.get("k1").?);
    try std.testing.expectEqualStrings("value with spaces", decoded.get("k2").?);
}

// QN-NEW-10 — shared percent-codec round-trip. Pins the extracted
// `src/propagation/percent.zig` so the W3C-baggage and Jaeger propagators
// keep encoding/decoding identically.
test "percent codec round-trips reserved, %, =, and non-ASCII bytes" {
    const percent = otel.propagation.percent;
    const original = "a b%c=d;é"; // space, %, =, ; and a non-ASCII byte.

    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(std.testing.allocator);
    try percent.percentEncode(std.testing.allocator, &encoded, original);

    // Encoding must escape every reserved byte (no raw space/%/=/; survive).
    for (encoded.items) |c| {
        try std.testing.expect(c == '%' or percent.isUnreserved(c));
    }

    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(std.testing.allocator);
    try percent.percentDecode(std.testing.allocator, &decoded, encoded.items);
    try std.testing.expectEqualStrings(original, decoded.items);
}

test "percent decode of a known-encoded string matches expected bytes" {
    const percent = otel.propagation.percent;
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(std.testing.allocator);
    // "%20" -> space, "%25" -> '%', "%3D" -> '='.
    try percent.percentDecode(std.testing.allocator, &decoded, "x%20y%25z%3Dw");
    try std.testing.expectEqualStrings("x y%z=w", decoded.items);
}

test "percent decode rejects a truncated escape" {
    const percent = otel.propagation.percent;
    var decoded: std.ArrayList(u8) = .empty;
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.InvalidPercentEncoding,
        percent.percentDecode(std.testing.allocator, &decoded, "abc%2"),
    );
}

// PR-6 / #139 — Baggage.put dupe-before-dedup regression.
//
// Pre-fix, `put` performed `arena.dupe(key)` + `arena.dupe(value)` (and
// metadata) BEFORE searching for an existing entry. On the hit path the
// duped key bytes became permanent arena waste; N consecutive puts of the
// same key grew arena bytes proportional to N × (key_len + value_len + meta_len)
// instead of N × (value_len + meta_len).
//
// This test pins two complementary invariants:
//   1. Pointer stability — after the first put establishes the entry, the
//      stored `key.ptr` must remain identical across subsequent puts of the
//      same key (the original arena bytes are reused, never re-duped).
//   2. Bounded arena growth — `queryCapacity()` after N hit-path puts grows
//      by less than N × (key_len + value_len) i.e. the per-iteration cost
//      drops the key contribution.
test "Baggage.put hit-path does not re-dupe the key (PR-6 / #139)" {
    var bag = otel.api.baggage.Baggage.init(std.testing.allocator);
    defer bag.deinit();

    // Long key + 1-byte value so the pre-fix waste dominates per iteration.
    const key = "a-deliberately-long-baggage-key-so-the-leak-is-obvious-58B"; // gitleaks:allow -- baggage key test fixture, not a credential
    const value = "v";

    try bag.put(key, value, null);
    const original_key_ptr = bag.entries.items[0].key.ptr;
    const baseline_capacity = bag.arena.queryCapacity();

    const iterations: usize = 1024;
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        try bag.put(key, value, null);
    }

    // Invariant 1 — key pointer stability across the hit path.
    try std.testing.expectEqual(original_key_ptr, bag.entries.items[0].key.ptr);

    // Invariant 2 — bounded growth. Pre-fix, each hit-path put leaks
    // key.len (~58 B) + value.len (1 B) + alignment, so 1024 iterations
    // grows the arena by ~64 KiB. Post-fix only value.len (~1-8 B with
    // alignment) is duped per iteration, so 1024 iterations grows by at
    // most ~16 KiB (and typically much less because the arena's chunk size
    // already absorbs many small dupes into one bump). Use a bound that
    // catches the pre-fix leak (≥ 1024 × 58 B = 59 392 B of strict key
    // bytes) but is loose enough to tolerate arena chunk over-allocation.
    //
    // Bound choice: iterations × 32 B = 32 768 B. Pre-fix grows by
    // ~iterations × ~64 B ≥ 65 536 B (well over the bound). Post-fix grows
    // by < iterations × 8 B ≪ 32 768 B.
    const post_capacity = bag.arena.queryCapacity();
    const grew_by = post_capacity - baseline_capacity;
    const value_only_bound = iterations * 32;
    try std.testing.expect(grew_by < value_only_bound);

    // Sanity — the entry still reflects the most recent put + only one entry.
    try std.testing.expectEqualStrings(value, bag.get(key).?);
    try std.testing.expectEqual(@as(usize, 1), bag.count());
}
