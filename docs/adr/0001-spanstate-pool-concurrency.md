# ADR-0001: SpanState pool concurrency model

* Status: Accepted
* Date: 2026-04-27
* Deciders: benji at codepros.org
* Related: P0-2 (#6, GitLab), AM 2026-04-26 audit notes ("concurrent-producer story pending")

## Context

`api.trace.SpanState.init` currently does **2 small heap allocations**
per recorded span (the SpanState struct + the name dupe), plus the
implicit cost of standing up a fresh `ArenaAllocator` (which page-
faults its first allocation on demand). At ~2 µs per span on
`micro_span_record_steady_state`, this is the dominant cost on the
trace hot path.

The straightforward optimisation — pool drained `SpanState`s and
recycle them via `arena.reset(.retain_capacity)` — runs into a
concurrency question that the AM 2026-04-26 audit explicitly flagged
as needing a design call:

> P0-2 SpanState pool concurrency contract — the AM audit explicitly
> flagged "concurrent-producer story pending." Without a clear MPSC
> pool contract, the obvious single-thread `arena.reset(.retain_capacity)`
> will race when multiple threads start spans concurrently.

Trace producers in OpenTelemetry are *intrinsically concurrent*: any
thread in the user's process can call `tracer.startSpan()`. The pool
must therefore tolerate concurrent acquire/release without corruption.

## Considered options

### A. Thread-local pool

Each thread maintains its own freelist as a `threadlocal var`.

* ✅ Zero contention; near-optimal for high-core-count workloads.
* ❌ No automatic teardown when a thread exits — pooled SpanStates
  for a dead thread would leak until provider deinit. Requires an
  explicit `releaseThreadPool()` from each tracing thread, which is
  a footgun for embedders.
* ❌ Pool sizing is per-thread, so total memory cost scales with
  thread count even when individual threads are idle.

### B. Mutex-guarded freelist (chosen)

A single intrusive freelist on the TracerProvider, guarded by
`std.Thread.Mutex`. acquire pops from the head; release pushes onto
the head; both run under the lock.

* ✅ Trivially correct; reviewable by anyone who has seen a freelist.
* ✅ Pool is process-global; idle threads don't waste capacity.
* ✅ Cleanup at `TracerProvider.deinit` is a single drain.
* ❌ Lock contention scales with concurrent span starts. With span
  end on a different thread (BSP pump) the release path also takes
  the lock. At low-to-moderate concurrency (≤8 producer threads
  emitting < 1M spans/sec each) this is well below contention
  threshold (the lock is held for two pointer ops).
* ❌ Worst case at high concurrency: degrades to mutex-contention-
  bound throughput. Solvable by escalating to Option C if a real
  workload demonstrates the contention.

### C. Lock-free MPSC freelist

Treiber stack with `cmpxchgWeak`-based push and pop, using ABA-safe
tagging (Zig 0.16's `std.atomic.Value` with version counter).

* ✅ Best-in-class scaling.
* ❌ Significantly more complex; ABA bugs are a real risk; needs
  extensive stress testing before trust.
* ❌ Premature without measured contention data.

### D. Per-tracer pools

Each `Tracer` value owns its own pool. Avoids cross-thread sharing
when each component holds a stable Tracer.

* ❌ Defeats pooling: in practice users share one Tracer across many
  producer threads (the Tracer value is cheap-to-copy, but hot
  components reuse the handle).
* ❌ Memory overhead scales with Tracer count, not with active
  producers.

## Decision

Adopt **Option B** (mutex-guarded freelist) as the initial pool
implementation. This buys most of the perf win at minimal complexity
and review cost. We treat Option C as a follow-up gated on observed
contention; the freelist API is shaped so that the producer code
does not change when (if) we swap the implementation.

Pool cap: **128 entries**. Larger than typical sustained-burst depth
(~32 spans in flight); sized to bound the worst-case retained memory
to ~128 × (SpanState struct + arena page) ≈ 128 × ~5 KiB = 640 KiB
per provider. When the pool is full on release we fall through to
the existing `deinit` path.

## Consequences

* `TracerProvider.deinit` must drain the pool before the allocator
  is invalidated. Tests catch leaks via the testing allocator.
* `SpanState.deinit` semantics are unchanged for callers; the pool
  layer is internal to the SDK. The processor pipeline still calls
  the deinit it already does — that call now routes through the
  pool's `release`.
* `arena.reset(.retain_capacity)` is the recycle primitive. The
  arena's first page is preserved, so re-used spans pay no page
  fault on their first attribute. Subsequent overflow pages are
  freed at reset, capping retained memory per slot to one page.
* If we add custom allocators per-tracer in the future, we will
  need a per-allocator pool keyed off the allocator pointer. Out
  of scope today.
