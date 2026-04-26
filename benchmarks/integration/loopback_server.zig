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
    err: ?anyerror = null,
    thread: ?std.Thread = null,

    pub fn endpoint(self: *LoopbackServer, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.bound_port});
    }

    pub fn requestCount(self: *const LoopbackServer) u32 {
        return self.request_count.load(.acquire);
    }

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

        if (self.shutdown_requested.load(.acquire)) return;

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

/// Send a sentinel HTTP request to ourselves so the parked
/// `accept()` returns cleanly. Best-effort — if any step fails the
/// server thread will eventually time out or notice the flag on its
/// next iteration, but this is the fast path. Uses a fresh
/// `std.Io.Threaded` so it doesn't collide with the server's own
/// io view that's parked in accept.
fn wake(self: *LoopbackServer) void {
    var threaded = std.Io.Threaded.init(self.allocator, .{});
    defer threaded.deinit();
    var client: std.http.Client = .{ .allocator = self.allocator, .io = threaded.io() };
    defer client.deinit();
    var ep_buf: [64]u8 = undefined;
    const ep = self.endpoint(&ep_buf) catch return;
    _ = client.fetch(.{
        .location = .{ .url = ep },
        .method = .POST,
        .payload = "",
    }) catch {};
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
