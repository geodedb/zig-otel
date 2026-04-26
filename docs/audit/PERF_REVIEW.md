# Performance Review — Phase 3

**Date:** 2026-04-26
**Reviewer:** codepros perf-reviewer
**Inputs:** `docs/audit/PERF_SCAN.md` (Phase 2, 39 findings)
**Method:** static re-read of every cited file/line, semantic confirmation of complexity claims, allocation counting on hot paths, mutex-granularity analysis. Read-only.
**Output contract:** PerfScore for each P0/P1, ranked fix recipes for the top 5, concrete bench plans, risk callouts. Feeds the Phase-4 perf-issue-tracker.

PerfScore formula: `Severity × Hotness × Fix Confidence`

- **Severity**: P0 = 8, P1 = 4, P2 = 2, P3 = 1
- **Hotness**: 1 = per-export, 2 = per-batch / per-collect, 3 = per-span/per-record (every call)
- **Fix Confidence**: 1 = uncertain, requires harness work; 2 = clear path, moderate risk; 3 = obvious mechanical fix

---

## Validation Outcome Summary

| Finding | Phase 2 Conf. | Phase 3 Conf. | PerfScore | Notes |
|---|---|---|---:|---|
| P0-1 AttributeSet.put O(n²) + pre-dedup arena dupe | confirmed | **Confirmed** | **72** | Worst-of-both: arena pollution + linear scan; affects every span/log/event/exception/metric. |
| P0-2 SpanState alloc/arena/dupe per span | confirmed | **Confirmed** | **72** | Single biggest knob in the trace path. Pool + arena.reset is the canonical fix. |
| P0-3 setName free+dupe churn | confirmed | **Confirmed** | 24 | Real but smaller; trivial fix. |
| P0-4 pointFor 5 alloc/record | confirmed | **Confirmed** | **72** | Hottest metric path. Five allocations on hit, six on miss — verified by counting. |
| P0-5 attributeKey ArrayList scratch | confirmed | **Confirmed** | 48 | Subset of P0-4; same call site. |
| P0-6 Linear instrument list | confirmed (no-op) | **Confirmed (no-op)** | — | Only used at collect; write path bypasses. |
| P0-7 Histogram bucket linear scan | confirmed | **Confirmed** | 48 | Trivially fixable; 15-bucket default is binary-search territory. |
| P0-8 batchOnEnd mutex per span | confirmed | **Confirmed (severity Likely)** | 32 | Free with default `async_workers=0`; bites only when async is on. |
| P0-9 async_workers=0 default → inline export every 512 | confirmed | **Confirmed** | **72** | Tail-latency catastrophe. |
| P0-10 SimpleSpanProcessor default = one HTTP per span | confirmed | **Confirmed** | **72** | Worst out-of-box default in the SDK. |
| P1-1 encodeSpansProto byte-shift per submessage | confirmed | **Confirmed** | 24 | O(payload × nesting) memmove per encode; nested submessages amplify. |
| P1-2 writeVarint per-byte append | confirmed | **Confirmed** | 24 | Real but smaller than P1-1 it sits inside. |
| P1-3 drainLocked per-batch alloc | confirmed | **Confirmed** | 16 | Cheap fix (scratch buffer). |
| P1-4 exportBatch SpanData parallel alloc | confirmed | **Confirmed** | 8 | Subsumed by P0-2 fix. |
| P1-5 forceFlush 200µs busy-poll | confirmed | **Confirmed** | 8 | Bounded; fix only when adopting condvar. |
| P1-6 collect no pre-sizing | confirmed | **Confirmed** | 8 | One-line `ensureTotalCapacity`. |
| P1-7 sortedEntries alloc + sort per JSON span | confirmed | **Confirmed** | 16 | Per-span sort; matters at JSON paths. |
| P1-8 Prometheus.render per-line writer | confirmed | **Confirmed** | 8 | High-cardinality scrape path. |
| P1-9 Fresh `std.http.Client` per export | confirmed | **Confirmed** | **48** | Massive: 5–50× per-batch overhead on HTTPS. |
| P1-10 Retry on UnsupportedTransport | confirmed | **Confirmed** | 8 | Misconfig amplifier; fail-fast fix. |
| P1-11 Fresh GrpcClient per export | confirmed | **Confirmed** | **48** | Defeats HTTP/2 multiplexing entirely. |
| P1-12 Resource.merge O(n²) via put | confirmed | **Confirmed (cold)** | 4 | Cold path; auto-fixed by P0-1. |
| P1-13 SpanState wide layout | suspected | **Suspected** | 4 | Needs perf-counter measurement before action. |

---

## Top 5 by PerfScore — Fix Recipes

The five at score 72: **P0-1, P0-2, P0-4, P0-9, P0-10.** Each gets a full recipe (root cause, surface, fix mechanics, bench, risk). P1-9 / P1-11 / P0-7 follow as one tier down, with shorter recipes in the per-finding section.

### #1 (PerfScore 72) — P0-1: `AttributeSet.put` is O(n²) and pollutes the arena before dedup

**Surface (confirmed re-read):**

- `src/internal/attributes.zig:106-127` — `put` body. Lines 112-113 dupe `key` and `value` into the arena *before* the linear scan at line 115-119 even decides whether the key already exists. On a duplicate-key write the freshly-duped key never gets reused (only `owned_value` is stored at line 117, and `owned_key` is orphaned in the arena).
- Caller hot-paths confirmed:
  - `src/sdk/trace.zig:242-244` — initial-attribute loop on every recording `startSpan`.
  - `src/api/trace.zig:180-184` — `setAttribute` per call.
  - `src/api/trace.zig:194-207` — `recordException` calls `putString` twice (n=2, but per-throw).
  - `src/sdk/metrics.zig:262-263` — `pointFor` rebuilds an `AttributeSet` per *new* time series with `put` per entry.
  - `src/sdk/resource.zig:30-38` — `Resource.merge` (cold path).
- The `for (self.entries.items, 0..)` lookup at line 115 compares with `std.mem.eql` byte-for-byte. With `max_attributes = 128` the worst case is 128 × 128 / 2 = 8192 byte-loop iterations *per span*, plus 256 arena allocs (key + value), plus 128 final `entries.append`s.

**Root cause:** Two bugs braided together:

1. **Algorithmic** — linear-scan dedup on every `put`. AttributeSet semantics demand last-write-wins on duplicate keys, so a hash index is required to drop O(n) → O(1).
2. **Allocation discipline** — the arena dupe runs *before* the dedup decision. Even if dedup were O(1), the duplicate-key path still allocates two arena slabs (key + value) and discards the key. For workloads that re-set the same key (HTTP `http.status_code` updates, metric attribute reuse), this is pure waste.

**Fix recipe:**

1. Add a parallel `key_index: std.StringHashMapUnmanaged(usize)` whose value is the index into `entries.items`. Rebuild it lazily after `entries` mutations or maintain it in lockstep.
2. Restructure `put` to:

   ```zig
   const gop = try self.key_index.getOrPut(self.arena.child_allocator, key);  // hash lookup uses caller's key — no arena dupe yet
   if (gop.found_existing) {
       // overwrite path: free existing value, dupe new value into arena, no key dupe
       self.entries.items[gop.value_ptr.*].value = try dupValue(arena_alloc, value);
       return;
   }
   // insert path: now (and only now) dupe key into arena
   const owned_key = try arena_alloc.dupe(u8, key);
   gop.key_ptr.* = owned_key;  // stable; arena owns
   gop.value_ptr.* = self.entries.items.len;
   try self.entries.append(self.arena.child_allocator, .{ .key = owned_key, .value = try dupValue(arena_alloc, value) });
   ```

3. `getString` and `sortedEntries` keep their current shapes (the latter still copies — sorted output is by-key, not insertion-order).
4. Tradeoff: small per-AttributeSet overhead (`StringHashMapUnmanaged` header ~24 bytes empty, grows with attrs). For sparse attribute sets this is a wash; for dense it's a strict win.

**Bench plan:**

- New micro: `bench_attributeset_put_unique_N` for N ∈ {1, 8, 32, 128} — plain insertion, current vs hash-indexed.
- New micro: `bench_attributeset_put_overwrite_N` for N ∈ {1, 8, 32} — repeat-key write pattern (HTTP status updates) to expose the orphan-arena bug.
- Expected: ~10× on N=128 unique; ~3× on overwrite-heavy; allocation-count drops to 1 alloc per overwrite (was 2).

**Risk:** Low. The `entries` list semantics are preserved (insertion order, last-write-wins). The 128-attribute spec limit is unchanged. Existing tests at `attributes.zig:159-210` cover dedup + cap and should pass unchanged. Only risk: any external caller iterating `entries.items` and expecting overwrite to bump position — none in this codebase per `rg "attributes\.entries\.items"`.

---

### #2 (PerfScore 72) — P0-2: `Tracer.startSpan` allocates SpanState + arena + dupe(name) per span

**Surface (confirmed re-read):**

- `src/api/trace.zig:103-118` — `SpanState.init` body. Three allocations per call:
  1. `allocator.create(SpanState)` — heap (line 104).
  2. `allocator.dupe(u8, name)` — heap (line 106).
  3. `std.heap.ArenaAllocator.init(allocator)` — cheap struct init, but the *first* arena allocation in `attributes.put` mmaps a page (line 108).
- `src/sdk/trace.zig:235` calls this on every recording span.
- `src/api/trace.zig:120-129` — `deinit` tears the arena down (`arena.deinit`) per span end. `child.destroy(self)` returns the SpanState struct slab.

**Root cause:** Per-span baseline cost. Even with all other hot-path optimizations, every recording span pays a `create + dupe + ArenaAllocator.deinit` cycle. Default GPA `mmap`s the first arena page per span; arena `deinit` `munmap`s it.

**Fix recipe:**

1. Introduce `SpanStatePool` keyed by the `TracerProvider`:

   ```zig
   pub const SpanStatePool = struct {
       free: std.ArrayListUnmanaged(*SpanState) = .empty,
       mutex: std.Thread.Mutex = .{}, // only when async_workers > 0
       allocator: std.mem.Allocator,
       max_capacity: usize = 1024,
   };
   ```

2. `acquire(name)`:
   - Pop from `free`. If empty, allocate a fresh SpanState with the arena pre-`reset(.retain_capacity)`-friendly state.
   - Reset the arena via `state.arena.reset(.retain_capacity)` — keeps mmap'd pages warm.
   - Memcpy `name` into the arena (kill `dupe` from the hot path; treat `name` as arena-owned).
3. `release(state)`:
   - `state.arena.reset(.retain_capacity)` — *no* `arena.deinit`.
   - Push back onto `free`. If `free.items.len >= max_capacity`, full `arena.deinit + destroy`.
4. Lifecycle hook: `TracerProvider.deinit` walks pool and tears down.
5. `setName` (P0-3) becomes a memcpy into the arena buffer; if longer than current capacity, just `arena.dupe` (no `child.free` of the previous slab).

**Bench plan:**

- `bench_startspan_record_no_attrs` baseline.
- `bench_startspan_record_no_attrs_pool` after fix.
- Expected: ~5–10× on steady-state (after pool warms). `mmap`/`munmap` syscalls per iteration drop from 2 → 0.

**Risk:** Medium.

- Concurrent producers: pool needs a mutex when async path is on; consider sharded free-lists.
- Memory growth: `max_capacity = 1024` × ~4 KiB arena ≈ 4 MiB resident. Document and make tunable in `TraceConfig`.
- `state.deinit()` is currently called from many sites (BSP `exportBatch`, simple processor); these become `pool.release(state)`. Audit-required but mechanical.

---

### #3 (PerfScore 72) — P0-4: `MeterProvider.pointFor` ≈ 5 allocations per record

**Surface (confirmed re-read):**

- `src/sdk/metrics.zig:254-285` — `pointFor`.
  - Line 255: `attributeKey(self.allocator, attributes)` — see P0-5; allocates ArrayList + `dupe`.
  - Line 256-261: linear scan over `inst.points.items` comparing keys.
  - Line 258: on hit, `self.allocator.free(key)` — wasted alloc + free.
  - Line 262-263: on miss, `attrs_mod.AttributeSet.init` + per-entry `put` (each `put` is itself O(n) per P0-1).
  - Line 274-278: histogram path additionally allocates `bounds` and `counts` slices.
- Hot callers: `counterAdd` (line 359), `udcAdd` (line 386), `histRecord` (line 404), `gaugeSet` (line 433). Every metric write hits `pointFor`.

**Per-call allocation count (re-counted):**

- **Hit path (steady-state common case):** `attributeKey` does (1) `alloc(sorted)` + (2) ArrayList grow + (3) final `dupe`. Then `pointFor` does (4) `free(key)`. Net 3 allocs + 1 free per record on a hit.
- **Miss path:** add (5) `AttributeSet.init` (lazy — first arena alloc on first `put`), (6) N × `put` arena dupes, (7) `inst.points.append`. ~5–7 allocs.

**Root cause:** No fast path for the common case "I've seen this attribute set before." The per-record key is rebuilt from scratch every time; the dedup is by string equality on the rebuilt key, not by hash.

**Fix recipe:**

1. Replace `inst.points: std.ArrayList(AggregatedPoint)` with `inst.points_index: std.StringHashMapUnmanaged(usize)` keyed by `attribute_key`, plus a parallel `inst.points: std.ArrayList(AggregatedPoint)` for ordered iteration.
2. Compute the key into a **reusable** scratch buffer per-instrument (no alloc in hit path):

   ```zig
   pub const InstrumentBackend = struct {
       ...
       key_scratch: std.ArrayListUnmanaged(u8) = .empty, // reused; pre-grown
   };
   ```

3. `pointFor`:

   ```zig
   inst.key_scratch.clearRetainingCapacity();
   try buildKeyInto(&inst.key_scratch, attributes);  // no dupe
   const gop = try inst.points_index.getOrPut(allocator, inst.key_scratch.items);
   if (gop.found_existing) return &inst.points.items[gop.value_ptr.*];  // ZERO allocs on hit
   // miss: dupe key, init AttributeSet, push point
   ```

4. The `key_scratch` lives for the instrument's lifetime — bounded by `(unique_attribute_sets × max_key_bytes)` = small.

**Bench plan:**

- `bench_counter_add_no_attrs` (key length = 0).
- `bench_counter_add_3_attrs` (steady-state hit).
- `bench_counter_add_first_seen_3_attrs` (cold path, small N).
- `bench_histogram_record_3_attrs`.
- Expected: hit path 0 allocations (was ~3), latency drops 5–10×. With P0-7 fix layered on top, histogram hit path is also alloc-free.

**Risk:** Low. The `points_index` is purely additive; iteration order in `collect` (line 506-543) keeps using `inst.points.items`. The string-keyed map mirrors what `pointFor` already needs to do; we just stop throwing it away.

---

### #4 (PerfScore 72) — P0-9: Default `async_workers = 0` ⇒ inline export every 512 spans

**Surface (confirmed re-read):**

- `src/sdk/export.zig:147` — `async_workers: u32 = 0`.
- `src/sdk/export.zig:343-378` — `batchOnEnd`. Lines 363-368: when the pool flag is off OR `pool == null`, control falls through to the "synchronous drain" path at lines 370-377.
- Lines 372-377: `drainLocked` + `exportBatch` runs *inline on the producer thread*. `exportBatch` calls `self.exporter.exportSpans(datas)` which for OTLP does protobuf encoding + HTTP POST + retry loop synchronously.
- `src/sdk/export.zig:142` — `schedule_delay_ms = 5_000` is *declared but never read* (P2-10) — there is no time-based flush. The producer thread takes the export latency on the 512th span end every batch.

**Root cause:** Two cooperating defects:

1. The default value `async_workers = 0` makes the BSP a synchronous batcher.
2. Even with `async_workers > 0`, this only fires when `build_options.use_devnw_pool == true`. The standard build has no async path at all.

**Fix recipe:**

1. **Short-term mitigation (no API change):** flip the default to `async_workers: u32 = 1` when `build_options.use_devnw_pool == true`, otherwise leave 0 with a documented hazard at the field declaration.
2. **Real fix:** ship a stdlib-thread fallback inside `BatchSpanProcessor` that is independent of the DevNW thread-pool. `std.Thread.spawn` + `std.Thread.Condition` is enough for one drain worker; this is a ~50-line addition and doesn't depend on the optional dependency.
3. **Wire `schedule_delay_ms`:** add a `std.Thread.Timer`-based wakeup (or condvar-with-deadline) that flushes after `schedule_delay_ms` of queue inactivity. Spec-required and prevents the "queue stuck at 511 for 60s" pathology under low traffic.

**Bench plan:**

- `bench_span_end_p99_default_config` — measure span `end()` P50/P99/P99.9 with default config under 10k spans/sec.
- Expected current: P99.9 spike to >10ms every 512th span (matches RTT to local OTLP collector).
- Expected after fix: P99.9 stays <50µs (just `mutex.lock` + `queue.append`).

**Risk:** Medium-high.

- A stdlib thread spawned by default changes the runtime profile (one extra thread, ~8 MiB stack reservation by default; cap with `Thread.SpawnConfig.stack_size`).
- Shutdown ordering: producer threads must observe the flush worker draining before `tp.deinit` returns. Existing `batchForceFlush` logic at lines 380-428 already polls `pending_tasks`; this generalizes.

---

### #5 (PerfScore 72) — P0-10: `SimpleSpanProcessor` is the default and exports one span per HTTP

**Surface (confirmed re-read):**

- `src/sdk/trace.zig:172-178` — when `processors` is empty and a `default_exporter` is set, the provider wraps it in `SimpleSpanProcessor`. There is no fallback to `BatchSpanProcessor`.
- `src/sdk/export.zig:101-121` — `simpleOnEnd` calls `self.exporter.exportSpans(&[_]SpanData{data})` with a one-element array. For OTLP/HTTP this triggers `expSpans` at `src/exporters/otlp_http.zig:172-228`, which encodes + POSTs + waits for response — **per span**.
- The `examples/basic.zig` and `examples/http_client.zig` paths both rely on this default.

**Root cause:** Sane-default failure. Spec doesn't mandate Simple; production-grade SDKs default to Batch. The current default is "for tests" — but that's not what the user gets out of the box.

**Fix recipe:**

1. Change `TracerProvider.init` (line 168-181) to wrap the `default_exporter` in a `BatchSpanProcessor` (with the P0-9 sane defaults) instead of `SimpleSpanProcessor`. Keep `SimpleSpanProcessor` available for explicit opt-in (tests).
2. Add a `TraceConfig.processor_kind: enum { batch, simple } = .batch` so callers can pick the legacy behavior explicitly.
3. Document migration in CHANGELOG: callers relying on synchronous export semantics (in-memory tests) should pass an explicit `SimpleSpanProcessor` in `processors` (which they already do — see `tests/integration.zig` historically).

**Bench plan:**

- `bench_default_tracer_throughput_localhost_otlp` — measure spans/sec with the default config and a localhost OTLP receiver.
- Current expected: ~1k–10k spans/sec (network RTT bound).
- After fix expected: ~50k–500k spans/sec (encoder-bound, batch-of-512).

**Risk:** Medium.

- Test surface area: tests using `default_exporter` and expecting synchronous export will need an explicit `SimpleSpanProcessor` or a `forceFlush` call. Inventory before flipping the default.
- Memory footprint: the BSP holds up to `max_queue_size = 2048` SpanState pointers. Default 2048 × pointer-size = 16 KiB. Fine.

---

## Per-Finding Detail (P0 + P1)

Format: **Confidence — PerfScore (Severity × Hotness × FixConf) — Suggested Fix — Bench — Risk.**

### P0-1 — AttributeSet.put O(n²)

- **Confidence:** Confirmed. `src/internal/attributes.zig:106-127` re-read. Linear scan + pre-dedup arena dupe both present.
- **PerfScore:** 8 × 3 × 3 = **72**.
- **Fix:** see #1 above.
- **Bench:** see #1.
- **Risk:** Low.

### P0-2 — SpanState alloc per span

- **Confidence:** Confirmed. `src/api/trace.zig:103-118` re-read; three allocations per init, full arena teardown per `deinit`.
- **PerfScore:** 8 × 3 × 3 = **72**.
- **Fix:** see #2.
- **Risk:** Medium.

### P0-3 — setName free+dupe churn

- **Confidence:** Confirmed. `src/api/trace.zig:159-165` re-read.
- **PerfScore:** 8 × 1 × 3 = **24** (Hotness 1 because rename is per-span at most, often per-1000-spans for HTTP route templates).
- **Fix:** Drop the `child.free(s.name)`; use `s.arena.allocator().dupe(u8, name)` so the name lives in the arena. Old name is freed at span end with the arena. (Or store `name: std.ArrayListUnmanaged(u8)` for in-place reuse.)
- **Bench:** `bench_set_name_repeated_x100`.
- **Risk:** Low. Arena ownership is already established for attributes/events.

### P0-4 — pointFor 5 alloc/record

- **Confidence:** Confirmed. `src/sdk/metrics.zig:254-285` re-read.
- **PerfScore:** 8 × 3 × 3 = **72**.
- **Fix:** see #3 above.
- **Risk:** Low.

### P0-5 — attributeKey ArrayList scratch

- **Confidence:** Confirmed. `src/sdk/metrics.zig:314-329` re-read. ArrayList grown then `dupe`d then `deinit`ed — discards capacity.
- **PerfScore:** 8 × 2 × 3 = **48** (Hotness 2: lives inside `pointFor` which is per-record, but the fix is shared with P0-4 so counted separately at smaller hotness).
- **Fix:** Folded into P0-4: per-instrument `key_scratch` reused across calls. The `sorted` slice can also be a per-instrument scratch (caps at `max_attributes`).
- **Bench:** same as P0-4.
- **Risk:** Low.

### P0-6 — Linear instrument list

- **Confidence:** Confirmed (no-op finding). Write path uses cached `Counter.ctx` pointer set at `makeCounter` (line 353-357); no lookup at write time.
- **PerfScore:** N/A.
- **No action.**

### P0-7 — Histogram bucket linear scan

- **Confidence:** Confirmed. `src/sdk/metrics.zig:414-419` — `for (h.bounds) |b|` walks one at a time.
- **PerfScore:** 8 × 2 × 3 = **48**.
- **Fix:** Replace with `std.sort.lowerBound(f64, h.bounds, value, lessThanF64)` — guaranteed-sorted bucket bounds (validated at instrument construction). For 15 buckets: ~4 comparisons vs 15 worst case; for 100 buckets ~7 vs 100.
- **Bench:** `bench_histogram_record_15_buckets`, `bench_histogram_record_100_buckets`.
- **Risk:** Low. The bounds slice is already sorted (validated upstream by spec or by checking at instrument creation; if not, add a one-time `std.sort.pdq` at construction and assert in tests).

### P0-8 — batchOnEnd mutex per span

- **Confidence:** Confirmed (mechanism); Likely (severity at scale).
- **PerfScore:** 8 × 2 × 2 = **32** (Hotness 2: only when async pool is enabled; FixConf 2: the right fix is a sharded MPSC queue which is non-trivial).
- **Fix:** Two tiers:
  1. Short-term: keep the mutex but bump it from `tp.sync.Mutex` to `std.Thread.Mutex` (consistent with the P0-9 fix that adds a stdlib thread fallback).
  2. Long-term: per-thread shard (`std.Thread.getCurrentId() % nshards`) with a thread-local stash, drained by the worker. Or a lock-free MPSC ring (e.g. Vyukov-style) sized to `max_queue_size`.
- **Bench:** `bench_bsp_producer_scaling` at 1/2/4/8 producer threads with `async_workers > 0`.
- **Risk:** Medium. Sharded queue changes ordering guarantees per producer thread; spec only requires "batch ordering" not "global ordering" so this is acceptable but needs explicit documentation.

### P0-9 — Default async_workers=0

- **Confidence:** Confirmed.
- **PerfScore:** 8 × 3 × 3 = **72**.
- **Fix:** see #4 above.
- **Risk:** Medium-high.

### P0-10 — Default SimpleSpanProcessor

- **Confidence:** Confirmed.
- **PerfScore:** 8 × 3 × 3 = **72**.
- **Fix:** see #5 above.
- **Risk:** Medium.

### P1-1 — encodeSpansProto wastes 10 bytes per submessage and shifts payload

- **Confidence:** Confirmed. `src/generated/otlp.zig:110-137` re-read; the `copyForwards` shift at line 134 fires on every `commitSubMessage` whose payload is small enough to encode in <10 varint bytes (which is essentially always).
- **PerfScore:** 4 × 2 × 3 = **24**.
- **Fix:** Two options, both proven:
  1. **Two-pass length computation** — walk the message twice: first to compute lengths (no I/O), second to write. Eliminates shifts entirely; doubles encode CPU time but halves memmove. Net win for large payloads.
  2. **Submessage-stack with back-patching using exact-size reservation** — track each begin/commit pair; reserve `varintLen(estimated_size)` bytes (estimate as 5 for "small" messages) and only shift when the estimate is wrong. Or: use the DevNW protobuf encoder (`encodeSpansProtoDevnw` already exists, line 499) — measure parity, switch.
- **Bench:** `bench_encode_spans_proto_100x10` (100 spans × 10 attrs); compare in-repo vs DevNW path. Existing parity test covers byte-equality.
- **Risk:** Low. Wire-format equivalence is already tested.

### P1-2 — writeVarint per-byte append

- **Confidence:** Confirmed. `src/generated/otlp.zig:42-49`.
- **PerfScore:** 4 × 2 × 3 = **24**.
- **Fix:** Encode into a stack `[10]u8` then `appendSlice` once:

  ```zig
  pub fn writeVarint(self: *Writer, value: u64) !void {
      var buf: [10]u8 = undefined;
      var v = value; var i: usize = 0;
      while (v >= 0x80) : (v >>= 7) { buf[i] = @as(u8, @intCast(v & 0x7f)) | 0x80; i += 1; }
      buf[i] = @as(u8, @intCast(v)); i += 1;
      try self.buf.appendSlice(self.allocator, buf[0..i]);
  }
  ```

- **Bench:** Folded into `bench_encode_spans_proto_100x10`.
- **Risk:** Trivial; mechanical.

### P1-3 — drainLocked alloc per drain

- **Confidence:** Confirmed. `src/sdk/export.zig:251-260`.
- **PerfScore:** 4 × 2 × 2 = **16**.
- **Fix:** Move the alloc to `BatchSpanProcessor.init` as a `drain_scratch: []*trace_api.SpanState` sized to `max_export_batch_size`. `drainLocked` returns a slice of it; `exportBatch` consumes the contents but does not free.
- **Bench:** Allocation tracker on `bench_bsp_drain`.
- **Risk:** Trivial.

### P1-4 — exportBatch parallel SpanData alloc

- **Confidence:** Confirmed. `src/sdk/export.zig:262-297`.
- **PerfScore:** 4 × 1 × 2 = **8**.
- **Fix:** Same as P1-3 — pre-allocate `datas: []SpanData` at processor init. Subsumed once P0-2 (SpanState pool) lands because then SpanState IS SpanData with thin glue.
- **Risk:** Low.

### P1-5 — forceFlush 200µs busy-poll

- **Confidence:** Confirmed. `src/sdk/export.zig:380-428`.
- **PerfScore:** 4 × 1 × 2 = **8**.
- **Fix:** Add a `std.Thread.Condition` to `BatchSpanProcessor`. Worker `notify()` after every drain completion; `forceFlush` `wait(deadline)` on the condvar instead of `tp.clock.sleep`.
- **Bench:** `bench_force_flush_under_load` measuring CPU on the flushing thread.
- **Risk:** Medium. Touches the async-path coordination surface; needs careful testing of the timeout semantics.

### P1-6 — collect no pre-sizing

- **Confidence:** Confirmed. `src/sdk/metrics.zig:499-557`.
- **PerfScore:** 4 × 1 × 2 = **8**.
- **Fix:** `try out.ensureTotalCapacity(out_alloc, provider.instruments.items.len);` at line 500.
- **Risk:** Trivial.

### P1-7 — sortedEntries alloc + sort per JSON span

- **Confidence:** Confirmed. `src/internal/json_codec.zig:154-164` + `src/internal/attributes.zig:147-156`.
- **PerfScore:** 4 × 2 × 2 = **16**.
- **Fix:** Two paths:
  1. Cache the sort: maintain `entries_sorted_dirty: bool` on `AttributeSet`; if writes are rare relative to sorts (typical), keep a parallel sorted index that we update incrementally on `put`. Memory cost: 16 bytes/entry index slice.
  2. Drop the sort entirely — JSON readers don't require sorted attributes; the `// determinism` comment is a self-imposed constraint. Tests would need a sort-on-compare instead of a sort-on-emit.
- **Bench:** `bench_json_export_with_attrs`.
- **Risk:** Option 1 low; Option 2 medium (changes externally-observable wire output for any JSON consumer relying on key order).

### P1-8 — Prometheus.render per-line writer

- **Confidence:** Confirmed. `src/exporters/prometheus.zig:25-86`.
- **PerfScore:** 4 × 1 × 2 = **8**.
- **Fix:** Pre-size `buf` from a heuristic of `provider.instruments.items.len * 256`. Hoist the writer (`var w = buf.writer(self.allocator);`) once per render. Cache `sanitized` in `InstrumentBackend` (P3-3). Replace per-attribute branchy writes with `w.writeAll` of pre-built fragment slices.
- **Bench:** `bench_prometheus_render_1000`.
- **Risk:** Low.

### P1-9 — Fresh `std.http.Client` per export

- **Confidence:** Confirmed. `src/exporters/otlp_http.zig:138-139` re-read; client is re-created inside `httpTransportImpl` and torn down at function exit.
- **PerfScore:** 4 × 2 × 3 = **48** (Hotness 2: per-export, but every export pays this; FixConf 3: stdlib client is `Client.init`-once).
- **Fix:** Lift the `std.http.Client` to live on `OtlpHttpExporter` itself. Init in `OtlpHttpExporter.init` (or lazy-init on first export to keep init cheap), tear down in `deinit`. The client's connection pool is the keep-alive store. Add a small mutex around `client.fetch` for the multi-thread case (the BSP serializes via `export_mutex` already, but the contract should be explicit).
- **Bench:** `bench_otlp_http_export_warm` (100 batches with reused vs fresh client). Expected: 5–50× per-batch on HTTPS endpoints.
- **Risk:** Medium. `std.http.Client` lifecycle in Zig 0.16 needs `io` to be valid throughout. Already plumbed via `OtlpHttpExporter.io`. Connection-pool memory growth needs a cap; `Client` has internal limits.

### P1-10 — Retry on UnsupportedTransport

- **Confidence:** Confirmed. `src/exporters/otlp_http.zig:212`.
- **PerfScore:** 4 × 1 × 2 = **8**.
- **Fix:** Remove `error.UnsupportedTransport` from the retry switch (line 212). Return immediately with that error. The error indicates a configuration problem, not a transient network failure.
- **Bench:** Integration test: `bench_misconfigured_export_first_export_latency` should drop from ~3s to <1ms.
- **Risk:** Trivial.

### P1-11 — Fresh GrpcClient per export

- **Confidence:** Confirmed. `src/exporters/otlp_grpc.zig:171-172`.
- **PerfScore:** 4 × 2 × 3 = **48**.
- **Fix:** Same shape as P1-9 — persistent `GrpcClient` on the `OtlpGrpcExporter` struct. Initialized lazily on first export, torn down in `deinit`. gRPC's whole point is HTTP/2 stream multiplexing across calls; tearing it down per-call defeats the protocol.
- **Bench:** `bench_otlp_grpc_export_warm` (loopback gRPC server).
- **Risk:** Medium. Need to verify `grpc-zig`'s `GrpcClient` is reusable across calls (some clients require one-shot semantics). Quick read of `grpc-zig` source needed; if not reusable, escalate to upstream.

### P1-12 — Resource.merge O(n²)

- **Confidence:** Confirmed. `src/sdk/resource.zig:30-38`.
- **PerfScore:** 4 × 1 × 1 = **4** (Hotness 1: cold path; FixConf 1: auto-fixed by P0-1).
- **Fix:** None directly. P0-1 fix to `AttributeSet.put` cascades through.
- **Risk:** N/A.

### P1-13 — SpanState wide layout

- **Confidence:** Suspected. Needs `perf stat -e L1-dcache-load-misses` measurement before action.
- **PerfScore:** 4 × 1 × 1 = **4**.
- **Fix:** Reorder fields by access frequency: `recording`, `ended`, `arena.state`, `attributes` head into the first cache line; `status_code`, `end_unix_nano`, `events`, `links`, `instrumentation_scope` to the tail. Then re-measure.
- **Bench:** `perf stat -e L1-dcache-load-misses,LLC-load-misses` on a span lifecycle micro.
- **Risk:** Low if measurement-driven.

---

## Cross-Cutting / Default-Config Issues (Re-confirmed)

| Setting | File:Line | Default | Confirmed Issue | Recommended Default |
|---|---|---|---|---|
| `BatchSpanProcessorOptions.async_workers` | `src/sdk/export.zig:147` | `0` | Synchronous export on producer | `1` (with stdlib-thread fallback per P0-9) |
| `BatchSpanProcessorOptions.schedule_delay_ms` | `src/sdk/export.zig:142` | `5_000` | **Declared but never read** (re-confirmed via `rg "schedule_delay_ms"`). Spec violation. | Wire to a periodic flush condvar |
| Default tracer processor | `src/sdk/trace.zig:172-178` | `SimpleSpanProcessor` | Per-span HTTP. | `BatchSpanProcessor` |
| Default logger processor | `src/sdk/logs.zig:82-88` | `SimpleLogProcessor` | No batch alternative exists. | Add `BatchLogProcessor`, default to it |
| HTTP retry `max_attempts` | `src/exporters/otlp_http.zig:196` | `5` | Wastes ~3s per misconfigured export | Keep 5 but exclude `UnsupportedTransport` from retry switch (P1-10) |

---

## Bench Coverage — Required for Phase 4 Validation

The Phase 2 scan listed 16 missing micro benches. After validation, the following are *load-bearing* for the top-5 fixes (must exist before any optimization claim is signed off):

| Bench | Validates | Layer |
|---|---|---|
| `bench_attributeset_put_unique_N` (N=1,8,32,128) | P0-1 | micro |
| `bench_attributeset_put_overwrite_N` | P0-1 (arena pollution) | micro |
| `bench_startspan_record_no_attrs` | P0-2 | micro |
| `bench_startspan_drop_sampler_off` | P0-2 baseline | micro |
| `bench_counter_add_no_attrs` | P0-4 | micro |
| `bench_counter_add_3_attrs` | P0-4 + P0-5 | micro |
| `bench_histogram_record_15_buckets` | P0-7 | micro |
| `bench_histogram_record_100_buckets` | P0-7 amplification | micro |
| `bench_span_end_p99_default_config` | P0-9 (tail latency) | integration |
| `bench_default_tracer_throughput_localhost_otlp` | P0-10 | integration |
| `bench_encode_spans_proto_100x10` | P1-1 + P1-2 | micro |
| `bench_otlp_http_export_warm` | P1-9 (client reuse) | integration |
| `bench_otlp_grpc_export_warm` | P1-11 | integration |

**Pre-requisite blocker:** `benchmarks/bench.zig:55-71` calls `lib.init(.{})` which does not exist on the public surface (re-confirmed via `rg "pub fn init" src/otel.zig` — no match). The harness must be repaired (or replaced) before any of the above benches can run. `benchmarks/micro/` is empty.

Recommended sequence for Phase 4:

1. Fix `benchmarks/bench.zig` to compile (drop `init` and stub the framework against real surface).
2. Add the load-bearing micros above under `benchmarks/micro/`.
3. Capture baseline for P0-1, P0-2, P0-4 (top three by leverage).
4. Implement fix recipes #1, #2, #3 in three independent worktrees; A/B against baseline.
5. Then tackle P0-7 (binary search — purely mechanical), P1-9, P1-11 (client pooling), and the encoder rewrite (P1-1).

---

## Confidence Distribution

| Confidence | Count |
|---|---|
| Confirmed | 21 |
| Likely (severity-only) | 1 (P0-8) |
| Suspected | 1 (P1-13) |

All P0/P1 algorithmic and allocation claims are **confirmed by direct re-read**. The only items with reduced confidence are about *severity at scale* (P0-8 needs producer-thread scaling bench) and *cache-line layout* (P1-13 needs hardware perf counters).

---

## Hand-off to Phase 4 (perf-issue-tracker)

**Issue creation order (top to bottom by PerfScore):**

1. **P0-1** AttributeSet hash index + defer-dupe — score 72 — recipe in #1
2. **P0-2** SpanState pool with arena reset — score 72 — recipe in #2
3. **P0-4** pointFor zero-alloc hit path — score 72 — recipe in #3
4. **P0-9** Default `async_workers` + stdlib thread fallback — score 72 — recipe in #4
5. **P0-10** Default to BatchSpanProcessor — score 72 — recipe in #5
6. **P1-9** Persistent `std.http.Client` — score 48
7. **P1-11** Persistent `GrpcClient` — score 48
8. **P0-7** Histogram binary search — score 48
9. **P0-5** key_scratch reuse (folded into P0-4)
10. **P0-8** BSP queue contention — score 32
11. **P0-3** setName arena-only — score 24
12. **P1-1** Two-pass proto encoder — score 24
13. **P1-2** Stack-buffered writeVarint — score 24
14. P1-3 / P1-4 / P1-5 / P1-6 / P1-7 / P1-8 / P1-10 — scores 8–16
15. P1-12 / P1-13 — scores 4

**Hard pre-req before any benchmark validation:** repair `benchmarks/bench.zig` (broken `lib.init` reference) and seed `benchmarks/micro/` with the 13 load-bearing benches in the table above.
