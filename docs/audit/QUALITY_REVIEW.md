# Quality Review — Phase 3 Deep Dive

Phase 3 of the codepros audit. Inputs: `docs/audit/QUALITY_SCAN.md`
(31 findings — 3 Critical, 8 High, 10 Medium, 10 Low). This document
re-inspects every cited site, normalises the severity scoring against
a `PriorityScore = SeverityWeight × BlastRadius × FixConfidence`
formula, and recommends an execution order for Phase 4.

Severity weights: `Critical = 8`, `High = 4`, `Medium = 2`, `Low = 1`.
Blast Radius: `1` (isolated module / test only) → `3` (public API,
hot path, or wire-protocol drift). Fix Confidence: `1` (needs design
work) → `3` (mechanical edit, low blast-radius rewrite).

Verification methodology: each finding was re-read against the cited
file and any callers identified by `rg`. Confirmation status carries
forward from Phase 2 unless the deep read disagreed (none did — every
`confidence::confirmed` finding survives).

## Headline Reordering vs. Phase 2

Phase 2's narrative grouped findings by checklist category. The
PriorityScore reordering pulls the **C2 metric pipeline half-build**,
**H7 Span.recordException swallow**, and **C3 schedule_delay_ms
ignored** to the top because they combine high blast radius (public
API surface, OTel spec contracts) with mechanical or near-mechanical
fixes. The bench-scaffolding lies (C1, H5) drop to the second tier —
they erode CI signal but the fix is essentially "delete or rewrite a
script."

---

## Top 5 Findings — Specific Fix Recipes

The first five rows of the master ranking carry a complete recipe
(file:line, before/after snippets, verification step). The rest of
this document is the per-category review; the master ranking is the
last section.

### #1 — H7: `Span.recordException` swallows allocation failures (Reliability)

PriorityScore: `4 × 3 × 3 = 36`. Confidence: confirmed.

**Where**: `src/api/trace.zig:194-207`.

**Root cause**: the function signature is `!void` (claims to propagate
errors) but every fallible call inside the body uses `catch return` or
`catch {}`. Callers cannot detect dropped exception records, OOM, or
attribute-write failures. This is the most spec-toxic shape an
observability library can ship: silent telemetry loss with a
contract that lies about it.

**Before**:

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

**After** (commit to error propagation; matches the `!void`
signature and lets callers see OOM):

```zig
pub fn recordException(self: Span, message: []const u8, exception_type: []const u8, time_unix_nano: ?u64) !void {
    const s = self.state orelse return;
    if (!s.recording or s.ended) return;
    const child = s.arena.child_allocator;
    const arena = self.eventArena(s);
    const ev_attrs = try arena.create(attrs.AttributeSet);
    ev_attrs.* = attrs.AttributeSet.init(child);
    errdefer ev_attrs.deinit();
    try ev_attrs.putString("exception.message", message);
    try ev_attrs.putString("exception.type", exception_type);
    const t = time_unix_nano orelse posixNow(s.start_unix_nano);
    try s.events.append(child, .{ .name = "exception", .time_unix_nano = t, .attributes = ev_attrs });
}
```

(If the team prefers fire-and-forget, change the signature to `void`
*and* increment a `dropped_events` counter on every swallowed branch
— the current half-state is the worst of both options.)

While in the file, audit `Span.setName` (line 159) and `Span.setStatus`
(line 167) — both share the same swallow pattern but return `void`
honestly. Pick one model and apply it across all three.

**Verify**: add a test under `test/trace.zig` using
`std.testing.FailingAllocator` that drives `recordException` past the
fail threshold and asserts the propagated `error.OutOfMemory`.

---

### #2 — C2: Metric export pipeline is half-built (`MetricReader.collect` never invoked) (API contract / Reliability)

PriorityScore: `8 × 3 × 1 = 24`. Confidence: confirmed.

**Where**: `src/sdk/metrics.zig:38-47,166-200,499-557`,
`src/sdk/export.zig:475-492`, `src/exporters/in_memory.zig:89-91`,
`src/exporters/stdout_json.zig:28-30`.

**Root cause**: `MetricReader` exposes a `collectFn`, `forceFlushFn`,
`shutdownFn` triple, but `MeterProvider.deinit` (line 167) calls only
`shutdownFn`, `MeterProvider.forceFlush` (line 198) calls only
`forceFlushFn`, and **no code path** ever calls `collectFn`. The
`metricExporter()` constructors on `Recorder` and `StdoutJson` are
dead vtables — the SDK has no machinery that takes a `MetricExporter`
and drives it on a schedule.

**Decision required (design)**: pull or push?

- **Pull-only** (smallest blast-radius cleanup): delete
  `MetricReader.collect`, delete `MetricExporter`, delete
  `Recorder.metricExporter` / `StdoutJson.metricExporter`. Document
  metrics as "caller invokes `sdk.metrics.collect()` then serializes
  the returned slice." Keep `forceFlushFn` for the spec-required
  `MeterProvider.forceFlush` semantics.
- **Push (spec-aligned)**: add a `PeriodicExportingMetricReader`
  (OTel's official name) that owns a worker, calls
  `sdk.metrics.collect()` then `exporter.exportMetrics()` on each
  `interval_ms`. Reuse the `tp.ThreadPool` plumbing already gated
  behind `-Dotel_use_devnw_pool` (see `src/sdk/export.zig:155`).
  This also gives `MetricProviderConfig.interval_ms`
  (`src/sdk/config.zig:68`, currently dead) a consumer.

**Recommended**: do **push** so the OTel declarative config schema's
`metric_readers.periodic { interval, exporter }` block actually does
something. Sketch:

```zig
// new file: src/sdk/metric_reader.zig (or hoist into sdk/metrics.zig)
pub const PeriodicExportingMetricReader = struct {
    allocator: std.mem.Allocator,
    exporter: exp.MetricExporter,
    interval_ns: u64,
    pool: ?*tp.ThreadPool = null,
    stop: std.atomic.Value(bool) = .{ .raw = false },

    pub fn reader(self: *@This()) MetricReader {
        return .{
            .ctx = self,
            .collectFn = collectAndExport,
            .forceFlushFn = forceFlush,
            .shutdownFn = shutdown,
        };
    }

    fn collectAndExport(ctx: ?*anyopaque, alloc: std.mem.Allocator, provider: *MeterProvider) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        const datas = try sdk_metrics.collect(provider, alloc);
        defer freeMetricSlice(alloc, datas);
        _ = try self.exporter.exportMetrics(datas);
    }
    // ... forceFlush / shutdown
};
```

Wire `MeterProvider.forceFlush` and a new `MeterProvider.collectAll`
to call `r.collectFn`. Tear down the worker on `MeterProvider.deinit`
(it already calls `shutdownFn`).

**Verify**: add `test/metrics_periodic_reader.zig` with a fake
`MetricExporter` whose `exportFn` increments a counter on each call,
sleep ~3× interval, assert ≥ 2 invocations. Add a second test that
proves `MeterProvider.deinit` drains pending exports.

---

### #3 — C3: `BatchSpanProcessorOptions.schedule_delay_ms` is silently ignored (Reliability)

PriorityScore: `8 × 2 × 2 = 32`. Confidence: confirmed.

**Where**: `src/sdk/export.zig:139-148,343-378,380-428`. `rg
"schedule_delay_ms"` returns exactly the declaration site — no read.

**Root cause**: `batchOnEnd` only flushes when
`queue.items.len >= max_export_batch_size` or when `forceFlush` is
called. Low-volume telemetry can sit in the queue indefinitely.

**Before** (the synchronous drain branch in `batchOnEnd`):

```zig
const should_flush = self.queue.items.len >= self.options.max_export_batch_size;
self.mutex.unlock();
if (!should_flush) return;
// drain
```

**After** (track last-flush time; drain on EITHER trigger):

```zig
// Add to BatchSpanProcessor struct:
last_flush_ns: i128 = 0,

// in batchOnEnd, after enqueue:
const now_ns = clock_mod.unixNanoNow();
const stale = (now_ns - self.last_flush_ns) >= @as(i128, self.options.schedule_delay_ms) * std.time.ns_per_ms;
const should_flush = self.queue.items.len >= self.options.max_export_batch_size or stale;
// (record self.last_flush_ns = now_ns inside drain branch)
```

For the pool-on path (`-Dotel_use_devnw_pool=true`), spawn a periodic
`tp.clock.sleep`-driven task in `init` that calls
`async_pool.submitDrain(self)` every `schedule_delay_ms`. This
matches the design choice in C2 above — both signals share one
periodic-scheduler primitive.

If the team would rather defer the timer-driven path, **change the
field doc comment to "best-effort, only honoured when async_workers
> 0; spec-mandated periodic drain is tracked in #N"** so the contract
is honest. The current state of "doc says it works, code ignores it"
is the worst of all worlds.

**Verify**: in `test/batch_async.zig`, set
`schedule_delay_ms = 50`, push a single span, sleep 200 ms, assert
the exporter received it. The current test would fail until the fix
lands.

---

### #4 — H1: `OtlpConfig.compression` and `skip_tls_verify` (and `insecure`) are dead config fields (API contract / Reliability)

PriorityScore: `4 × 3 × 2 = 24`. Confidence: confirmed.

**Where**: `src/sdk/config.zig:47-57`,
`src/exporters/otlp_http.zig:108-163`,
`src/exporters/otlp_grpc.zig:38-46`. `rg "config\.compression\|skip_tls_verify\|config\.insecure"`
in `src/exporters` returns nothing.

**Root cause**: callers wiring `OTEL_EXPORTER_OTLP_COMPRESSION=gzip`
(spec-mandated env var) get zero bandwidth reduction;
`skip_tls_verify=true` against a self-signed dev collector silently
fails closed. Both are listed in the OTel env-var spec, both are
parsed into `OtlpConfig`, neither is ever consumed.

**Minimal fix** (compression):

```zig
// In httpTransportImpl, after building `body`:
const final_body = switch (self.config.compression) {
    .none => body,
    .gzip => blk: {
        var compressed: std.ArrayList(u8) = .empty;
        defer compressed.deinit(allocator);
        var input = std.io.fixedBufferStream(body);
        try std.compress.gzip.compress(input.reader(), compressed.writer(allocator), .{});
        try headers_list.append(allocator, .{ .name = "content-encoding", .value = "gzip" });
        break :blk try compressed.toOwnedSlice(allocator);
    },
};
```

(API names approximate — Zig 0.16's gzip helpers shifted; verify
against `std.compress.gzip` at build time.)

**Minimal fix** (`skip_tls_verify`): until `std.http.Client` exposes
a stable knob for "accept any cert", at minimum **fail loud at
`init`** if `skip_tls_verify=true` and we cannot honour it:

```zig
pub fn init(allocator: std.mem.Allocator, config: OtlpConfig) !OtlpHttpExporter {
    if (config.endpoint.len == 0) return error.InvalidEndpoint;
    if (config.skip_tls_verify) {
        // Either implement against std.http.Client.Connection.tls or
        // refuse the configuration so the caller knows their flag is
        // ignored.
        return error.InvalidConfig;
    }
    // ...
}
```

**Quickest contract repair** (no implementation): tag the unused
fields with a `///` doc comment ("not yet honoured — tracked in #N
— prefer the OTLP collector for compression / dedicated TLS
relaxation"). Promote that to a hard warning at `OtlpHttpExporter.init`
that returns `error.InvalidConfig` if either flag is set non-default
without an implementation.

**Verify**: add `test/otlp.zig` cases: (a) compression=`gzip` →
content-encoding header present and body shorter than uncompressed.
(b) skip_tls_verify=`true` + `init` → either succeeds with the knob
honoured, or returns `InvalidConfig` (whichever path the team chose).

---

### #5 — H2: 4-way duplication of attribute-value formatting silently drops arrays (API contract / Maintainability)

PriorityScore: `4 × 3 × 2 = 24`. Confidence: confirmed.

**Where**:

- `src/exporters/prometheus.zig:146-154` (`writeStringValue`)
- `src/exporters/in_memory.zig:171-179` (`valueToString`)
- `src/sdk/metrics.zig:335-351` (`formatValue`)
- `src/internal/json_codec.zig:166-174` (`writeValue`)

**Root cause**: every exporter reimplements the same five-arm switch
on `attrs.Value`. Three of them collapse arrays to the literal
string `"<array>"`; `json_codec.writeValue` collapses to `null`. So:

- a span attribute `.string_array` shows up as `"<array>"` in the
  in-memory recorder, Prometheus, and Prometheus label values;
- the same attribute shows up as `null` in stdout JSON / file JSONL;
- the OTLP wire path may eventually emit it correctly — at which
  point the four backends silently disagree.

This is a **spec-compliance bug** (array attributes are part of the
OTel data model) wrapped inside a **maintainability bug** (one fix
must be applied four times).

**Recipe** — hoist a single helper into
`src/internal/attributes.zig`:

```zig
/// Append a textual representation of `v` to `buf`. `array_separator`
/// joins multi-value attributes (`,` for Prometheus, `;` for
/// human-readable contexts). For full-fidelity JSON or protobuf
/// serialization, use the dedicated codec instead — this helper is
/// for label / debug output where loss of nesting is acceptable.
pub fn appendValueText(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    v: Value,
    array_separator: u8,
) !void {
    switch (v) {
        .string => |s| try buf.appendSlice(allocator, s),
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .int => |i| try buf.writer(allocator).print("{d}", .{i}),
        .double => |d| try buf.writer(allocator).print("{d}", .{d}),
        .string_array => |arr| {
            for (arr, 0..) |s, i| {
                if (i > 0) try buf.append(allocator, array_separator);
                try buf.appendSlice(allocator, s);
            }
        },
        .int_array => |arr| {
            for (arr, 0..) |x, i| {
                if (i > 0) try buf.append(allocator, array_separator);
                try buf.writer(allocator).print("{d}", .{x});
            }
        },
        // ... double_array, bool_array
    }
}
```

Then:

- `prometheus.writeStringValue` → `attrs.appendValueText(allocator, buf, v, ',')`
- `in_memory.valueToString` → wrap `appendValueText` to return owned `[]u8`
- `metrics.formatValue` → call `appendValueText(... '|')` (the
  attribute-key builder uses `|` as the entry delimiter; pick a
  different separator for the array values)
- `json_codec.writeValue` keeps its own JSON-escaping path (arrays
  serialize to a real JSON array — that's a separate, codec-aware
  case)

**Verify**: extend `test/trace.zig` with a span carrying
`.string_array = &.{ "a", "b" }`, route it through each exporter,
assert the array is preserved (or, where lossy, that the documented
separator is used — never the placeholder `<array>`).

---

## Readability & Maintainability

| # | Finding | File:Line | Root Cause | Impact | Confidence |
|---|---------|-----------|------------|--------|------------|
| H2 | 4-way duplication of attribute formatting; arrays collapse to `<array>` / `null` | `src/exporters/prometheus.zig:146`, `src/exporters/in_memory.zig:171`, `src/sdk/metrics.zig:335`, `src/internal/json_codec.zig:166` | Each exporter ships its own switch; arrays unsupported across all four | Silent attribute fidelity loss; 4× drift surface | confirmed |
| H3 | Duplicate noop/shutdown shims across 5 exporters | `src/exporters/in_memory.zig:98-99`, `stdout_json.zig:37-38`, `file.zig:34-42`, `otlp_http.zig:165-170`, `otlp_grpc.zig:57-62` | No shared helper in `sdk/export.zig` | Adding a vtable slot needs 5 edits | confirmed |
| H4 | `parseGrpcEndpoint`-style scheme strip duplicated between OTLP HTTP and gRPC | `otlp_grpc.zig:132-150`, `otlp_http.zig:115-117` | No `internal.endpoint.parse()` helper | URL-parse rules drift; HTTP requires scheme, gRPC doesn't | confirmed (drift is structural; behavioural divergence suspected) |
| L8 | TracerProvider/MeterProvider/LoggerProvider init/deinit are 90% identical | `src/sdk/trace.zig:136-195`, `logs.zig:60-103`, `metrics.zig:141-185` | Resource ownership + processor selection pattern copy-pasted 3× | Bug fixes (e.g. errdefer, L4) need 3 edits | confirmed |
| L1 | snake_case vs camelCase convention undocumented | API surface (`api/`, `sdk/`) | Convention is consistent; no contributor doc | Style bikeshed risk | confirmed |
| L9 | `Severity.shortText` 25-arm switch maps to 6 strings | `src/api/logs.zig:39-49` | Computed mapping would be 4 lines | Trivial maintainability cost | confirmed |
| L5 | `tools/golden.zig` mixes two hex-output styles | `tools/golden.zig:79-95,142-150` | `id_mod.toHex` vs hand-rolled `writeHexBytes` | Refactor of `id.toHex` will leave the other behind | confirmed |
| L6 | `instrumentation/http.zig` stack-buf passed into `tracer.startSpan` (safe today, fragile pattern) | `src/instrumentation/http.zig:26-34,48-52` | `startSpan` dupes — but the contract is implicit | Future regression of dupe contract → UAF | confirmed |
| M10 | Hand-rolled YAML parser is fragile and silently truncates | `src/sdk/config.zig:222-287` | Single-level nesting, splits on `:` without quote handling | YAML configs from Java/Go SDKs may produce empty configs here | confirmed |

**Notes**:

- The H2/H3/L8 cluster is the maintenance-debt hotspot. After the H2
  fix lands, H3 and L8 become near-mechanical — both essentially ask
  "extract a shared helper from N copies." Bundle them in one PR if
  scheduling allows.
- L9 is the cheapest finding in the entire scan (4-line patch). Use
  it as a warm-up commit if a contributor needs an entry point.
- M10 is the only readability finding with a real failure mode — the
  hand-rolled YAML parser silently produces wrong configs for valid
  inputs. Either route every YAML through the DevNW backend (gated
  on `-Dotel_use_devnw_config`) or harden the in-repo parser to
  reject unknown keys instead of silently dropping them.

---

## API & Contract Consistency

| # | Finding | File:Line | Root Cause | Impact | Confidence |
|---|---------|-----------|------------|--------|------------|
| C2 | `MetricReader.collect` vtable never invoked; `metricExporter()` constructors are dead | `src/sdk/metrics.zig:38-47,166-200`, `src/sdk/export.zig:475-492` | No `PeriodicExportingMetricReader`; pull/push contract is half-built | Public extension point lies; OTLP metrics export not pluggable | confirmed |
| C3 | `BatchSpanProcessorOptions.schedule_delay_ms` declared but never read | `src/sdk/export.zig:139-148` | Periodic drain not implemented | Spec-mandated periodic flush silently disabled; low-volume telemetry stalls | confirmed |
| H1 | `OtlpConfig.compression` / `skip_tls_verify` / `insecure` parsed but ignored | `src/sdk/config.zig:47-57`, `src/exporters/otlp_http.zig:108-163` | Exporter never consumes | Spec env-vars silently no-op; bandwidth + TLS contracts violated | confirmed |
| H8 | 28+ public symbols in `api/trace.zig` (and equivalents in `api/metrics.zig`, `api/logs.zig`, `api/baggage.zig`, `sdk/export.zig`) lack `///` docs | `src/api/trace.zig` (entire file), `src/api/metrics.zig:36-115`, `src/api/logs.zig` | No doc-comment discipline on the public surface | External integrators cannot tell thread-safety / lifetime / spec semantics | confirmed |
| M3 | `setActiveProvider` is a no-op compatibility shim (only used by 2 in-file tests) | `src/sdk/metrics.zig:375-378` | Legacy of an earlier API | Dead exported function; future readers will wonder when to call | confirmed |
| L3 | `otel.Error` documents a small set; modules return ad-hoc errors not aliased through it | `src/otel.zig:99-113` | Convention mismatch | "One place to import errors" is misleading | confirmed |
| L7 | `RetryPolicy.seed` declared but never read (PRNG initialised at exporter scope) | `src/sdk/export.zig:542-548` | Structural mismatch with `nextBackoff` callers | Dead config field | confirmed |
| L10 | `Span.addEvent` `@compileError`-gated but still appears in public docs | `src/api/trace.zig:213-224` | `@compileError` body, declaration always present | IDE / generated docs offer a function that fails to compile | confirmed |
| M2 | `internal/ring_buffer.zig` re-exported on `otel.internal.ring_buffer` but no production caller; comment claims it's used by the batch processor | `src/internal/ring_buffer.zig:1-71`, `src/otel.zig:93` | Dead code with misleading provenance | Public surface lies; future contributors follow the wrong trail | confirmed |
| M7 | OTLP partial-success body parsed into `last_response_body` but no accessor / no typed payload | `src/exporters/otlp_http.zig:215-219,42-43,156-162` | Field exposed but contract isn't | Operators can't decide retry vs alert vs drop | confirmed |

**Notes**:

- C2 is the structural cleanup that unlocks several other items
  (M3's `setActiveProvider`, M2's `ring_buffer`, the
  `MetricProviderConfig.interval_ms` dead field). Pick the
  push-vs-pull design once, then sweep everything tied to it.
- H8 is the largest doc gap — the public API has zero `///` lines on
  the most-touched types (`Span`, `Tracer`, `Counter`, `Histogram`).
  This blocks any external integrator from reasoning about
  thread-safety, allocation behaviour, or recording semantics.
- L7 (dead `RetryPolicy.seed`) and the dead `OtlpConfig` fields
  (H1) cluster nicely with `setActiveProvider` (M3) and
  `MetricProviderConfig.interval_ms` (Phase 2 dead-code table) —
  one mechanical "delete dead config fields and shims" PR can land
  them all.

---

## Reliability Enablers

| # | Finding | File:Line | Root Cause | Impact | Confidence |
|---|---------|-----------|------------|--------|------------|
| H7 | `Span.recordException` swallows allocation errors despite `!void` signature | `src/api/trace.zig:194-207` | `catch return` / `catch {}` everywhere; same shape in `setName`, `setStatus` | Silent telemetry loss with a contract that lies | confirmed |
| H6 | `test/grpc_loopback.zig` self-skips unconditionally | `test/grpc_loopback.zig:31-32` | grpc-zig HTTP/2 deadlock not yet root-caused | OTLP/gRPC has zero round-trip coverage | confirmed |
| C1 | `benchmarks/bench.zig` calls non-existent `lib.init(.{})` | `benchmarks/bench.zig:55-71` | Template scaffolding not adapted to actual API | Hard compile failure for any contributor running `zig build bench` | confirmed |
| H5 | `bench` / `bench-micro` / `scale-bench` / `compare-bench` CI steps aliased to `fmt_check` | `build.zig:391-401` | Stub gating; CI dashboard reports "passed" | Benchmark regressions never caught | confirmed |
| M1 | `redact.maskString` exists and is exercised by `tools/golden.zig` + `test/security.zig` but not wired into any production exporter | `tools/golden.zig:178`, `test/security.zig:8-19`, `src/exporters/*` | No call from `json_codec.writeValue` / `otlp_http.encodeSpansProto` | Redaction is opt-in via caller-side wrapping → defeats the helper | confirmed |
| M4 | Resource detectors (`envDetector`, `osDetector`, `processDetector`, `hostDetector`) zero downstream tests; `processDetector` is Linux-only (`std.os.linux.getpid()`) | `src/sdk/resource.zig:63-156` | No coverage; macOS CI matrix runs them via `compose` but `compose` itself is never tested | Likely hard build failure on macOS once `compose` is invoked | confirmed (build break on Darwin: very likely) |
| M5 | `Context.withBaggage` writes through a `threadlocal pinned: ?Baggage`; second call clobbers the first | `src/api/context.zig:57-94` | Optimisation that doesn't survive concurrent use | Stack-allocated baggage handed up the call stack outlives its valid lifetime | confirmed |
| M6 | OTLP/HTTP and OTLP/gRPC retry loops diverge on retry-on errors and elapsed-time accounting | `src/exporters/otlp_http.zig:191-228`, `src/exporters/otlp_grpc.zig:87-120` | No shared retry helper | Future spec changes have to be applied 2× | confirmed |
| M8 | Tests are happy-path heavy; no FailingAllocator sweep, no overflow drop counter test, no 4xx test, no `recordException` test | `test/` (multiple files) | No discipline around failure-path coverage | Failure-handling bugs hide | confirmed (specifics suspected; gaps are confirmed) |
| M9 | `applyEnv` borrows env-var slices into a thread-local buffer that the next call clobbers | `src/sdk/config.zig:122-217` | `envOrNull` borrows + `applyEnv` chains 12+ calls + stores into config | All-but-the-last config field points at corrupt memory | confirmed |
| L2 | Hard-coded magic seeds (`0xC0DE_C0FFEE`, `0xC0DE_C0DE`) in PRNG init; `RetryPolicy.seed` dead | `src/exporters/otlp_http.zig:54`, `otlp_grpc.zig:44`, `src/sdk/trace.zig:163` | Deterministic seeds across processes | Retry-storm collisions across collector restarts; trace ID collisions | confirmed |
| L4 | Provider `init` lacks `errdefer` cleanup on partially-built state | `src/sdk/trace.zig:136-184`, `logs.zig:60-93`, `metrics.zig:141-164` | OOM mid-init leaks resource + random | Long-running processes accumulate leaks under memory pressure | suspected (needs FailingAllocator sweep) |

**Notes**:

- H7 + M5 + M9 are the three "silent failure" findings most likely
  to surface as production weirdness. M9 in particular is a
  confirmed UAF/stale-slice bug — every config field except the last
  one read points at corrupt memory once a second env-var read
  happens. The fact that tests don't catch it is itself the bug
  (M8): no test sets two env vars at once.
- M4's macOS risk deserves immediate verification: try to compile
  `processDetector` on Darwin (or wrap `getpid` behind
  `@import("builtin").os.tag == .linux` immediately as a defensive
  measure). The Phase 2 scan flagged this but didn't run the
  experiment.
- C1 (broken bench file) and H5 (stubbed CI steps) are the same
  underlying problem: the benchmark surface was scaffolded from
  zig-template and never re-pointed at the actual public API. Pair
  the fixes.

---

## Documentation Gaps

| # | Finding | File:Line | What's Missing | Impact | Confidence |
|---|---------|-----------|----------------|--------|------------|
| H8 | Public API surface lacks `///` doc comments | `src/api/trace.zig` (entire file), `src/api/metrics.zig:36-115`, `src/api/logs.zig`, `src/api/baggage.zig`, `src/sdk/export.zig` (vtables) | No semantic docs on `Span`, `Tracer`, `Counter`, `Histogram`, `LogRecord`, `SpanExporter`, `SpanProcessor` | External integrators cannot tell thread-safety / lifetime / recording rules | confirmed |
| L1 | No CONTRIBUTING note on naming convention | `CONTRIBUTING` (n/a), `src/otel.zig` | snake_case-fields / camelCase-methods convention undocumented | Style drift in new contributions | confirmed |
| L6 | `Tracer.startSpan` ownership contract (name is duped on entry) is undocumented | `src/api/trace.zig:245`, `src/sdk/trace.zig:235` | No `///` comment stating the dupe contract | Future refactor that drops the dupe = UAF | confirmed |
| M2 | `internal/ring_buffer.zig` doc comment claims the batch processor uses it; reality says no | `src/internal/ring_buffer.zig:1-7` | Stale provenance comment | Misleads contributors into thinking the buffer is the active queue | confirmed |
| H6 | `test/grpc_loopback.zig`'s skip is documented in code but no tracked issue link | `test/grpc_loopback.zig:1-30` | `// TODO`-style comment without an issue tracker reference | "Will fix later" rot | confirmed |
| H1 | Dead `OtlpConfig.compression` / `skip_tls_verify` / `insecure` lack "not yet honoured" doc | `src/sdk/config.zig:47-57` | Field comments don't disclaim the missing implementation | Callers wire spec env vars expecting bandwidth / dev-cert relaxation | confirmed |
| C3 | Same disclaimer missing on `BatchSpanProcessorOptions.schedule_delay_ms` | `src/sdk/export.zig:139-148` | No `///` warning on the dead field | Same false-confidence shape as H1 | confirmed |
| M10 | `applyYamlString` syntax limitations not documented at the public-fn level | `src/sdk/config.zig:222-287` | No `///` listing the unsupported YAML features | Configs that work elsewhere silently produce empty configs here | confirmed |
| M3 | `setActiveProvider` doc comment says "compat shim" but the shim itself is dead | `src/sdk/metrics.zig:375-378` | Comment + dead pub fn | Future readers wonder when to call it | confirmed |
| M1 | `internal/redact.zig` is integrated nowhere downstream; spec compliance doc doesn't disclose this | `src/internal/redact.zig`, `docs/SPEC_COMPLIANCE.md` | No "redaction is opt-in" disclaimer | Operators may assume PII is auto-stripped at the wire | confirmed |

**Notes**:

- H8 is a 1-PR sweep (mechanical: add `///` lines per type/method)
  worth scheduling early — every later refactor cites the doc as
  the contract being preserved.
- The "field-doc disclaimers for unimplemented features" pattern
  (H1, C3, M3) is the cheapest reliability win in the entire scan:
  if the team is not ready to implement, at least make the contract
  honest.

---

## Master Ranking (PriorityScore Descending)

| Rank | ID | Title | Severity | Blast | FixConf | Score |
|------|----|-------|----------|-------|---------|-------|
| 1 | H7 | `Span.recordException` swallows alloc failures | High (4) | 3 | 3 | **36** |
| 2 | C3 | `BatchSpanProcessorOptions.schedule_delay_ms` ignored | Critical (8) | 2 | 2 | **32** |
| 3 | C2 | `MetricReader.collect` / `MetricExporter` never invoked | Critical (8) | 3 | 1 | **24** |
| 4 | H1 | `OtlpConfig.compression` / `skip_tls_verify` / `insecure` dead | High (4) | 3 | 2 | **24** |
| 5 | H2 | 4× attribute formatting; arrays silently dropped | High (4) | 3 | 2 | **24** |
| 6 | H8 | Public API surface lacks `///` docs | High (4) | 3 | 2 | **24** |
| 7 | C1 | `benchmarks/bench.zig` calls non-existent `lib.init` | Critical (8) | 1 | 3 | **24** |
| 8 | M9 | `applyEnv` thread-local-buffer aliasing corrupts config | Medium (2) | 3 | 3 | **18** |
| 9 | H5 | `bench`/`scale-bench`/`compare-bench` aliased to `fmt_check` | High (4) | 2 | 2 | **16** |
| 10 | H6 | `test/grpc_loopback.zig` self-skips unconditionally | High (4) | 2 | 2 | **16** |
| 11 | M5 | `Context.withBaggage` thread-local lifetime trap | Medium (2) | 3 | 2 | **12** |
| 12 | H3 | Duplicate noop/shutdown shims across 5 exporters | High (4) | 1 | 3 | **12** |
| 13 | M6 | OTLP/HTTP vs OTLP/gRPC retry loops diverge | Medium (2) | 2 | 2 | **8** |
| 14 | M4 | Resource detectors untested; processDetector Linux-only | Medium (2) | 2 | 2 | **8** |
| 15 | M7 | OTLP partial-success body inaccessible to callers | Medium (2) | 2 | 2 | **8** |
| 16 | M1 | `redact` not wired into export pipeline | Medium (2) | 2 | 2 | **8** |
| 17 | H4 | OTLP HTTP/gRPC scheme-strip duplicated | High (4) | 1 | 2 | **8** |
| 18 | L8 | Provider init/deinit duplicated 3× | Low (1) | 2 | 3 | **6** |
| 19 | M8 | Tests cluster on happy paths; no FailingAllocator sweep | Medium (2) | 2 | 1 | **4** |
| 20 | M10 | `applyYamlString` silently truncates unknown keys | Medium (2) | 2 | 1 | **4** |
| 21 | M2 | `internal/ring_buffer.zig` is dead code | Medium (2) | 1 | 2 | **4** |
| 22 | M3 | `setActiveProvider` no-op shim | Medium (2) | 1 | 3 | **6** |
| 23 | L2 | Hard-coded PRNG seeds; `RetryPolicy.seed` dead | Low (1) | 2 | 2 | **4** |
| 24 | L4 | Provider `init` lacks `errdefer` on partial state | Low (1) | 2 | 2 | **4** |
| 25 | L3 | `otel.Error` set incomplete relative to actual returns | Low (1) | 2 | 2 | **4** |
| 26 | L7 | `RetryPolicy.seed` field never read | Low (1) | 1 | 3 | **3** |
| 27 | L10 | `Span.addEvent` `@compileError` while present in public surface | Low (1) | 1 | 3 | **3** |
| 28 | L9 | `Severity.shortText` 25-arm switch | Low (1) | 1 | 3 | **3** |
| 29 | L6 | `instrumentation/http.zig` stack-buf pattern (safe today) | Low (1) | 1 | 2 | **2** |
| 30 | L5 | `tools/golden.zig` mixes hex output styles | Low (1) | 1 | 2 | **2** |
| 31 | L1 | snake_case vs camelCase undocumented | Low (1) | 1 | 1 | **1** |

**Tier breakpoints**:

- **Tier 1 (Score ≥ 24)**: 7 findings. These are the deep-review
  recipes. Sequence: H7 (mechanical, blocks honest API contract) →
  C3 (mechanical timer wiring; spec compliance) → C2 (design call:
  push or pull, then sweep) → H1 (compression + TLS) → H2 (shared
  attribute formatter) → H8 (`///` doc sweep) → C1 (delete or
  rewrite the bench file).

- **Tier 2 (Score 12–18)**: 5 findings. M9 (env-buffer aliasing) is
  the only confirmed memory-corruption bug in the codebase and
  belongs near the top of Tier 2 despite being a Medium. H5 (CI lie),
  H6 (gRPC test skip), M5 (baggage threadlocal trap), and H3
  (exporter shim duplication) round out the tier.

- **Tier 3 (Score 6–8)**: 7 findings. Cluster the dead-code/dead-
  field cleanup (M3 + M7 + L7 + the unused `OtlpConfig` fields
  already covered by H1) into one PR. Land the M1 redaction wiring
  alongside H2's attribute formatter — both touch the same JSON /
  proto codec entry points.

- **Tier 4 (Score ≤ 4)**: 12 findings. Quality-of-life cleanup;
  schedule when contributors need warm-up commits.

---

## Phase 4 Handoff (quality-issue-tracker inputs)

The following items should each become a tracked issue in Phase 4,
with the tier-1 set tagged `priority::1` and recipes carried over
verbatim:

1. H7 — recordException swallow → fix per recipe #1
2. C3 — schedule_delay_ms wiring → fix per recipe #3 (or
   contract-honest doc per fallback)
3. C2 — metric pipeline design + PeriodicReader → fix per recipe #2
4. H1 — OtlpConfig.compression + skip_tls_verify → fix per recipe #4
5. H2 — single attribute-value formatter + array support → fix per
   recipe #5
6. H8 — public API `///` doc sweep
7. C1 + H5 — repair or delete benchmark surface; fix CI step
   aliasing

Tier-2 issues (M9, H6, M5, H3) should be filed individually, with M9
flagged as a memory-corruption bug despite its Medium severity (the
only confirmed memory-safety issue in the scan).

Tier-3 dead-code cleanup (M3, L7, L10, plus the dead `OtlpConfig`
fields and `MetricProviderConfig.interval_ms` from the Phase 2
dead-code table) can land as a single mechanical PR with no
behaviour change. That gives the team a low-risk way to shrink
public surface before the structural refactors land.
