# P0-2 — SpanState reuse pool

Closes GitLab issue **#6** (P0, PerfScore 72) and resolves the
related **P1-4 #42** (SpanState arena first-page mmap on every
span). Concurrency design captured in
[ADR-0001](../../adr/0001-spanstate-pool-concurrency.md).

## Hypothesis

Every recorded span paid for:

1. `allocator.create(SpanState)` — heap-allocated struct
2. `allocator.dupe(name)` — name copy via the parent allocator
3. `ArenaAllocator.init` — zero allocations until first `allocator()`
   call, but the first allocation page-faults via `mmap`
4. `AttributeSet`'s own arena — same mmap pattern
5. `events`/`links` ArrayLists — first append page-allocates the
   backing buffer

Span end then ran `SpanState.deinit`, releasing every one of those
back to the OS / general allocator. Long-running services that
sustain a few hundred thousand spans/sec saw the SpanState struct
plus arena page churn as the dominant cost on the trace hot path.

## Change

Three coordinated edits:

1. **`SpanState.recycle`** (api/trace.zig) — new end-of-life hook.
   Resets transient state (name, status_description, events, links,
   attributes) but **retains** the SpanState struct + arena's first
   page + ArrayList capacities + AttributeSet hash buckets.
2. **`AttributeSet.reset`** (internal/attributes.zig) — reset
   primitive used by `recycle`. Calls
   `arena.reset(.retain_capacity)` plus
   `clearRetainingCapacity()` on the entries vec and hash index.
3. **`sdk/span_pool.zig`** (new) — mutex-guarded freelist of drained
   SpanStates. Cap at 128 (see ADR). Lock collapses to a no-op when
   the async pool is off (single-thread producer = consumer).

`TracerProvider` owns the pool, drains it on `deinit`, and wires the
recycler on every fresh SpanState. The four `state.deinit()` call
sites in `sdk/trace.zig` and `sdk/export.zig` (Simple processor,
BSP queue overflow, BSP successful export, BSP shutdown) now route
through `state.recycle()`, which falls through to `deinit` only when
the pool is full.

## A/B

`zig build -Doptimize=ReleaseFast bench-micro -- --filter
micro_span_record_steady_state` (median of 6 samples; new bench
added in this commit).

| Metric | Before | After | Δ |
|--------|---:|---:|---:|
| Wall time p50 | 2044 ns/op | 1040 ns/op | **1.97×** speedup |
| Allocations | 10.02 / op | 6.03 / op | -4 per span |
| Allocator bytes | 1384 B / op | 625 B / op | -55% |

The four allocations the pool eliminates per span are: the
SpanState struct, the arena's first page, the AttributeSet arena's
first page, and the ArrayList backing buffers for events + links
(amortised: first append per span absent in the pool path).

## Risks / follow-ups

- **Pool cap (128).** Bursty spikes above 128 in-flight spans fall
  through to `deinit`, exactly as before. Steady-state at >128
  in-flight would benefit from a higher cap; documented in the
  ADR.
- **Mutex contention** at very high concurrency. ADR Option C
  (lock-free Treiber stack) is the documented escalation path. We
  ship the simple version first, measure, escalate if needed.
- **`Span.recycle` correctness on partial init.** A span that errors
  mid-`startSpan` (e.g. dupe of `name` fails) calls the SpanState's
  `errdefer destroy` — that path is unchanged. Pool only ever
  receives fully-constructed spans handed off from the processor.
- **Test isolation.** The testing allocator detects leaks via
  reference counting, so the pool's `deinit()` correctly tears
  down every retained SpanState. Confirmed by `zig build test`
  PASS across the existing 102-test suite.
