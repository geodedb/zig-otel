# ADR-0003: Default to BatchSpanProcessor for `default_exporter`

* Status: Accepted
* Date: 2026-04-27
* Deciders: benji at codepros.org
* Related: P0-10 (#28), ADR-0002 (BSP scheduled flush)

## Context

`TraceConfig.default_exporter` is a convenience field: callers
supply a `SpanExporter` and the SDK wires it into a default
processor without forcing them to write the processor boilerplate.
Until now the SDK wrapped that exporter in a
**SimpleSpanProcessor** — every `Span.end` synchronously calls
the exporter on the producer thread.

Real workloads almost always want **BatchSpanProcessor**: spans
buffer in a queue and the BSP flushes them in batches, off the
producer hot path. Every other major OpenTelemetry SDK
(Go, Java, JS, Python, .NET) defaults to BSP for exactly this
reason. Defaulting to Simple means new users who pick the obvious
"give me a default processor" knob inherit a synchronous,
allocator-pressured, blocking export on every span. They have to
read the source to discover the BSP exists.

The cost of fixing this is that tests and benchmarks that depend
on synchronous post-`end` visibility break: BSP buffers, so
`recorder.spans.items.len == N` right after the loop now reads 0.

## Considered options

### A. Add a `default_processor_kind: enum { simple, batch }` field

Default it to `.batch`; keep `default_exporter` as the wrap target.

* ✅ Surfaced explicitly in the config; users see what they get.
* ❌ More API surface. The "I just want a default" path is now
  two fields, not one.
* ❌ Defers the actual default flip — users still have to
  affirmatively pick `.batch` to opt out of `.simple` if we
  default to keeping legacy behaviour, or affirmatively pick
  `.simple` if we flip the default.

### B. Flip `default_exporter` to wrap in BSP (chosen)

`default_exporter` stays a single field; the wrapping changes from
`SimpleSpanProcessor` to `BatchSpanProcessor` with sensible
defaults (`async_workers = 1`, `schedule_delay_ms = 5_000`,
`max_export_batch_size = 512`). Callers who actually need
synchronous flush (most tests) drop into the lower-level
`processors` field with an explicit Simple processor.

* ✅ Matches every other OTel SDK.
* ✅ Aligns the obvious-default path with the production-correct
  behaviour. New users get the right answer for free.
* ✅ One-line caller fix when sync is genuinely needed
  (`processors = &.{ simple.processor() }`).
* ❌ Behaviour change. Every existing test that asserts on
  recorder state directly after `span.end()` needs a `forceFlush`
  call. CHANGELOG entry is mandatory.

### C. Keep Simple as the default, document BSP

Status quo. New users continue to inherit the synchronous default.

* ❌ Users who don't read the source learn the lesson at
  production scale. The whole point of the convenience field is
  that the obvious answer is also the right answer.

## Decision

Adopt **Option B**.

Defaults the SDK applies when `default_exporter` is set:

* `async_workers = 1` — one worker thread is enough to keep
  exports off the producer hot path.
* `schedule_delay_ms = 5_000` — matches the OTel spec
  recommendation; ADR-0002 has already wired this.
* `max_queue_size = 2048`, `max_export_batch_size = 512` — the
  existing BSP defaults.

When `build_options.use_devnw_pool` is **off** (no DevNW thread
pool), the BSP still buffers spans in its queue but the timer
thread + async drain are inert (see ADR-0002 Option C — deferred).
In that mode the producer pays only the queue-append cost; spans
flush on `forceFlush` or queue-fill, exactly as today's
synchronous-drain BSP path. This keeps the no-pool build green
without forcing a Simple-vs-BSP switch on the caller.

## Consequences

* **Test/bench migration.** Every direct `recorder.spans.items.len`
  read needs an `tp.forceFlush(timeout_ms)` before it. The flip
  is one-line per call site.
* **CHANGELOG migration entry.** Users upgrading across this
  change must either accept BSP semantics (recommended) or wire an
  explicit `SimpleSpanProcessor` via the `processors` field
  (one-time mechanical edit).
* **Example update.** `examples/basic.zig` and
  `examples/http_client.zig` get a `forceFlush` before exit and
  a comment pointing at this ADR.
* **`SimpleSpanProcessor` is not deprecated.** It remains the
  right tool for in-process tests, golden-file goldens, and any
  embedder that wants a strict-ordering one-batch-per-span
  contract.
