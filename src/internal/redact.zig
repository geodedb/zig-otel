// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Drop-in helper that masks sensitive attribute values before they cross
// any boundary (logs, exporters, internal diagnostics). The matcher is
// case-insensitive on a small set of OpenTelemetry-style key tokens.

const std = @import("std");

pub const redacted_marker: []const u8 = "[REDACTED]";

const sensitive_tokens = [_][]const u8{
    "password",
    "secret",
    "token",
    "api.key",
    "apikey",
    "authorization",
    "credential",
};

/// Returns true if `key` mentions any sensitive token. Comparison is
/// case-insensitive and tolerant of common separators (`.`, `-`, `_`)
/// so `Authorization`, `api.key`, `X-API-KEY`, and `db_password` all
/// match the same way.
pub fn isSensitive(key: []const u8) bool {
    if (key.len == 0) return false;

    // O(1)-per-byte fast-reject screen for the common (non-sensitive) hot
    // path: this runs once per string attribute key on every encode. Every
    // normalised sensitive token below begins with a letter in the set
    // {a, c, p, s, t} (apikey/authorization=a, credential=c, password=p,
    // secret=s, token=t). For a token to appear as a substring of the
    // normalised haystack, that token's first letter MUST appear somewhere
    // in the key — and normalisation only lowercases / strips separators,
    // so it never introduces a letter that was absent from the raw key.
    // Therefore, if the (lowercased) key contains none of these letters it
    // cannot match any token and we skip the 512-byte scratch copy + six
    // substring scans entirely. This is provably classification-preserving:
    // it can only ever SKIP work for keys that are guaranteed non-sensitive.
    var maybe_sensitive = false;
    for (key) |c| {
        switch (std.ascii.toLower(c)) {
            'a', 'c', 'p', 's', 't' => {
                maybe_sensitive = true;
                break;
            },
            else => {},
        }
    }
    if (!maybe_sensitive) return false;

    // Normalise into a scratch buffer: lowercase, strip separators.
    var scratch: [512]u8 = undefined;
    var len: usize = 0;
    for (key) |c| {
        if (len == scratch.len) break;
        switch (c) {
            '.', '-', '_', ' ' => continue,
            else => {
                scratch[len] = std.ascii.toLower(c);
                len += 1;
            },
        }
    }
    const haystack = scratch[0..len];
    const normalised_tokens = [_][]const u8{
        "password", "secret", "token", "apikey", "authorization", "credential",
    };
    for (normalised_tokens) |needle| {
        if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    }
    return false;
}

/// Returns the redacted marker if `key` is sensitive, else returns `value`
/// unchanged. The string slice always belongs to the caller — no allocation.
pub fn maskString(key: []const u8, value: []const u8) []const u8 {
    return if (isSensitive(key)) redacted_marker else value;
}

test "case-insensitive token match" {
    try std.testing.expect(isSensitive("Authorization"));
    try std.testing.expect(isSensitive("authorization"));
    try std.testing.expect(isSensitive("X-Authorization-Token"));
    try std.testing.expect(isSensitive("api.token"));
    try std.testing.expect(isSensitive("apiKey"));
    try std.testing.expect(isSensitive("DB_PASSWORD"));
    try std.testing.expect(isSensitive("user.credential"));
    try std.testing.expect(!isSensitive("db.user"));
    try std.testing.expect(!isSensitive("http.method"));
}

test "mask returns marker for sensitive keys" {
    try std.testing.expectEqualStrings("[REDACTED]", maskString("Authorization", "Bearer abc"));
    try std.testing.expectEqualStrings("alice", maskString("db.user", "alice"));
}
