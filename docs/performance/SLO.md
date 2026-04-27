# Performance SLOs — devnw/zig/otel

**Status:** Active
**Last updated:** 2026-04-27 (PERF-SLO-DEFINE, gitlab #167)
**Owner:** perf-issue-tracker
**Gate:** [`benchmarks/check_hard_criteria.zig`](../../benchmarks/check_hard_criteria.zig)
**Build target:** `zig build hard-criterion-check`

---

## 1. Purpose

This document defines the **service-level performance objectives (SLOs)**
that gate every PR landing on `main`. Each row is anchored to a real,
on-disk benchmark baseline under `docs/performance/<date>-<id>/`; the
chosen ceiling carries a documented headroom buffer over the verified
floor. Regressions trip the bench-CI hard-criterion gate
(`zig build hard-criterion-check`) and fail the build.

The SLOs cover three dimensions:

1. **Per-operation latency** — wall-clock cost of one logical op (one
   `Counter.add`, one `Span.end`, one attribute-set put, etc.).
2. **Per-operation allocations** — heap traffic in the hot path. The
   bar for "zero-alloc" hot paths is `0` allocs/op; setup-amortized
   paths get explicit per-op rate ceilings.
3. **Cross-cutting overhead** — comptime-disabled and level-1-tracer
   noop overhead must remain free relative to the no-call baseline.

---

## 2. Scope

### In-scope

- The 18 micro-scenarios in `benchmarks/micro/main.zig` (zero-alloc,
  attribute, metric, span-state, encoder, redact paths).
- The 8 comparison scenarios in `benchmarks/compare_bench.zig`
  (baseline-no-call, comptime-disabled, runtime-disabled-noop, level-0
  through level-6).
- The 1 integration scenario in `benchmarks/integration/main.zig`
  (`level-6-full-otlp-http-loopback`).

### Out of scope (this revision)

- TLS handshake latency — gated by upstream DevNW `tls` work; tracked
  separately in `docs/DEPENDENCIES.md`.
- gRPC streaming throughput SLOs — deferred until the in-house gRPC
  client lands. Tracked under PR-9 (#143).
- Memory-RSS-over-24h soak — out of bench harness scope.
- Multi-process / multi-host SLOs — out of bench harness scope.

---

## 3. Per-operation Targets

All ceilings derived from `docs/performance/2026-04-26-p0-4-pointfor/results/after.json`
unless noted otherwise. Headroom column = `ceiling / measured`.

### 3.1 Latency targets (ns/op, p99)

| Metric | Measured (p99) | Ceiling | Headroom | Source bench | Gate |
|---|---:|---:|---:|---|---|
| **attr-update p99** | 31.92 ns/op | **50 ns/op** | 1.57x | `micro_attr_put_update` | `check_hard_criteria.zig` Rule 3 |
| attr-update p50 (informational) | 31.87 ns/op | n/a | — | `micro_attr_put_update` | not gated |
| counter-add no-attrs p99 | 81.29 ns/op | n/a (informational) | — | `micro_counter_add_no_attrs` | not gated |
| counter-add 4-attrs hit p99 | 286.0 ns/op | n/a (informational) | — | `micro_counter_add_4_attrs_hit` | not gated |
| histogram-record 4-attrs hit p99 | 251.9 ns/op | n/a (informational) | — | `micro_histogram_record_4_attrs_hit` | not gated |
| span-record steady-state p99 | 1043 ns/op | n/a (informational) | — | `micro_span_record_steady_state` | not gated |
| trace-id mint p99 | 2.65 ns/op | n/a (informational) | — | `micro_next_trace_id` | not gated |
| span-id mint p99 | 1.48 ns/op | n/a (informational) | — | `micro_next_span_id` | not gated |
| clock unix-nano p99 | 19.51 ns/op | n/a (informational) | — | `micro_clock_unix_nano` | not gated |
| OTLP encode 64-span batch p99 | TBD | n/a (deferred) | — | `micro_encode_spans_proto_64` | tracked under #166 |
| OTLP encode 512-span batch p99 | TBD | n/a (deferred) | — | `micro_encode_spans_proto_512` | tracked under #166 |
| OTLP encode 4096-span batch p99 | TBD | n/a (deferred) | — | `micro_encode_spans_proto_4096` | tracked under #166 |

> **Why only `attr-update` is hard-gated this revision:** the listed
> p99s for `counter-add`, `histogram-record`, and `span-record` show
> meaningful run-to-run noise on the baseline runner (the current
> `wall_ns_p95 / wall_ns_p99` field reports the same value because
> `sample_count` is 6 — the framework collapses both to the highest
> sample). Setting hard ceilings against a single 6-sample run would
> flake. The plan: re-baseline at sample_count >= 30 under
> `bench-baselines #166`, then promote each row from "informational"
> to "gated" with a 2x headroom buffer over the new p99.

### 3.2 Allocation targets (allocs/op)

| Metric | Measured (allocs/op) | Ceiling | Headroom | Source bench | Gate |
|---|---:|---:|---:|---|---|
| **counter-add 4-attrs hit allocs/op** | 0.0015 | **0.005** | 3.3x | `micro_counter_add_4_attrs_hit` | `check_hard_criteria.zig` Rule 4 |
| histogram-record 4-attrs hit allocs/op | 0.0017 | n/a (informational) | — | `micro_histogram_record_4_attrs_hit` | not gated |
| attr-update allocs/op | 0.0003 | n/a (informational) | — | `micro_attr_put_update` | not gated |
| trace-id mint allocs/op | 0 | **0** (strict) | — | `micro_next_trace_id` | `framework.zero_alloc_expected` |
| span-id mint allocs/op | 0 | **0** (strict) | — | `micro_next_span_id` | `framework.zero_alloc_expected` |
| clock unix-nano allocs/op | 0 | **0** (strict) | — | `micro_clock_unix_nano` | `framework.zero_alloc_expected` |
| redact is-sensitive miss allocs/op | 0 | **0** (strict) | — | `micro_redact_is_sensitive_miss` | `framework.zero_alloc_expected` |
| redact is-sensitive hit allocs/op | 0 | **0** (strict) | — | `micro_redact_is_sensitive_hit` | `framework.zero_alloc_expected` |
| noop-vtable-dispatch allocs/op | 0 | **0** (strict) | — | `micro_noop_vtable_dispatch` | `framework.zero_alloc_expected` |

> The `0`-strict rows are enforced inside the framework runner via
> `Scenario.zero_alloc_expected = true` (see
> [`framework.zig:62`](../../benchmarks/framework.zig)) — the runner
> exits non-zero on any allocation in the timed body. Those rows do
> not need an additional `check_hard_criteria.zig` rule.
>
> The `counter-add 4-attrs hit` row's measured 0.0015 allocs/op is the
> **post-PR-1 / post-P0-4 floor**. The 15 allocations across 10 000
> ops are setup costs (instrument creation, attribute-set materialize)
> spread across the loop, not per-call hot-path allocations. The
> per-call hot path is verified zero-alloc by PR-1 and P0-4
> (`MeterProvider.pointFor` returns indices, not pointers; the
> fingerprint cache hit path takes no arena traffic). The 0.005
> ceiling preserves a 3.3x headroom over the measured floor; trips on
> any change that re-introduces per-call allocation.

---

## 4. Cross-cutting Targets

These are the **comptime-disabled** and **level-1 tracer-noop**
hard criteria already in place pre-#167. Keeping them documented here
means a single source of truth for the SLO contract.

| Metric | Floor | Ceiling | Source bench | Gate |
|---|---:|---:|---|---|
| **comptime-disabled overhead** | baseline-no-call (~0.349 ns/op @ ref-B) | **baseline + 2 ns/op** | `comptime-disabled` (flag=true) | `check_hard_criteria.zig` Rule 1 |
| **comptime-disabled allocs/op** | 0 (after setup amortization) | **0.01 allocs/op** | same | same |
| **level-1-tracer-noop overhead** | baseline-no-call (~0.532 ns/op @ ref-A) | **baseline + 5 ns/op** | `level-1-tracer-noop` (flag=false) | `check_hard_criteria.zig` Rule 2 |
| **level-1-tracer-noop allocs/op** | 0 | **0** (strict) | same | same |

Source: `docs/performance/2026-04-26-zero-overhead-when-disabled/results/{ref-a,ref-b}.json`.

---

## 5. Drain-side Targets (BSP / OTLP encode)

These rows depend on the in-flight `bench-baselines #166` work to
produce reproducible p99s. Until that lands they remain
**informational**. The check_hard_criteria.zig gate skips silently
when the corresponding scenario is missing.

| Metric | Target | Source bench | Status |
|---|---|---|---|
| BSP enqueue latency p99 | **TBD** (target: <= 200 ns/op) | not yet authored | tracked under #166 |
| OTLP encode per-span (512-batch) p99 | **TBD** (target: <= 2000 ns/span at batch=512) | `micro_encode_spans_proto_512` | tracked under #166 |
| Batch encode time at N=4096 | **TBD** (target: O(N) — no quadratic regression) | `micro_encode_spans_proto_4096` | tracked under #166 |
| level-6-full-otlp-http-loopback p99 | **TBD** (target: <= 5000 ns/op) | `level-6-full-otlp-http-loopback` | tracked under #166 |

---

## 6. How These Are Gated

### 6.1 The hard-criterion check

The single source of truth is
[`benchmarks/check_hard_criteria.zig`](../../benchmarks/check_hard_criteria.zig).
It accepts up to three JSON inputs:

```text
zig build hard-criterion-check -- \
    --ref-a   docs/performance/<date>-comparison/results/ref-a.json \
    --ref-b   docs/performance/<date>-comparison/results/ref-b.json \
    --micro   docs/performance/<date>-micro/results/after.json
```

- `--ref-a` / `--ref-b` drive Rules 1 and 2 (cross-cutting overhead).
- `--micro` drives Rules 3 and 4 (per-op SLOs from this document).
- Any missing input causes its rules to **skip cleanly** with a
  notice; absence is non-fatal so the step is safe to wire into bench-CI
  before every baseline has been re-captured.

Exit codes:

- `0` — every supplied rule PASSED, OR no inputs supplied.
- non-zero — at least one supplied rule FAILED.

### 6.2 CI wiring (Makefile)

The `make slo-check` target (added 2026-04-27) drives a fresh
`bench-micro` run and re-checks the SLO rules end-to-end:

```text
make slo-check
```

Internally:

1. `zig build bench-micro -Doptimize=ReleaseFast -- --output benchmarks/results/micro-latest.json`
2. `zig build hard-criterion-check -- --micro benchmarks/results/micro-latest.json`

> **Build-mode contract:** every baseline JSON committed under
> `docs/performance/<date>-p0-*/results/` was captured under
> `-Doptimize=ReleaseFast`. The `slo-check` target enforces the same
> mode — running the bench under `Debug` would trip the latency
> ceiling against an order-of-magnitude unrelated overhead gap that
> is not a real regression. Updating any SLO row therefore implies
> capturing the new baseline under ReleaseFast as well.

`make ci` already includes `make slo-check` as the bench gate (see
[`Makefile`](../../Makefile)).

### 6.3 PR contract

A PR that touches `src/api/`, `src/sdk/`, `src/exporters/`, or
`src/internal/` must:

1. Run `make slo-check` locally, OR
2. Rely on the GitLab CI `bench-ci` job, which runs
   `zig build hard-criterion-check` against fresh JSON.

Failures are blocking — the merge gate inspects the runner exit code.

---

## 7. Update Procedure

When and how to revise this document:

### 7.1 Tightening a ceiling (regression-driven)

Optimization landed -> measured floor moved down -> ceiling should
follow with the same headroom multiplier.

1. Re-run the affected bench at `sample_count >= 30`.
2. Capture the new JSON under `docs/performance/<YYYY-MM-DD>-<id>/results/`.
3. Update the row's `Measured` and `Ceiling` cells; preserve the
   `Headroom` ratio (e.g. 1.5x or 2x).
4. Update the corresponding `*_max_*` constant in
   `check_hard_criteria.zig`.
5. Reference the JSON file in the source-of-floor comment block.

### 7.2 Loosening a ceiling (carefully)

A real workload pivot or platform change requires a higher ceiling.

1. **Required:** an ADR under `docs/adr/` that justifies the
   regression and references the affected bench JSON.
2. Update the row's `Ceiling` cell with explicit "loosened YYYY-MM-DD;
   see ADR-XXXX" annotation.
3. Update the constant in `check_hard_criteria.zig` with the same
   ADR reference in its doc-comment.
4. Mention the loosened SLO in `CHANGELOG.md` under
   `[Unreleased] / Performance`.

### 7.3 Promoting an "informational" row to "gated"

When `bench-baselines #166` produces a stable >=30-sample baseline
for a row currently marked **informational**:

1. Confirm `wall_ns_p99` is stable across at least 3 fresh runs
   (relative stddev `<= 5%`).
2. Pick a ceiling = 2x measured p99 (or 1.5x for very stable
   scenarios where the variance is sub-1%).
3. Add a new rule in `check_hard_criteria.zig` matching the existing
   `checkLatencyRule` / `checkAllocRule` shape.
4. Move the row from §3.x informational to §3.x gated and update the
   `Gate` cell to point at the new rule.
5. Reference the new baseline JSON in the source comment.

---

## 8. Open / Deferred Items

These rows are explicitly **deferred** to future work, all tracked
under `BENCH-BASELINES-MISSING` (gitlab #166):

| Deferred SLO row | Tracker | Why deferred |
|---|---|---|
| BSP enqueue latency p99 | #166 | No isolated bench scenario yet (the queue probe is buried inside `level-6-full-otlp-http-loopback`). |
| OTLP encode per-span (512-batch) p99 | #166 | `micro_encode_spans_proto_512` exists but only one 6-sample run; need a stable >=30-sample baseline. |
| Batch encode time at N=4096 | #166 | Same as above; the existing JSON predates the deferred-compaction Writer fix and is not directly comparable. |
| `level-6-full-otlp-http-loopback` p99 | #166 | Loopback server cold-start dominates; need >=30 samples to extract the steady-state p99. |
| span-record steady-state p99 | #166 | `wall_ns_p99 == wall_ns_p95` artifact at sample_count=6; need >=30 samples for a real p99 separation. |
| counter-add 4-attrs hit p99 (latency, not allocs) | #166 | Same artifact as above. |
| histogram-record 4-attrs hit p99 (latency) | #166 | Same artifact. |
| OTLP/HTTP per-export wall-time | #166 | PR-4 (#47) `std.http.Client` keepalive missing; fixing PR-4 changes the floor — re-baseline post-PR-4. |
| Prometheus scrape latency p99 | #166 | PR-7 (#146) per-bucket re-sort fix changes the floor — re-baseline post-PR-7. |

Each deferred row will be promoted to **gated** as #166 unblocks them.

---

## 9. Cross-references

- [`benchmarks/check_hard_criteria.zig`](../../benchmarks/check_hard_criteria.zig)
  — the gate source
- [`benchmarks/framework.zig`](../../benchmarks/framework.zig) — JSON
  schema (`ResultRow` + `ResultDocument`)
- [`benchmarks/micro/main.zig`](../../benchmarks/micro/main.zig) —
  micro-scenario definitions
- [`docs/PERF_GAP_ANALYSIS.md`](../PERF_GAP_ANALYSIS.md) — open perf
  findings + their tracking issues
- [`Makefile`](../../Makefile) `slo-check` target
- gitlab #167 (this work item) and #166 (baseline backlog)
