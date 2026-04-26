// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Multi-shot loopback HTTP discard server for the level-6 integration
// bench. Adapted from the single-shot variant in
// test/tls_test_helpers.zig.
//
// Lifecycle:
//
// * `start(allocator)` returns a heap-allocated `LoopbackServer` bound
//   to 127.0.0.1:0 (random ephemeral port) with a background thread
//   already accepting connections.
// * `endpoint(buf)` formats the bound address as
//   "http://127.0.0.1:<port>" so callers can hand it to OtlpConfig.
// * `stop()` signals the server thread to exit, sends a sentinel
//   HTTP request to wake any parked `accept()`, joins the thread,
//   then closes the listening socket and frees all owned resources.
//
// Cancellation:
//
// Zig 0.16's std.Io.net does not expose a `Server.shutdown()` API;
// `Server.deinit()` calls `posix.close()` on the listening fd, which
// causes a concurrent `accept()` to return EBADF — and
// `netAcceptPosix` maps EBADF to `errnoBug` (debug-mode panic),
// not to a recoverable error. So instead of relying on
// deinit-cancellation, we use a self-connect sentinel: `stop()` sets
// `shutdown_requested = true` and then issues a single HTTP fetch to
// our own port. The server thread wakes up from `accept()`,
// processes the sentinel request normally, loops back, observes the
// flag, and returns. `listener.deinit()` runs after the join, so no
// concurrent close-on-accept ever happens.
//
// Per-connection behaviour: receive HTTP/1.1 head, drain request body
// to a discarding writer, respond 200 OK with Content-Length: 0,
// keep-alive=false. The accept loop continues until `shutdown_requested`
// is set, so a single LoopbackServer handles all spans across all
// iterations of the bench.
//
// `stop()` is NOT thread-safe — call it once from the producer thread.
// Calling it twice is undefined behaviour (the second call would touch
// freed memory).

const std = @import("std");

pub const LoopbackServer = struct {
    allocator: std.mem.Allocator,
    /// Heap-allocated so the address survives the producer thread
    /// returning from `start()` while the server thread holds onto it.
    threaded: *std.Io.Threaded,
    /// `threaded.io()` cached so the server thread can close the
    /// listener even after the test thread has dropped its view.
    io: std.Io,
    listener: std.Io.net.Server,
    bound_port: u16,
    /// Set by `stop()` to ask the accept loop to exit on its next
    /// iteration. Checked at two points: top of the loop, and
    /// immediately after `accept()` returns (so the sentinel
    /// connection from `wake()` is observed cleanly).
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Incremented at the tail of every successful response. Read by
    /// tests to confirm multi-shot accept actually fired. Includes the
    /// sentinel wake-up request, so `requestCount()` reflects the
    /// total connections handled, not just user requests.
    request_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// First server-thread error, if any. Surfaced via `lastError()`.
    /// CONTRACT: only read after `stop()` has joined the server thread —
    /// the field is mutated unguarded by `runMulti` and reading it
    /// concurrently is a data race. The post-join read is safe because
    /// `Thread.join` is a happens-before edge.
    err: ?anyerror = null,
    thread: ?std.Thread = null,

    pub fn endpoint(self: *LoopbackServer, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.bound_port});
    }

    pub fn requestCount(self: *const LoopbackServer) u32 {
        return self.request_count.load(.acquire);
    }

    /// Only safe to call after `stop()` has joined the server thread.
    /// See `err` field doc for the cross-thread contract.
    pub fn lastError(self: *const LoopbackServer) ?anyerror {
        return self.err;
    }

    /// Tear the server down: signal shutdown, wake the parked accept,
    /// join the thread, close the listener, free the heap allocation.
    /// NOT thread-safe; call once from the producer thread.
    pub fn stop(self: *LoopbackServer) void {
        self.shutdown_requested.store(true, .release);
        wake(self);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.listener.deinit(self.io);
        self.threaded.deinit();
        const allocator = self.allocator;
        allocator.destroy(self.threaded);
        allocator.destroy(self);
    }
};

/// Spin up an in-process loopback HTTP discard server bound to
/// `127.0.0.1:0` on a background thread. Caller frees via `stop()`.
pub fn start(allocator: std.mem.Allocator) !*LoopbackServer {
    const threaded = try allocator.create(std.Io.Threaded);
    errdefer allocator.destroy(threaded);
    threaded.* = std.Io.Threaded.init(allocator, .{});
    errdefer threaded.deinit();

    const io = threaded.io();

    var listen_addr: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var listener = try listen_addr.listen(io, .{ .reuse_address = true });
    errdefer listener.deinit(io);

    const bound_port = listener.socket.address.getPort();

    const srv = try allocator.create(LoopbackServer);
    errdefer allocator.destroy(srv);
    srv.* = .{
        .allocator = allocator,
        .threaded = threaded,
        .io = io,
        .listener = listener,
        .bound_port = bound_port,
    };

    srv.thread = try std.Thread.spawn(.{}, runMulti, .{srv});
    return srv;
}

fn runMulti(self: *LoopbackServer) void {
    while (true) {
        if (self.shutdown_requested.load(.acquire)) return;
        var stream = self.listener.accept(self.io) catch |err| {
            if (self.err == null) self.err = err;
            return;
        };
        defer stream.close(self.io);
        // Always handle the request to completion, even if shutdown
        // was signaled between `accept()` returning and now. Closing
        // the stream mid-handshake leaves the wake-up client (or any
        // in-flight real client) blocked forever waiting for the HTTP
        // response head — `std.http.Client.fetch` does not surface
        // peer-close on the head read as an error in Zig 0.16.
        // Cancellation happens at the top of the loop instead.
        handleOne(self, &stream) catch |err| {
            if (self.err == null) self.err = err;
            // Continue accepting; one bad request shouldn't kill the
            // server while the bench is still running.
        };
        _ = self.request_count.fetchAdd(1, .acq_rel);
    }
}

fn handleOne(self: *LoopbackServer, stream: *std.Io.net.Stream) !void {
    const io = self.io;
    var recv_buffer: [8 * 1024]u8 = undefined;
    var send_buffer: [4 * 1024]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);

    var server: std.http.Server = .init(&connection_reader.interface, &connection_writer.interface);
    var request = try server.receiveHead();

    var body_buf: [4 * 1024]u8 = undefined;
    const reader = request.readerExpectContinue(&body_buf) catch |err| switch (err) {
        error.HttpExpectationFailed => {
            try request.respond("", .{ .status = .expectation_failed, .keep_alive = false });
            return;
        },
        else => |e| return e,
    };

    var counter: std.Io.Writer.Discarding = .init(&.{});
    _ = reader.streamRemaining(&counter.writer) catch {};

    try request.respond("", .{
        .status = .ok,
        .keep_alive = false,
    });
}

/// Wake the parked `accept()` by opening a raw TCP connection to
/// our own port and immediately closing it. Linux-only — that
/// matches the bench's required platform per the audit (`benchmarks
/// /framework.zig` already restricts RSS reading to Linux).
///
/// Uses raw `std.os.linux` syscalls instead of `std.http.Client.fetch`
/// because fetch blocks on the HTTP response head read, which races
/// with the server thread's shutdown-flag check: if the server
/// already exited at its loop top before our fetch issues, no one
/// will ever respond and fetch deadlocks. A bare `connect` returns
/// as soon as the kernel finishes the 3-way handshake (microseconds
/// on loopback, or `ECONNREFUSED` once the listener is closed),
/// never waits on an HTTP response, and never hangs.
fn wake(self: *LoopbackServer) void {
    comptime {
        if (@import("builtin").os.tag != .linux) {
            @compileError("LoopbackServer.wake() requires Linux: it issues raw std.os.linux syscalls (socket/connect/close). bench-integration is Linux-only — gate cross-OS bench builds out via build.zig.");
        }
    }
    const linux = std.os.linux;
    const sock_rc = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (std.posix.errno(sock_rc) != .SUCCESS) return;
    const sock: i32 = @intCast(sock_rc);
    defer _ = linux.close(sock);

    const addr_in: linux.sockaddr.in = .{
        .port = std.mem.nativeToBig(u16, self.bound_port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001), // 127.0.0.1
    };
    _ = linux.connect(sock, @ptrCast(&addr_in), @sizeOf(linux.sockaddr.in));
    // Best-effort. Result ignored: if the connection succeeds the
    // server's accept returns and processes (or skips) the half-
    // open stream; if it fails (e.g. listener already closed by a
    // racing stop()), the server thread is already on its way out.
}

// ----------------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------------

test "start binds to 127.0.0.1 with a non-zero ephemeral port" {
    const srv = try start(std.testing.allocator);
    defer srv.stop();
    try std.testing.expect(srv.bound_port != 0);
    var buf: [64]u8 = undefined;
    const ep = try srv.endpoint(&buf);
    try std.testing.expect(std.mem.startsWith(u8, ep, "http://127.0.0.1:"));
}

test "handles a single POST and counts at least one request" {
    const srv = try start(std.testing.allocator);
    defer srv.stop();

    var buf: [64]u8 = undefined;
    const ep = try srv.endpoint(&buf);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = ep },
        .method = .POST,
        .headers = .{ .content_type = .{ .override = "application/x-protobuf" } },
        .payload = "hello",
    });
    try std.testing.expectEqual(std.http.Status.ok, result.status);
    // The user request must have been counted; the wake-up sentinel
    // (sent by `stop()` in defer) hasn't fired yet at this point.
    try std.testing.expectEqual(@as(u32, 1), srv.requestCount());
}

test "handles many sequential POSTs (multi-shot accept)" {
    const srv = try start(std.testing.allocator);
    defer srv.stop();

    var buf: [64]u8 = undefined;
    const ep = try srv.endpoint(&buf);

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();

    const N: u32 = 25;
    var i: u32 = 0;
    while (i < N) : (i += 1) {
        const result = try client.fetch(.{
            .location = .{ .url = ep },
            .method = .POST,
            .headers = .{ .content_type = .{ .override = "application/x-protobuf" } },
            .payload = "hello",
        });
        try std.testing.expectEqual(std.http.Status.ok, result.status);
    }
    try std.testing.expectEqual(N, srv.requestCount());
    try std.testing.expectEqual(@as(?anyerror, null), srv.lastError());
}
