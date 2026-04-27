// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Header validation and parsing for the OTLP/HTTP exporter.
//
// Split out of `src/exporters/otlp_http.zig` as part of OTEL-Q-001
// (gitlab #149). The parsing rules are unchanged; this module only
// hosts the helpers so the facade does not have to bundle them.

const std = @import("std");

pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

/// Maximum permitted header name length per RFC 7230 (de-facto sanity
/// limit; the spec doesn't fix one). Anything longer is almost certainly
/// an injection attempt or a misconfigured upstream.
pub const max_header_name_len: usize = 256;

/// Maximum permitted header value length. 4 KiB is the upper bound most
/// HTTP servers accept before a 431 response.
pub const max_header_value_len: usize = 4096;

/// RFC 7230 §3.2.6 token character set.
fn isTokenByte(c: u8) bool {
    // Token = 1*tchar; tchar = "!" / "#" / "$" / "%" / "&" / "'" / "*"
    //       / "+" / "-" / "." / "^" / "_" / "`" / "|" / "~" / DIGIT / ALPHA
    return switch (c) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        '0'...'9', 'A'...'Z', 'a'...'z' => true,
        else => false,
    };
}

pub fn isValidHeaderName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_header_name_len) return false;
    for (name) |c| if (!isTokenByte(c)) return false;
    return true;
}

pub fn isValidHeaderValue(value: []const u8) bool {
    if (value.len > max_header_value_len) return false;
    // RFC 7230 §3.2: VCHAR / SP / HTAB / obs-text. Reject any control
    // byte except HT (0x09) — that catches CR/LF (response splitting),
    // NUL (smuggling), and DEL (0x7F).
    for (value) |c| {
        if (c == '\t') continue;
        if (c < 0x20) return false;
        if (c == 0x7F) return false;
    }
    return true;
}

/// Parse a comma-separated `name=value` header string (the OTel
/// `OTEL_EXPORTER_OTLP_HEADERS` shape) into `HeaderEntry` slots in
/// `out_buf`. Returns the populated prefix.
///
/// Rejects:
///   - Header names that aren't RFC 7230 §3.2.6 tokens
///   - Header values containing control bytes (CR, LF, NUL, DEL, ...)
///   - Names > 256 bytes or values > 4096 bytes
///   - User-supplied `content-type` (which the exporter sets canonically;
///     forwarding a duplicate would either confuse the collector or let
///     a caller override the OTLP wire format)
pub fn parseHeaderString(headers: []const u8, out_buf: []HeaderEntry) ![]HeaderEntry {
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, headers, ',');
    while (it.next()) |raw_pair| {
        const pair = std.mem.trim(u8, raw_pair, " \t");
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse return error.InvalidHeader;
        const name = std.mem.trim(u8, pair[0..eq], " \t");
        const value = std.mem.trim(u8, pair[eq + 1 ..], " \t");

        if (!isValidHeaderName(name)) return error.InvalidHeader;
        if (!isValidHeaderValue(value)) return error.InvalidHeader;

        // M-8: drop any user-supplied content-type — the exporter sets
        // this itself based on `OtlpConfig.protocol`, so a user override
        // would either duplicate the header or silently misrepresent the
        // wire format. We drop rather than error to keep deployment
        // configs portable across SDKs that handle this differently.
        if (std.ascii.eqlIgnoreCase(name, "content-type")) continue;

        if (count >= out_buf.len) return error.HeaderListTooLarge;
        out_buf[count] = .{ .name = name, .value = value };
        count += 1;
    }
    return out_buf[0..count];
}
