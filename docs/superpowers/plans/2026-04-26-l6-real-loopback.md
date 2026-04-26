# L6 Real Loopback HTTP Bench Implementation Plan (F-5)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the synthetic `fakeTransport` in the level-6 OTLP/HTTP integration bench with a real in-process loopback HTTP server, so the bench measures actual TCP socket I/O cost on top of the OTLP encode pipeline.

**Architecture:** Extend `framework.Context` with `io: std.Io` so scenarios can spawn `std.Io.net`-backed servers. Add `benchmarks/integration/loopback_server.zig`: a multi-shot HTTP discard server adapted from the single-shot version in `test/tls_test_helpers.zig`. In `benchmarks/integration/main.zig`, switch `benchLevel6` to detect `build_options.use_devnw_tls` at runtime; when on, spawn the loopback server in `main()`, plumb its endpoint into `OtlpHttpExporter.config.endpoint` and `exporter.io = ctx.io`, and leave `transport` at the sentinel so `expSpans` routes through the real `httpTransportImpl`/`std.http.Client` path. When off, keep the existing `fakeTransport` so the default `zig build bench-integration` keeps producing comparable numbers.

**Tech Stack:** Zig 0.16, `std.Io.Threaded`, `std.Io.net.Server`, `std.http.Server`, `std.http.Client`, `std.Thread`. No new external dependencies. Build flag `-Dotel_use_devnw_tls=true` activates the real path; default builds keep the encode-only fakeTransport behaviour.

**Repo:** `/data/home/benji/src/devnw/zig/otel`. Branch: `main`. Baseline: commit `f492d42` (the `docs(perf): mark F-1..F-4 done, F-5 deferred` commit).

---

## Task 1: Add `io: std.Io` to `framework.Context`

**Files:**

- Modify: `benchmarks/framework.zig` (Context struct + `runScenarios` Context construction)

- [ ] **Step 1.1: Extend Context with the `io` field**

Open `benchmarks/framework.zig`. Find the existing Context struct (lines 55-60):

```zig
pub const Context = struct {
    allocator: std.mem.Allocator,
    scenario: *const Scenario,
    iteration_index: u32,
    user_data: ?*anyopaque,
};
```

Replace it with:

```zig
pub const Context = struct {
    allocator: std.mem.Allocator,
    /// The std.Io view threaded through from `runScenarios`. Scenarios
    /// that need to do networking (e.g. spawning a loopback server)
    /// read this; pure-CPU scenarios can ignore it.
    io: Io,
    scenario: *const Scenario,
    iteration_index: u32,
    user_data: ?*anyopaque,
};
```

- [ ] **Step 1.2: Pass `io` into Context inside `runScenarios`**

In the same file, find the per-iteration Context construction inside the warmup+sample loop (around line 241):

```zig
            var ctx = Context{
                .allocator = iter_allocator,
                .scenario = &iter_scenario,
                .iteration_index = iter,
                .user_data = scenario.user_data,
            };
```

Replace with:

```zig
            var ctx = Context{
                .allocator = iter_allocator,
                .io = io,
                .scenario = &iter_scenario,
                .iteration_index = iter,
                .user_data = scenario.user_data,
            };
```

- [ ] **Step 1.3: Verify the field flows through the embedded framework tests**

The framework's own tests construct Context indirectly through `runScenarios`. They do not need editing — the new field is automatically populated.

Run:

```bash
cd /data/home/benji/src/devnw/zig/otel
zig build bench-framework-test
```

Expected: `All 5 tests passed.` (You will see the spurious "failed command:" line that `zig build` emits when a test prints to stderr — exit code is 0 and the per-test counter says 5/5.)

- [ ] **Step 1.4: Verify all bench artifacts still compile**

Existing scenarios in `benchmarks/micro/main.zig`, `benchmarks/integration/main.zig`, and `benchmarks/compare_bench.zig` use `ctx.allocator` and `ctx.scenario.ops_per_iteration`; none touch `ctx.io`, so adding the field is backward-compatible.

Run:

```bash
zig build check
zig build check -Dotel_disabled=true
zig build check -Dotel_use_devnw_pool=true
zig build check -Dotel_use_devnw_tls=true
```

Expected: each command exits 0 with no errors.

- [ ] **Step 1.5: Verify the existing test suite is still green in both flag modes**

Run:

```bash
zig build test -Dotel_disabled=false
zig build test -Dotel_disabled=true
```

Expected: both exit 0.

- [ ] **Step 1.6: Commit**

```bash
git add benchmarks/framework.zig
git commit -m "$(cat <<'EOF'
feat(bench): add io to framework.Context (F-5 prep)

First step of F-5. Plumbs std.Io through runScenarios into each
scenario's Context so scenarios can spawn std.Io.net-backed servers
(loopback HTTP discard server for the level-6 bench). Pure-CPU
scenarios ignore the field; this is a backward-compatible additive
change.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Create the multi-shot LoopbackServer

**Files:**

- Create: `benchmarks/integration/loopback_server.zig`

**Reference pattern:** `test/tls_test_helpers.zig` (single-shot version). Copy the scaffolding (heap-allocated `std.Io.Threaded`, listener bound to `127.0.0.1:0`, server thread spawned via `std.Thread.spawn`, `endpoint(buf)` formatter) and replace `runOnceFallible` with a `while`-loop accept handler.

- [ ] **Step 2.1: Write the file**

Create `benchmarks/integration/loopback_server.zig` with exactly this content:

```zig
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
// * `stop()` closes the listening socket (causing the accept loop to
//   exit), joins the server thread, frees all owned resources. Safe to
//   call multiple times.
//
// Per-connection behaviour: receive HTTP/1.1 head, drain request body
// to a discarding writer, respond 200 OK with Content-Length: 0,
// keep-alive=false. The accept loop continues until the listener is
// closed, so a single LoopbackServer handles all spans across all
// iterations of the bench.
//
// Single-threaded by design — std.Io.Threaded already provides per-IO
// concurrency, and the bench client is synchronous (one in-flight
// request at a time per producer). If parallel exports become a
// scenario later, switch the per-connection handler to spawn a worker
// thread.

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
    /// Incremented at the tail of every successful response. Read by
    /// tests to confirm multi-shot accept actually fired.
    request_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// First server-thread error, if any. Surfaced via `lastError()`.
    err: ?anyerror = null,
    thread: ?std.Thread = null,
    listener_closed: bool = false,

    pub fn endpoint(self: *LoopbackServer, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}", .{self.bound_port});
    }

    pub fn requestCount(self: *const LoopbackServer) u32 {
        return self.request_count.load(.acquire);
    }

    pub fn lastError(self: *const LoopbackServer) ?anyerror {
        return self.err;
    }

    /// Block until the server thread exits, closing the listening
    /// socket so any pending `accept` returns. Safe to call multiple
    /// times.
    pub fn stop(self: *LoopbackServer) void {
        if (!self.listener_closed) {
            self.listener.deinit(self.io);
            self.listener_closed = true;
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
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
        var stream = self.listener.accept(self.io) catch |err| switch (err) {
            // Listener closed by `stop()` — clean exit.
            error.SocketNotListening => return,
            else => {
                if (self.err == null) self.err = err;
                return;
            },
        };
        defer stream.close(self.io);

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

test "handles a single POST and increments the request counter" {
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
```

- [ ] **Step 2.2: Wire a `bench-loopback-test` build step**

Open `build.zig`. Find the `bench-framework-test` block at the end of the file (look for `framework_test_module = b.createModule`). Add a sibling block immediately after it:

```zig
    // Tests for the multi-shot loopback HTTP discard server used by
    // the level-6 integration bench. Std-only — no otel imports
    // needed, since the server's contract is independent of the SDK.
    const loopback_test_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/integration/loopback_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    const loopback_test = b.addTest(.{ .root_module = loopback_test_module });
    if (tsan) loopback_test.root_module.sanitize_thread = true;
    const loopback_test_step = b.step("bench-loopback-test", "Run loopback HTTP discard server tests");
    loopback_test_step.dependOn(&b.addRunArtifact(loopback_test).step);
```

- [ ] **Step 2.3: Run the loopback tests and verify all three pass**

Run:

```bash
zig build bench-loopback-test
```

Expected: exit code 0; the build will print stderr noise but the underlying binary exits with `All 3 tests passed.` Verify by running the binary directly:

```bash
./.zig-cache/o/*/test 2>&1 | tail
```

Expected output (last few lines):

```text
1/3 loopback_server.test.start binds to 127.0.0.1 with a non-zero ephemeral port...OK
2/3 loopback_server.test.handles a single POST and increments the request counter...OK
3/3 loopback_server.test.handles many sequential POSTs (multi-shot accept)...OK
All 3 tests passed.
```

- [ ] **Step 2.4: Commit**

```bash
git add benchmarks/integration/loopback_server.zig build.zig
git commit -m "$(cat <<'EOF'
feat(bench): multi-shot loopback HTTP discard server (F-5 prep)

Second step of F-5. Adds benchmarks/integration/loopback_server.zig:
heap-allocated std.Io.Threaded + std.Io.net.Server bound to
127.0.0.1:ephemeral, accept loop on a std.Thread that drains every
request body and responds 200 OK / Content-Length: 0. Embeds three
tests proving single + multi-shot semantics, wired via a new
bench-loopback-test build step (sibling of bench-framework-test).

Adapted from test/tls_test_helpers.zig — that file's single-shot
variant remains for the existing TLS integration test; this version
is multi-shot so one server handles all spans across all iterations
of the level-6 bench.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Wire LoopbackServer into integration `benchLevel6`

**Files:**

- Modify: `benchmarks/integration/main.zig`

**Strategy:** Use a file-scope `var g_loopback_server: ?*loopback_server.LoopbackServer = null;` global. Initialize it in `main()` before `runScenarios` (only when `build_options.use_devnw_tls == true`); tear it down after `runScenarios`. `benchLevel6` reads the global and falls back to `fakeTransport` when it is null. This avoids mutating a `const` scenarios array and keeps the existing scenario-table style consistent with sibling bench files.

- [ ] **Step 3.1: Add the imports + global**

Open `benchmarks/integration/main.zig`. The top imports currently end with:

```zig
const build_options = @import("build_options");
```

Replace the import block with:

```zig
const std = @import("std");
const Io = std.Io;
const otel = @import("otel");
const framework = @import("framework");
const build_options = @import("build_options");
const loopback_server = @import("loopback_server.zig");

/// Hoisted outside the timed loop per architect Decision D-3. Started
/// in `main()` when `-Dotel_use_devnw_tls=true`; consulted by
/// `benchLevel6` to decide between real-loopback and fakeTransport
/// modes. Null when the build flag is off, so the default
/// `zig build bench-integration` continues to measure encode-only L6
/// cost (current behaviour).
var g_loopback_server: ?*loopback_server.LoopbackServer = null;
```

- [ ] **Step 3.2: Start/stop the server in `main()`**

Find the `pub fn main(...)` block near the top of the file. Locate the line:

```zig
    switch (try framework.parseArgs(allocator, init.minimal.args)) {
```

Insert this block immediately before that `switch`:

```zig
    if (build_options.use_devnw_tls) {
        g_loopback_server = try loopback_server.start(init.gpa);
    }
    defer if (g_loopback_server) |srv| {
        srv.stop();
        g_loopback_server = null;
    };
```

The `init.gpa` allocator is used (rather than the arena `allocator`) because the server outlives `runScenarios` and must survive the arena reset that happens implicitly when the arena is destroyed. The arena is fine for the parsed-args strings but not for the long-lived server.

- [ ] **Step 3.3: Update `benchLevel6` to use the real loopback**

Find the existing `benchLevel6` function. It currently looks like:

```zig
fn benchLevel6(ctx: *framework.Context) anyerror!void {
    var resource = try otel.sdk.resource.defaultResource(ctx.allocator);
    defer resource.deinit();

    var otlp_exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(ctx.allocator, .{
        .endpoint = "http://localhost:4318",
        .protocol = .http_protobuf,
    });
    defer otlp_exporter.deinit();
    // Swap the real `httpTransport` (which returns UnsupportedTransport
    // unless `-Dotel_use_devnw_tls=true`) for a fake that signals 200 OK
    // without touching the network. Measures the OTLP encode pipeline,
    // not socket I/O.
    otlp_exporter.transport = fakeTransport;
    // ... rest of body
```

Replace the entire function body with:

```zig
fn benchLevel6(ctx: *framework.Context) anyerror!void {
    var resource = try otel.sdk.resource.defaultResource(ctx.allocator);
    defer resource.deinit();

    // F-5: when the bench is built with -Dotel_use_devnw_tls=true and
    // the loopback server was started in main(), use the real
    // std.http.Client transport against the in-process server. When
    // the flag is off, fall back to the fakeTransport (encode-only)
    // so the default `zig build bench-integration` numbers stay
    // comparable across runs.
    var endpoint_buf: [64]u8 = undefined;
    const endpoint: []const u8 = if (build_options.use_devnw_tls and g_loopback_server != null)
        try g_loopback_server.?.endpoint(&endpoint_buf)
    else
        "http://localhost:4318";

    var otlp_exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(ctx.allocator, .{
        .endpoint = endpoint,
        .protocol = .http_protobuf,
        .allow_loopback = true,
    });
    defer otlp_exporter.deinit();

    if (build_options.use_devnw_tls and g_loopback_server != null) {
        // Plumb the std.Io view so httpTransportImpl (sentinel-routed
        // from expSpans) can drive std.http.Client over the real
        // socket. Leaving `transport` at the default sentinel value
        // is the trigger for the real path.
        otlp_exporter.io = ctx.io;
    } else {
        // Encode-only fallback: no network, returns 200 immediately.
        otlp_exporter.transport = fakeTransport;
    }

    var tp = try otel.sdk.trace.TracerProvider.init(ctx.allocator, .{
        .resource = &resource,
        .default_exporter = otlp_exporter.spanExporter(),
    });
    defer tp.deinit();

    var mp = try otel.sdk.metrics.MeterProvider.init(ctx.allocator, .{ .resource = &resource });
    defer mp.deinit();
    var rec = otel.exporters.in_memory.Recorder.init(ctx.allocator);
    defer rec.deinit();
    var lp = try otel.sdk.logs.LoggerProvider.init(ctx.allocator, .{
        .resource = &resource,
        .default_exporter = rec.logExporter(),
    });
    defer lp.deinit();

    const tracer = tp.tracer(.{ .name = "bench" });
    const meter = mp.meter(.{ .name = "bench" });
    const counter = try meter.counter(.{ .name = "bench.requests", .kind = .counter });
    const histogram = try meter.histogram(.{ .name = "bench.latency_ms", .kind = .histogram });
    const logger = lp.logger(.{ .name = "bench" });

    try emitFullPipeline(tracer, counter, histogram, logger, ctx.scenario.ops_per_iteration);
    std.mem.doNotOptimizeAway(rec.logs.items.len);
}
```

- [ ] **Step 3.4: Verify the encode-only path still works (default flag)**

Run:

```bash
zig build bench-integration -Doptimize=ReleaseFast -- --filter integ_level6
```

Expected: scenario runs to completion; the 6 sample medians should land in the same ballpark as the pre-F-5 numbers (~3.8 µs/span on local Linux x86_64). The build flag is OFF, so `g_loopback_server` is null and `fakeTransport` is used.

- [ ] **Step 3.5: Verify the real-loopback path runs end-to-end**

Run:

```bash
zig build bench-integration -Doptimize=ReleaseFast -Dotel_use_devnw_tls=true -- --filter integ_level6
```

Expected: scenario runs to completion; per-span time will be higher than the encode-only baseline (loopback TCP adds ~10-20 µs on a typical Linux runner). No `error.UnsupportedTransport`, no `error.RetryExhausted`, no test panics.

- [ ] **Step 3.6: Confirm the existing test suite is still green**

Run:

```bash
zig build test -Dotel_disabled=false
zig build test -Dotel_disabled=true
zig build test -Dotel_use_devnw_tls=true
zig build bench-loopback-test
```

Expected: all four exit 0.

- [ ] **Step 3.7: Commit**

```bash
git add benchmarks/integration/main.zig
git commit -m "$(cat <<'EOF'
feat(bench): real loopback HTTP for level-6 integration bench (F-5)

Closes F-5. When the bench is built with -Dotel_use_devnw_tls=true,
benchLevel6 now uses the multi-shot loopback HTTP discard server
introduced in the previous commit and routes through the real
httpTransportImpl (std.http.Client over a TCP socket) instead of the
synthetic fakeTransport. The server is started once in main() and
reused across all iterations per architect Decision D-3.

When the build flag is off (default), benchLevel6 keeps the
fakeTransport fallback so `zig build bench-integration` numbers stay
comparable with pre-F-5 runs. No build.zig changes; existing
artifact graph already imports build_options.

The comparison-layer L6 (benchmarks/compare_bench.zig) intentionally
keeps fakeTransport: the AB harness measures the comptime-elision
delta, and encode-only is sufficient there. Real-network L6 only
matters for the integration bench's "what does the full pipeline
cost when enabled" answer, which is what this commit unlocks.

Refs: docs/performance/2026-04-26-zero-overhead-when-disabled/architecture.md (F-5)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Capture baseline numbers for the new path

**Files:**

- Modify: `docs/performance/2026-04-26-zero-overhead-when-disabled/architecture.md` (Follow-up F-5 section)

- [ ] **Step 4.1: Run the encode-only and real-loopback variants side by side**

Run:

```bash
mkdir -p /tmp/f5
zig build bench-integration -Doptimize=ReleaseFast -- --filter integ_level6 --quiet --output /tmp/f5/encode-only.json
zig build bench-integration -Doptimize=ReleaseFast -Dotel_use_devnw_tls=true -- --filter integ_level6 --quiet --output /tmp/f5/real-loopback.json
```

Expected: both files exist and parse as JSON. Inspect with:

```bash
python3 -c "
import json
for label, path in [('encode-only', '/tmp/f5/encode-only.json'), ('real-loopback', '/tmp/f5/real-loopback.json')]:
    with open(path) as f: doc = json.load(f)
    for r in doc['rows']:
        ns_per_op = r['wall_ns_p50'] / max(1, r['ops_per_iteration'])
        print(f'{label:>14} {r[\"scenario_name\"]}: {ns_per_op:.0f} ns/span')
"
```

Record the two numbers. The real-loopback figure should be 3-10× higher than encode-only.

- [ ] **Step 4.2: Update the architecture doc to mark F-5 done**

Open `docs/performance/2026-04-26-zero-overhead-when-disabled/architecture.md`. Find the section starting with `**Follow-up F-5 — DEFERRED (L6 real loopback).**`. Replace the entire F-5 block with:

```markdown
**Follow-up F-5 — DONE.** Real loopback HTTP for the L6 integration
bench. `framework.Context` gained an `io: std.Io` field;
`benchmarks/integration/loopback_server.zig` is a multi-shot
`std.Io.net.Server` running on a `std.Thread` that drains every
request body and responds 200 OK / Content-Length: 0.
`benchLevel6` checks `build_options.use_devnw_tls` at runtime and
either plumbs `OtlpHttpExporter.io = ctx.io` against the loopback
server endpoint (real path, routes through `httpTransportImpl` →
`std.http.Client`) or falls back to the encode-only `fakeTransport`
(default).

Local Linux x86_64 ReleaseFast, 100 spans/iter:

  - Encode-only (default):    <ENCODE_NS> ns/span
  - Real loopback (-Dotel_use_devnw_tls=true): <LOOPBACK_NS> ns/span

The comparison-layer L6 in `benchmarks/compare_bench.zig`
intentionally keeps `fakeTransport`: the AB harness measures the
comptime-elision delta, where encode-only is sufficient. Real-network
L6 only matters for the integration bench.
```

Replace `<ENCODE_NS>` and `<LOOPBACK_NS>` with the numbers you captured in Step 4.1 (rounded to the nearest 10 ns).

- [ ] **Step 4.3: Run markdownlint to confirm the doc still passes**

Run:

```bash
pre-commit run markdownlint --files docs/performance/2026-04-26-zero-overhead-when-disabled/architecture.md
```

Expected: `markdownlint...Passed`.

- [ ] **Step 4.4: Commit**

```bash
git add docs/performance/2026-04-26-zero-overhead-when-disabled/architecture.md
git commit -m "$(cat <<'EOF'
docs(perf): mark F-5 done, record real-loopback L6 numbers

Updates the bench architecture document's Follow-up F-5 entry from
DEFERRED to DONE, with the captured ns/span deltas between the
encode-only fakeTransport (default) and the real-loopback path
unlocked by -Dotel_use_devnw_tls=true.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

- [ ] **Step SR.1: Spec coverage**

The spec has four concrete requirements:

1. *Extend framework.Context with io: std.Io* → Task 1, Steps 1.1-1.6.
2. *Adapt tls_test_helpers single-shot HTTP server into multi-shot* → Task 2, Steps 2.1-2.4.
3. *Build with -Dotel_use_devnw_tls=true so httpTransportImpl uses real std.http.Client* → Task 3, Step 3.5 (verifies the real path works).
4. *Wire it all into benchLevel6* → Task 3, Steps 3.1-3.7.

Plus implicit deliverables: tests, build wiring, doc update. All covered.

- [ ] **Step SR.2: Placeholder scan**

Search the plan text for forbidden patterns: `TBD`, `TODO`, `implement later`, `fill in details`, `Add appropriate error handling`, `add validation`, `handle edge cases`, `Write tests for the above`, `Similar to Task N`. None present.

The two `<ENCODE_NS>` / `<LOOPBACK_NS>` placeholders in Step 4.2 are intentional — those values are captured from a measurement run in the immediately preceding step (4.1) and substituted in. Each is documented inline as a measurement-output substitution, which is concrete and actionable.

- [ ] **Step SR.3: Type consistency**

- `LoopbackServer` is the struct name throughout (not `Server`, not `DiscardServer`).
- `start(allocator) !*LoopbackServer` is the constructor (not `init`, not `New`).
- `stop()` is the destructor (not `deinit`, not `close`).
- `endpoint(buf) ![]const u8` is the URL formatter (matches the existing `tls_test_helpers.Server.endpoint` shape).
- `g_loopback_server: ?*loopback_server.LoopbackServer` is the integration-side global; the import alias is `loopback_server`. Consistent.
- `framework.Context.io` is the new field name (matches `framework.RunOptions` parameter style elsewhere).
- The `Io` type is `std.Io` everywhere; `framework.zig` already aliases it to `Io` at file scope, so the new field uses the alias.

No inconsistencies found.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-26-l6-real-loopback.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, two-stage review between tasks (spec compliance + code quality), fast iteration in this session.

**2. Inline Execution** — I execute tasks here using the executing-plans skill, batched with checkpoints for your review.

Which approach?
