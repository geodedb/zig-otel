# Quality Scan — OpenTelemetry Zig SDK

Phase 2 of the codebase audit. Scope: `src/` (36 files, ~7080 LOC), `test/`
(16 files, ~1309 LOC, 112 tests), `tools/`, `examples/`, `benchmarks/`,
`build.zig`. Toolchain: Zig 0.16.0.

Methodology: ran `zig fmt --check` on every tracked source tree, walked
the public API surface module-by-module, cross-referenced declarations
against call sites with `rg`, scored function size and nesting by
inspection, and audited each test file against its production module
to surface coverage holes.

Findings are tagged `confidence::confirmed` (verified by reading
both the declaration and call sites) or `confidence::suspected`
(needs manual confirmation, e.g. by running tests with the appropriate
`-D` flag).

## Headline Numbers

| Check | Result |
|------|--------|
| `zig fmt --check src test tools examples build.zig benchmarks` | **PASS** (no drift) |
| Tooling configured | `zig fmt`, pre-commit, CI matrix (Linux/macOS, Zig 0.16.0) |
| Tooling absent | coverage instrumentation, fuzz target (suppressed), TSan in CI, benchmark gate (stubbed), Windows runners (zeroed) |
| Files > 500 LOC | 5 (`benchmarks/framework.zig` 613, `src/sdk/metrics.zig` 605, `src/exporters/otlp_http.zig` 592, `src/sdk/export.zig` 569, `src/sdk/config.zig` 509) |
| Files > 800 LOC | 0 |
| Functions > 50 LOC | 7 (none > 70) |
| Public symbols missing doc comments | 28+ in `src/api/trace.zig` alone (zero `///` lines for `Tracer`, `SpanKind`, `Span`, `Status`, etc.) |

Bottom line: formatting + per-file size are healthy. The high-impact
issues are (1) a CI-stubbed benchmark step that hides a
**guaranteed-broken** `benchmarks/bench.zig` (calls a non-existent
`lib.init`), (2) a metrics export pipeline whose vtable is wired but
never reached (no `MetricReader` implementation), (3) significant
duplication of attribute-value formatting across four exporters, and
(4) sparse doc coverage on the public API surface.

---

## Critical

### C1 — `benchmarks/bench.zig` calls a non-existent `lib.init` (build fails when `bench` runs for real)

- **File**: `/data/home/benji/src/devnw/zig/otel/benchmarks/bench.zig:55-71`
- **Snippet**:

  ```zig
  fn benchInitDefault(ctx: *framework.Context) anyerror!void {
      var i: u64 = 0;
      while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
          try lib.init(.{});                       // lib == otel; otel has no `init`
      }
  }

  fn benchInitCustom(ctx: *framework.Context) anyerror!void {
      // ...
      try lib.init(.{
          .debug = (i & 1) == 0,                   // also no `debug`/`max_retries`/`timeout_ms` fields
          .max_retries = @intCast(1 + (i % 16)),
          .timeout_ms = 1 + (i % 1024),
      });
  }
  ```

  `src/otel.zig` exposes `version`, `api`, `propagation`, `sdk`,
  `exporters`, `instrumentation`, `semconv`, `internal`, `otlp_wire`,
  `Error`. There is no top-level `init`. The CI `bench` step in
  `build.zig:391-392` is gated on `fmt_check_step` instead of
  `bench.zig`, so the broken file never compiles in CI:

  ```zig
  const bench_step = b.step("bench", "Run benchmark suite (stub — wired in a follow-up)");
  bench_step.dependOn(&fmt_check.step); // any always-succeed step
  ```

- **Why it matters**: any contributor who tries `zig build bench`
  expecting it to do something useful will hit a hard compile failure.
  The CI dashboard says "green" but the artifact is bit-rotten template
  scaffolding from the zig-template starter. The same story repeats for
  `benchmarks/scale.zig` and `benchmarks/compare.zig` (both gated on
  `fmt_check.step`).
- **Suggested fix**: either (a) wire `bench_step.dependOn(&bench_exe.step)`
  and rewrite the scenarios against the actual public surface
  (`MeterProvider.init`, `Counter.add`, `BatchSpanProcessor.init`,
  `OtlpHttpExporter.encodeSpansProto`, etc.), or (b) delete
  `benchmarks/bench.zig` and stop pretending the step does work.
  Document the chosen path in the build comment so future readers
  don't trip over the same drift.
- `confidence::confirmed`

---

### C2 — Metric export pipeline is wired half-way: no `MetricReader` implementation exists

- **Files**: `/data/home/benji/src/devnw/zig/otel/src/sdk/metrics.zig:38-47,198-200,499-557`,
  `/data/home/benji/src/devnw/zig/otel/src/sdk/export.zig:475-492`,
  `/data/home/benji/src/devnw/zig/otel/src/exporters/in_memory.zig:89-91`,
  `/data/home/benji/src/devnw/zig/otel/src/exporters/stdout_json.zig:28-30`
- **Snippet**:

  ```zig
  // src/sdk/metrics.zig
  pub const MetricReader = struct {
      ctx: ?*anyopaque,
      collectFn: *const fn (?*anyopaque, std.mem.Allocator, *MeterProvider) anyerror!void,
      forceFlushFn: *const fn (?*anyopaque, u64) anyerror!void,
      shutdownFn: *const fn (?*anyopaque) void,
      pub fn collect(self: MetricReader, allocator: std.mem.Allocator, provider: *MeterProvider) !void {
          try self.collectFn(self.ctx, allocator, provider);
      }
  };

  // The MeterProvider only ever calls forceFlushFn; collect() is never
  // dispatched anywhere. There is no PeriodicReader, no SimpleReader,
  // and no production code path that exists between collect() and
  // MetricExporter.exportMetrics().

  // src/exporters/in_memory.zig + stdout_json.zig — exporters declare
  // metricExporter() but nothing calls it.
  pub fn metricExporter(self: *Recorder) exp.MetricExporter { ... }
  ```

- **Why it matters**: callers can register `MetricReader` slots in
  `MetricsConfig.readers`, but the SDK never invokes their `collectFn`.
  The metric pipeline only works if the application calls
  `sdk.metrics.collect()` directly (as the tests do); the OTLP, stdout,
  and in-memory `metricExporter()` constructors are dead vtables.
  The `expMetrics` and `exp.MetricExporter` types pretend to exist as
  a public extension point, but no one can plug them into the
  `MeterProvider` lifecycle.
- **Suggested fix**: add a `PeriodicReader(MetricExporter, interval_ns)`
  that owns a thread (or std.Io worker) and calls
  `sdk.metrics.collect()` then `exporter.exportMetrics()` on each tick.
  Wire it through `MetricsConfig.readers`. Either that or remove
  `MetricExporter`/`MetricReader`/`metricExporter()` and document
  metrics as a pull-only pipeline (`sdk.metrics.collect()` → caller
  serializes to wire). The current half-built shape is the worst of
  both.
- `confidence::confirmed`

---

### C3 — `BatchSpanProcessorOptions.schedule_delay_ms` is silently ignored

- **File**: `/data/home/benji/src/devnw/zig/otel/src/sdk/export.zig:139-148`
- **Snippet**:

  ```zig
  pub const BatchSpanProcessorOptions = struct {
      max_queue_size: usize = 2048,
      max_export_batch_size: usize = 512,
      schedule_delay_ms: u64 = 5_000,         // never read anywhere
      async_workers: u32 = 0,
  };
  ```

  `rg -nrIP "schedule_delay_ms" src/` returns exactly the declaration.
  Neither the synchronous drain (`batchOnEnd`) nor the
  `async_pool.submitDrain` path looks at it. The only flush trigger is
  "queue ≥ max_export_batch_size" or an explicit `forceFlush`.
- **Why it matters**: the spec mandates a periodic drain on
  `schedule_delay_ms` even when the queue hasn't reached the batch
  size. As written, low-volume telemetry can sit in the queue for an
  arbitrarily long time. The documented field gives callers false
  confidence that the periodic drain is happening.
- **Suggested fix**: implement the timer-driven drain (likely against
  `tp.clock.sleep` in the pool path; for the synchronous path,
  document explicitly that the field is best-effort and only honoured
  when the pool flag is set; consider hoisting it into the periodic
  reader infrastructure proposed in C2 so both signals share one
  scheduling model).
- `confidence::confirmed`

---

## High

### H1 — `OtlpConfig.compression` and `skip_tls_verify` are declared but ignored

- **Files**: `/data/home/benji/src/devnw/zig/otel/src/sdk/config.zig:47-57`,
  `/data/home/benji/src/devnw/zig/otel/src/exporters/otlp_http.zig:108-163`
- **Snippet**:

  ```zig
  pub const OtlpConfig = struct {
      // ...
      compression: enum { none, gzip } = .none,
      insecure: bool = false,
      skip_tls_verify: bool = false,
  };
  ```

  None of these are referenced in either `otlp_http.zig` or
  `otlp_grpc.zig`. The `httpTransportImpl` constructs a default
  `std.http.Client` and never sets gzip headers nor relaxes TLS
  verification.
- **Why it matters**: callers wiring `OTEL_EXPORTER_OTLP_COMPRESSION=gzip`
  expect bandwidth reductions; they get none. `skip_tls_verify=true`
  silently fails closed against self-signed endpoints. Both are listed
  in the OpenTelemetry env-var spec.
- **Suggested fix**: implement gzip via `std.compress.gzip` around the
  body before `client.fetch`; surface a TLS configuration knob via
  `std.http.Client.Connection`. If implementation is deferred, mark the
  fields with a doc comment ("not yet honoured — tracked in #N") so the
  contract is explicit.
- `confidence::confirmed`

---

### H2 — Significant duplication of attribute-value formatting across exporters

- **Files**:
  - `/data/home/benji/src/devnw/zig/otel/src/exporters/prometheus.zig:146-154` (`writeStringValue`)
  - `/data/home/benji/src/devnw/zig/otel/src/exporters/in_memory.zig:171-179` (`valueToString`)
  - `/data/home/benji/src/devnw/zig/otel/src/sdk/metrics.zig:335-351` (`formatValue`)
  - `/data/home/benji/src/devnw/zig/otel/src/internal/json_codec.zig:166-174` (`writeValue`)
- **Snippet** (prometheus):

  ```zig
  fn writeStringValue(allocator, buf, v: attrs_mod.Value) !void {
      switch (v) {
          .string => |s| try buf.appendSlice(allocator, s),
          .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
          .int => |i| try buf.writer(allocator).print("{d}", .{i}),
          .double => |d| try buf.writer(allocator).print("{d}", .{d}),
          else => try buf.appendSlice(allocator, "<array>"),
      }
  }
  ```

  All four implementations share the same five-arm switch with
  trivial divergences (`json_codec.writeValue` JSON-escapes strings;
  `in_memory.valueToString` returns owned `[]u8` rather than appending
  to a buffer). Each one handles array types as a literal `"<array>"`
  placeholder — meaning array-shaped attribute values **silently
  collapse to the string `<array>`** in stdout JSON, Prometheus, and
  in-memory recorders. (OTLP/HTTP protobuf and JSON paths each have
  their own copy in `writeKeyValue` / `json_codec.writeValue` that does
  the same.)
- **Why it matters**: silent loss of array-shaped attribute fidelity is
  a spec compliance bug; once one path learns to emit arrays
  (e.g. for the OTLP wire), the others will silently disagree. The
  duplication also means every fix has to be applied 4–5 times.
- **Suggested fix**: hoist a single `internal.attributes.formatValue`
  (or `attrs_mod.Value.format`) helper that handles all variants
  including arrays. Each exporter wraps it with their own escaping
  policy.
- `confidence::confirmed`

---

### H3 — Duplicate noop/shutdown shims across four exporters

- **Files**: `/data/home/benji/src/devnw/zig/otel/src/exporters/in_memory.zig:98-99`,
  `/data/home/benji/src/devnw/zig/otel/src/exporters/stdout_json.zig:37-38`,
  `/data/home/benji/src/devnw/zig/otel/src/exporters/file.zig:34-42`,
  `/data/home/benji/src/devnw/zig/otel/src/exporters/otlp_http.zig:165-170`,
  `/data/home/benji/src/devnw/zig/otel/src/exporters/otlp_grpc.zig:57-62`
- **Snippet**: every exporter ships its own `noopShutdown` /
  `noopFlush` (or `doShutdown` / `doFlush`) pair, all identical
  except for the `closed = true` line in OTLP and the `file.sync`
  in `file.zig`.
- **Why it matters**: vtable boilerplate fans out across 5 files;
  adding a new vtable slot (e.g. `pub fn name() []const u8`) means
  touching 5 exporters with copy-paste. Drift is inevitable.
- **Suggested fix**: provide `exp.SpanExporter.noopFlush` / `noopShutdown`
  helper functions in `src/sdk/export.zig` that all exporters can reuse;
  or generate the no-op vtable via a comptime helper
  (`exp.makeNoop(SpanExporter, .{ .exportFn = expSpans })`).
- `confidence::confirmed`

---

### H4 — Identical `parseGrpcEndpoint`-style scheme stripping copy-pasted between OTLP exporters

- **Files**: `/data/home/benji/src/devnw/zig/otel/src/exporters/otlp_grpc.zig:132-150`,
  `/data/home/benji/src/devnw/zig/otel/src/exporters/otlp_http.zig:115-117`
  (the trim/strip dance is repeated in `httpTransportImpl`).
- **Why it matters**: the two endpoints have to stay in sync (URL parse
  rules, default ports, error names). Today they diverge on whether the
  scheme is required (OTLP/HTTP requires it via `init`; gRPC
  silently accepts a scheme-less endpoint).
- **Suggested fix**: hoist a shared `endpoint.parse()` helper in
  `src/internal/` that returns `{ scheme, host, port, path }` and
  let each exporter apply its own validation rules on top.
- `confidence::suspected` (the duplication is real; whether they
  actually diverge in observed behaviour requires running the live
  test suite).

---

### H5 — `bench-micro`, `scale-bench`, `compare-bench` are stubs aliased to `fmt_check`

- **File**: `/data/home/benji/src/devnw/zig/otel/build.zig:391-401`
- **Snippet**:

  ```zig
  const bench_step = b.step("bench", "Run benchmark suite (stub — wired in a follow-up)");
  bench_step.dependOn(&fmt_check.step); // any always-succeed step

  const bench_micro_step = b.step("bench-micro", "Run micro-benchmarks (stub)");
  bench_micro_step.dependOn(&fmt_check.step);

  const scale_bench_step = b.step("scale-bench", "Run scale benchmarks (stub)");
  scale_bench_step.dependOn(&fmt_check.step);

  const compare_bench_step = b.step("compare-bench", "Compare benchmark output to baseline (stub)");
  compare_bench_step.dependOn(&fmt_check.step);
  ```

- **Why it matters**: CI can never report a benchmark regression. The
  step descriptions admit it ("stub"), but the dashboard signals
  "passed" — gaslighting any CI consumer.
- **Suggested fix**: either implement them on top of
  `benchmarks/framework.zig` (after fixing C1) or delete the steps
  outright and remove the corresponding CI jobs.
- `confidence::confirmed`

---

### H6 — `test/grpc_loopback.zig` self-skips unconditionally

- **File**: `/data/home/benji/src/devnw/zig/otel/test/grpc_loopback.zig:31-42`
- **Snippet**:

  ```zig
  test "OTLP/gRPC loopback round-trips a span" {
      return error.SkipZigTest;
  }

  comptime {
      _ = otel.exporters.otlp_grpc.OtlpGrpcExporter;
      _ = helpers.startLoopbackGrpc;
      _ = build_options.use_devnw_grpc;
      _ = std.testing.allocator;
  }
  ```

- **Why it matters**: the OTLP/gRPC exporter has zero round-trip
  coverage. The 200-line loopback server harness in
  `src/exporters/otlp_grpc_test_server.zig` is dead weight in the
  binary until the grpc-zig deadlock noted in the file header is fixed.
  Production callers depending on the gRPC path are flying blind.
- **Suggested fix**: the file's comment block says the hang is "most
  likely the HTTP/2 SETTINGS exchange" — open a tracked issue, link
  it from the test, and (in the meantime) add a unit-level test that
  exercises just `unaryExport` against a hand-crafted HTTP/2 mock
  rather than the full `client.call` path. At minimum, fail loud (not
  silent skip) so contributors notice.
- `confidence::confirmed`

---

### H7 — `Span.recordException` swallows allocation failures

- **File**: `/data/home/benji/src/devnw/zig/otel/src/api/trace.zig:194-207`
- **Snippet**:

  ```zig
  pub fn recordException(self: Span, message: []const u8, exception_type: []const u8, time_unix_nano: ?u64) !void {
      const s = self.state orelse return;
      if (!s.recording or s.ended) return;
      const child = s.arena.child_allocator;
      const arena = self.eventArena(s);
      const ev_attrs = arena.create(attrs.AttributeSet) catch return;
      ev_attrs.* = attrs.AttributeSet.init(child);
      ev_attrs.putString("exception.message", message) catch {};
      ev_attrs.putString("exception.type", exception_type) catch {};
      const t = time_unix_nano orelse posixNow(s.start_unix_nano);
      s.events.append(child, .{ .name = "exception", .time_unix_nano = t, .attributes = ev_attrs }) catch return;
  }
  ```

  Function is declared `!void` (errors propagate) but every fallible
  call inside is `catch {}` / `catch return`. The error union is
  cosmetic; callers cannot detect dropped exception records.
- **Why it matters**: silent telemetry loss on OOM / bookkeeping
  failures is the worst kind of silent failure for an observability
  library — the operator sees no signal when something is wrong with
  the SDK itself.
- **Suggested fix**: either remove the `!void` (commit to the
  fire-and-forget contract and bump the dropped-events counter on
  every swallowed failure) or actually propagate the inner errors.
  The same pattern repeats in `Span.setName`, `Span.setStatus` — pick
  one model and stick to it.
- `confidence::confirmed`

---

### H8 — Public API surface is undocumented (28+ symbols missing `///` in `api/trace.zig` alone)

- **Files**: `/data/home/benji/src/devnw/zig/otel/src/api/trace.zig` (Tracer,
  SpanKind, SpanOptions, StatusCode, Status, InstrumentationScope, Link,
  Event, Span, all without doc comments), and similar gaps in
  `src/api/metrics.zig` (Counter/UpDownCounter/Histogram/Gauge — no
  doc comments on public types or their methods),
  `src/api/logs.zig` (LogRecord/Body/Severity), `src/api/baggage.zig`
  (Baggage struct constructors), `src/sdk/export.zig` (SpanExporter
  vtable, SpanProcessor vtable).
- **Why it matters**: this is the **public API**. Library consumers
  cannot tell whether `Span.setStatus` is allowed on a non-recording
  span, whether `Counter.add` is thread-safe, what
  `Tracer.startSpanFn`'s lifetime contract is, etc. All of that
  information is implicit in the implementation.
- **Suggested fix**: add `///` doc comments on every `pub` type and
  method in `src/api/`. Mirror the format used in `internal/clock.zig`
  (which is documented well) and `internal/redact.zig`.
- `confidence::confirmed`

---

## Medium

### M1 — `redact.zig`: stale comment about Phase-1 "suspected unused" — module is actually wired

- **Files**: `/data/home/benji/src/devnw/zig/otel/tools/golden.zig:178`,
  `/data/home/benji/src/devnw/zig/otel/test/security.zig:8-19`
- **Why it matters**: the Phase 1 orientation flagged
  `internal/redact.zig` as suspected-unused. It's actually invoked from
  the `redaction` golden subcommand (`tools/golden.zig:178`) and
  exercised by `test/security.zig`. The module is **not** used by any
  production exporter, however — span/log/metric exports do not call
  `redact.maskString` before encoding. The redaction is thus only ever
  applied if the caller manually wraps every attribute, which defeats
  the purpose of the helper existing.
- **Suggested fix**: integrate `redact.maskString` into the JSON/proto
  encoders (`json_codec.writeValue`, `otlp_http.encodeSpansProto`) so
  sensitive keys are stripped at the wire boundary. Alternatively,
  document explicitly that redaction is opt-in via a wrapper attribute
  set the caller constructs.
- `confidence::confirmed`

---

### M2 — `internal/ring_buffer.zig` is dead code

- **File**: `/data/home/benji/src/devnw/zig/otel/src/internal/ring_buffer.zig:10-71`
- **Snippet**:

  ```zig
  pub fn RingBuffer(comptime T: type) type {
      // 100-line generic SPMC ring buffer
  }
  ```

  Header comment says: "Fixed-capacity SPMC ring buffer used by the
  batch span/log processors." Reality: `BatchSpanProcessor` uses
  `std.ArrayList(*trace_api.SpanState)` with a `std.mem.copyForwards`
  shift (`src/sdk/export.zig:251-260`); no caller imports
  `internal.ring_buffer`. `rg -n "ring_buffer|RingBuffer" src test`
  shows only the file's own tests and the re-export in `otel.zig:93`.
- **Why it matters**: the comment is misleading and a future
  contributor hunting for the buffer-vs-arraylist trade-off will
  follow the wrong trail. The file is also re-exported via
  `otel.internal.ring_buffer`, leaking dead surface.
- **Suggested fix**: either (a) actually use it in
  `BatchSpanProcessor` (avoids the O(n) shift on every drain), or
  (b) delete it and remove the re-export.
- `confidence::confirmed`

---

### M3 — `setActiveProvider` is a no-op compatibility shim that should be deleted

- **File**: `/data/home/benji/src/devnw/zig/otel/src/sdk/metrics.zig:375-378`
- **Snippet**:

  ```zig
  /// Compatibility shim retained for tests written against an earlier API.
  /// New code does not need to call this — the instrument carries its own
  /// provider pointer.
  pub fn setActiveProvider(_: *MeterProvider) void {}
  ```

  Used in two in-file tests (`metrics.zig:564,585`). Nothing else
  calls it.
- **Why it matters**: dead exported function. Future readers will
  wonder when to call it.
- **Suggested fix**: delete the function and the two stale test calls.
- `confidence::confirmed`

---

### M4 — Resource detectors (`envDetector`, `osDetector`, `processDetector`, `hostDetector`) have zero downstream tests or call sites

- **File**: `/data/home/benji/src/devnw/zig/otel/src/sdk/resource.zig:63-156`
- **Snippet**: four detector constructors plus a `compose` helper.
  `rg -n "envDetector|osDetector|processDetector|hostDetector|resource\.compose"`
  finds only the declarations themselves.
- **Why it matters**: the spec-mandated default resource composition is
  exposed but never exercised. Any breakage (e.g. `processDetector`
  using `std.os.linux.getpid()` is **Linux-only** and will fail to
  compile on macOS — a real risk given the CI matrix runs both) goes
  undetected.
- **Suggested fix**: add a tests in `test/` that walks each detector,
  asserts the produced attribute keys, and runs `compose` to verify
  ordering. Cross-check `processDetector` works on Darwin.
- `confidence::confirmed`

---

### M5 — `Context.withBaggage` writes through a `threadlocal` pin — non-obvious lifetime trap

- **File**: `/data/home/benji/src/devnw/zig/otel/src/api/context.zig:57-94`
- **Snippet**:

  ```zig
  pub fn withBaggage(self: Context, baggage: Baggage) Context {
      var c = self;
      c.baggage = &storageOf(baggage);   // borrows a threadlocal slot
      return c;
  }
  // ...
  threadlocal var pinned: ?Baggage = null;
  fn storageOf(b: Baggage) *const Baggage {
      pinned = b;                        // ⚠ overwrites previous pin
      return &pinned.?;
  }
  ```

- **Why it matters**: every call to `withBaggage(value)` clobbers the
  thread-local `pinned` slot, so two concurrent contexts on the same
  thread silently share the latest pin. The doc comment hints at this
  ("Test harnesses that rely on this should prefer `withBaggageRef`")
  but the bug is still callable from production code. Stack-allocated
  baggage handed to `withBaggage` and passed up the call stack will
  outlive its valid lifetime if the caller calls `withBaggage` again.
- **Suggested fix**: delete the `threadlocal pinned` mechanism; either
  (a) only accept `*const Baggage` (the existing `withBaggageRef` is
  fine), or (b) take an arena allocator and clone the baggage into it.
  Mark the threadlocal variant deprecated until it can be removed.
- `confidence::confirmed`

---

### M6 — Two retry loops with subtly different error categorisation

- **Files**: `/data/home/benji/src/devnw/zig/otel/src/exporters/otlp_http.zig:191-228`,
  `/data/home/benji/src/devnw/zig/otel/src/exporters/otlp_grpc.zig:87-120`
- **Snippet** (HTTP):

  ```zig
  switch (err) {
      error.ConnectionRefused, error.ConnectionResetByPeer, error.UnsupportedTransport, error.NetworkUnreachable => continue,
      else => return err,
  }
  ```

  gRPC adds `error.WouldBlock`. HTTP also has dedicated branches for
  status codes 207, 200–299, 400–499, 500+, 429; gRPC delegates to its
  own `GrpcStatus` enum. The two loops also diverge on
  `RetryPolicy.max_elapsed_ms` accounting (HTTP increments
  `elapsed_ms` on every retry; gRPC does too but the `attempt += 1`
  guard ordering differs).
- **Why it matters**: behavioural divergence between two transports
  for the same SDK is a spec drift risk. A future "retries are
  bounded to 5 attempts" policy change has to be applied in both
  places.
- **Suggested fix**: extract the retry loop into
  `sdk.export.retry(transport_call, policy)` and parameterise the
  retry-on / fail-on / partial categorisation. Hoist the `max_attempts`
  constant from both files into `RetryPolicy`.
- `confidence::confirmed`

---

### M7 — `OtlpHttpExporter` swallows `result.body` partial-success info

- **Files**: `/data/home/benji/src/devnw/zig/otel/src/exporters/otlp_http.zig:215-219,42-43,156-162`
- **Snippet**:

  ```zig
  if (result.status == 207) return error.PartialSuccess;
  // partial-success body is captured in self.last_response_body but
  // never inspected — the typed PartialSuccess error carries no payload.
  ```

  The exporter goes to the trouble of stashing `last_response_body`
  but the only way to read it is through the exporter handle after the
  call — and the OTLP partial-success body has structured
  `RejectedSpans` / `error_message` fields that callers never see.
- **Why it matters**: partial-success is the OTLP collector's primary
  back-pressure signal. Surfacing only `error.PartialSuccess` with no
  count means callers can't decide whether to retry, drop, or alert.
- **Suggested fix**: parse the body (it's a tiny protobuf:
  `int64 rejected_spans = 1; string error_message = 2`) and stash the
  parsed fields on the exporter; expose
  `lastPartialSuccess() ?PartialSuccessInfo` so callers can introspect.
- `confidence::confirmed`

---

### M8 — Tests are mostly happy-path; missing failure-mode coverage on key paths

- **Files**: `/data/home/benji/src/devnw/zig/otel/test/`, especially
  `metrics.zig`, `logs.zig`, `trace.zig`.
- **Specifics**:
  - `MeterProvider`: no test for the OOM path on a `pointFor` allocation
    failure (the in-file `counterAdd` returns silently on `catch return`).
  - `BatchSpanProcessor`: no test for the `dropped` counter incrementing
    when the queue overflows; `test/batch_async.zig` only verifies the
    happy path (200 spans, 4096 queue).
  - `OtlpHttpExporter`: covers retry-on-503 and 207, but no test for
    400-class permanent failures, no test for multi-batch ordering, no
    test for the JSON body structure beyond the `{"resourceSpans":[`
    prefix.
  - `Resource`: only `merge` and `defaultResource` are tested; the four
    detectors plus `compose` are not (see M4).
  - `Span.recordException`: no tests at all.
  - `LoggerProvider.forceFlush`: no test.
  - `BaggageFull`: tested in `api/baggage.zig` in-file but not in the
    external `test/baggage.zig`.
- **Why it matters**: 112 tests sounds like a lot, but they cluster
  around the encoding/aggregation paths and leave the failure-handling
  surface — exactly where bugs hide — uncovered.
- **Suggested fix**: add an `OutOfMemory`-failing allocator wrapper
  (`std.testing.FailingAllocator`) and run a sweep of the SDK init/
  emit/end paths through it. Add explicit "queue overflow drops with
  counter increment" coverage. Add a `BatchSpanProcessor.dropped`
  test parallel to the existing async test.
- `confidence::suspected` (the gaps are real; whether each gap has a
  latent bug requires running the proposed coverage).

---

### M9 — `applyEnv` reads env-var slices into a thread-local buffer that the caller assumes lives forever

- **Files**: `/data/home/benji/src/devnw/zig/otel/src/sdk/config.zig:122-217`
- **Snippet**:

  ```zig
  threadlocal var env_buf: [1024]u8 = undefined;
  threadlocal var env_len: usize = 0;
  fn envOrNull(name: []const u8) ?[]const u8 {
      // ...
      @memcpy(env_buf[0..raw.len], raw);
      env_len = raw.len;
      return env_buf[0..raw.len];
  }

  fn applyEnv(cfg: *Config) !void {
      // each subsequent envOrNull() call clobbers env_buf
      if (envOrNull("OTEL_EXPORTER_OTLP_ENDPOINT")) |v| {
          cfg.traces.otlp.endpoint = v;
          cfg.metrics.otlp.endpoint = v;
          cfg.logs.otlp.endpoint = v;        // v is a borrow into env_buf
      }
      if (envOrNull("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT")) |v|
          cfg.traces.otlp.endpoint = v;       // OVERWRITES env_buf — earlier
                                              // metrics/logs slices now point
                                              // at this string's bytes
      // ...
  ```

  Every `envOrNull` call clobbers the same thread-local buffer.
  Because `applyEnv` chains 12+ calls and stores the slices into the
  config, all-but-the-last config field point at corrupt memory.
- **Why it matters**: this is silently miscopying every environment
  variable except the last one read; the docstring on `envOrNull` warns
  about this but the caller (`applyEnv`) violates the warning. Tests
  pass because none of them set more than one env var at once.
- **Suggested fix**: pass an allocator down into `envOrNull` (or
  `applyEnv`) and `dupe` each value into the config. The thread-local
  scratch optimization isn't worth the lifetime risk.
- `confidence::confirmed`

---

### M10 — `applyYamlString` minimal YAML parser is fragile and silently truncates

- **Files**: `/data/home/benji/src/devnw/zig/otel/src/sdk/config.zig:222-287`
- **Snippet**: the hand-rolled parser only handles top-level mapping +
  one nesting level, splits on `:` (no quote handling on the key side),
  doesn't support multi-line strings, and silently `return`s on any
  unknown key.
- **Why it matters**: YAML files that work against the Go/Java OTel
  SDKs may silently produce empty configs here. The DevNW yaml backend
  (gated on `-Dotel_use_devnw_config`) is the spec-compliant path; the
  in-repo parser is a stop-gap that masks the gap.
- **Suggested fix**: either route every YAML through `devnw_yaml` (and
  document the build flag as required for declarative config), or
  swap the in-repo parser for a more strict implementation that
  errors on unknown keys instead of silently dropping them. At
  minimum, add a doc comment on the public `applyYamlString` listing
  the unsupported syntax.
- `confidence::confirmed`

---

## Low

### L1 — Naming consistency: snake_case fields vs camelCase methods (intentional, but worth a style note)

- **Files**: API surface uses snake_case for fields
  (`is_remote`, `start_unix_nano`, `trace_state`) and camelCase for
  methods (`startSpan`, `setStringAttribute`). This is the
  Zig convention, but a few outliers exist:
  - `IdGenerator.nextTraceIdFn` (camelCase function pointer field) —
    consistent with `Tracer.startSpanFn`.
  - `Counter.addFn`, `Histogram.recordFn`, `Gauge.setFn` (camelCase
    function pointer field).
  - `Recorder.spans` / `Recorder.metrics` / `Recorder.logs` — snake_case.
- **Why it matters**: the codebase is internally consistent on the
  rule "fields = snake_case unless function pointer, methods =
  camelCase". A short style note in CONTRIBUTING (or a top-of-file
  comment in `src/otel.zig`) would lock the contract in for new
  contributors.
- **Suggested fix**: document the convention. No code change.
- `confidence::confirmed`

---

### L2 — Hard-coded magic seeds and constants

- **Files**:
  - `/data/home/benji/src/devnw/zig/otel/src/exporters/otlp_http.zig:54`
    (`std.Random.DefaultPrng.init(0xC0DE_C0FFEE)`)
  - `/data/home/benji/src/devnw/zig/otel/src/exporters/otlp_grpc.zig:44`
    (same seed)
  - `/data/home/benji/src/devnw/zig/otel/src/sdk/trace.zig:163`
    (`id_mod.Random.init(0xC0DE_C0DE)`)
  - `/data/home/benji/src/devnw/zig/otel/src/sdk/export.zig:547`
    (`RetryPolicy.seed: u64 = 0xC0FFEE`, but PRNG is initialised at
    exporter scope, not from this seed — `seed` field is dead).
- **Why it matters**: deterministic PRNG seeds in retry jitter are bad
  for production (every collector reset triggers identical retry
  storms). The unused `RetryPolicy.seed` is dead config (M3-shaped).
- **Suggested fix**: seed the PRNG from `std.crypto.random.int(u64)` at
  exporter `init` time; honour `RetryPolicy.seed` if non-zero (test
  override). Same for the trace ID generator — `0xC0DE_C0DE` collides
  across processes.
- `confidence::confirmed`

---

### L3 — Many error sets duplicate the hoisted `otel.Error` set

- **Files**: `/data/home/benji/src/devnw/zig/otel/src/otel.zig:99-113`
  hoists `Error = error{ InvalidTraceParent, InvalidTraceState, ... }`,
  but each module defines and returns its own ad-hoc errors
  (`error.InvalidEndpoint`, `error.InvalidConfig`, `error.RetryExhausted`,
  `error.UnsupportedTransport`, etc.) rather than aliasing through
  `otel.Error.*`. The hoisted set is documentation only — Zig compiles
  the implicit error sets per function.
- **Why it matters**: callers can't `catch otel.Error.RetryExhausted`
  because `RetryExhausted` is in `error{...}` defined ad-hoc inside
  the function — the **identity** of the error tag matches by name,
  not by namespace, so `catch error.RetryExhausted` works either way.
  But the documentation contract (`otel.Error` is "one place to
  import from") is broken: a caller browsing `otel.Error` won't see
  `error.OutOfMemory`, which every fallible function actually returns.
- **Suggested fix**: either (a) make `otel.Error` an exhaustive
  reference set documented as "every error any pub function may
  return", and add the missing variants (`OutOfMemory`,
  `InvalidHex`, `InvalidTraceIdLength`, `InvalidSpanIdLength`,
  `BaggageFull`), or (b) delete `otel.Error` and let the implicit
  sets speak for themselves. The current half-state is misleading.
- `confidence::confirmed`

---

### L4 — `defer` on `arena.deinit` not paired with `errdefer` on partially-built provider state

- **Files**: `/data/home/benji/src/devnw/zig/otel/src/sdk/trace.zig:136-184`,
  `/data/home/benji/src/devnw/zig/otel/src/sdk/logs.zig:60-93`,
  `/data/home/benji/src/devnw/zig/otel/src/sdk/metrics.zig:141-164`
- **Snippet** (TracerProvider.init): the function allocates `resource`,
  then `random`, then `processors`. If the `processors` allocation
  fails, `random` and `resource` leak (no `errdefer` cleanup).
- **Why it matters**: out-of-memory during provider init leaks the
  partially-built state. The likelihood is low, but the fix is small
  and the consequence (leaked resource handles in long-running
  processes) compounds.
- **Suggested fix**: add `errdefer` cleanup branches that mirror the
  successful-path `deinit` ordering. Same fix shape across all three
  provider `init` functions.
- `confidence::suspected` (need to walk each branch with a failing
  allocator to confirm the leak shape).

---

### L5 — `tools/golden.zig` mixes two formatting styles for hex output

- **File**: `/data/home/benji/src/devnw/zig/otel/tools/golden.zig:79-95,142-150`
- **Snippet**: `runTraceContext` calls `id_mod.toHex` (returns a fixed
  array), then writes it byte-by-byte; `runSignals` rolls its own
  `writeHexBytes` helper that does the same alphabet lookup. Pick one.
- **Why it matters**: minor — a future refactor of `id_mod.toHex` may
  silently leave `writeHexBytes` behind.
- **Suggested fix**: hoist `writeHexBytes` to `internal.id` (or use
  `id_mod.toHex` everywhere) so the two paths stay in sync.
- `confidence::confirmed`

---

### L6 — `instrumentation/http.zig` uses a stack-local `name_buf` whose lifetime ends with the function

- **File**: `/data/home/benji/src/devnw/zig/otel/src/instrumentation/http.zig:26-34,48-52`
- **Snippet**:

  ```zig
  pub fn startClientSpan(...) {
      var name_buf: [256]u8 = undefined;
      const default_name = std.fmt.bufPrint(name_buf[0..], "{s}", .{req.method}) catch req.method;
      const span_name = req.span_name orelse default_name;
      const span = try tracer.startSpan(parent, span_name, .{ .kind = .client });
      ...
  }
  ```

  `default_name` borrows from `name_buf`, which is stack-allocated.
  `tracer.startSpan` (in `src/sdk/trace.zig:235`) eagerly dupes the
  name into its arena (`SpanState.init` → `allocator.dupe`), so this
  particular case is safe — but the pattern would silently break if
  `startSpan` ever stopped owning its name copy.
- **Why it matters**: low risk today, but the "stack-buf string passed
  into a constructor" pattern is one of the most common UAF traps in
  Zig. A doc comment on `Tracer.startSpan` documenting the ownership
  contract ("name is duped on entry") would prevent the next
  contributor from removing the dupe.
- **Suggested fix**: document the name-duping contract on
  `Tracer.startSpan`; consider replacing the stack buffer with a
  direct `tracer.startSpan(parent, req.method, ...)` call (the buffer
  serves no purpose since `bufPrint("{s}", req.method)` is just
  `req.method` again).
- `confidence::confirmed`

---

### L7 — `RetryPolicy.seed` is declared but never read

- **File**: `/data/home/benji/src/devnw/zig/otel/src/sdk/export.zig:542-548`
- **Snippet**:

  ```zig
  pub const RetryPolicy = struct {
      // ...
      seed: u64 = 0xC0FFEE,
  };
  ```

  `nextBackoff` takes a `prng: *std.Random.DefaultPrng` from the
  caller; `policy.seed` is never consulted.
- **Suggested fix**: delete the field, or actually use it
  (e.g. `nextBackoff` constructs its own PRNG from `policy.seed` if
  the caller didn't supply one).
- `confidence::confirmed`

---

### L8 — `LoggerProvider`/`MeterProvider`/`TracerProvider` `init`+`deinit` patterns are 90% identical

- **Files**: `/data/home/benji/src/devnw/zig/otel/src/sdk/trace.zig:136-195`,
  `/data/home/benji/src/devnw/zig/otel/src/sdk/logs.zig:60-103`,
  `/data/home/benji/src/devnw/zig/otel/src/sdk/metrics.zig:141-185`
- **Snippet**: each provider repeats the same "if config.resource is
  set borrow it, else create a default and remember to free it; if
  config.processors is non-empty dupe it, else if default_exporter is
  set wrap it in a Simple* processor, else allocate an empty slice"
  pattern, with three different concrete types substituted in.
- **Why it matters**: triple-maintenance burden; bug fixes (e.g. the
  errdefer issue in L4) have to be applied in all three places.
- **Suggested fix**: extract a `provider_helpers.makeProcessors(comptime P, ...)`
  - `makeOwnedResource(allocator, config) -> { *Resource, owns: bool }`.
  Even if the main bodies stay distinct, the resource-handling
  boilerplate is mechanical.
- `confidence::confirmed`

---

### L9 — `Severity.shortText` switches on 25 enum variants but maps them to 6 strings

- **Files**: `/data/home/benji/src/devnw/zig/otel/src/api/logs.zig:39-49`
- **Snippet**: `pub fn shortText(self: Severity) []const u8`. The
  switch lists every numbered variant (`trace`, `trace2`, `trace3`,
  `trace4`, ...) explicitly. A computed mapping
  (`return labels[(@intFromEnum(self) - 1) / 4]` with bounds check)
  would be 4 lines instead of 13.
- **Why it matters**: trivial — but adding a 25-arm prose list when
  the spec defines a clean grouping is a maintainability cost.
- **Suggested fix**: replace with the formula above; add a
  `comptime` assertion that the formula stays correct.
- `confidence::confirmed`

---

### L10 — `Span.addEvent` is gated behind `-Ddeprecated_span_events=true` but always present in the public API doc surface

- **Files**: `/data/home/benji/src/devnw/zig/otel/src/api/trace.zig:213-224`
- **Snippet**: `pub fn addEvent(...)` issues a `@compileError` when the
  flag is off. The function still appears in `pub` declarations
  scanned by `refAllDecls` and IDE autocomplete; the compile error
  fires only if a caller actually invokes it.
- **Why it matters**: doc generators (`zig build-obj -femit-docs`)
  will list the function; downstream IDEs will offer it. The error
  surface is also `@compileError`, which is harsh — soft-deprecating
  with a `@compileLog` warning would be friendlier.
- **Suggested fix**: gate the entire function declaration behind
  `if (build_options.deprecated_span_events)` so it disappears from
  the public surface when the flag is off; emit an honest
  `@deprecated` annotation when it's on.
- `confidence::confirmed`

---

## Notes On Build / CI Scope

- `zig fmt --check` over `src/`, `test/`, `tools/`, `examples/`,
  `build.zig`, `benchmarks/` is **clean** (exit 0, no output).
- No coverage instrumentation in CI; `zig test` doesn't emit
  coverage natively, and there's no `kcov` / `llvm-cov` wiring.
- TSan is wired (`-Dtsan=true`) but no CI job sets the flag.
- Fuzz target is suppressed (Zig 0.16 stdlib bug — see
  `test/security.zig:36-44`).
- Windows runners are zeroed (`rules: when: never`).
- The `bench` / `bench-micro` / `scale-bench` / `compare-bench` build
  steps are stubs aliased to `fmt_check` (see H5).
- `CODEOWNERS` is a placeholder per Phase 1 orientation.

---

## Summary Tables

### Lint/Format/Typecheck

| Tool | Command | Status | Findings |
|------|---------|--------|----------|
| `zig fmt` | `zig fmt --check src test tools examples build.zig benchmarks` | PASS | No drift |
| `zig build check` | `zig build check` | NOT RUN (out of scope; compile check only) | n/a |

### Duplication & Complexity

| Finding | File:Line | Metric | Confidence |
|---------|-----------|--------|------------|
| `writeStringValue` / `writeValue` / `valueToString` / `formatValue` duplicated 4× | prometheus.zig:146, in_memory.zig:171, json_codec.zig:166, sdk/metrics.zig:335 | 4 near-identical 8-line functions | confirmed |
| `noopShutdown` / `noopFlush` duplicated 5× | in_memory.zig:98, stdout_json.zig:37, file.zig:34, otlp_http.zig:165, otlp_grpc.zig:57 | 5× 1-line shims | confirmed |
| Provider init/deinit pattern duplicated 3× | sdk/trace.zig:136, sdk/logs.zig:60, sdk/metrics.zig:141 | ~50 LOC × 3 | confirmed |
| OTLP retry loop diverges between HTTP and gRPC | otlp_http.zig:191, otlp_grpc.zig:87 | ~40-line bodies, structurally identical with subtle differences | confirmed |
| `encodeSpansProto` (60 LOC, 5-deep nesting) | otlp_http.zig:230-289 | longest function in `otlp_http.zig` | confirmed |
| `encodeSpansProtoDevnw` (68 LOC) | otlp_http.zig:499-566 | parallel encoder for parity | confirmed |
| `applyEnv` (67 LOC) | sdk/config.zig:122 | flat 12-arm if-let chain | confirmed |
| `MeterProvider.collect` (59 LOC) | sdk/metrics.zig:499-557 | nested switches on instrument kind × value variant | confirmed |
| Files > 500 LOC | sdk/metrics.zig (605), exporters/otlp_http.zig (592), sdk/export.zig (569), sdk/config.zig (509), benchmarks/framework.zig (613) | size flag only | confirmed |

### Dead Code

| Finding | File:Line | Type | Confidence |
|---------|-----------|------|------------|
| `internal/ring_buffer.zig` not used in production pipeline | src/internal/ring_buffer.zig (whole file) | unused public module | confirmed |
| `setActiveProvider` is a no-op | src/sdk/metrics.zig:378 | dead pub fn (compat shim) | confirmed |
| `MetricExporter` / `MetricReader.collect` never invoked | src/sdk/export.zig:475, src/sdk/metrics.zig:44 | dead vtable surface | confirmed |
| `OtlpConfig.compression` never read | src/sdk/config.zig:52 | dead config field | confirmed |
| `OtlpConfig.skip_tls_verify` never read | src/sdk/config.zig:56 | dead config field | confirmed |
| `OtlpConfig.insecure` never read | src/sdk/config.zig:53 | dead config field | confirmed |
| `BatchSpanProcessorOptions.schedule_delay_ms` never read | src/sdk/export.zig:142 | dead config field | confirmed |
| `RetryPolicy.seed` never read | src/sdk/export.zig:547 | dead config field | confirmed |
| Resource detectors lack downstream tests | src/sdk/resource.zig:63-156 | untested (likely Linux-only) | confirmed |
| `redact` not integrated into export pipeline | src/internal/redact.zig | exported & tested but never wired into encoders | confirmed |
| `MetricProviderConfig.interval_ms` parsed but unused | src/sdk/config.zig:68 | parsed in 2 places, never consumed | confirmed |

### Performance Hotspots

| Finding | File:Line | Category | Impact | Confidence |
|---------|-----------|----------|--------|------------|
| `BatchSpanProcessor.drainLocked` uses `std.mem.copyForwards` shift after each drain | sdk/export.zig:251-260 | O(n) shift per drain | high under sustained load | confirmed |
| Every `counterAdd` / `udcAdd` / `histRecord` / `gaugeSet` re-sorts attributes by key for the cardinality lookup | sdk/metrics.zig:314-329 (called from each instrument-write path) | O(n log n) sort per write | high in hot loops | confirmed |
| `MeterProvider.pointFor` linearly scans `inst.points.items` to find the matching attribute set | sdk/metrics.zig:254-285 | O(p) per write, p = unique attribute combos | high once cardinality grows | confirmed |
| `attributeKey` allocates a new buffer on every metric write | sdk/metrics.zig:314 | per-write heap allocation | high; no per-write allocator pool | confirmed |
| Encoder paths allocate per-span temporary buffers (json_codec, prometheus.render) | json_codec.zig (whole), prometheus.zig:25-86 | per-span dupe + arena allocation | medium in batch exports | suspected |
| Stdout fallback shells out to `std.posix.write` per record without buffering | exporters/stdout_json.zig:46-50 | 2 syscalls per emitted record | high in hot pipes | confirmed |

### Build/CI Issues

| Finding | File:Line | Category | Impact | Confidence |
|---------|-----------|----------|--------|------------|
| `bench` / `bench-micro` / `scale-bench` / `compare-bench` aliased to `fmt_check` | build.zig:391-401 | dishonest CI signal | high | confirmed |
| `benchmarks/bench.zig` calls non-existent `lib.init` | benchmarks/bench.zig:55-71 | broken; compiles only because the build step skips it | high | confirmed |
| `test/grpc_loopback.zig` self-skips unconditionally | test/grpc_loopback.zig:31-32 | OTLP/gRPC has zero round-trip coverage | high | confirmed |
| Coverage instrumentation absent | n/a | dashboard | medium | confirmed |
| Fuzz target suppressed (stdlib bug) | test/security.zig:36-44 | fuzz coverage | medium | confirmed |
| TSan flag exists but no CI job consumes it | build.zig:12, ci configs | medium | medium | confirmed |
| Windows builds zeroed | gitlab-ci (per Phase 1) | platform coverage | medium | suspected |
| CODEOWNERS placeholder | per Phase 1 | governance | low | suspected |

---

## Phase 3 Inputs

The reviewer should focus on, in order:

1. **C1 + H5 + the bench step lie** — three ways the project signals
   "benchmarked, regressions caught" while doing nothing of the sort.
2. **C2 + M3 + the dead `MetricExporter` surface** — decide whether the
   metric pipeline is push, pull, or both, and remove the half-built
   alternatives.
3. **H1 + H7 + M5 + M9** — silent failures and lifetime traps that
   look fine in unit tests but break in production.
4. **H2 + H3 + L8** — duplication that will become a drift trap as
   soon as the next exporter or processor lands.
5. **H8** — the public API needs `///` doc comments before any
   external consumer can integrate confidently.

The auto-detected dead code (M2, M3, the dead `OtlpConfig` fields,
`RetryPolicy.seed`) can be cleaned up in a single PR with no behaviour
change. That's a low-risk way to shrink the surface before the
larger refactors above.
