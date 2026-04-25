// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");

test "redaction marker is exact" {
    try std.testing.expectEqualStrings("[REDACTED]", otel.internal.redact.maskString("Authorization", "Bearer x"));
}

test "redaction passes through innocuous keys" {
    try std.testing.expectEqualStrings("alice", otel.internal.redact.maskString("db.user", "alice"));
}

test "case-insensitive sensitive token detection" {
    try std.testing.expect(otel.internal.redact.isSensitive("AUTHORIZATION"));
    try std.testing.expect(otel.internal.redact.isSensitive("X-API-KEY"));
    try std.testing.expect(otel.internal.redact.isSensitive("Cookie-Authorization-Header"));
    try std.testing.expect(!otel.internal.redact.isSensitive("user.name"));
}

test "OTLP exporter rejects HTTP scheme outside http(s)" {
    try std.testing.expectError(error.InvalidEndpoint, otel.exporters.otlp_http.OtlpHttpExporter.init(std.testing.allocator, .{ .endpoint = "ftp://x" }));
}

test "attribute set caps string values" {
    var as = otel.internal.attributes.AttributeSet.init(std.testing.allocator);
    defer as.deinit();
    var huge: [otel.internal.attributes.max_string_value_bytes + 100]u8 = undefined;
    @memset(huge[0..], 'x');
    try as.putString("k", huge[0..]);
    try std.testing.expectEqual(@as(usize, otel.internal.attributes.max_string_value_bytes), as.getString("k").?.len);
}
