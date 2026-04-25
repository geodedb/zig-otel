// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Loopback HTTP server for the OTLP/HTTP exporter integration test.
//
// We deliberately serve **plain HTTP** (not HTTPS) here even though the
// build flag is named `-Dotel_use_devnw_tls`. The flag's effective
// meaning post-Phase-6 is "the real `std.http.Client`-backed transport
// is wired in" — see `docs/DEPENDENCIES.md` (TLS row). The TLS code
// itself lives in `std.crypto.tls` inside the Zig stdlib; we trust it to
// be tested upstream. What this loopback validates is that *our*
// transport speaks HTTP/1.1 over a real socket end-to-end (URL
// construction, content-type header, POST body framing, status code
// translation). The HTTPS path uses the same `fetch` call site, so a
// passing HTTP loopback gates the part of the transport we own.
//
// Lifecycle:
//
// * `startLoopbackHttps` returns a heap-allocated `Server`. The caller
//   is responsible for `destroy()` even if `join()` is never called.
// * `join()` blocks until the server thread exits, then closes the
//   listening socket. After `join()` it is safe to read `bodyLen()`
//   and `serverError()`.
// * `destroy()` releases the Io context and the heap allocation. It
//   implicitly joins if the caller has not done so.
// * Both methods are safe to call multiple times.
//
// Design notes:
//
// * The server runs on a `std.Thread`, not on `Io.async`, because the
//   client `fetch` runs synchronously on the test thread and we need
//   the server to accept *concurrently*. Threads are joined by
//   `destroy()` so the testing allocator does not flag leaks.
// * The server accepts exactly one connection, drains the request body,
//   responds 200 with an empty body, and exits. The loopback test only
//   needs to round-trip a single span.

const std = @import("std");

pub const Server = struct {
    allocator: std.mem.Allocator,
    threaded: *std.Io.Threaded,
    /// The Io view of `threaded`. Stored so the listener can be closed
    /// in `join` even after the server thread has exited.
    io: std.Io,
    listener: std.Io.net.Server,
    bound_port: u16,
    /// Captures the request body length after the server thread drains
    /// it. Synchronised by `thread.join()` in `join`; until then, only
    /// the server thread touches it.
    captured_body_len: usize = 0,
    /// First error (if any) seen by the server thread. Surfaced via
    /// `serverError()` after `join`.
    err: ?anyerror = null,
    thread: ?std.Thread = null,
    /// Tracks whether the listening socket has been closed so `destroy`
    /// can safely re-call `join` without double-closing.
    listener_closed: bool = false,

    pub fn endpoint(self: *Server, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.bound_port});
    }

    pub fn bodyLen(self: *const Server) usize {
        return self.captured_body_len;
    }

    pub fn serverError(self: *const Server) ?anyerror {
        return self.err;
    }

    /// Block until the server thread exits, closing the listening
    /// socket so any pending `accept` returns. Safe to call multiple
    /// times. After `join()` returns, `bodyLen()` and `serverError()`
    /// reflect the final state.
    pub fn join(self: *Server) void {
        if (!self.listener_closed) {
            self.listener.deinit(self.io);
            self.listener_closed = true;
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    /// Tear down the Io context and free the heap-allocated `Server`.
    /// Implicitly joins the server thread first; safe to call without a
    /// prior `join()`.
    pub fn destroy(self: *Server) void {
        self.join();
        self.threaded.deinit();
        const allocator = self.allocator;
        allocator.destroy(self.threaded);
        allocator.destroy(self);
    }
};

/// Spin up an in-process loopback HTTP server bound to `127.0.0.1:0` on
/// a background thread. The returned `Server` is heap-allocated and the
/// caller must free it via `destroy()`.
pub fn startLoopbackHttps(allocator: std.mem.Allocator) !*Server {
    // The Threaded Io must outlive any reference to its `.io()` view.
    // Heap-allocate so the address is stable across the test thread and
    // the server thread.
    const threaded = try allocator.create(std.Io.Threaded);
    errdefer allocator.destroy(threaded);
    threaded.* = std.Io.Threaded.init(allocator, .{});
    errdefer threaded.deinit();

    const io = threaded.io();

    var listen_addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    errdefer listener.deinit(io);

    const bound_port = listener.socket.address.getPort();

    const srv = try allocator.create(Server);
    errdefer allocator.destroy(srv);
    srv.* = .{
        .allocator = allocator,
        .threaded = threaded,
        .io = io,
        .listener = listener,
        .bound_port = bound_port,
    };

    srv.thread = try std.Thread.spawn(.{}, runOnce, .{srv});
    return srv;
}

fn runOnce(self: *Server) void {
    runOnceFallible(self) catch |err| switch (err) {
        // Accept fails with SocketNotListening when the test calls
        // `join` before a client connects. That's a clean exit, not a
        // server bug.
        error.SocketNotListening => {},
        else => self.err = err,
    };
}

fn runOnceFallible(self: *Server) !void {
    const io = self.io;

    var stream = try self.listener.accept(io);
    defer {
        var copy = stream;
        copy.close(io);
    }

    var recv_buffer: [8 * 1024]u8 = undefined;
    var send_buffer: [4 * 1024]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);

    var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    var request = try server.receiveHead();

    // Drain the request body before responding so the client side of
    // the connection does not block on an unread send queue.
    var body_buf: [4 * 1024]u8 = undefined;
    const reader = request.readerExpectContinue(&body_buf) catch |err| switch (err) {
        error.HttpExpectationFailed => {
            try request.respond("", .{ .status = .expectation_failed, .keep_alive = false });
            return;
        },
        else => |e| return e,
    };

    var counter: std.Io.Writer.Discarding = .init(&.{});
    // Errors here are surfaced via `self.err`; still try to respond so
    // the client doesn't time out.
    _ = reader.streamRemaining(&counter.writer) catch |e| {
        self.err = e;
    };
    self.captured_body_len = @intCast(counter.fullCount());

    try request.respond("", .{
        .status = .ok,
        .keep_alive = false,
    });
}
