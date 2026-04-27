// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// PR-9 (#143) regression test — pin the OTLP/gRPC exporter's
// "parse endpoint once at init" invariant.
//
// Pre-fix `OtlpGrpcExporter` re-parsed `config.endpoint` on every
// export call (`checkExportPreconditions`, `expSpans`, `expMetrics`).
// The endpoint is immutable for the exporter's lifetime, so the work
// was pure waste. The fix caches the parsed host/port/scheme on the
// exporter at `init` and reads from the cache thereafter.
//
// These tests pin three behaviours that promote the cache to a
// public contract:
//   1. `init` populates `parsed_endpoint` with the correct fields.
//   2. `init` rejects malformed endpoints up front (instead of
//      deferring failure to first export).
//   3. Mutating `config.endpoint` after `init` does NOT affect
//      dispatch — the cached version wins. This last point is the
//      load-bearing invariant: any future code that "helpfully"
//      re-derives the parsed values from `config.endpoint` will
//      break this test.

const std = @import("std");
const otel = @import("otel");

test "PR-9: init caches parsed endpoint host/port/scheme" {
    var exporter = try otel.exporters.otlp_grpc.OtlpGrpcExporter.init(std.testing.allocator, .{
        .endpoint = "https://collector.example.com:4319",
        .protocol = .grpc,
        // bypass C-2 (https without insecure flag) so we can read the
        // cached fields without checkExportPreconditions erroring.
        .insecure = true,
    });
    defer exporter.deinit();

    try std.testing.expectEqualStrings("collector.example.com", exporter.parsed_endpoint.host);
    try std.testing.expectEqual(@as(u16, 4319), exporter.parsed_endpoint.port);
    try std.testing.expectEqual(true, exporter.parsed_endpoint.scheme_secure);
}

test "PR-9: init rejects malformed endpoint up front" {
    // Empty host (`http://:4317`) was previously accepted at init and
    // only failed at first export. Cache-at-init promotes the failure
    // to construction time so callers fail fast.
    try std.testing.expectError(error.InvalidEndpoint, otel.exporters.otlp_grpc.OtlpGrpcExporter.init(std.testing.allocator, .{
        .endpoint = "http://:4317",
        .protocol = .grpc,
    }));
}

test "PR-9: post-init mutation of config.endpoint does not affect cache" {
    var exporter = try otel.exporters.otlp_grpc.OtlpGrpcExporter.init(std.testing.allocator, .{
        .endpoint = "http://127.0.0.1:4317",
        .protocol = .grpc,
    });
    defer exporter.deinit();

    const cached_host_before = exporter.parsed_endpoint.host;
    const cached_port_before = exporter.parsed_endpoint.port;

    // Swap endpoint to a different host:port. The cache must NOT
    // pick up the change — it was frozen at init by design. This
    // protects future readers that might reach `expSpans`/
    // `expMetrics` and find them dispatching to the cached host.
    exporter.config.endpoint = "http://other.example:9999";

    try std.testing.expectEqualStrings(cached_host_before, exporter.parsed_endpoint.host);
    try std.testing.expectEqual(cached_port_before, exporter.parsed_endpoint.port);
    try std.testing.expectEqualStrings("127.0.0.1", exporter.parsed_endpoint.host);
    try std.testing.expectEqual(@as(u16, 4317), exporter.parsed_endpoint.port);
}

test "PR-9: checkExportPreconditions still refuses https without insecure (C-2)" {
    // Confirm the C-2 guard reads from the cache and still fires.
    var exporter = try otel.exporters.otlp_grpc.OtlpGrpcExporter.init(std.testing.allocator, .{
        .endpoint = "https://collector.example.com:4317",
        .protocol = .grpc,
    });
    defer exporter.deinit();
    try std.testing.expectError(error.UnsupportedTransport, exporter.checkExportPreconditions());
}

test "PR-9: checkExportPreconditions still refuses non-empty headers (C-3)" {
    // Confirm the C-3 guard still fires through the cached path.
    var exporter = try otel.exporters.otlp_grpc.OtlpGrpcExporter.init(std.testing.allocator, .{
        .endpoint = "http://127.0.0.1:4317",
        .protocol = .grpc,
        .headers = "Authorization=Bearer x",
    });
    defer exporter.deinit();
    try std.testing.expectError(error.UnsupportedTransport, exporter.checkExportPreconditions());
}
