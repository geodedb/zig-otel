// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Loopback gRPC server harness for the OTLP/gRPC exporter integration
// test. Lives inside the library's source tree (rather than under
// `test/`) for one structural reason: Zig 0.16 forbids the same source
// file belonging to two distinct modules, and the `grpc-zig` package
// exposes its `grpc-client` and `grpc-server` modules with overlapping
// transitive imports (`proto/service.zig`, `transport.zig`, etc.).
// Pulling both into the same compilation through two separate modules
// trips the collision regardless of which consumer adds them. The
// otel `build.zig` works around this by synthesizing a single
// "umbrella" module (`grpc_zig`) rooted at
// `third_party/grpc_zig/all.zig` that imports both client and server
// as siblings inside one module identity. By hosting this harness
// inside the otel source tree it can use the same umbrella import
// (`@import("grpc_zig")`) the exporter uses, so the loopback test
// reaches the server via `otel.exporters.otlp_grpc_test_server.*`
// without adding a second grpc-zig consumer module.
//
// Cleartext h2 (h2c) is used — no TLS in the loopback path. This mirrors
// the Phase 6 `tls_loopback` decision: TLS is upstream-tested, our gRPC
// transport speaks the same wire shape over either a plain or
// TLS-wrapped socket, and standing up self-signed certs would only test
// `std.crypto.tls` and the grpc-zig TLS shim, neither of which we own.
//
// Lifecycle:
//
// * `startLoopbackGrpc` returns a heap-allocated `Server`. The caller
//   must call `shutdown()` to release resources.
// * `requestCount()` is safe to read after the export call returns —
//   synchronisation comes from the loopback round-trip itself
//   (`GrpcClient.call` only returns once the server has written the
//   response trailer).
// * `endpoint()` returns an `http://127.0.0.1:<port>` URL suitable for
//   `OtlpConfig.endpoint`.

const std = @import("std");
const build_options = @import("build_options");
const id_mod = @import("../internal/id.zig");

pub const Server = if (build_options.use_devnw_grpc) RealServer else Stub;

/// Spin up an in-process loopback gRPC server bound to `127.0.0.1:0` on
/// a background thread. The returned `Server` is heap-allocated and the
/// caller must free it via `shutdown()`. When the
/// `-Dotel_use_devnw_grpc` flag is off this returns
/// `error.SkipZigTest` so the calling test self-skips.
pub fn startLoopbackGrpc(allocator: std.mem.Allocator) !*Server {
    if (!build_options.use_devnw_grpc) return error.SkipZigTest;
    return RealServer.start(allocator);
}

// ---------------------------------------------------------------------------
// Real implementation — only resolves when the build flag is on.
// ---------------------------------------------------------------------------

const grpc_zig = if (build_options.use_devnw_grpc) @import("grpc_zig") else struct {};

const RealServer = struct {
    allocator: std.mem.Allocator,
    threaded: *std.Io.Threaded,
    io: std.Io,
    server: *grpc_zig.GrpcServer,
    bound_port: u16,
    /// Atomically incremented by the handler each time it is invoked.
    /// Read by the test after `exportSpans` returns, by which point the
    /// server thread has at minimum entered the handler once (the client
    /// only unblocks on response).
    request_count: std.atomic.Value(usize),
    thread: ?std.Thread = null,
    shutdown_flag: std.atomic.Value(bool),

    pub fn endpoint(self: *RealServer, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.bound_port});
    }

    pub fn requestCount(self: *const RealServer) usize {
        return self.request_count.load(.acquire);
    }

    /// Tear down the server: signal shutdown, close the listener (which
    /// causes the accept loop to error out), join the background
    /// thread, and free all resources. Safe to call once.
    pub fn shutdown(self: *RealServer) void {
        self.shutdown_flag.store(true, .release);
        // Closing the listening socket forces `accept()` in the server
        // loop to error out, which terminates the daemon thread cleanly.
        self.server.server.deinit(self.io);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
        self.server.handlers.deinit(self.server.allocator);
        self.server.health_check.deinit();
        self.allocator.destroy(self.server);
        self.threaded.deinit();
        self.allocator.destroy(self.threaded);
        self.allocator.destroy(self);
    }

    fn start(allocator: std.mem.Allocator) !*RealServer {
        const threaded = try allocator.create(std.Io.Threaded);
        errdefer allocator.destroy(threaded);
        threaded.* = std.Io.Threaded.init(allocator, .{});
        errdefer threaded.deinit();

        const io = threaded.io();

        const inner = try allocator.create(grpc_zig.GrpcServer);
        errdefer allocator.destroy(inner);
        // GrpcServer.init binds to 0.0.0.0 (see grpc-zig server.zig:32);
        // 127.0.0.1-only binding would require touching upstream. Loopback
        // is safe because the test environment is hermetic.
        //
        // GAP-SEC-M-1: generate a fresh per-server token from the OS
        // CSPRNG so two test runs never share the same loopback secret.
        // Stash the generated token on the server so a future test that
        // wants to assert against it can read it back.
        var token_bytes: [16]u8 = undefined;
        id_mod.fillCsprngBytesPub(&token_bytes);
        var token_hex: [32]u8 = undefined;
        const alphabet = "0123456789abcdef";
        for (token_bytes, 0..) |b, idx| {
            token_hex[idx * 2] = alphabet[(b >> 4) & 0x0f];
            token_hex[idx * 2 + 1] = alphabet[b & 0x0f];
        }
        const token = try allocator.dupe(u8, token_hex[0..]);
        errdefer allocator.free(token);
        inner.* = try grpc_zig.GrpcServer.init(allocator, io, 0, token);
        errdefer {
            inner.handlers.deinit(allocator);
            inner.health_check.deinit();
            inner.server.deinit(io);
        }

        const bound_port = inner.server.socket.address.getPort();

        const srv = try allocator.create(RealServer);
        errdefer allocator.destroy(srv);
        srv.* = .{
            .allocator = allocator,
            .threaded = threaded,
            .io = io,
            .server = inner,
            .bound_port = bound_port,
            .request_count = std.atomic.Value(usize).init(0),
            .shutdown_flag = std.atomic.Value(bool).init(false),
        };

        // Stash a pointer so the handler can find the counter. The
        // upstream Handler signature gives us the transport but no user
        // context; a thread-local pointer lets the handler reach back
        // into the Server. Loopback tests only run one server per test,
        // so a single pointer is sufficient.
        active_server = srv;
        try inner.handlers.append(allocator, .{
            .name = "Export",
            .handler_fn = exportHandler,
        });

        srv.thread = try std.Thread.spawn(.{}, runDaemon, .{srv});
        return srv;
    }
};

/// Single-test global pointer back to the active loopback server. The
/// upstream `Handler` signature has no opaque-context slot, so we cannot
/// pass `srv` through `handler_fn`. Loopback tests are sequential and
/// only spin up one server at a time.
var active_server: ?*RealServer = null;

fn runDaemon(srv: *RealServer) void {
    srv.server.start() catch {
        // Expected to fail with `error.SocketNotListening` (or similar)
        // when `shutdown()` closes the listener. Any other error is
        // swallowed because the test asserts via `requestCount()`.
    };
}

const TransportType = if (build_options.use_devnw_grpc) grpc_zig.Transport else void;

fn exportHandler(
    request: []const u8,
    _: []const u8,
    trans: *TransportType,
    allocator: std.mem.Allocator,
) anyerror!void {
    _ = request;
    _ = allocator;
    if (active_server) |srv| {
        _ = srv.request_count.fetchAdd(1, .release);
    }
    // OTLP/gRPC TraceService.Export reply is `ExportTraceServiceResponse`,
    // which is empty when there are no rejected spans. An empty protobuf
    // message is the empty byte string.
    try trans.writeMessage("");
}

// ---------------------------------------------------------------------------
// Stub — keeps the file compilable when the grpc flag is off so the
// otel module's `pub const otlp_grpc_test_server = @import(...)` works
// regardless of build configuration.
// ---------------------------------------------------------------------------

const Stub = struct {
    pub fn endpoint(_: *Stub, _: []u8) ![]const u8 {
        return error.SkipZigTest;
    }

    pub fn requestCount(_: *const Stub) usize {
        return 0;
    }

    pub fn shutdown(_: *Stub) void {}
};
