# Benchmark Architecture: zero-overhead-when-disabled

**Run directory:** `docs/performance/2026-04-26-zero-overhead-when-disabled/`
**Date:** 2026-04-26
**Baseline ref (ref-A):** `4de1b11` on `main`
**Language:** Zig (native toolchain only — `zig build`)

---

## 1. Goal

Two parallel questions the user needs answered empirically:

**Axis A — Runtime-noop overhead.** The API layer already has a vtable
no-op path (`Tracer.startSpanFn` defaults to `noopStart` in
`src/api/trace.zig:243`). The question is whether that path is genuinely
free. The bench system must measure `noop-tracer-startend` (API layer noop,
no SDK provider) and `runtime-disabled-alwaysOff` (SDK linked,
`Sampler.alwaysOff`) against a hard control (`baseline-no-call`) and a
fully-enabled reference (`fully-enabled-alwaysOn-inmemory`). Expected
outcome: both noop variants are within the noise floor of the control; the
enabled variant is measurably higher.

**Axis B — Compile-time elision.** A new build option `-Dotel_disabled=true`
(not yet wired in `build.zig`) is intended to make the compiled binary
contain no reachable OTel code paths at all. The bench system must prove
that a binary compiled with `-Dotel_disabled=true` and then calling
`tracer.startSpan` produces a `ns_per_op_median` indistinguishable from
`baseline-no-call` and an `alloc_count` of exactly zero. This is the
headline claim of the feature.

Secondary goal: produce a **level-graded cost ladder** (levels 0–6) so
future callers can read off the incremental cost of each telemetry
component.

Targeted hot paths (from code inspection):

| Source | Symbol | Why it matters |
|--------|--------|----------------|
| `src/api/trace.zig:243` | `Tracer.startSpanFn` (vtable dispatch) | Every span start goes here on the noop path |
| `src/sdk/trace.zig:219-261` | `startSpan` | ID generation (lines 224-225), sampler call (227), `SpanState.init` allocation |
| `src/internal/id.zig:215-231` | `randomTraceId`/`randomSpanId` | PRNG-backed; even alwaysOff still generates IDs (sdk/trace.zig:224-225) |
| `src/internal/clock.zig:21-44` | `unixNanoNow` | `clock_gettime(REALTIME)` syscall on every `span.end` |
| `src/internal/attributes.zig:115-140` | `AttributeSet.put` | Linear scan O(n) for dedup; `arena.dupe` allocation |
| `src/internal/redact.zig:26-49` | `isSensitive` | Per-attribute key scan across 6 tokens; called in exporters |
| `src/internal/json_codec.zig` | `writeAttributes` | Sort (`sortedEntries` alloc) + JSON encode on every export |
| `src/sdk/export.zig:395-412` | `batchForceFlush` busy-poll | 200 µs sleep per loop; contaminates any async drain bench |

---

## 2. Scope — scenarios per layer

### 2.1 Micro layer (`benchmarks/micro/`)

Isolated, single-function benches. Each uses a `TrackingAllocator` diff to
assert zero-alloc where the spec allows it. All micro scenarios run with
`optimize = .ReleaseFast` (or `.ReleaseSmall` as a second pass) and a fixed
deterministic clock (`clock.Fixed`) plus a `Sequence` ID generator to
eliminate noise sources unrelated to the target function.

| Scenario ID | Target function | Isolate | Zero-alloc expected |
|-------------|----------------|---------|---------------------|
| `micro_attr_put_new` | `AttributeSet.put` — new key | 4-attr set, string value | No (arena dup) |
| `micro_attr_put_update` | `AttributeSet.put` — existing key update | pre-seeded 4-attr set | No (arena dup) |
| `micro_attr_put_near_limit` | `AttributeSet.put` — 127/128 entries | near-full set | No (arena dup) |
| `micro_next_trace_id` | `id.Random.nextTraceId` | PRNG only | Yes |
| `micro_next_span_id` | `id.Random.nextSpanId` | PRNG only | Yes |
| `micro_clock_unix_nano` | `clock.unixNanoNow` | syscall cost | Yes |
| `micro_redact_is_sensitive_miss` | `redact.isSensitive` — non-sensitive key | "http.method" | Yes |
| `micro_redact_is_sensitive_hit` | `redact.isSensitive` — sensitive key | "authorization" | Yes |
| `micro_json_write_attrs_4` | `json_codec.writeAttributes` — 4 attrs | arena provided | No (sort alloc) |
| `micro_json_write_attrs_32` | `json_codec.writeAttributes` — 32 attrs | arena provided | No (sort alloc) |
| `micro_noop_vtable_dispatch` | `Tracer.startSpanFn` noop only | direct call, noop provider | Yes |

Total micro scenarios: **11**

### 2.2 Integration layer (`benchmarks/integration/`)

End-to-end span lifecycle benches (start + setAttribute x4 + end) at
multiple span counts. Sweep is 1, 100, 10 000 spans per iteration.
All integration scenarios use `async_workers=0` (synchronous drain) for
this round because the `batchForceFlush` 200 µs busy-poll (V-4) would
dominate async results and mask the real signal. Async-drain scenarios are
marked as future work (see Section 11).

Scenarios:

| Scenario ID | Level | Provider config | Span count |
|-------------|-------|-----------------|------------|
| `integ_level3_sync_1span` | tracing-on | TracerProvider + alwaysOn + InMemoryExporter | 1 |
| `integ_level3_sync_100spans` | tracing-on | same | 100 |
| `integ_level3_sync_10kspans` | tracing-on | same | 10 000 |
| `integ_level4_sync_100spans` | + metrics | level-3 + MeterProvider + Counter + Histogram + InMemoryExporter | 100 |
| `integ_level5_sync_100spans` | + logs | level-4 + LoggerProvider + InMemoryExporter | 100 |
| `integ_level6_otlp_loopback_100spans` | + OTLP/HTTP | level-5 + OtlpHttpExporter pointing at a `std.net.Server` loopback that discards bytes | 100 |

Total integration scenarios: **6**

### 2.3 Comparison layer (`benchmarks/compare.zig` + A/B runner)

The comparison layer is the primary evidence surface for both axes. It runs
two binary variants side-by-side using the `bench-ab` runner and writes a
pair of JSON result documents that `bench-compare` diffs.

#### Axis A — four-corner comparison

| Scenario ID | Binary variant | Provider setup |
|-------------|----------------|---------------|
| `baseline-no-call` | default (`-Dotel_disabled=false`) | no OTel call at all; caller body is a counter increment |
| `noop-tracer-startend` | default | API-layer noop Tracer (no SDK init) — `startSpan` + `span.end(null)` |
| `runtime-disabled-alwaysOff` | default | SDK `TracerProvider.init` with `Sampler.alwaysOff()`; `startSpan` + `span.end(null)` |
| `fully-enabled-alwaysOn-inmemory` | default | SDK `TracerProvider.init` with `Sampler.alwaysOn()` + `InMemoryExporter`; 1 span with 4 attrs |

#### Axis B — compile-time elision pair

| Scenario ID | Binary variant | Provider setup |
|-------------|----------------|---------------|
| `comptime-disabled` | `-Dotel_disabled=true` | `tracer.startSpan(...); span.end(null);` — same call site as noop |
| `runtime-disabled-noop` | `-Dotel_disabled=false` | API-layer noop Tracer — same call site |

#### Level ladder (all in default binary)

| Scenario ID | Components active |
|-------------|-------------------|
| `level-0-disabled` | `-Dotel_disabled=true` (axis B binary) |
| `level-1-tracer-noop` | API-layer noop tracer |
| `level-2-tracer-alwaysoff` | SDK + alwaysOff sampler |
| `level-3-tracing-only` | SDK + alwaysOn + InMemoryExporter |
| `level-4-tracing-metrics` | level-3 + MeterProvider + Counter + Histogram + InMemoryExporter |
| `level-5-tracing-metrics-logs` | level-4 + LoggerProvider + InMemoryExporter |
| `level-6-full-otlp-http-loopback` | level-5 + OtlpHttpExporter → loopback discard server |

Fixed "unit of work" for all level scenarios: emit 1 span with 4 string
attributes, increment 1 Counter with 2 attributes, record 1 Histogram value
with 2 attributes, emit 1 LogRecord with 3 attributes. Attribute counts and
key/value shapes are identical across levels so deltas reflect configuration
overhead only.

Total comparison scenarios: **13**

**Grand total across all layers: 30 scenarios.**

---

## 3. Result schema usage

The existing `benchmarks/framework.zig` `ResultRow` is the canonical output
struct. The implementation phase will add an envelope layer for comparison
scenarios that carries the universal fields needed for cross-run correlation.
Neither the `ResultRow` definition nor the existing `compare.zig` logic is
modified at the schema level — new fields are additive.

Fields each scenario emits:

### Framework fields (existing `ResultRow`)

| Field | Description |
|-------|-------------|
| `git_sha` | Output of `git rev-parse HEAD` |
| `run_timestamp_unix_s` | Unix epoch seconds at run time |
| `zig_version` | `builtin.zig_version_string` |
| `os` | `@tagName(builtin.os.tag)` |
| `arch` | `@tagName(builtin.cpu.arch)` |
| `cpu` | `builtin.cpu.model.name` |
| `scenario_name` | Stable scenario ID string (matches `id` in plan.json) |
| `ops_per_iteration` | Work units per framework iteration |
| `sample_count` | Number of sampled iterations |
| `wall_ns_min` | Min wall ns across samples |
| `wall_ns_p50` | Median wall ns (primary comparison metric) |
| `wall_ns_p95` | 95th-percentile wall ns |
| `wall_ns_p99` | 99th-percentile wall ns |
| `wall_ns_max` | Max wall ns |
| `wall_ns_stddev` | Stddev of wall ns samples |
| `throughput_ops_per_sec` | Ops/s at median latency |
| `throughput_stddev_ops_per_sec` | Stddev of throughput |
| `alloc_count` | Allocations per iteration (from `TrackingAllocator`) |
| `alloc_bytes` | Allocation bytes per iteration |
| `peak_live_bytes` | Peak live bytes across samples |
| `rss_current_bytes` | RSS at end of run (Linux only) |
| `rss_peak_bytes` | Peak RSS across run (Linux only) |

### Universal envelope fields (added by comparison-layer adapter)

| Field | Source |
|-------|--------|
| `scenario_id` | Same as `scenario_name` |
| `layer` | `"micro"`, `"integration"`, or `"comparison"` |
| `language` | `"zig"` (constant) |
| `variant` | Build variant string, e.g. `"otel_disabled=false"` |
| `command` | Full command used to produce this result |
| `warmups` | Actual warmup count used |
| `rounds` | Actual sample count used |
| `metrics` | Array of metric keys emitted |
| `counters.alloc_delta_bytes` | `alloc_bytes` from `TrackingAllocator` |
| `counters.alloc_threshold_bytes` | Configured zero-alloc threshold (0 when `zero_alloc_expected`) |
| `counters.alloc_assertion` | `"pass"`, `"fail"`, or `"n/a"` |

The `ns_per_op_median` derived field is `wall_ns_p50 / ops_per_iteration`.
The `compare.zig` noise gate already uses `throughput_stddev_ops_per_sec`;
no change needed.

---

## 4. Repo-native commands

The existing `build.zig` already declares four stub steps (`bench`,
`bench-micro`, `scale-bench`, `compare-bench`) that currently alias
`fmt-check`. The implement phase must replace these stubs with
`addRunArtifact` wiring against real executables. Two new steps are added:
`bench-integration` and `bench-ab`. The existing `compare-bench` step is
renamed-alias for `bench-compare` to match the A/B runner contract.

| Step name | Artifact | Purpose |
|-----------|----------|---------|
| `bench-ci` | runs `bench-micro` + `bench-integration` + `bench-compare` in sequence | Full CI bench gate |
| `bench-micro` | `benchmarks/micro/main.zig` executable | All micro scenarios |
| `bench-integration` | `benchmarks/integration/main.zig` executable | All integration scenarios |
| `bench-ab` | `benchmarks/compare.zig` executable (two build variants) | Runs ref-A binary and ref-B binary, emits two JSON files |
| `bench-compare` | `benchmarks/compare.zig` executable | Diffs baseline vs current JSON; exits non-zero on regression |
| `bench-smoke` | `benchmarks/smoke.zig` executable | Sanity: 1 iteration of every comparison scenario; used in macOS CI |

### Step-to-artifact graph (for implement phase)

```text
bench-ci
  -> bench-micro   (addRunArtifact: bench_micro_exe)
  -> bench-integration (addRunArtifact: bench_integration_exe)
  -> bench-compare (addRunArtifact: compare_bench_exe)
       consumes: bench_integration_exe output JSON + stored baseline JSON

bench-ab
  -> build variant A: bench_ab_exe compiled without -Dotel_disabled
  -> build variant B: bench_ab_exe compiled with   -Dotel_disabled=true
  -> runs both, writes docs/performance/2026-04-26-zero-overhead-when-disabled/
       results/ref-a.json and results/ref-b.json

bench-compare
  -> compare_bench_exe --baseline ref-a.json --current ref-b.json
       --floor 3.0

bench-smoke
  -> bench_smoke_exe  (1 warmup, 1 sample; always fast)
```

The existing `scale-bench` step stub remains as an alias for `bench-ci` to
preserve CI catalog compatibility.

---

## 5. A/B protocol

### Baseline ref policy

- ref-A is the git SHA at design time: `4de1b11` (HEAD of `main`).
- ref-B is always `HEAD` at the time `bench-ab` runs.
- The implement phase stores ref-A result JSON under

  `docs/performance/2026-04-26-zero-overhead-when-disabled/results/ref-a.json`.
  It is checked in so future runs can re-compare against the same baseline.

- If a new baseline is desired, rerun `bench-ab --ref-a <new-sha>` and commit

  the new `ref-a.json`.

### Protocol parameters

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Warmup iterations | 3 | Covers cold-cache + allocator one-time setup |
| Sample rounds | 20 | Provides stable p50/p95 with stddev < 5% for most scenarios |
| Stress multiplier | 20 (ops_per_iteration) | Applied to micro scenarios only; set to 10 000 for hot paths |
| Variance gate multiplier | 3.0 | `noise_gate = max(floor_pct, 3.0 * baseline_stddev_pct)` |
| Fixed floor | 3.0% | Below this no regression is flagged regardless of stddev |
| Target gain | +5.0% | Headline claim: comptime-disabled is at least 5% faster than runtime-noop |
| Max regression | -3.0% | Any non-target scenario may not regress beyond this |

These match the `compare.zig` formula already in the repo:

```text
noise_gate = max(floor_pct, 3.0 * stddev_pct)
```

The `--floor` argument to `compare-bench` is set to `3.0` for the
zero-overhead run. The default in the existing `compare.zig` is `15.0`;
the implement phase must add a `--floor` CLI override (already present as
`floor_pct` in `compare.zig:50`) — no code change needed, just pass
`--floor 3.0` from the bench-ci step.

### Comptime-disabled hard criterion

For `comptime-disabled` vs `baseline-no-call`, the regression formula is
replaced with a hard pass criterion (not a noise-gate percentage):

```text
PASS iff:
  abs(ns_per_op_median_a - ns_per_op_median_b) <= 2   (nanoseconds)
  AND alloc_count_b == 0
```

This check is implemented in a thin wrapper script invoked by `bench-ci`
after `bench-compare` exits. It reads the two JSON files and applies the
criterion directly.

---

## 6. Gating

### Variance-aware regression gate

The existing `compare.zig` already implements the formula. The bench-ci
pipeline applies it as follows:

1. `bench-micro` runs all 11 micro scenarios, writes `micro.json`.
2. `bench-integration` runs all 6 integration scenarios, writes `integ.json`.
3. `bench-ab` runs all 13 comparison scenarios in two builds (enabled vs

   disabled), writes `ref-a.json` and `ref-b.json`.

4. `bench-compare --baseline ref-a.json --current ref-b.json --floor 3.0`

   exits non-zero if any targeted scenario regresses past the noise gate.

5. The hard criterion for `comptime-disabled` is checked by a dedicated

   step that reads `ref-b.json` and asserts the two conditions above.

### CI summary line

The stable one-line summary written to stdout by `bench-ci`:

```text
BENCH <date> <git-sha-short> micro=<N>pass integ=<N>pass compare=<N>pass/<M>total hard_criterion=PASS|FAIL
```

Example:

```text
BENCH 2026-04-26 4de1b11 micro=11pass integ=6pass compare=13pass/13total hard_criterion=PASS
```

This line is the only stdout output from `bench-ci`; all per-scenario
detail goes to stderr. CI jobs scrape the single line via `grep '^BENCH '`.

### Fixed floor placement

The floor of 3.0% is applied to all comparison scenarios. The micro and
integration layers do not gate CI; they are informational (their output is
archived but does not fail the step). Only `bench-compare` and the hard
criterion gate CI.

---

## 7. Cross-platform coverage

### Linux x86_64 (required)

All 30 scenarios run on Linux x86_64. CPU pinning: the implement phase
should document running `bench-ci` with `taskset -c 0` on dedicated CI
runners. For shared runners, cpu-affinity pinning is advisory only; the
variance gate accounts for noise.

### macOS (smoke only, `allow_failure: true`)

The `bench-smoke` step runs 1 warmup + 1 sample of every comparison scenario
on macOS. It does not gate CI (`allow_failure: true`). This exercises the
`clock.unixNanoNow` Darwin path and verifies the `TrackingAllocator` wiring
compiles on macOS. The `alloc_count == 0` criterion is NOT enforced on
macOS in this round (Darwin allocator internals may differ).

macOS-specific notes:

- `readRssCurrent()` returns 0 on non-Linux; that is expected.
- The `bench-ab` two-variant build must still succeed on macOS because

  `-Dotel_disabled=true` is a compile-time flag, not a runtime env var.

- The 200 µs sleep in `batchForceFlush` (V-4) also affects macOS; the

  same `async_workers=0` constraint applies.

### Windows

Suppressed. No CI job targets Windows for benchmarks. The clock fallback
path in `src/internal/clock.zig` returns 0 on Windows; bench scenarios
would report 0 ns timings, making the data meaningless.

### CPU pinning conventions

On Linux CI runners, invoke via:

```text
taskset -c 0 zig build bench-ci -- --output docs/performance/<run-dir>/results/
```

On development machines the pinning is optional but strongly recommended.
The variance gate (3× stddev floor) provides a safety margin when pinning
is not available.

---

## 8. Evidence policy

### Run directory layout

```text
docs/performance/2026-04-26-zero-overhead-when-disabled/
  architecture.md          <- this document (design-time artifact)
  plan.json                <- machine-readable plan (design-time artifact)
  results/
    ref-a.json             <- baseline run (checked in after first run)
    ref-b.json             <- current run (re-generated on each run)
    micro.json             <- micro layer results
    integ.json             <- integration layer results
  decisions/
    PASS.md  OR  FAIL.md   <- written by bench-ci at run completion
  rollback/
    notes.md               <- populated if a regression triggers a revert
```

### Retention

- `architecture.md` and `plan.json` are permanent design artifacts; never

  deleted.

- `ref-a.json` is checked in to `main` after the first successful A/B run;

  it becomes the standing baseline for future comparisons against this
  run directory.

- `ref-b.json`, `micro.json`, `integ.json` are regenerated on every CI run.

  They are uploaded as CI artifacts (not committed) unless the run produces
  a new decision document.

- `decisions/PASS.md` or `decisions/FAIL.md` is committed to `main` after

  each intentional measurement session (not on every CI run).

### Decision/rollback structure

- **PASS:** Write `decisions/PASS.md` with the summary line, key metrics,

  and git SHA. The comptime-disabled feature lands on `main`.

- **FAIL:** Write `decisions/FAIL.md` with the failing scenario(s), delta,

  and noise gate. Open a follow-up issue. If the failing scenario is the
  hard criterion (`comptime-disabled`), the feature branch is not merged.

- **Rollback:** If a regression is detected post-merge, write

  `rollback/notes.md` and revert the offending commit. Re-run `bench-ab`
  against the reverted SHA to confirm recovery.

---

## 9. Risks and language-specific caveats

### Zig compiler inlining

Zig's `ReleaseFast` optimizer will inline `noopStart` (three lines,
returns a constant). The micro scenario `micro_noop_vtable_dispatch` uses
an indirect function call through a `Tracer` value stored in a
`volatile`-equivalent opaque pointer to prevent the optimizer from seeing
through the vtable. The implement phase must verify with `zig objdump`
that the call site does not degenerate to a no-op load.

Similarly, for `comptime-disabled`, the implement phase must verify with
`zig objdump --disassemble` that the `startSpan` call site compiles down
to no instructions (or a single `ret`), not just a noop vtable dispatch.

### PRNG state contamination

`id.Random` uses `std.Random.DefaultPrng` (Xoroshiro128+). In micro
scenarios, a single `Random` instance is reused across iterations. The
PRNG output changes each iteration, which is correct (IDs should be
unique). The performance is stable because the PRNG is deterministic and
branch-free. No risk.

### Clock syscall cost

`clock.unixNanoNow` on Linux calls `clock_gettime(CLOCK_REALTIME)`. On
modern kernels this is a vDSO call (no kernel entry), typically 20–40 ns.
The `micro_clock_unix_nano` scenario measures this directly. Callers seeing
>100 ns should check whether vDSO is available (`cat /proc/self/maps | grep
vdso`).

### `TrackingAllocator` overhead

The `TrackingAllocator` wraps every alloc/free with counter increments.
This adds ~5–15 ns per call. For zero-alloc scenarios this is irrelevant
(no allocator calls occur). For scenarios that do allocate (e.g. span
creation), the tracking overhead is included in the reported wall time.
This is intentional: we want to measure the full cost of allocation in
context. Disable tracking with `--no-track` to see the allocation-free
wall time.

### `batchForceFlush` busy-poll (V-4)

`src/sdk/export.zig:406` contains:

```zig
tp.clock.sleep(200 * std.time.ns_per_us);
```

inside the async-drain loop. This 200 µs sleep will dominate any
end-to-end bench that drains an async batch processor, making the
measured latency useless for comparison purposes. All integration and
comparison scenarios in this round use `async_workers=0` (synchronous
drain path, lines 415-427 of `export.zig`). Async-drain benches are
deferred until the sleep is replaced with a proper condition variable or
reduced to a microsecond-scale yield. See follow-up item 3.

### In-memory exporter allocation pattern

`src/exporters/in_memory.zig` stores spans as `StoredSpan` with
heap-allocated name and attribute KV copies. This means
`fully-enabled-alwaysOn-inmemory` and all level-3+ scenarios will show
non-zero `alloc_count`. That is expected and correct. The zero-alloc
assertion applies only to:

- `comptime-disabled`
- `noop-tracer-startend`
- `runtime-disabled-alwaysOff` (alwaysOff returns a non-recording span;

  `Span.state` is null, so `span.end` is a no-op; no `SpanState` is
  allocated)

- All micro scenarios targeting PRNG and clock

### alwaysOff still generates IDs

`src/sdk/trace.zig:224-225`: even when the sampler returns `.drop`, the
SDK generates a `trace_id` and `span_id` before checking the decision.
This is spec-compliant (IDs are needed for W3C trace-context propagation
even for dropped spans) but means `runtime-disabled-alwaysOff` is NOT
zero-alloc from the ID generator's perspective — however the ID generator
is stack-allocated, so `alloc_count` from the `TrackingAllocator` will
still be 0. The `SpanState` allocation does NOT happen on the drop path
(line 235-237 of `sdk/trace.zig`). Therefore `alloc_count == 0` holds for
`runtime-disabled-alwaysOff`.

### macOS Darwin clock

`clock.unixNanoNow` on macOS uses `std.c.clock_gettime(CLOCK.REALTIME)`.
Unlike Linux, this is not guaranteed to be vDSO-backed. The smoke
scenario on macOS may show 3–5× higher `micro_clock_unix_nano` times than
Linux. This is documented, not a failure.

---

## 10. Open decisions for the user

The following items need explicit decisions before or during the implement
phase:

**Decision D-1: `ops_per_iteration` for comparison scenarios.**
The plan uses 10 000 ops per iteration for comparison scenarios
(1 span + attrs per op). If the span state allocation makes each op
individually measurable at >1 µs, a lower count (1 000) may be preferable
to avoid 10-second iterations. The implement phase should sanity-check
iteration duration and adjust if needed. The plan encodes a
`ops_per_iteration_default` that can be overridden via `--ops N`.

**Decision D-2: `bench-ab` binary variant mechanism.**
The A/B runner needs to build two differently-configured binaries from the
same source. The cleanest approach with the existing `build.zig` pattern is
to add a second executable step in `build.zig` named `bench-ab-disabled`
compiled with `-Dotel_disabled=true`. An alternative is a shell script that
calls `zig build bench-ab` twice with different `-D` flags. The shell-script
approach requires no `build.zig` changes but is harder to cache. The plan
uses the shell-script approach as the default (less invasive); the implement
phase may upgrade to a `build.zig` dual-artifact pattern.

**Decision D-3: loopback discard server for level-6.**
`level-6-full-otlp-http-loopback` requires a `std.net.Server` that
accepts TCP connections and discards all bytes. The implement phase must
decide whether to: (a) run the discard server in a separate thread within
the bench process, or (b) spawn it as a subprocess. Option (a) is simpler
and avoids process-spawn latency contaminating the bench; option (b) more
closely mirrors production. The plan assumes option (a).

**Decision D-4: `bench-smoke` scope.**
The smoke step is defined here as "1 warmup + 1 sample of every comparison
scenario". If the loopback server (level-6) is too expensive to stand up
in a smoke run, it can be excluded. The implement phase should mark level-6
as `smoke: false` in the plan if needed.

---

## 11. Follow-up items

These items are out of scope for the current design but must be tracked:

**Follow-up F-1 — DONE (commit 4acbda5).** `-Dotel_disabled=true`
build option is wired through `build_options` and threaded into every
API call site (`Tracer.startSpan`, `Counter.add`, `Histogram.record`,
`Gauge.set`, `UpDownCounter.add`, `Logger.emit`, `Observer.observe*`,
plus `TracerProvider.tracer()`/`MeterProvider.meter()`/
`LoggerProvider.logger()`). 10 dedicated tests in
`test/comptime_disabled.zig`; existing test suite passes in both modes
(SDK-pipeline tests skip-guarded when the flag is on).

**Follow-up F-2 — DONE (commit 9a3fc5f).** `Config.disabled`
(`OTEL_SDK_DISABLED` env var) was parsed but never consulted. Fixed by
adding a `disabled: bool` field to each provider's config struct
(`TraceConfig`, `MetricsConfig`, `LogsConfig`); the corresponding
factory methods short-circuit to API-layer noop handles when the flag
is set. Precedence: comptime `build_options.otel_disabled` > runtime
`config.disabled` > default. Three new tests in
`test/comptime_disabled.zig` confirm each provider drops records when
constructed with `.disabled=true`.

**Follow-up F-3 — DONE (commit 01a57c7).** Replaced the 200µs
`clock.sleep` busy-poll in `batchForceFlush` (`src/sdk/export.zig:406`)
with `tp.sync.Condition` (the thread_pool sync primitive that wraps
`std.Io.Mutex` futex semantics — Zig 0.16 dropped `std.Thread.Condition`).
Workers broadcast the cond at the tail of every drain via a new
`drainCompleted` helper; `batchForceFlush` waits on it against the
remaining timeout budget. Wake-up latency: futex round-trip (low µs on
Linux) vs the legacy 200µs floor. Existing `test/batch_async.zig`
passes under `-Dotel_use_devnw_pool=true`.

**Follow-up F-4 — DONE (commit 395ab06).** Added two async-drain
integration scenarios — `integ_level3_async_100spans` and
`integ_level3_async_10kspans` — with `async_workers=2`,
`max_export_batch_size=256`, and `forceFlush(5_000)` inside the timed
body. Compiled out entirely when `-Dotel_use_devnw_pool=false` (the
default). Local Linux x86_64 ReleaseFast: 100 spans / 886µs, 10k spans
/ 26.6ms (~376k spans/s).

**Follow-up F-5 — DEFERRED (L6 real loopback).** The current
`level-6-full-otlp-http-loopback` (in both integration and comparison
layers) uses a synthetic `fakeTransport` that returns 200 OK without
networking — measures the OTLP encode pipeline only. To capture real
TCP I/O cost, the bench needs:

1. Extend `framework.Context` with `io: std.Io` and pass it through
   from `runScenarios`.
2. Adapt `test/tls_test_helpers.zig`'s loopback HTTP server into
   `benchmarks/integration/loopback_server.zig` with a multi-shot
   accept loop (current is single-shot).
3. Build the bench with `-Dotel_use_devnw_tls=true` and plumb
   `OtlpHttpExporter.io = ctx.io`. Leave `transport` at the default
   `httpTransport` sentinel; `expSpans` then routes through
   `httpTransportImpl` which uses `self.io` and `std.http.Client`.
4. Update `benchLevel6` in both `integration/main.zig` and
   `compare_bench.zig` to start the server, wire the endpoint into the
   exporter, then stop the server in defer.

Estimated cost: ~150 lines, primarily the multi-shot server. Expected
delta from current encode-only L6 numbers: +10-20µs/span on loopback
(real socket round-trip). Not a blocker for the headline
zero-overhead-when-disabled result, since L6 only matters when the
SDK is enabled — and the current encode-only number is already an
upper bound on per-call cost in that mode.

---

## Next steps

```text
1. /native-benchmarks:implement --plan docs/performance/2026-04-26-zero-overhead-when-disabled/plan.json
2. /native-benchmarks:run-ab --ref-a 4de1b11 --ref-b HEAD
3. /native-benchmarks:compare and /native-benchmarks:report close out the run.
```
