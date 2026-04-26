# Performance Scan — Phase 2

**Date:** 2026-04-26
**Scope:** /data/home/benji/src/devnw/zig/otel (OpenTelemetry SDK for Zig 0.16)
**Inputs:** Phase 1 orientation hot paths
**Method:** static read + ripgrep over `src/`, `benchmarks/`, `test/`. No microbench numbers — every "estimated impact" is a hypothesis to be validated by the perf-reviewer in Phase 3.

Severity legend:

- **P0** — Hot path on every emitted span/metric/log; blocks throughput goals or burns CPU at idle.
- **P1** — Per-export or per-collect path; high amplification but bounded by batch size or scrape interval.
- **P2** — Per-instrument or startup path; matters at scale but not per-event.
- **P3** — Cosmetic / cleanup-path inefficiency.

Confidence: `confirmed` (the code unambiguously does the thing) vs `suspected` (likely but needs measurement).

---

## P0 — Per-Span / Per-Record Hot Paths

### P0-1 — `AttributeSet.put` is O(n²) per span (linear-scan dedup + arena dupe per call)

- **File:** `src/internal/attributes.zig:106-127` (`put`), `src/internal/attributes.zig:60-69` (`getString`)
- **Evidence:** Every `put` walks `self.entries.items` end-to-end looking for the key (line 115), then either overwrites or appends. Both `key` and `value` are arena-duped (lines 112-113) before the dedup check, so a duplicate-key write still allocates a fresh copy that is then orphaned in the arena until the span ends. Combined with the `Tracer.startSpan` initial-attribute loop at `src/sdk/trace.zig:242-244` (`for (opts.initial_attributes) |entry| state.attributes.put(...)`) and per-call `setAttribute` at `src/api/trace.zig:180-184`, a span with N attributes does N×N/2 byte comparisons plus 2N arena allocations.
- **Why it matters:** `startSpan` is the canonical hot path. Spec allows up to 128 attributes (line 11). At 50 attributes per span, this is ~1250 `mem.eql` calls and 100 arena allocations *per span* on top of the SpanState allocation itself.
- **Estimated impact:** Latency on `startSpan` + `setAttribute` scales quadratically with attribute count. A small hash index (open-addressing on hashed key) or sorted insertion would drop dedup to O(log n) or O(1). For typical OTel workloads (5-20 attrs/span) the constant factor still bites.
- **Verifies via:** micro bench `startSpan_with_N_attrs` for N=1,8,32,128; flame graph showing `mem.eql` cumulative time.
- **Confidence:** `confirmed`

### P0-2 — `Tracer.startSpan` allocates a SpanState struct + arena + `dupe(name)` per span

- **File:** `src/sdk/trace.zig:235` (`SpanState.init`), `src/api/trace.zig:103-118` (`SpanState.init` body)
- **Evidence:** Every recording span: (1) `allocator.create(SpanState)` (heap), (2) `ArenaAllocator.init` (mmap on first allocation), (3) `allocator.dupe(u8, name)` for the span name. After `end()`, `arena.deinit` releases the whole arena; no pool reuse. The arena is the *child* allocator of the AttributeSet/Events/Links arenas (line 121-128 deinit), so each span pays one arena tear-down cost too.
- **Why it matters:** This is the per-span baseline cost — every other hot-path optimization is dwarfed by it. Sampler `.drop` correctly short-circuits at `src/sdk/trace.zig:230-232`, but every recording span pays full price.
- **Estimated impact:** Allocator pressure dominates throughput for high-cardinality span workloads. Object-pooling SpanState (with arena reset rather than deinit) would cut steady-state cost dramatically; this is the single biggest knob in the trace path.
- **Verifies via:** `startSpan_drop_vs_record` micro bench, GPA tracking allocation count and bytes per iteration.
- **Confidence:** `confirmed`

### P0-3 — Per-span `setName` re-allocates and frees the old name

- **File:** `src/api/trace.zig:159-165` (`Span.setName`)
- **Evidence:** `child.free(s.name); s.name = child.dupe(u8, name) catch return;` — pure churn: free + alloc + memcpy on every rename. Common in HTTP instrumentation where a placeholder name is set at startSpan and replaced once the route is known (the http instrumentation in `src/instrumentation/http.zig:28-30` uses `bufPrint` on a stack buf, but downstream renames aren't gated).
- **Why it matters:** Allocator round-trip on a hot path that should be O(memcpy) at worst.
- **Estimated impact:** Small absolute cost but shows up in flame graphs as `free` + `dupe` adjacent — easy to fix by storing name in the existing arena.
- **Verifies via:** micro bench that calls `setName` once per span.
- **Confidence:** `confirmed`

### P0-4 — `MeterProvider.pointFor` allocates and serializes attribute key on every record

- **File:** `src/sdk/metrics.zig:254-285` (`pointFor`), `src/sdk/metrics.zig:314-329` (`attributeKey`)
- **Evidence:** Every `counterAdd`/`udcAdd`/`histRecord`/`gaugeSet` call routes through `pointFor`. `pointFor` calls `attributeKey` which:
  1. Allocates a sort buffer (`sorted = try allocator.alloc(...)`, line 318).
  2. Sorts the attributes (line 321).
  3. Serializes each attribute into an ArrayList (lines 322-327).
  4. Copies the result with `dupe` (line 328).
  Then `pointFor` walks `inst.points.items` linearly comparing the key (lines 256-261) and frees the just-built key on a hit (line 258). On a miss, it allocates *another* `AttributeSet`, dupes every entry into it, and appends to `inst.points`. **Five allocations per record on a steady-state hit, six on a miss.**
- **Why it matters:** Counter/histogram `record()` is the highest-frequency telemetry call in any production system. The hot-path "record one observation, increment one bucket" should be branch + add, not 5 allocations.
- **Estimated impact:** Recording a counter with no attributes still allocates the sort buffer (zero-length but the call stack is real); recording with 3 attributes hits all 6 allocations on the first call and 5 on every subsequent call. At 100k records/sec this is 500k allocations/sec on a single instrument.
- **Verifies via:** `counter_add_no_attrs`, `counter_add_3_attrs`, `histogram_record_3_attrs` micro benches.
- **Confidence:** `confirmed`

### P0-5 — Per-record allocation and ArrayList growth in `attributeKey`'s scratch buf

- **File:** `src/sdk/metrics.zig:314-329`
- **Evidence:** `var buf: std.ArrayList(u8) = .empty;` then `buf.appendSlice` per attribute. ArrayList starts empty and grows via doubling; for any non-trivial attribute count, this is multiple `realloc` calls per record. The buffer is then `dupe`d (line 328) and the original is `deinit`ed (line 316), discarding the allocator's just-grown capacity.
- **Why it matters:** Two allocators (the ArrayList and the dupe) when one (a fixed-size fmt-into-buffer) would do for any sane attribute set.
- **Estimated impact:** Same record path as P0-4; this is one of the 5 allocations.
- **Verifies via:** flame graph during high-frequency `counter.add` calls.
- **Confidence:** `confirmed`

### P0-6 — `MeterProvider.instruments` is a linear list (used during `collect` only, but…)

- **File:** `src/sdk/metrics.zig:137` (`instruments: std.ArrayList(*InstrumentBackend)`), `src/sdk/metrics.zig:506` (collect walks all instruments)
- **Evidence:** Instrument lookup is O(n) any time we need to find one by descriptor — but the only such lookup at write time is via the cached `Counter.ctx` pointer (set at construction, see `makeCounter` line 353-357), so steady-state writes already bypass this. Collect-time iteration is fine.
- **Why it matters:** Already optimal at write time. Listed for completeness — no action.
- **Confidence:** `confirmed` no-op finding.

### P0-7 — Histogram bucket lookup is a linear scan, not a binary search

- **File:** `src/sdk/metrics.zig:414-419` (`histRecord`)
- **Evidence:** `for (h.bounds) |b| { if (value <= b) break; idx += 1; }` walks bucket boundaries one at a time. The default histogram has 15 boundaries (line 288); a binary search would be ~4 comparisons vs up to 15.
- **Why it matters:** Hot path on every `histogram.record`; matters more as users add custom bucket schemes (latency histograms with 30+ buckets are common).
- **Estimated impact:** ~3-5x faster bucket lookup with binary search on the 15-bucket default; worse the more buckets are configured.
- **Verifies via:** `histogram_record_with_N_buckets` micro bench for N=10,30,100.
- **Confidence:** `confirmed`

### P0-8 — `BatchSpanProcessor.batchOnEnd` takes the queue mutex on every span end

- **File:** `src/sdk/export.zig:343-378`
- **Evidence:** `batchOnEnd` always acquires `self.mutex.lock()` (line 345). With `async_workers=0` (the default), `QueueMutex` is a stub (line 163-166), so this is free in single-threaded mode — but **only** because no actual processor runs in the background. Once `async_workers > 0` is set, every producer pays a real mutex acquire on every span end. There is no per-thread shard or lock-free MPSC queue.
- **Why it matters:** With multiple producer threads, this becomes the bottleneck the moment async export is enabled — exactly the configuration that exists to scale out export throughput.
- **Estimated impact:** Throughput plateaus once mutex contention dominates; a sharded or lock-free queue (e.g., per-core MPSC ring, or `crossbeam`-style steal) would scale linearly.
- **Verifies via:** producer-thread-scaling micro bench at async_workers=1,2,4,8.
- **Confidence:** `confirmed` (mutex usage), `suspected` (severity at scale)

### P0-9 — Default `async_workers=0` means *all* span export is synchronous on the producer thread

- **File:** `src/sdk/export.zig:147` (default), and the synchronous-drain path at `src/sdk/export.zig:370-377`
- **Evidence:** The default `BatchSpanProcessorOptions.async_workers = 0`. The synchronous fallback at line 370-377 calls `exportBatch` (which serializes protobuf, calls the HTTP transport, and waits for the response) **inline on the producer thread** whenever the queue hits `max_export_batch_size`. With queue size 2048 and batch size 512, every 512th span pays the full export latency on its own `end()` call.
- **Why it matters:** Span `end()` is supposed to be near-free. With this default, every 512 spans one call pays for a network round-trip. P50 looks fine; P99.8 spikes by orders of magnitude.
- **Estimated impact:** Tail latency: ~10-100ms per 512 spans depending on collector RTT. Throughput: capped at (1 span / 512) × export_throughput.
- **Verifies via:** end-to-end bench with default config — measure span `end()` P50/P99/P99.9.
- **Confidence:** `confirmed`

### P0-10 — `simpleOnEnd` (default processor) is fully synchronous and exports one-span-at-a-time

- **File:** `src/sdk/export.zig:101-121`
- **Evidence:** The "simple span processor" — wired as the default when no processor is given (`src/sdk/trace.zig:172-178`) — calls `self.exporter.exportSpans(&[_]SpanData{data})` with a single-element slice on every span end. For OTLP/HTTP this means one HTTP POST per span. There is no batching at all in this path.
- **Why it matters:** This is what users get out-of-the-box. The default config is "synchronous export, one span per request" — catastrophic for throughput.
- **Estimated impact:** Throughput limited to network RTT (~1-10 spans/sec on remote collector, ~1k/sec on localhost). Wrap default exporter in a `BatchSpanProcessor` instead.
- **Verifies via:** end-to-end throughput bench with default tracer config + OTLP exporter.
- **Confidence:** `confirmed`

---

## P1 — Per-Export / Per-Flush Path

### P1-1 — `encodeSpansProto` wastes 10 bytes per submessage and forces a `copyForwards` shift

- **File:** `src/generated/otlp.zig:110-137` (`beginSubMessage` / `commitSubMessage`)
- **Evidence:** `beginSubMessage` always reserves 10 bytes for the size varint (line 114). `commitSubMessage` then computes the actual varint size and uses `std.mem.copyForwards` to shift the entire payload back over the unused slack (line 134), then `shrinkRetainingCapacity` to trim. For a span with attributes, this happens for: ResourceSpans, Resource, ScopeSpans, Scope, Span, Status, plus one KeyValue + AnyValue per attribute. **A 10-attribute span triggers ~26 `copyForwards` calls, each shifting bytes for the entire enclosing submessage.**
- **Why it matters:** The shift is O(payload_size) per submessage. Nested submessages mean inner shifts get re-shifted by every enclosing commit. This is essentially O(n²) byte movement in the depth of nesting × number of attributes.
- **Estimated impact:** Encoder throughput dominated by memmove rather than actual encoding work. A two-pass encoder (compute lengths first, then write tightly) or back-patching with `bufferedWriter.print` would eliminate the shift. Alternative: write a placeholder, then *swap* via a dedicated submessage stack. The DevNW protobuf encoder already exists as an alt path (line 499) — measure the parity test for proof.
- **Verifies via:** `encode_spans_proto` micro bench at N spans × M attrs; compare against `encodeSpansProtoDevnw`.
- **Confidence:** `confirmed`

### P1-2 — Varint append byte-by-byte via `ArrayList.append` (per-byte allocator dispatch)

- **File:** `src/generated/otlp.zig:42-49` (`writeVarint`)
- **Evidence:** `try self.buf.append(self.allocator, ...)` once per byte of varint output. Each `append` call goes through the allocator's growth check + potential `realloc`. A 10-byte varint = 10 allocator calls.
- **Why it matters:** `writeVarint` is called for every field tag and every length-delimited prefix — typically dozens of times per span. Replacing with a stack-buffered "encode varint into [10]u8 then `appendSlice`" cuts allocator chatter by ~10x for varint operations.
- **Estimated impact:** Modest per-call but cumulative; benchmarking will show.
- **Verifies via:** `encode_spans_proto` flame graph; check `ArrayList.append` cumulative time.
- **Confidence:** `confirmed`

### P1-3 — `BatchSpanProcessor.drainLocked` allocates a fresh slice on every drain

- **File:** `src/sdk/export.zig:251-260`
- **Evidence:** Every drain: `self.allocator.alloc(*trace_api.SpanState, n)`. Followed by `std.mem.copyForwards` to compact the queue. The drain output is freed by `exportBatch` (line 263) and the next drain allocates again.
- **Why it matters:** Per-batch allocation that could trivially be a fixed scratch buffer reused across drains.
- **Estimated impact:** One alloc + one free per batch (every 512 spans by default). Not catastrophic, but pure noise that shows up in profiles.
- **Verifies via:** allocation tracker on the BSP path.
- **Confidence:** `confirmed`

### P1-4 — `exportBatch` allocates a parallel `SpanData` slice (one alloc per drain) and frees per-span

- **File:** `src/sdk/export.zig:262-297`
- **Evidence:** `self.allocator.alloc(SpanData, batch.len)` (line 265) plus per-span construction (lines 270-287), then `for (batch) |s| s.deinit()` (line 296) which tears down the per-span arena one at a time.
- **Why it matters:** SpanState arena teardown is the dominant per-export cost. If SpanState were pooled (P0-2 fix), this cost vanishes too.
- **Confidence:** `confirmed`

### P1-5 — `forceFlush` busy-polls with 200µs sleeps in the async-pool path

- **File:** `src/sdk/export.zig:380-428` (`batchForceFlush`)
- **Evidence:** Lines 395-409: `while (true) { ... tp.clock.sleep(200 * std.time.ns_per_us); ... }`. The loop wakes every 200µs to check `pending_tasks` and resubmit drains. There is no condvar / wake-up signal from the worker side.
- **Why it matters:** `forceFlush` is normally only called at shutdown or on explicit flush requests, so the 200µs CPU burn is bounded — but the design forces a context switch every 200µs. With heavy multi-producer load and a chunky export, that's a measurable CPU floor on the flushing thread.
- **Estimated impact:** ~5000 wakeups/sec on the flushing thread until done. Replacing with a `std.Thread.Condition` (or DevNW pool's wait primitive) would be near-zero CPU.
- **Verifies via:** `force_flush_under_load` bench measuring flushing-thread CPU.
- **Confidence:** `confirmed`

### P1-6 — `MeterProvider.collect` allocates `points` slice per instrument with no scratch reuse

- **File:** `src/sdk/metrics.zig:499-557`
- **Evidence:** For each instrument: `try out_alloc.alloc(exp.DataPoint, inst.points.items.len)` (line 508) and `try out.append(out_alloc, ...)` (line 544). `out.toOwnedSlice` at the end. No pre-sizing of `out` from `provider.instruments.items.len` (line 500: `var out: std.ArrayList(exp.MetricData) = .empty;`).
- **Why it matters:** Periodic reader runs collect on a schedule (default `interval_ms = 60_000` per `src/sdk/config.zig:68`). At 60s intervals the allocation cost is irrelevant, but Prometheus pull can hit much more frequently and `Prometheus.render` calls `collect` on every scrape (`src/exporters/prometheus.zig:29`).
- **Estimated impact:** N+1 allocations per scrape (one per instrument + one for the outer list). `out.ensureTotalCapacity(provider.instruments.items.len)` is a one-line fix.
- **Verifies via:** `prometheus_render` micro bench at varying instrument counts.
- **Confidence:** `confirmed`

### P1-7 — JSON encoders walk attributes via `sortedEntries` (extra alloc + sort per span)

- **File:** `src/internal/json_codec.zig:154-164` (`writeAttributes`), `src/internal/attributes.zig:147-156` (`sortedEntries`)
- **Evidence:** Every JSON span/log/metric emit goes through `sortedEntries`, which `alloc`s a fresh `[]Entry`, `memcpy`s, and `std.mem.sort`s. For a span with 20 attributes that is one allocation + an O(n log n) sort *per span*.
- **Why it matters:** stdout/file/JSON OTLP paths all go through this. Insertion-order is enforced inside AttributeSet anyway; if the JSON exporter doesn't strictly need sorted-by-key semantics, drop the sort. (Determinism is the rationale per the comment at line 8-9, so the sort is intentional — but it should be amortized: pre-sort on insert, or sort once per export and cache.)
- **Estimated impact:** O(n log n) per export per span on attribute count.
- **Verifies via:** `json_export_with_attrs` micro bench.
- **Confidence:** `confirmed`

### P1-8 — `Prometheus.render` rebuilds the entire text body via `buf.writer().print` per metric

- **File:** `src/exporters/prometheus.zig:25-86`
- **Evidence:** Every line: `try buf.writer(self.allocator).print(...)`. The writer is reconstructed per `print` call (line 38, 45, 53, 54, etc.). Each `print` goes through the formatter machinery and may grow the ArrayList.
- **Why it matters:** Pull-based exporter; high-cardinality metric registries can produce hundreds of KB of output per scrape. Allocating ArrayList writer wrappers per line is overhead the formatter doesn't need.
- **Estimated impact:** Modest constant-factor cost; the bigger issue is no pre-sizing of `buf` and no caching of `sanitized` names across collect cycles (line 36: every render re-sanitizes every metric name).
- **Verifies via:** `prometheus_render_high_cardinality` bench.
- **Confidence:** `confirmed`

### P1-9 — `OtlpHttpExporter.expSpans` constructs a fresh `std.http.Client` per export attempt

- **File:** `src/exporters/otlp_http.zig:138-139` inside `httpTransportImpl`
- **Evidence:** `var client: std.http.Client = .{ .allocator = allocator, .io = io }; defer client.deinit();` — a new client every call. No connection pool, no keep-alive reuse across exports.
- **Why it matters:** Every batch export pays TCP + TLS handshake. For HTTPS to a real collector, this is ~50-200ms per batch. The collector likely supports HTTP/1.1 keep-alive and HTTP/2 multiplexing; we're throwing it away.
- **Estimated impact:** Massive. Reusing a client across exports cuts per-batch network cost by 5-50x for HTTPS endpoints.
- **Verifies via:** comparison bench: 100 batches with fresh client vs reused client.
- **Confidence:** `confirmed`

### P1-10 — `OtlpHttpExporter` retry on `error.UnsupportedTransport` is a tight loop

- **File:** `src/exporters/otlp_http.zig:212`
- **Evidence:** The error switch on line 212 retries `error.UnsupportedTransport` — but this error is returned synchronously when `build_options.use_devnw_tls=false` or `io == null`. The retry adds backoff jitter (line 208), so it's not a true tight loop, but it will *always* exhaust `max_attempts=5` before giving up. Five retries × increasing backoff ≈ 3.1 seconds per failed export, *every* export, on a misconfigured build.
- **Why it matters:** Misconfiguration cost. Should fail fast.
- **Estimated impact:** ~3s of pure sleep per export attempt on a misconfigured deployment.
- **Verifies via:** integration test with `use_devnw_tls=false`; measure first-export latency.
- **Confidence:** `confirmed`

### P1-11 — `OtlpGrpcExporter` likewise has no client pooling and re-inits `GrpcClient` per call

- **File:** `src/exporters/otlp_grpc.zig:171-172`
- **Evidence:** `var client = try grpc_zig.GrpcClient.init(allocator, io, host, port); defer client.deinit();` — fresh gRPC client per export. gRPC's whole point is HTTP/2 stream multiplexing; tearing the connection down between exports negates that.
- **Why it matters:** Same as P1-9 but worse — gRPC connection setup + HTTP/2 SETTINGS exchange per export.
- **Estimated impact:** Even higher than HTTP. Persistent client is table stakes for any production gRPC client.
- **Verifies via:** loopback gRPC bench; measure export RTT cold vs warm.
- **Confidence:** `confirmed`

### P1-12 — `Resource.merge` calls `put` per attribute, suffering the O(n²) of P0-1

- **File:** `src/sdk/resource.zig:30-38`
- **Evidence:** `for (self.attributes.entries.items) |e| try out.attributes.put(e.key, e.value);` then the same for `other`. Each `put` is O(n) — total O(n²) for resource merge.
- **Why it matters:** Resource merge is startup-only (detector chain), not per-span. Listed for the perf-reviewer to cross-reference once P0-1 is addressed.
- **Confidence:** `confirmed` but cold-path.

---

## P2 — Per-Instrument / Startup / Cleanup

### P2-1 — Random `nextTraceId` rejection-loop on all-zero IDs

- **File:** `src/internal/id.zig:140-156`
- **Evidence:** `while (true) { self.prng.random().bytes(&t.bytes); if (t.isValid()) return t; }`. Probability of all-zero TraceId is 1/2^128 — the loop is effectively a single-iteration noop in practice. But `isValid` walks all 16 bytes (`for (self.bytes) |b| if (b != 0) return true;`) per call. Cost is trivial; flagged for completeness.
- **Confidence:** `confirmed` no-op finding.

### P2-2 — `attributeKey` formats values via `bufPrint` into a small stack buffer

- **File:** `src/sdk/metrics.zig:339-349`
- **Evidence:** Per-record formatting uses 24-byte/40-byte stack buffers — fine for cardinality but allocates the wrapping ArrayList scratch buffer (P0-5).
- **Confidence:** see P0-5.

### P2-3 — Per-export `ArenaAllocator` init in OTLP exporters

- **File:** `src/exporters/otlp_http.zig:177-179`, `src/exporters/otlp_grpc.zig:72-74`
- **Evidence:** `var arena = std.heap.ArenaAllocator.init(self.allocator); defer arena.deinit();` per export call.
- **Why it matters:** ArenaAllocator init is cheap (no allocation until first request); the deinit releases all pages. For a long-running exporter, holding an arena across exports and resetting it (`arena.reset(.retain_capacity)`) keeps pages warm — single-digit-µs win per export.
- **Confidence:** `confirmed`

### P2-4 — Stdout JSON exporter writes one span at a time via raw posix write

- **File:** `src/exporters/stdout_json.zig:47-49`
- **Evidence:** `_ = std.posix.write(fd, payload) catch return; _ = std.posix.write(fd, "\n") catch return;` — two syscalls per span when no `out_writer` is wired. No buffering.
- **Why it matters:** Two syscalls × many spans = high syscall rate. A buffered stdout writer (or a single `writev`) would amortize.
- **Estimated impact:** Bench-visible at high throughput; irrelevant for low-volume use.
- **Confidence:** `confirmed`

### P2-5 — File JSONL exporter calls `writeAll` twice per span (payload + newline) and arena-init per span

- **File:** `src/exporters/file.zig:44-58`
- **Evidence:** Same pattern — two writes per span, plus `ArenaAllocator.init` inside the per-span loop (line 52). The arena is born and dies per span.
- **Estimated impact:** O(spans) syscall count and arena init cost. Loop-hoist the arena, batch writes via a buffered writer.
- **Confidence:** `confirmed`

### P2-6 — `in_memory.Recorder.expSpans` has no pre-sizing of internal ArrayLists

- **File:** `src/exporters/in_memory.zig:101-117`
- **Evidence:** `try self.spans.append(...)` per item. The Recorder has `spans: std.ArrayList(StoredSpan) = .empty` and never pre-sizes.
- **Why it matters:** Test-only path; flagged so the perf-reviewer doesn't fold it into hot-path numbers.
- **Confidence:** `confirmed` test-only.

### P2-7 — `Span.recordException` allocates an AttributeSet on every call

- **File:** `src/api/trace.zig:194-207`
- **Evidence:** `arena.create(attrs.AttributeSet)` then two `putString` calls. The `arena.create` uses the span's existing arena (good), but each `putString` triggers the AttributeSet O(n²) walk (P0-1) — albeit n=2 here. Notable that the AttributeSet's *child* allocator is the span's `arena.child_allocator` (line 203), so the AttributeSet has its own arena nested inside the span's arena.
- **Why it matters:** Each exception recorded ⇒ nested arena allocation. For exception-heavy code paths this is per-throw overhead.
- **Confidence:** `confirmed`

### P2-8 — Logs path: `simpleEmit` allocates a one-element stack array per log

- **File:** `src/sdk/logs.zig:34-38`
- **Evidence:** `var data = [1]exp.LogData{.{...}};` — stack-allocated, but the call signature for `exportLogs(&data)` runs the exporter inline on the producer thread. No batching for the log path *at all* — the spec allows a BatchLogProcessor and one isn't implemented (only `SimpleLogProcessor` exists).
- **Why it matters:** Logs in production are higher-frequency than spans. Without a BatchLogProcessor, every `logger.emit` blocks on export.
- **Estimated impact:** Same as P0-10 (default tracer) but for logs; tail-latency catastrophe under load.
- **Verifies via:** `logger_emit` throughput bench.
- **Confidence:** `confirmed` (no batch processor exists in this codebase)

### P2-9 — `MeterProvider` has no batched/async metric processor

- **File:** `src/sdk/metrics.zig` (entire), `src/sdk/export.zig:475-492` (`MetricExporter` only — no `MetricProcessor`)
- **Evidence:** Metric collection is pull-only via readers; there is no equivalent of `BatchSpanProcessor` for metrics. `forceFlush` walks readers (line 198-200). Periodic readers don't appear to exist in `src/sdk/`.
- **Why it matters:** Means metric export latency hits whichever caller invokes the reader. For Prometheus pull this is fine; for OTLP push, it means `collect()` runs synchronously on whoever called `forceFlush`.
- **Confidence:** `confirmed`

### P2-10 — `BatchSpanProcessor` has no `schedule_delay_ms` enforcement

- **File:** `src/sdk/export.zig:142` (option declared), no usage in `batchOnEnd` / `batchForceFlush`
- **Evidence:** The `schedule_delay_ms = 5_000` default is in the struct (line 142) but `rg "schedule_delay_ms"` shows it is only declared — never read. The processor only flushes on (a) batch-size threshold or (b) explicit forceFlush. There is no time-based wakeup.
- **Why it matters:** Spec mandates a periodic timer-driven flush. A low-traffic application will queue spans for arbitrary time, then lose them on crash. From a performance standpoint, time-based flush would also keep the queue from sitting at 511 spans for long stretches.
- **Estimated impact:** Functional (spec) bug + latency: queued spans wait for the next 512th end before draining.
- **Confidence:** `confirmed`

---

## P3 — Cosmetic / Cleanup-Path

### P3-1 — `BatchSpanProcessor.deinit` walks every queued span sequentially

- **File:** `src/sdk/export.zig:240`
- **Evidence:** `for (self.queue.items) |s| s.deinit();` — fine; called once at shutdown.
- **Confidence:** `confirmed` no-op.

### P3-2 — `sanitizeMetricName` walks bytes one at a time with branchy switch

- **File:** `src/sdk/metrics.zig:296-312`
- **Evidence:** Per-character branch. Could be a SIMD/lookup-table replacement, but called once per instrument creation. Cold path.
- **Confidence:** `confirmed` cold-path.

### P3-3 — Prometheus exporter re-sanitizes name on every render

- **File:** `src/exporters/prometheus.zig:36`
- **Evidence:** `const sanitized = try sanitize(self.allocator, m.name); defer self.allocator.free(sanitized);` per render call per metric. Sanitized name doesn't change between renders.
- **Why it matters:** Cache sanitized name in the InstrumentBackend (it's already there as `devnw_name` for the DevNW backend — same data, just generalize).
- **Confidence:** `confirmed`

### P3-4 — `writeJsonString` per-byte escaping with ArrayList append

- **File:** `src/internal/json_codec.zig:219-239`
- **Evidence:** Per-byte branch + `buf.append(arena, c)` for the common case. For long string attributes this is allocator-pressure-heavy. A scan-then-bulk-copy approach (find the next escape, `appendSlice` the run, write the escape, repeat) would be markedly faster.
- **Estimated impact:** Bench-visible on any payload with long string values.
- **Confidence:** `confirmed`

### P3-5 — `propagation/baggage.zig` `inject` and `extract` allocate ArrayList scratch per call

- **File:** `src/propagation/baggage.zig:17-35` (`inject`), `:55-58` (`extract`)
- **Evidence:** Per-call ArrayList allocation. Baggage propagation is per-request on instrumented code paths, so this is hotter than it looks — but bounded by header size (4096 bytes max, line 11).
- **Confidence:** `confirmed`

---

## Bench Coverage Gaps

Existing `benchmarks/bench.zig:55-71` calls `lib.init` only — and `lib.init` doesn't even exist (Phase 1 noted this). The micro/, integration/, and comparison/ layers planned in Phase 1 are empty (`benchmarks/micro/` is empty per the listing). **No hot path identified above is covered by a benchmark.** Specifically, the following micro benches are required for Phase 3 to validate any of these findings:

| Hot Path | Required Bench | Why |
|---|---|---|
| `Tracer.startSpan` (record) | `startSpan_record_no_attrs` | Baseline for P0-2 |
| `Tracer.startSpan` (drop) | `startSpan_drop_sampler_off` | Confirms sampler short-circuit |
| `Tracer.startSpan` w/ attrs | `startSpan_record_8_attrs`, `_32_attrs`, `_128_attrs` | Confirms P0-1 quadratic |
| `Span.setAttribute` repeated | `set_attribute_x100` | P0-1 |
| `Span.setName` | `set_name_repeated` | P0-3 |
| `Counter.add` no attrs | `counter_add_no_attrs` | P0-4 baseline |
| `Counter.add` 3 attrs | `counter_add_3_attrs` | P0-4 / P0-5 confirmed |
| `Histogram.record` 15 buckets | `histogram_record_15_buckets` | P0-7 |
| `Histogram.record` 100 buckets | `histogram_record_100_buckets` | P0-7 amplification |
| `BatchSpanProcessor.onEnd` synchronous drain trigger | `bsp_sync_export_at_batch` | P0-9 tail latency |
| `SimpleSpanProcessor.onEnd` | `simple_processor_onEnd` | P0-10 |
| `encodeSpansProto` 100 spans × 10 attrs | `encode_spans_proto_100x10` | P1-1 / P1-2 |
| OTLP/HTTP export round trip | `otlp_http_export_warm` | P1-9 (client reuse) |
| Prometheus.render 1000 metrics | `prometheus_render_1000` | P1-8 / P3-3 |
| ForceFlush under load | `force_flush_with_pending` | P1-5 |
| Logger emit synchronous | `logger_emit_sync` | P2-8 |

`docs/audit/PERF_SCAN.md` (this file) is the input contract for `bench-optimize:audit` to expand `benchmarks/micro/` per the table above.

---

## Default Config Issues (Cross-cutting)

| Setting | File:Line | Default | Concern |
|---|---|---|---|
| `BatchSpanProcessorOptions.async_workers` | `src/sdk/export.zig:147` | `0` | Synchronous export on producer thread. P0-9. |
| `BatchSpanProcessorOptions.schedule_delay_ms` | `src/sdk/export.zig:142` | `5_000` | Declared but **never read** — no time-based flush. P2-10. |
| `BatchSpanProcessorOptions.max_queue_size` | `src/sdk/export.zig:140` | `2048` | Reasonable; with sync export and batch-of-512, queue rarely exceeds 512. With async + slow collector, 2048 may drop spans. |
| `BatchSpanProcessorOptions.max_export_batch_size` | `src/sdk/export.zig:141` | `512` | Reasonable but tightly coupled to the synchronous-drain trigger. |
| `MetricProviderConfig.interval_ms` | `src/sdk/config.zig:68` | `60_000` | 60s default may be too slow for development; consider 10s. |
| `OtlpConfig.timeout_ms` | `src/sdk/config.zig:51` | `10_000` | Per OTLP spec default. OK. |
| Default tracer processor when `processors` empty | `src/sdk/trace.zig:172-178` | `SimpleSpanProcessor` | Batches *nothing*; one HTTP per span. P0-10. |
| Default logger processor when `processors` empty | `src/sdk/logs.zig:82-88` | `SimpleLogProcessor` | No batch alternative exists. P2-8. |
| HTTP retry policy `max_attempts` | `src/exporters/otlp_http.zig:196` | `5` | With 100ms initial backoff × 2 multiplier capped at 5s, total ≈ 9.7s. Reasonable for transient errors but bad on misconfig (P1-10). |

---

## Cache-Unfriendly Layouts (Speculative)

### P1-13 — `SpanState` is a wide struct holding two ArrayLists, an arena, AttributeSet, scope struct…

- **File:** `src/api/trace.zig:81-101`
- **Evidence:** ~120+ bytes between fields used only at end (status, end_unix_nano) and fields used at start (name, sc). `recording: bool` and `ended: bool` are checked on every API call but live near the end of the struct. No deliberate field grouping.
- **Why it matters:** `setAttribute` reads `s.recording`/`s.ended` then writes into `s.attributes` — those touch different cache lines.
- **Estimated impact:** `suspected` — needs perf-counter measurement of L1/L2 misses on the hot API surface.
- **Verifies via:** `perf stat -e L1-dcache-load-misses` on the startSpan/setAttribute/end loop.
- **Confidence:** `suspected`

### P2-11 — `AttributeSet.entries` is an ArrayList of `Entry { key, value }` where `value` is a tagged union — pointer chasing

- **File:** `src/internal/attributes.zig:26-30`, lookup at `:60`
- **Evidence:** `Entry.value` is `Value` (tagged union, ~32 bytes). The lookup loop reads `e.key` (a slice — load the data ptr, then deref the bytes) then on miss continues. Slice headers + heap-allocated key bytes mean every iteration potentially misses cache.
- **Estimated impact:** `suspected`. A SoA layout (parallel `keys: ArrayList([]const u8)` and `values: ArrayList(Value)`) plus a parallel `key_hashes: ArrayList(u32)` for early rejection would dramatically cut compare cost.
- **Confidence:** `suspected`

---

## Summary by Severity

| Severity | Count | Theme |
|---|---|---|
| P0 | 10 | Per-span/per-record allocation, O(n²) attribute writes, sync-export defaults |
| P1 | 13 | Encoder shifts, missing client pooling, busy-poll flush, sortedEntries |
| P2 | 11 | Cleanup paths, cold-path startup |
| P3 | 5 | Cosmetic |

**Top three to fix first** (highest leverage on the trace path):

1. **P0-1 + P0-4 + P0-5** — kill the AttributeSet O(n²) and the per-record `attributeKey` alloc storm. (Hash-indexed AttributeSet + reusable scratch buffer.)
2. **P0-2** — pool `SpanState` with arena reset instead of full alloc/teardown.
3. **P1-1 + P1-2** — rework the OTLP protobuf encoder (two-pass length computation, batched varint writes). Comparison against `encodeSpansProtoDevnw` is already wired (`src/exporters/otlp_http.zig:499`) — measure once and decide.

**Top default-config fix:** flip the default tracer processor to a `BatchSpanProcessor` (P0-10) and make `async_workers` default sane (P0-9), or fix `schedule_delay_ms` so the time-based flush actually runs (P2-10).

**Top exporter fix:** persistent `std.http.Client` and `grpc_zig.GrpcClient` across exports (P1-9, P1-11) — table stakes for any push exporter.

---

## Cross-references for perf-reviewer (Phase 3)

- All findings cite `file:line`. Verify by reading the cited line.
- Where I marked `suspected`, do not treat as actionable until a microbench confirms.
- `benchmarks/bench.zig` is currently broken (calls non-existent `lib.init`); fix this first or none of the validation will run.
- The `bench-optimize` plugin's `audit → baseline → hypothesize → iterate → finalize` flow can be driven directly from this document; the bench-coverage table above is the input to `bench-optimize:audit`.
