// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Shared RFC 3986 percent-codec used by the W3C-baggage and Jaeger
// (`uberctx-*`) propagators. Both encode baggage values against the same
// unreserved set and decode with the same `%XX` grammar; this module is
// the single source of truth so the two propagators can't drift.
//
// `percentDecode` reports malformed input as the codec-neutral
// `error.InvalidPercentEncoding`; each call site maps it to its own
// module-specific error (baggage → InvalidBaggageValue; Jaeger drops the
// entry) so observable behaviour is unchanged from the pre-extraction
// inline copies. QN-NEW-10.

const std = @import("std");

/// Append the RFC 3986 percent-encoding of `value` to `out`. Bytes in the
/// unreserved set pass through verbatim; everything else becomes `%XX`
/// (uppercase hex).
pub fn percentEncode(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |c| {
        if (isUnreserved(c)) {
            try out.append(allocator, c);
        } else {
            try out.append(allocator, '%');
            try out.append(allocator, hexUpper(c >> 4));
            try out.append(allocator, hexUpper(c & 0x0f));
        }
    }
}

/// Append the percent-decoding of `value` to `out`. A truncated or
/// non-hex `%` escape yields `error.InvalidPercentEncoding`; callers map
/// it onto their module-local error.
pub fn percentDecode(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    var i: usize = 0;
    while (i < value.len) {
        const c = value[i];
        if (c == '%') {
            if (i + 2 >= value.len) return error.InvalidPercentEncoding;
            const hi = nibble(value[i + 1]) catch return error.InvalidPercentEncoding;
            const lo = nibble(value[i + 2]) catch return error.InvalidPercentEncoding;
            try out.append(allocator, (hi << 4) | lo);
            i += 3;
        } else {
            try out.append(allocator, c);
            i += 1;
        }
    }
}

/// RFC 3986 unreserved set: ALPHA / DIGIT / "-" / "." / "_" / "~".
pub fn isUnreserved(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

/// Map a 4-bit nibble to an uppercase hex digit.
pub fn hexUpper(n: u8) u8 {
    const alphabet = "0123456789ABCDEF";
    return alphabet[n & 0x0f];
}

fn nibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHex,
    };
}
