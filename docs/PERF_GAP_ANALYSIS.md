# Performance Gap Analysis

**Last updated:** 2026-04-26
**Source:** `docs/audit/PERF_REVIEW.md` (Phase 3, 39 findings; 23 P0/P1 actionable)
**Owner:** codepros perf-issue-tracker (Phase 4)
**Project:** [`devnw/zig/otel`](https://gitlab.com/devnw/zig/otel) (GitLab)

> **Status legend:** `triage` = issue filed, no work started · `blocked` = waiting on a prerequisite · `in-progress` = active · `validated` = fix landed + bench shows expected delta · `closed` = no further action.

---

## Summary

### Counts by PerfSeverity

| PerfSeverity | Open Issues | Blocker | Notes |
|---|---:|---:|---|
| **P0 (blocker)** | 1 | 1 | Bench harness gate — see #2. |
| **P0 (perf)** | 9 | — | All confirmed by direct re-read. |
| **P1** | 13 | — | 12 confirmed, 1 suspected (`P1-13` cache layout). |
| **Total tracked** | **23** | **1** | — |

### Top 5 risks (PerfScore = 72; tied)

1. **`AttributeSet.put` is O(n²) + pollutes arena pre-dedup** (P0-1) — every span / log / metric record. Hash index + defer-dupe → ~10× on N=128. → [#5](https://gitlab.com/devnw/zig/otel/-/work_items/5)
2. **`SpanState` alloc/arena/dupe per span** (P0-2) — every recording span pays 3 allocs + `mmap`/`munmap`. Pool with `arena.reset(.retain_capacity)` → ~5–10× steady state. → [#6](https://gitlab.com/devnw/zig/otel/-/work_items/6)
3. **`MeterProvider.pointFor` 3-7 allocs per record** (P0-4) — every metric write rebuilds the attribute key. Per-instrument scratch + `points_index` → 0 allocs on hit, 5–10× latency drop. → [#15](https://gitlab.com/devnw/zig/otel/-/work_items/15)
4. **Default `async_workers=0` + dead `schedule_delay_ms`** (P0-9) — every 512th span eats full export latency on the producer thread. Stdlib thread + condvar → P99.9 from >10ms to <50µs. → [#22](https://gitlab.com/devnw/zig/otel/-/work_items/22)
5. **Default = `SimpleSpanProcessor`** (P0-10) — one HTTP POST per span out of the box. Wrap default in BSP → 1k spans/sec → 50k–500k spans/sec. → [#28](https://gitlab.com/devnw/zig/otel/-/work_items/28)

### Hard blocker (#2)

`benchmarks/bench.zig:55-71` calls `lib.init(.{})` which does not exist on the public surface, and `benchmarks/micro/` is empty. Until the harness compiles and the 13 load-bearing micros land, **no A/B validation of any perf fix is possible**. All baseline cells below read **"no baseline yet"**. See [#2](https://gitlab.com/devnw/zig/otel/-/work_items/2).

---

## Stack-ranked findings (sorted by PerfScore desc, then by ID)

| Rank | PerfSeverity | PerfScore | Finding ID | Component | File:Line | Confidence | Baseline | Issue | Status |
|---:|:---:|---:|:---|:---|:---|:---:|:---|:---|:---|
| — | P0 (blocker) | — | BENCH-HARNESS | benchmarks | `benchmarks/bench.zig:55-71` | confirmed | n/a | [#2](https://gitlab.com/devnw/zig/otel/-/work_items/2) | triage (gate) |
| 1 | P0 | **72** | P0-1 | api/internal | `src/internal/attributes.zig:106-127` | confirmed | no baseline yet | [#5](https://gitlab.com/devnw/zig/otel/-/work_items/5) | blocked (#2) |
| 2 | P0 | **72** | P0-2 | api | `src/api/trace.zig:103-118` | confirmed | no baseline yet | [#6](https://gitlab.com/devnw/zig/otel/-/work_items/6) | blocked (#2) |
| 3 | P0 | **72** | P0-4 | sdk | `src/sdk/metrics.zig:254-285` | confirmed | no baseline yet | [#15](https://gitlab.com/devnw/zig/otel/-/work_items/15) | blocked (#2) |
| 4 | P0 | **72** | P0-9 | sdk | `src/sdk/export.zig:147,142,343-378` | confirmed | no baseline yet | [#22](https://gitlab.com/devnw/zig/otel/-/work_items/22) | blocked (#2) |
| 5 | P0 | **72** | P0-10 | sdk | `src/sdk/trace.zig:172-178` | confirmed | no baseline yet | [#28](https://gitlab.com/devnw/zig/otel/-/work_items/28) | blocked (#2) |
| 6 | P0 | 48 | P0-5 | sdk | `src/sdk/metrics.zig:314-329` | confirmed | no baseline yet | [#17](https://gitlab.com/devnw/zig/otel/-/work_items/17) | blocked (#2) — folded into P0-4 |
| 7 | P0 | 48 | P0-7 | sdk | `src/sdk/metrics.zig:414-419` | confirmed | no baseline yet | [#18](https://gitlab.com/devnw/zig/otel/-/work_items/18) | blocked (#2) |
| 8 | P1 | 48 | P1-9 | exporters | `src/exporters/otlp_http.zig:138-139` | confirmed | no baseline yet | [#47](https://gitlab.com/devnw/zig/otel/-/work_items/47) | blocked (#2) |
| 9 | P1 | 48 | P1-11 | exporters | `src/exporters/otlp_grpc.zig:171-172` | confirmed | no baseline yet | [#70](https://gitlab.com/devnw/zig/otel/-/work_items/70) | blocked (#2) |
| 10 | P0 | 32 | P0-8 | sdk | `src/sdk/export.zig:343-378` | confirmed (severity Likely) | no baseline yet | [#21](https://gitlab.com/devnw/zig/otel/-/work_items/21) | blocked (#2 + P0-9) |
| 11 | P0 | 24 | P0-3 | api | `src/api/trace.zig:159-165` | confirmed | no baseline yet | [#10](https://gitlab.com/devnw/zig/otel/-/work_items/10) | blocked (#2) |
| 12 | P1 | 24 | P1-1 | exporters | `src/generated/otlp.zig:110-137` | confirmed | no baseline yet | [#36](https://gitlab.com/devnw/zig/otel/-/work_items/36) | blocked (#2) |
| 13 | P1 | 24 | P1-2 | exporters | `src/generated/otlp.zig:42-49` | confirmed | no baseline yet | [#40](https://gitlab.com/devnw/zig/otel/-/work_items/40) | blocked (#2) |
| 14 | P1 | 16 | P1-3 | sdk | `src/sdk/export.zig:251-260` | confirmed | no baseline yet | [#41](https://gitlab.com/devnw/zig/otel/-/work_items/41) | blocked (#2) |
| 15 | P1 | 16 | P1-7 | api/exporters | `src/internal/json_codec.zig:154-164` + `src/internal/attributes.zig:147-156` | confirmed | no baseline yet | [#45](https://gitlab.com/devnw/zig/otel/-/work_items/45) | blocked (#2) |
| 16 | P1 | 8 | P1-4 | sdk | `src/sdk/export.zig:262-297` | confirmed | no baseline yet | [#42](https://gitlab.com/devnw/zig/otel/-/work_items/42) | blocked (#2) — subsumed by P0-2 |
| 17 | P1 | 8 | P1-5 | sdk | `src/sdk/export.zig:380-428` | confirmed | no baseline yet | [#43](https://gitlab.com/devnw/zig/otel/-/work_items/43) | blocked (#2) |
| 18 | P1 | 8 | P1-6 | sdk | `src/sdk/metrics.zig:499-557` | confirmed | no baseline yet | [#44](https://gitlab.com/devnw/zig/otel/-/work_items/44) | blocked (#2) |
| 19 | P1 | 8 | P1-8 | exporters | `src/exporters/prometheus.zig:25-86` | confirmed | no baseline yet | [#46](https://gitlab.com/devnw/zig/otel/-/work_items/46) | blocked (#2) |
| 20 | P1 | 8 | P1-10 | exporters | `src/exporters/otlp_http.zig:212` | confirmed | no baseline yet | [#56](https://gitlab.com/devnw/zig/otel/-/work_items/56) | triage (code fix needs no bench) |
| 21 | P1 | 4 | P1-12 | sdk | `src/sdk/resource.zig:30-38` | confirmed | no baseline yet | [#75](https://gitlab.com/devnw/zig/otel/-/work_items/75) | blocked (#2) — auto-fixed by P0-1 |
| 22 | P1 | 4 | P1-13 | api | `src/api/trace.zig:71-101` | suspected | no baseline yet | [#82](https://gitlab.com/devnw/zig/otel/-/work_items/82) | blocked (#2 + needs `perf` access) |

> **No baseline yet** — every cell pending #2 (bench harness). The Phase-3 PerfScores are derived from semantic re-read, allocation counting, and complexity arguments — see `docs/audit/PERF_REVIEW.md` for per-finding evidence.

---

## Findings by area

### `area::api` (4)

- **P0-1** AttributeSet hash index + defer-dupe ([#5](https://gitlab.com/devnw/zig/otel/-/work_items/5)) — score 72
- **P0-2** SpanState pool with arena reset ([#6](https://gitlab.com/devnw/zig/otel/-/work_items/6)) — score 72
- **P0-3** setName arena-only ([#10](https://gitlab.com/devnw/zig/otel/-/work_items/10)) — score 24
- **P1-7** sortedEntries cache or drop ([#45](https://gitlab.com/devnw/zig/otel/-/work_items/45)) — score 16
- **P1-13** SpanState layout ([#82](https://gitlab.com/devnw/zig/otel/-/work_items/82)) — score 4 (suspected)

### `area::sdk` (10)

- **P0-4** pointFor zero-alloc hit ([#15](https://gitlab.com/devnw/zig/otel/-/work_items/15)) — score 72
- **P0-5** attributeKey scratch (folded) ([#17](https://gitlab.com/devnw/zig/otel/-/work_items/17)) — score 48
- **P0-7** Histogram binary search ([#18](https://gitlab.com/devnw/zig/otel/-/work_items/18)) — score 48
- **P0-8** BSP queue contention ([#21](https://gitlab.com/devnw/zig/otel/-/work_items/21)) — score 32
- **P0-9** Default `async_workers` + `schedule_delay_ms` ([#22](https://gitlab.com/devnw/zig/otel/-/work_items/22)) — score 72
- **P0-10** Default to BatchSpanProcessor ([#28](https://gitlab.com/devnw/zig/otel/-/work_items/28)) — score 72
- **P1-3** drainLocked alloc ([#41](https://gitlab.com/devnw/zig/otel/-/work_items/41)) — score 16
- **P1-4** exportBatch parallel alloc ([#42](https://gitlab.com/devnw/zig/otel/-/work_items/42)) — score 8
- **P1-5** forceFlush busy-poll ([#43](https://gitlab.com/devnw/zig/otel/-/work_items/43)) — score 8
- **P1-6** collect pre-sizing ([#44](https://gitlab.com/devnw/zig/otel/-/work_items/44)) — score 8
- **P1-12** Resource.merge cascade ([#75](https://gitlab.com/devnw/zig/otel/-/work_items/75)) — score 4

### `area::exporters` (7)

- **P1-1** Two-pass proto encoder ([#36](https://gitlab.com/devnw/zig/otel/-/work_items/36)) — score 24
- **P1-2** Stack-buffered writeVarint ([#40](https://gitlab.com/devnw/zig/otel/-/work_items/40)) — score 24
- **P1-8** Prometheus.render pre-size + cache ([#46](https://gitlab.com/devnw/zig/otel/-/work_items/46)) — score 8
- **P1-9** Persistent `std.http.Client` ([#47](https://gitlab.com/devnw/zig/otel/-/work_items/47)) — score 48
- **P1-10** Fail-fast on `UnsupportedTransport` ([#56](https://gitlab.com/devnw/zig/otel/-/work_items/56)) — score 8
- **P1-11** Persistent `GrpcClient` ([#70](https://gitlab.com/devnw/zig/otel/-/work_items/70)) — score 48

### `area::bench` (1)

- **BENCH-HARNESS** Repair `benchmarks/bench.zig` + seed 13 micros ([#2](https://gitlab.com/devnw/zig/otel/-/work_items/2)) — **gate**

---

## Cross-link map (shared fixes)

| Anchor | Cascade-fixes / co-fixes |
|---|---|
| **P0-1** ([#5](https://gitlab.com/devnw/zig/otel/-/work_items/5)) | Auto-resolves **P1-12** ([#75](https://gitlab.com/devnw/zig/otel/-/work_items/75)). Co-fix path for **P1-7** ([#45](https://gitlab.com/devnw/zig/otel/-/work_items/45) — sorted-index lives in same struct). Improves cold path of **P0-4** ([#15](https://gitlab.com/devnw/zig/otel/-/work_items/15)). |
| **P0-2** ([#6](https://gitlab.com/devnw/zig/otel/-/work_items/6)) | Subsumes **P1-4** ([#42](https://gitlab.com/devnw/zig/otel/-/work_items/42)). Cleans up surface for **P0-3** ([#10](https://gitlab.com/devnw/zig/otel/-/work_items/10)). Hardens **P1-13** ([#82](https://gitlab.com/devnw/zig/otel/-/work_items/82)) — pool retention exposes layout effects. |
| **P0-4** ([#15](https://gitlab.com/devnw/zig/otel/-/work_items/15)) | Subsumes **P0-5** ([#17](https://gitlab.com/devnw/zig/otel/-/work_items/17)). Stacks with **P0-7** ([#18](https://gitlab.com/devnw/zig/otel/-/work_items/18)) for fully alloc-free histogram hit path. |
| **P0-9** ([#22](https://gitlab.com/devnw/zig/otel/-/work_items/22)) | Hard-enables **P0-10** ([#28](https://gitlab.com/devnw/zig/otel/-/work_items/28)) — switching the default to BSP without an async pump is worse than today. Makes **P0-8** ([#21](https://gitlab.com/devnw/zig/otel/-/work_items/21)) load-bearing (mutex contention only matters when async is on). Adds the condvar infra used by **P1-5** ([#43](https://gitlab.com/devnw/zig/otel/-/work_items/43)). **Overlaps with quality finding C3** (`schedule_delay_ms` declared but unused). |
| **P1-9** ([#47](https://gitlab.com/devnw/zig/otel/-/work_items/47)) ↔ **P1-11** ([#70](https://gitlab.com/devnw/zig/otel/-/work_items/70)) | Same fix shape: lift transport client to exporter struct, lazy-init, mutex on call. Co-implement. |
| **P1-1** ([#36](https://gitlab.com/devnw/zig/otel/-/work_items/36)) ↔ **P1-2** ([#40](https://gitlab.com/devnw/zig/otel/-/work_items/40)) | P1-2 sits inside the P1-1 encoder rewrite. Validate together with `bench_encode_spans_proto_100x10`. |
| **P1-3** ([#41](https://gitlab.com/devnw/zig/otel/-/work_items/41)) ↔ **P1-4** ([#42](https://gitlab.com/devnw/zig/otel/-/work_items/42)) | Same scratch-at-init pattern. P1-4 fully subsumed by P0-2. |

---

## Roadmap

### Quick wins (< 1 day each, mechanical)

| ID | Issue | Score | Why first |
|---|---|---:|---|
| P1-2 | [#40](https://gitlab.com/devnw/zig/otel/-/work_items/40) | 24 | 8-line stack-buffer fix; lands inside P1-1 rewrite or standalone. |
| P1-6 | [#44](https://gitlab.com/devnw/zig/otel/-/work_items/44) | 8 | Single line `ensureTotalCapacity`. |
| P1-10 | [#56](https://gitlab.com/devnw/zig/otel/-/work_items/56) | 8 | Remove one switch arm. Doesn't even need bench harness. |
| P0-7 | [#18](https://gitlab.com/devnw/zig/otel/-/work_items/18) | 48 | `std.sort.lowerBound` swap; immediate ~2× on default histogram. |

### Medium (1–5 days)

| ID | Issue | Score | Notes |
|---|---|---:|---|
| P0-1 | [#5](https://gitlab.com/devnw/zig/otel/-/work_items/5) | 72 | Hash index + defer-dupe restructure of `AttributeSet.put`. Cascade-fixes 3 others. |
| P0-4 | [#15](https://gitlab.com/devnw/zig/otel/-/work_items/15) | 72 | Per-instrument `key_scratch` + `points_index`. Subsumes P0-5. |
| P0-3 | [#10](https://gitlab.com/devnw/zig/otel/-/work_items/10) | 24 | Move `name` into the arena. Lands cleanest alongside P0-2. |
| P1-3 / P1-4 | [#41](https://gitlab.com/devnw/zig/otel/-/work_items/41) [#42](https://gitlab.com/devnw/zig/otel/-/work_items/42) | 16 / 8 | Scratch-at-init pattern. P1-4 closed by P0-2. |
| P1-9 | [#47](https://gitlab.com/devnw/zig/otel/-/work_items/47) | 48 | Persistent `std.http.Client`; co-implement with P1-11. |
| P1-11 | [#70](https://gitlab.com/devnw/zig/otel/-/work_items/70) | 48 | Persistent `GrpcClient`; needs `grpc-zig` reusability check first. |
| P1-7 | [#45](https://gitlab.com/devnw/zig/otel/-/work_items/45) | 16 | Cache-the-sort lives cleanly in the P0-1 hash-index restructure. |
| P1-8 | [#46](https://gitlab.com/devnw/zig/otel/-/work_items/46) | 8 | Pre-size + sanitized-name cache. |

### Strategic (> 5 days)

| ID | Issue | Score | Notes |
|---|---|---:|---|
| P0-2 | [#6](https://gitlab.com/devnw/zig/otel/-/work_items/6) | 72 | SpanState pool with `arena.reset(.retain_capacity)`. Touches lifecycle, BSP, simple processor; ~4 MiB resident at default cap; needs concurrent-producer story. |
| P0-9 | [#22](https://gitlab.com/devnw/zig/otel/-/work_items/22) | 72 | Stdlib-thread fallback for BSP + wire `schedule_delay_ms`. Changes runtime profile by default. |
| P0-10 | [#28](https://gitlab.com/devnw/zig/otel/-/work_items/28) | 72 | Default to BatchSpanProcessor. Hard-depends on P0-9 landing first. Tests must explicitly opt into Simple. |
| P0-8 | [#21](https://gitlab.com/devnw/zig/otel/-/work_items/21) | 32 | Sharded MPSC queue. Only after P0-9 lands. |
| P1-1 | [#36](https://gitlab.com/devnw/zig/otel/-/work_items/36) | 24 | Two-pass encoder (or switch to DevNW path). Touches wire-format hot path; parity test required. |
| P1-5 | [#43](https://gitlab.com/devnw/zig/otel/-/work_items/43) | 8 | Condvar refactor; piggyback on P0-9. |
| P1-13 | [#82](https://gitlab.com/devnw/zig/otel/-/work_items/82) | 4 | Measure-first; only ship if `perf stat` shows measurable miss-rate delta. |

### Pre-requisite (gate)

- **#2 — Repair `benchmarks/bench.zig` + seed 13 micros.** Nothing above can be A/B-validated without this. **Do this first.**

---

## Recommended execution sequence

1. **Land #2** (bench harness + 13 micros). Capture `bench-baseline-pre-perf-fixes` JSON.
2. **Quick wins in parallel** — P1-10 (no harness), P0-7, P1-6, P1-2.
3. **High-leverage trio** in three independent worktrees, each with its own micro: P0-1 (`#5`), P0-4 (`#15`), P0-2 (`#6`). Capture A/B per-finding.
4. **Default-config bundle**: P0-9 (`#22`) → P0-10 (`#28`) → P0-8 (`#21`) → P1-5 (`#43`). Order matters; each builds on the previous.
5. **Exporter trio**: P1-9 (`#47`) + P1-11 (`#70`) co-implemented; then P1-1 (`#36`) + P1-2 (`#40`) for the encoder.
6. **Tail cleanup**: P0-3, P1-3/4, P1-7, P1-8, P1-12.
7. **Optional, measurement-driven**: P1-13.

---

## Open unknowns / what would unblock evidence

- **#2** is the universal unblocker for measured baselines.
- **P0-8** severity at scale needs `bench_bsp_producer_scaling` at 1/2/4/8 producer threads (gated on P0-9 landing).
- **P1-11** assumes `grpc-zig`'s `GrpcClient` is reusable across calls — needs a 30-min read of upstream source; if not, escalate to upstream issue.
- **P1-13** layout effect needs Linux `perf stat -e L1-dcache-load-misses,LLC-load-misses` access on the bench host.
- **P1-7** Option 2 (drop sort) needs a survey of JSON consumers to confirm no one relies on key order.
