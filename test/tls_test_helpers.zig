// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Loopback HTTPS test helpers for the OTLP/HTTP exporter integration test.
//
// Status: SCAFFOLD ONLY.
//
// Phase 6 of the DevNW dependency integration plan is BLOCKED on the real
// HTTPS transport (Task 6.3) because the DevNW `tls` package is QUIC-first
// (RFC 9001) and provides no TLS-over-TCP client API — only the message
// parsing primitives in `tls13_full`. Driving HTTPS through it requires
// implementing the full TLS 1.3 record layer over a TCP socket, which is
// out of scope for this phase. See `docs/DEPENDENCIES.md` (TLS row) for
// the full status.
//
// This file deliberately exposes an `Server` shape close to what the real
// loopback would look like, so that when the transport lands the helper
// can be filled in without reshaping the test. The current `start` returns
// `error.LoopbackHttpsNotImplemented` so the loopback test can `try` it,
// catch the sentinel, and skip cleanly.

const std = @import("std");

pub const Error = error{
    LoopbackHttpsNotImplemented,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    bound_port: u16 = 0,
    body_buf: std.ArrayListUnmanaged(u8) = .empty,
    // The real implementation will own a TCP listener (and an Io context
    // to drive it on Zig 0.16). Both are deliberately omitted from this
    // scaffold so the type compiles without picking an `Io` strategy
    // before the transport's socket model is decided.

    pub fn endpoint(self: *Server, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "https://127.0.0.1:{d}", .{self.bound_port});
    }

    pub fn bodyLen(self: *const Server) usize {
        return self.body_buf.items.len;
    }

    pub fn shutdown(self: *Server) void {
        self.body_buf.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Spin up an in-process loopback HTTPS server bound to `127.0.0.1:0`.
///
/// Returns `Error.LoopbackHttpsNotImplemented` until Task 6.3 lands a real
/// TLS-over-TCP transport in `src/exporters/otlp_http.zig`. The test
/// caller is expected to translate that sentinel to `error.SkipZigTest`.
pub fn startLoopbackHttps(allocator: std.mem.Allocator) Error!Server {
    _ = allocator;
    return Error.LoopbackHttpsNotImplemented;
}
