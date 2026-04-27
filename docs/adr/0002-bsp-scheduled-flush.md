# ADR-0002: BSP scheduled flush via `schedule_delay_ms`

* Status: Accepted
* Date: 2026-04-27
* Deciders: benji at codepros.org
* Related: P0-9 (#22), AM 2026-04-26 audit notes

## Context

`BatchSpanProcessorOptions.schedule_delay_ms` was declared (default
5 000 ms) but never read. The processor only drained the queue on
two triggers:

1. **Queue fill** — `batchOnEnd` calls `submitDrain` when the queue
   reaches `max_export_batch_size`.
2. **Caller-driven flush** — `forceFlush` runs to completion.

A producer that emits below the batch threshold could therefore see
its spans sit in the queue until either a flush call or a queue-fill
event. That defeats the spec's "spans should leave the SDK within
schedule_delay_ms of being recorded" guarantee and gives users
indefinite tail latency on debug traces.

## Considered options

### A. Don't wire it; document the gap

Keep `schedule_delay_ms` as advisory metadata. Tell users they need
to call `forceFlush` themselves on a timer.

* ❌ Spec violation. OpenTelemetry users expect the field to mean
  what it says.
* ❌ Forces every embedder to write the same boilerplate.

### B. Per-process timer thread (chosen)

Spawn one `std.Thread` per BatchSpanProcessor that wakes every
`schedule_delay_ms` and submits a drain task if the queue is non-
empty. The thread is gated on `use_devnw_pool && async_workers > 0`
because that's where `tp.sync.Mutex` / `tp.sync.Condition` (the
synchronisation primitives we need to interrupt the timer's sleep
on shutdown) are available; without those, periodic flush would
race the producer in the no-op-mutex path.

* ✅ Standard implementation pattern; matches the OTel Go/Java/JS
  SDKs almost verbatim.
* ✅ Bounded latency upper bound = `schedule_delay_ms`.
* ✅ Zero overhead when the queue is steady — the timer just rearms.
* ✅ Cooperative shutdown: a condition variable lets `deinit` cancel
  the sleep instead of waiting for the next tick.
* ❌ Adds one dedicated thread per provider. Acceptable in
  process-level providers; the alternative — sharing a global
  scheduler — leaks state across providers.

### C. Stdlib-thread fallback (deferred)

Make the timer + drain pump also work when `use_devnw_pool=false`
by using `std.Io.Threaded` + `std.Io.Mutex` directly.

* ✅ Removes the `use_devnw_pool` build dependency for periodic
  flush.
* ❌ Significantly larger surface: `std.Io.Threaded.init` allocates,
  spawns its own worker pool, and threads an `Io` argument through
  every mutex operation. Plumbing an `Io` through the
  `SpanProcessor` vtable is a public API break.
* ❌ Out of scope for this commit. Tracked as a follow-up that we
  open if a real consumer asks for it; today every active embedder
  has the DevNW pool flag on.

## Decision

Adopt **Option B**.

Field `schedule_delay_ms_actual` is the runtime value (copied from
options on `init`). Setting it to 0 disables the timer (e.g. for
synchronous tests or tight-budget embeds that prefer manual
flushes). The 5 000 ms default is preserved.

The cooperative-shutdown handshake uses two new fields:

* `shutdown_requested: std.atomic.Value(bool)` — read by the timer
  before each sleep; latched true by `deinit`.
* `shutdown_cond` + `shutdown_cond_mu` — `timedWait` with the
  schedule delay; broadcast by `deinit`. The thread observes the
  flag immediately after wake.

`deinit` must broadcast *and* join *before* tearing down the pool,
otherwise the timer's in-flight `submitDrain` could land on a
freed pool. Order in code: set flag → broadcast → join → pool
deinit.

## Consequences

* Latency upper bound for un-flushed spans drops from "until next
  forceFlush or batch-fill" to `schedule_delay_ms` (default 5 s).
* +1 thread per BSP. Memory footprint: ≈ 2 MB stack, negligible.
* No behaviour change when `async_workers = 0` (synchronous mode)
  or `schedule_delay_ms = 0` (explicit disable).
* The follow-up Option C work is recorded; the API on the SDK
  surface (option name, default, units) is forward-compatible with
  it.
