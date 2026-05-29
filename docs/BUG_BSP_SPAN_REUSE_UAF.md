# BUG: BatchSpanProcessor span-reuse UAF in synchronous-drain path

**Status:** FIXED — `SpanState.ended` is now `std.atomic.Value(bool)` and
`Span.end()` claims it with a single `swap(true, .acq_rel)`, so a span
fires `on_end` (and is therefore enqueued/recycled) exactly once even
under concurrent `end()` on the same SpanState. This closes the
double-enqueue → double-recycle UAF. Regression cover:
`test/bsp_span_reuse_race.zig` (deterministic same-span double-end
exactly-once assertion + 8-producer integration shape). Closes the
second BSP race surface after `0c34ce9`.

**Status (historical):** OPEN — second race surface, distinct from the
queue-mutex race fixed in `0c34ce9 fix(bsp): close concurrent-producer
race in synchronous-drain build` (2026-04-30, current `main`).
**Filed:** 2026-04-30
**Affected version:** post-`0c34ce9` HEAD (i.e. with the queue mutex
in place).
**Discovered via:** Geode database server crash under multi-connection
QUIC load. systemd journal shows `SIGABRT (status 6)` after ~6 min of
runtime / ~9.4 GiB peak memory at 8 concurrent QUIC clients. Stack
trace below.

---

## TL;DR

`exportBatch`'s for-loop reads `span.kind` (and 12 other field
accesses) from `*SpanState` pointers in `batch[]` **without holding any
mutex**. The previous `0c34ce9` fix closed the queue-mutation race
(`queue.append` ↔ `drainLocked.@memcpy`), but it left the
**span-reuse-while-being-read** race wide open: nothing prevents
another producer thread from `Span.end → batchOnEnd → recycle`-ing a
`*SpanState` whose pointer is still sitting in our `batch[]`.

Compounded by a non-atomic `ended: bool` flag in `SpanState` (see
`src/api/trace.zig:101, 213-214`) — two threads racing on `Span.end()`
of the same `*Span` value can each pass the
`if (s.ended) return;` check and queue the **same** `*SpanState`
twice, after which the second recycle UAF's the first reader.

---

## Symptom

```text
Apr 30 16:25:50 haleth geode[2938560]: General protection exception (no address available)
Apr 30 16:25:50 haleth geode[2938560]: zig-pkg/otel-0.1.0-B0v3lr2UMwA5qFJCa20OT-1huDPLm1sTIFD22PQBADDD/src/sdk/export.zig:347:29  in exportBatch
Apr 30 16:25:50 haleth geode[2938560]: zig-pkg/otel-0.1.0-B0v3lr2UMwA5qFJCa20OT-1huDPLm1sTIFD22PQBADDD/src/api/trace.zig:216:30   in end
Apr 30 16:25:50 haleth geode[2938560]: src/storage/user_storage.zig:328:48                                                          in findUserByUsernameInGraph
…
Apr 30 16:25:50 haleth geode[2938560]: src/server/quic_connection_handler.zig:2282:28                                               in handleQuicConnection
Apr 30 16:25:50 haleth geode[2938560]: src/transport/thread_pool.zig:333:32                                                         in runSubmittedTask
Apr 30 16:25:51 haleth systemd[1]: geode.service: Main process exited, code=killed, status=6/ABRT
Apr 30 16:25:51 haleth systemd[1]: geode.service: Consumed 6min 3.776s CPU time, 9.4G memory peak.
```

The hash `B0v3lr2UMwA5qFJCa20OT-1huDPLm1sTIFD22PQBADDD` matches
`gitlab.com/devnw/zig/otel @ 0c34ce9bcd8a7a8fb59257344344d053519565cd`
— i.e. the binary already contains the queue-mutex fix.

`export.zig:347:29` is `.kind = span.kind,` inside the for-loop:

```zig
for (batch, 0..) |span, i| {
    datas[i] = .{
        .name = span.name,
        .span_context = span.sc,
        .parent_span_id = span.parent_span_id,
        .kind = span.kind,                                     // <-- crashes here
        .start_unix_nano = span.start_unix_nano,
        .end_unix_nano = span.end_unix_nano orelse span.start_unix_nano,
        .status_code = span.status_code,
        .status_description = span.status_description,
        .attributes = &span.attributes,
        .events = span.events.items,
        .links = span.links.items,
        .instrumentation_scope = span.instrumentation_scope,
        .resource = self.resource_ref,
        .dropped_attributes_count = span.attributes.dropped,
    };
}
self.export_mutex.lock();
_ = self.exporter.exportSpans(datas) catch {};
self.export_mutex.unlock();
for (batch) |s| s.recycle();   // <-- pool releases happen here
```

`General protection exception (no address available)` indicates the
CPU attempted to read from an unmapped page; this is consistent with
`span` holding a SpanState pointer whose backing arena was already
deinit'd by another thread's `recycle() → Pool.tryRelease == false →
SpanState.deinit()` (line `src/api/trace.zig:189`).

---

## Two distinct defects, same crash site

### Defect 1: `SpanState.ended` is non-atomic

`src/api/trace.zig:101`:

```zig
ended: bool = false,
```

`src/api/trace.zig:213-214`:

```zig
pub fn end(self: Span, end_unix_nano: ?u64) void {
    const s = self.state orelse return;
    if (s.ended) return;            // racy read
    s.ended = true;                 // racy write
    ...
    if (s.on_end) |cb| cb(s.on_end_ctx, s);  // batchOnEnd(s) → queue.append
}
```

Two threads holding distinct `Span` values whose `state` aliases the
same `*SpanState` (e.g. an `*Span` smuggled through application code,
or a span pool reuse race — see below) can each read `ended == false`,
each set `ended = true`, and each propagate the on-end callback to the
processor. Result: **the same `*SpanState` is appended to the queue
twice**.

When the BSP later drains it:

```text
queue:  [..., span_X, span_X, ...]
drainLocked → batch = [..., span_X, span_X, ...]
exportBatch iter i:    reads span_X.kind   (OK)
exportBatch iter i+k:  reads span_X.kind   (OK — recycle hasn't run yet)
…end of for-loop…
exporter.exportSpans(datas)
for (batch) |s| s.recycle();   // recycles span_X TWICE
                                //  - 1st recycle: SpanState in pool free-list
                                //  - 2nd recycle: re-frees / double-pool-release
```

### Defect 2: pool-released span re-acquired by another thread mid-export

Even without Defect 1, the for-loop reads are unprotected. A
concurrent producer can:

1. Call `Span.end()` on a different `*SpanState` (call it `span_Y`).
2. `batchOnEnd(span_Y)` flushes if
   `queue.items.len ≥ max_export_batch_size` on **its own thread**,
   runs **its own** drain + exportBatch.
3. **Its own** for-loop completes → its own
   `for (batch) |s| s.recycle()` releases `span_Y` to the pool
   free-list (`src/sdk/span_pool.zig:62`).
4. Now `span_Y` is observable by `Tracer.startSpan` on **any**
   thread: `src/sdk/trace.zig:355-365`

   ```zig
   reused.sc = sc;
   reused.start_unix_nano = start_ns;
   reused.instrumentation_scope = scope;
   …
   state.kind = opts.kind;            // <-- mutation visible to the OTHER thread's still-running for-loop
   if (parent_sc) |psc| state.parent_span_id = psc.span_id;
   ```

If — at the moment of step 4 — Thread A is in iteration *i* of *its*
for-loop and `batch_A[i] == span_Y` (because span_Y was in A's batch
via double-queueing, or because A and B share the queue and B drained
**after** A queued span_Y but **before** A drained), Thread A will
read mutated/torn `kind`, `name`, `attributes`, etc. The `name` field
is particularly risky because `recycle()` does
`child.free(self.name); self.name = &.{}` (`src/api/trace.zig:163-164`)
— Thread A's `.name = span.name,` then captures the empty slice or
worse, a slice pointing at freed memory if reuse already re-`dupe`d.

The diamond-dep on `thread_pool` versions in geode's binary
(`thread_pool-0.2.0-…dQCU0Y_-zzOoXuytAgqEkDkfuw2nB-YxUmEL` and
`thread_pool-0.2.1-…dgA9Y33CKQAssNN0It53bpRXpmWNmvDqHQXB` both in the
same crash stack) probably *amplifies* the timing window because two
distinct compiled task-dispatch paths interleave more aggressively
than either alone, but the race is **inherent** to the OTel SDK and
would fire on a single thread_pool version too.

---

## Reproduction

The deterministic Zig-side reproducer (no Geode dependency):

```zig
// test/test_bsp_span_reuse_uaf.zig
test "BSP exportBatch survives concurrent producer recycle" {
    const allocator = std.testing.allocator;

    const InMemRecorder = struct { … };
    var recorder: InMemRecorder = .{ … };

    var bsp = try BatchSpanProcessor.init(allocator, .{
        .exporter = recorder.exporter(),
        .max_export_batch_size = 2,   // force frequent drains
        .max_queue_size = 1024,
    }, &Resource.empty);
    defer bsp.deinit();

    var tp_handle = try @import("../src/sdk/trace.zig").TracerProvider.init(allocator, …);
    defer tp_handle.deinit();
    tp_handle.addProcessor(bsp.processor());

    const tracer = tp_handle.getTracer("test", "0.0.0", null, null);

    const N_THREADS = 8;
    const N_PER_THREAD = 1000;
    var threads: [N_THREADS]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, struct {
            fn run(tracer_: anytype) void {
                var i: usize = 0;
                while (i < N_PER_THREAD) : (i += 1) {
                    var span = tracer_.startSpan(Context.empty(), "s", .{}) catch return;
                    span.setIntAttribute("i", @intCast(i)) catch {};
                    span.end(null);
                }
            }
        }.run, .{ tracer });
    }
    for (&threads) |*t| t.join();

    try bsp.forceFlush(5_000);
    try std.testing.expectEqual(@as(usize, N_THREADS * N_PER_THREAD), recorder.count);
}
```

Run with `zig build test -fsanitize=thread` (or
`-Dotel_use_devnw_pool=true` AND `-Dotel_use_devnw_pool=false`
matrix):

- **Expected post-fix**: clean pass on both build configurations.
- **Current behavior**: SIGSEGV in `exportBatch` for-loop, OR
  `recorder.count != 8000`, OR ThreadSanitizer reports data race on
  `SpanState.ended`, `SpanState.name`, `SpanState.kind`.

---

## Affected files

| File | Lines | Defect |
|---|---|---|
| `src/api/trace.zig` | 101 | `ended: bool` should be `std.atomic.Value(bool)` |
| `src/api/trace.zig` | 213-214 | non-atomic compare-exchange on `ended` |
| `src/sdk/export.zig` | 343-368 | for-loop reads `span.*` fields without lock |
| `src/sdk/export.zig` | 371 | `for (batch) \|s\| s.recycle()` releases pointers that may still be referenced from other threads' in-flight `batch[]` slices when the same SpanState was double-queued |

---

## Proposed fix sketch

1. **Make `SpanState.ended` atomic** (`src/api/trace.zig:101`):

   ```zig
   ended: std.atomic.Value(bool) = .{ .raw = false },
   ```

   And replace the racy check in `Span.end`:

   ```zig
   pub fn end(self: Span, end_unix_nano: ?u64) void {
       const s = self.state orelse return;
       if (s.ended.cmpxchgStrong(false, true, .acq_rel, .acquire) != null) return;
       s.end_unix_nano = end_unix_nano orelse posixNow(s.start_unix_nano);
       if (s.on_end) |cb| cb(s.on_end_ctx, s);
   }
   ```

   Update every other reader (`isRecording`, `setName`,
   `setAttribute`, `setStringAttribute`, `setIntAttribute`,
   `setStatus`, `addEvent`, `addLink`) to use `.load(.acquire)`.

2. **Defer recycle until after the data has been fully consumed by
   the exporter** AND make recycle observe a refcount so the SAME
   pointer appearing twice in `batch[]` only triggers one pool
   release. The simplest correct approach: dedupe `batch[]` at drain
   time (inside `drainLocked`) — emit a warning when the same
   `*SpanState` appears twice, drop the duplicate.

3. **Hold `export_mutex` over the for-loop AND the recycle**, not
   just over the `exporter.exportSpans` call. The current code:

   ```zig
   for (batch, 0..) |span, i| { datas[i] = .{ … }; }
   self.export_mutex.lock();
   _ = self.exporter.exportSpans(datas) catch {};
   self.export_mutex.unlock();
   for (batch) |s| s.recycle();
   ```

   should become:

   ```zig
   self.export_mutex.lock();
   defer self.export_mutex.unlock();
   for (batch, 0..) |span, i| { datas[i] = .{ … }; }
   _ = self.exporter.exportSpans(datas) catch {};
   for (batch) |s| s.recycle();
   ```

   This single change closes Defect 2 because no other producer
   thread can enter `exportBatch` (also gated by `export_mutex`) and
   run `recycle()` on a span pointer we still hold.

   The cost is concurrency: with N producers each in BSP, exports
   serialize. That is **already the spec-required behaviour** — OTel
   SDK §6 forbids concurrent exporter calls. The current code only
   serializes `exportSpans` itself; widening the critical section to
   include the for-loop does not regress observed throughput because
   the exporter dominates.

4. **Inside `recycle()` (`src/api/trace.zig:187`)**, before
   `r.returnFn(r.ctx, self)`, fence the field-clear writes so any
   thread observing the SpanState on the pool's free-list sees the
   cleared values:

   ```zig
   @atomicStore(?*anyopaque, @ptrCast(&self.on_end), null, .release);
   if (r.returnFn(r.ctx, self)) return;
   ```

   (or wrap the whole recycle body in the same export_mutex section
   per fix 3.)

---

## What this isn't

- **Not the same as `0c34ce9`**: that fix added a real
  `std.Io.Mutex` to the queue (`mutex` field), closing the
  `queue.append` ↔ `drainLocked.@memcpy` race. The for-loop reads
  *after* drain are an entirely separate access pattern.
- **Not caused by `-Dotel_use_devnw_pool` toggle**: defects 1 and 2
  fire in both build configurations. The async path also reads
  `span.kind` etc. from a non-locked `batch[]`.
- **Not caused by the diamond-dep on `thread_pool`**: that's a
  separate packaging hazard (geode pins 0.2.1 directly, transitive
  paths still pull 0.2.0). It probably *increases* the race
  amplification but the race is inherent.
- **Not the `quic_min_smoothed_rtt_ns=0xAAAAAAAAAAAAAAAA` log line**:
  cosmetic uninit-stat sentinel, documented in
  `geode/.claude/skills/geode-harness-fix-loop/SKILL.md` and
  unrelated to the SIGABRT.

---

## See also

- Previous fix: `0c34ce9 fix(bsp): close concurrent-producer race in synchronous-drain build`
- `BUG_LONG_RESPONSE_STREAM_STALL.md` in
  `~/src/devnw/zig/quic/docs/` — adjacent multi-thread server-side
  bug fixed in `1226ece` (different library, same kind of "race
  surface that the application layer doesn't see").
- Geode-side context:
  - geode commit `2a9ea3a6 chore(deps): bump quic+otel+client_zig, re-add create_edge span` — the bump that put the otel `0c34ce9` fix into production, where this second race then surfaced.
  - `~/src/devnw/codepros/geode/geode/src/storage/user_storage.zig:328` — the user-visible call site (`findUserByUsernameInGraph` → `getNodesByLabel` emits a span on every concurrent QUIC auth check).
  - `~/src/devnw/codepros/geode/geode/.claude/projects/.../memory/preexisting_harness_failures.md` — geode-side memory note tracking pre-existing failures gated on this and other deps.
