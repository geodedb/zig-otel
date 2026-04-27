# Performance Gap Analysis

**Last updated:** 2026-04-27 (Phase 3 perf-reviewer + perf-issue-tracker sweep)
**Source:** `docs/audit/PERF_REVIEW.md` (Phase 3, 39 findings) + Phase 3 re-audit (P-N1..P-N7) + Phase 3 perf-reviewer (PR-1..PR-13)
**Owner:** codepros perf-issue-tracker (Phase 4)
**Project:** [`devnw/zig/otel`](https://gitlab.com/devnw/zig/otel) (GitLab)

> **Status legend:** `triage` = issue filed, no work started · `blocked` = waiting on a prerequisite · `in-progress` = active · `validated` = fix landed + bench shows expected delta · `closed` = no further action.

---

## Summary

### Counts by PerfSeverity

| PerfSeverity | Open Issues | Validated/Closed | Notes |
|---|---:|---:|---:|
| **P0** | 4 | 8 | Validated: PR-1 (#135), PR-2 (#36), PR-3 (#136), P0-1 (#5), P0-2 (#6), P0-4 (#15), P-N1 (#122), P-N2 (#126). |
| **P1** | 18 | 1 | Adds PR-5/PR-6/PR-7/PR-8/PR-9/PR-10 + tracking issues BENCH-BASELINES-MISSING (#166), PERF-SLO-DEFINE (#167). |
| **P2** | 3 | — | Adds PR-11 (#148), PR-12 (#153). |
| **P3** | 1 | — | Adds PR-13 (#155). |
| **Validated/Closed total** | — | **10** | #2 BENCH-HARNESS, #43 P1-5 forceFlush, #5/#6/#15/#36/#122/#126/#135 + previously CHANGELOG'd P0-9/P0-10. |
| **Total open** | **27** | **10** | — |

### Top 5 risks (post-validation)

1. **PR-7 — Prometheus per-bucket label re-sort** (P1, score 82) at `src/exporters/prometheus.zig:70-80,162-177`. Sort lives inside the bucket loop; should be hoisted. 5-10× scrape latency on histograms. → [#146](https://gitlab.com/devnw/zig/otel/-/work_items/146)
2. **PR-4 — new `std.http.Client` per export, no keepalive** (P1, score 76) at `src/exporters/otlp_http.zig:243`. One TCP+TLS handshake per batch on the post-default-BSP hot path. → [#47](https://gitlab.com/devnw/zig/otel/-/work_items/47)
3. **PR-5 — groupByScope linear scan** (P1, score 72) at `src/exporters/otlp_http.zig:402-423` (and now also the spans-side `groupSpansByScope` introduced by PR-3). Replace the linear scope-bucket scans with a hash-keyed grouping. → [#138](https://gitlab.com/devnw/zig/otel/-/work_items/138)
4. **PR-6 — Baggage.put dupe-before-dedup** (P1, score 72) at `src/api/baggage.zig:56-73`. Two arena dupes per put before the dedup check; collapse on the hit path. → [#139](https://gitlab.com/devnw/zig/otel/-/work_items/139)
5. **PR-8 — duplicate `clock.now` calls in metrics hot path** (P1, score 64) at `src/sdk/metrics.zig`. Two `clock.now` per record; coalesce. → [#141](https://gitlab.com/devnw/zig/otel/-/work_items/141)

> **Closed top risks:**
>
> **PR-3** ([#136](https://gitlab.com/devnw/zig/otel/-/work_items/136), score 78) — trace OTLP encoder multi-tracer mislabel fixed 2026-04-27. `groupSpansByScope` (mirrored on metrics' `groupByScope` pattern but keyed on the full `(name, version, schema_url)` tuple) buckets the input batch; both `encodeSpansProto` and `encodeSpansProtoDevnw` now emit one `ScopeSpans` per distinct `InstrumentationScope`. `ScopeSpans.schema_url` (field 3) is wired through both paths. The single-scope fast path is byte-identical to the pre-PR-3 wire shape (proto3 default-omit on the empty `schema_url` field). Coverage in `test/otlp_spans_multi_scope.zig` (5 tests: multi-scope by name/version/schema_url, single-scope byte-parity, DevNW↔in-repo wire parity); the multi-scope cases FAIL on `main` pre-fix and PASS post-fix. PR-5 (#138) replaces the linear scan with a hash-keyed bucket table next.
>
> **PR-2** ([#36](https://gitlab.com/devnw/zig/otel/-/work_items/36), score 88) — `Writer.commitSubMessage` quadratic `copyForwards` fixed 2026-04-27. The encoder now defers length-header rewrites until `toOwnedSlice`, which performs a single linear compaction sweep — no O(N²) tail shift on every nested commit. Coverage in `src/generated/otlp.zig` (6 PR-2 tests, including a 5-deep nesting parity check and a closed-form size-formula scaling probe at N ∈ {8, 128, 1024}) plus the existing wire-parity gate `test/otlp_wire_parity.zig` (3 byte-equality tests against the DevNW protobuf encoder). The new `bench-micro` scenarios `micro_encode_spans_proto_{64,512,4096}` measure flat ~50 K spans/s throughput across the 64×–4096× batch range — pre-fix the same workload showed super-linear ns-per-span growth.
>
> **PR-1** ([#135](https://gitlab.com/devnw/zig/otel/-/work_items/135), score 92) — `MeterProvider.pointFor` concurrency race fixed 2026-04-27. Per-instrument `InstrumentMutex` wraps every record-path and the `collect()` snapshot loop; `pointIndexFor` now returns indices not pointers; `collect()` deep-copies attribute sets and histogram buffers so the snapshot fully detaches from `inst.points`. Coverage in `test/metrics_concurrency.zig` (3 tests, including a 2-thread writer stress and a writer-vs-collector stress). Pre-fix the writer-stress test reliably crashes with a HashMap pointer-stability assert; post-fix it passes deterministically.

### Validated this sweep (8 issues closed)

| ID | Issue | Validation source |
|---|---|---|
| PR-1 | [#135](https://gitlab.com/devnw/zig/otel/-/work_items/135) | CHANGELOG: per-instrument mutex on metric pointFor / collect — race-free under concurrent record + collect; `test/metrics_concurrency.zig` (3 tests). |
| PR-2 | [#36](https://gitlab.com/devnw/zig/otel/-/work_items/36) | CHANGELOG: deferred-compaction `Writer.toOwnedSlice` — single O(N) sweep replaces per-commit `copyForwards`; `src/generated/otlp.zig` (6 PR-2 tests) + `test/otlp_wire_parity.zig` (3 byte-equality tests); `bench-micro` `micro_encode_spans_proto_{64,512,4096}` flat ~50 K spans/s. |
| PR-3 | [#136](https://gitlab.com/devnw/zig/otel/-/work_items/136) | CHANGELOG: `groupSpansByScope` keyed on `(name, version, schema_url)`; trace encoder emits one `ScopeSpans` per bucket on both in-repo and DevNW paths; new `test/otlp_spans_multi_scope.zig` (5 tests) — multi-scope cases FAIL on `main` pre-fix and PASS post-fix; single-scope batches stay byte-identical. |
| P-N1 | [#122](https://gitlab.com/devnw/zig/otel/-/work_items/122) | CHANGELOG: per-call retry backoff sleep added in OTLP/HTTP. |
| P-N2 | [#126](https://gitlab.com/devnw/zig/otel/-/work_items/126) | CHANGELOG: per-call retry backoff sleep added in OTLP/gRPC. |
| P0-1 | [#5](https://gitlab.com/devnw/zig/otel/-/work_items/5) | CHANGELOG: AttributeSet.put O(1) hash index — ~11× at 120-attr prefill. |
| P0-2 | [#6](https://gitlab.com/devnw/zig/otel/-/work_items/6) | CHANGELOG: SpanState pool with retain-capacity arena — ~1.97× steady-state. |
| P0-4 | [#15](https://gitlab.com/devnw/zig/otel/-/work_items/15) | CHANGELOG: pointFor zero-alloc fingerprint hit path — 3 → 0 allocs/op. |

### Bench / SLO gaps (now tracked)

- **BENCH-BASELINES-MISSING** ([#166](https://gitlab.com/devnw/zig/otel/-/work_items/166)) — **Partial 2026-04-27.** PR-2 nested-encode baseline captured at `docs/performance/2026-04-27-pr-2-encoder/results/{baseline,latest}.json` + `results.md`. Combined with the existing P0-1/P0-2/P0-4 dirs, every micro-scenario currently in `benchmarks/micro/main.zig` has a captured ReleaseFast snapshot. Remaining work — bench probes still need to be **authored** for P0-3, P0-5, P0-7, P0-8, P-N3..P-N7, P1-1..P1-3, P1-6..P1-13 — is reissued under the deferred-probes table below.
- **PERF-SLO-DEFINE** ([#167](https://gitlab.com/devnw/zig/otel/-/work_items/167)) — **closed 2026-04-27.** `docs/performance/SLO.md` defines per-op latency (`attr-update` p99 ≤ 50 ns/op) and per-op allocation (`counter-add 4-attrs hit` ≤ 0.005 allocs/op) ceilings; `benchmarks/check_hard_criteria.zig` extended with the matching runtime rules; `make slo-check` (and `make ci`) gate regressions. Deferred drain-side / OTLP-encode SLO rows tracked under #166.

---

## Stack-ranked findings (sorted by PerfScore desc, then by ID)

| Rank | PerfSeverity | PerfScore | Finding ID | Component | File:Line | Confidence | Issue | Status |
|---:|:---:|---:|:---|:---|:---|:---:|:---|:---|
| 1 | **P0** | **92** | **PR-1** | sdk | `src/sdk/metrics.zig:55-100,268-330,624-790` | confirmed | [#135](https://gitlab.com/devnw/zig/otel/-/work_items/135) | **closed 2026-04-27** — per-instrument `InstrumentMutex`; `pointIndexFor` returns indices not pointers; `collect()` deep-copies attribute sets + histogram buffers under the lock; tests in `test/metrics_concurrency.zig` (3) confirm pre-fix crash, post-fix pass. |
| 2 | **P0** | **88** | **PR-2** | exporters | `src/generated/otlp.zig:142-169` | confirmed | [#36](https://gitlab.com/devnw/zig/otel/-/work_items/36) | **closed 2026-04-27** — deferred-compaction `Writer.toOwnedSlice` (single O(N) sweep replaces per-commit `copyForwards`); `src/generated/otlp.zig` PR-2 tests (6) + `test/otlp_wire_parity.zig` (3); `bench-micro` `micro_encode_spans_proto_{64,512,4096}` flat ~50 K spans/s. |
| 3 | **P1** | **82** | **PR-7** | exporters | `src/exporters/prometheus.zig:70-80,162-177` | confirmed | [#146](https://gitlab.com/devnw/zig/otel/-/work_items/146) | triage |
| 4 | **P0** | **78** | **PR-3** | exporters | `src/exporters/otlp_http.zig:1039-1124,1378-1457` | confirmed | [#136](https://gitlab.com/devnw/zig/otel/-/work_items/136) | **closed 2026-04-27** — `groupSpansByScope` keys on `(name, version, schema_url)`; trace encoder emits one `ScopeSpans` per bucket on both in-repo (`encodeSpansProto`) and DevNW (`encodeSpansProtoDevnw`) paths; `ScopeSpans.schema_url` (field 3) wired through; new tests in `test/otlp_spans_multi_scope.zig` (5) cover multi-scope by name/version/schema_url, single-scope byte-parity fast path, and DevNW↔in-repo wire parity; FAIL on `main` pre-fix, PASS post-fix; PR-5 (#138) replaces the linear scan next. |
| 5 | **P1** | **76** | **PR-4** | exporters | `src/exporters/otlp_http.zig:243` | confirmed | [#47](https://gitlab.com/devnw/zig/otel/-/work_items/47) | triage |
| 6 | **P1** | **72** | **PR-5** | exporters | `src/exporters/otlp_http.zig:402-423` | confirmed | [#138](https://gitlab.com/devnw/zig/otel/-/work_items/138) | triage |
| 7 | **P1** | **72** | **PR-6** | api | `src/api/baggage.zig:56-73` | confirmed | [#139](https://gitlab.com/devnw/zig/otel/-/work_items/139) | triage |
| 8 | **P1** | **64** | **PR-8** | sdk | `src/sdk/metrics.zig` (clock.now ×2) | confirmed | [#141](https://gitlab.com/devnw/zig/otel/-/work_items/141) | **closed 2026-04-27** — single `provider.clock.now()` captured before the lock and reused for `pt.last_unix_nano`; `src/sdk/metrics.zig:527,560,595,619`; SLO gate clean (Rule 3 attr_put_update p99=28.97 ns/op; Rule 4 counter allocs/op=0.00150). |
| 9 | **P1** | **58** | **PR-9** | exporters | `src/exporters/otlp_grpc.zig:65,129,177` | confirmed | [#143](https://gitlab.com/devnw/zig/otel/-/work_items/143) | **closed 2026-04-27** — endpoint parsed once at `init` and cached in `OtlpGrpcExporter.parsed_endpoint`; the three former reparse sites (`checkExportPreconditions`, `expSpans`, `expMetrics`) now read from the cache; malformed endpoints fail fast at `init`. New regression suite `test/otlp_grpc_endpoint_cache.zig` (5 tests) pins the cache invariant including a "post-init mutation of `config.endpoint` does not affect dispatch" test. SLO gate clean (Rule 3 p99=27.89 ns/op; Rule 4 allocs/op=0.00150). |
| 10 | **P1** | **56** | **PR-10** | api/internal | `src/internal/json_codec.zig:50,75,100` | confirmed | [#144](https://gitlab.com/devnw/zig/otel/-/work_items/144) | **closed 2026-04-27** — `spanToJson` / `metricToJson` / `logToJson` now return `try buf.toOwnedSlice(arena)` instead of `try arena.dupe(u8, buf.items)`; the redundant per-call full-payload memcpy is gone (arena `remap` is O(1) when the buffer was the last allocation). The defunct `defer buf.deinit(arena)` lines are also dropped — the caller's arena owns the lifetime. Wire-parity tests still byte-identical. SLO gate clean (Rule 3 p99=29.81 ns/op; Rule 4 allocs/op=0.00150). |
| 11 | P0 | 48 | P0-5 | sdk | `src/sdk/metrics.zig:314-329` | confirmed | [#17](https://gitlab.com/devnw/zig/otel/-/work_items/17) | triage — folded into P0-4 |
| 12 | P0 | 48 | P0-7 | sdk | `src/sdk/metrics.zig:414-419` | confirmed | [#18](https://gitlab.com/devnw/zig/otel/-/work_items/18) | triage |
| 13 | P1 | 48 | P1-9 | exporters | `src/exporters/otlp_http.zig:138-139` | confirmed | [#47](https://gitlab.com/devnw/zig/otel/-/work_items/47) | triage (alias of PR-4) |
| 14 | P1 | 48 | P1-11 | exporters | `src/exporters/otlp_grpc.zig:171-172` | confirmed | [#70](https://gitlab.com/devnw/zig/otel/-/work_items/70) | triage |
| 15 | P0 | 32 | P0-8 | sdk | `src/sdk/export.zig:343-378` | confirmed | [#21](https://gitlab.com/devnw/zig/otel/-/work_items/21) | triage (sequenced after P0-9) |
| 16 | P0 | 24 | P0-3 | api | `src/api/trace.zig:159-165` | confirmed | [#10](https://gitlab.com/devnw/zig/otel/-/work_items/10) | triage |
| 17 | P1 | 24 | P1-1 | exporters | `src/generated/otlp.zig:110-137` | confirmed | [#36](https://gitlab.com/devnw/zig/otel/-/work_items/36) | triage (alias of PR-2) |
| 18 | P1 | 24 | P1-2 | exporters | `src/generated/otlp.zig:42-49` | confirmed | [#40](https://gitlab.com/devnw/zig/otel/-/work_items/40) | triage |
| 19 | P1 | 24 | P-N3 | bench | `benchmarks/integration/loopback_server.zig:181-184` | confirmed | [#128](https://gitlab.com/devnw/zig/otel/-/work_items/128) | triage |
| 20 | P1 | 24 | P-N6 | exporters | `src/exporters/stdout_json.zig:56-57,68-69,80-81` | confirmed | [#131](https://gitlab.com/devnw/zig/otel/-/work_items/131) | triage |
| 21 | P1 | 24 | P-N7 | exporters | `src/exporters/file.zig:82-83,93-94` | confirmed | [#132](https://gitlab.com/devnw/zig/otel/-/work_items/132) | triage |
| 22 | **P2** | **24** | **PR-11** | sdk | `src/sdk/metrics.zig` (companion bucket scan) | confirmed | [#148](https://gitlab.com/devnw/zig/otel/-/work_items/148) | triage |
| 23 | **P2** | **24** | **PR-12** | exporters | exporter per-export arena | confirmed | [#153](https://gitlab.com/devnw/zig/otel/-/work_items/153) | triage |
| 24 | P1 | 16 | P1-3 | sdk | `src/sdk/export.zig:251-260` | confirmed | [#41](https://gitlab.com/devnw/zig/otel/-/work_items/41) | triage |
| 25 | P1 | 16 | P1-7 | api/exporters | `src/internal/json_codec.zig:154-164` + `src/internal/attributes.zig:147-156` | confirmed | [#45](https://gitlab.com/devnw/zig/otel/-/work_items/45) | triage |
| 26 | P1 | 16 | P-N4 | bench | `benchmarks/integration/loopback_server.zig:131,135-156` | confirmed | [#129](https://gitlab.com/devnw/zig/otel/-/work_items/129) | triage |
| 27 | **P3** | **12** | **PR-13** | exporters | `src/exporters/prometheus.zig` (sanitizeMetricName) | confirmed | [#155](https://gitlab.com/devnw/zig/otel/-/work_items/155) | triage |
| 28 | P1 | 8 | P1-4 | sdk | `src/sdk/export.zig:262-297` | confirmed | [#42](https://gitlab.com/devnw/zig/otel/-/work_items/42) | triage — subsumed by P0-2 |
| 29 | P1 | 8 | P1-6 | sdk | `src/sdk/metrics.zig:499-557` | confirmed | [#44](https://gitlab.com/devnw/zig/otel/-/work_items/44) | triage |
| 30 | P1 | 8 | P1-8 | exporters | `src/exporters/prometheus.zig:25-86` | confirmed | [#46](https://gitlab.com/devnw/zig/otel/-/work_items/46) | triage |
| 31 | P1 | 8 | P1-10 | exporters | `src/exporters/otlp_http.zig:212` | confirmed | [#56](https://gitlab.com/devnw/zig/otel/-/work_items/56) | triage |
| 32 | P2 | 8 | P-N5 | bench | `benchmarks/integration/loopback_server.zig:159-184` | confirmed | [#130](https://gitlab.com/devnw/zig/otel/-/work_items/130) | triage |
| 33 | P1 | 4 | P1-12 | sdk | `src/sdk/resource.zig:30-38` | confirmed | [#75](https://gitlab.com/devnw/zig/otel/-/work_items/75) | triage — auto-fixed by P0-1 |
| 34 | P1 | 4 | P1-13 | api | `src/api/trace.zig:71-101` | suspected | [#82](https://gitlab.com/devnw/zig/otel/-/work_items/82) | triage |
| — | — | — | BENCH-BASELINES-MISSING | bench | `benchmarks/**`, `docs/performance/**` | confirmed | [#166](https://gitlab.com/devnw/zig/otel/-/work_items/166) | **Partial 2026-04-27** — captured PR-2 nested-encode under `docs/performance/2026-04-27-pr-2-encoder/`. All 18 micro scenarios currently in `benchmarks/micro/main.zig` are covered by a frozen ReleaseFast snapshot when combined with the 2026-04-26 P0-1/P0-2/P0-4 dirs. Remaining work — authoring bench probes for the 18 deferred gap rows (plus 2 won't-do rows P1-4 / P1-12) — reissued in §"Deferred bench probes" below. |
| — | — | — | PERF-SLO-DEFINE | bench | `docs/performance/SLO.md` + `benchmarks/check_hard_criteria.zig:65-77` | confirmed | [#167](https://gitlab.com/devnw/zig/otel/-/work_items/167) | **closed 2026-04-27** — `docs/performance/SLO.md` (~290 lines) defines per-op latency + alloc SLOs anchored to the 2026-04-26 P0-1/P0-4 baselines; `benchmarks/check_hard_criteria.zig` extended with two new runtime rules (Rule 3: `micro_attr_put_update` p99 ≤ 50 ns/op; Rule 4: `micro_counter_add_4_attrs_hit` allocs/op ≤ 0.005); `make slo-check` (Makefile) drives `bench-micro -Doptimize=ReleaseFast` + the gate; `make ci` includes `slo-check` so SLO regressions break the build. Verified `make slo-check` passes against fresh ReleaseFast bench-micro output (28.24 ns/op p99 attr-update; 0.0015 allocs/op counter-add hit). |

### Validated (closed, no further action this sweep)

| ID | Issue | Status |
|---|---|---|
| BENCH-HARNESS | [#2](https://gitlab.com/devnw/zig/otel/-/work_items/2) | closed 2026-04-26 PM |
| P1-5 | [#43](https://gitlab.com/devnw/zig/otel/-/work_items/43) | closed 2026-04-26 PM |
| P0-1 | [#5](https://gitlab.com/devnw/zig/otel/-/work_items/5) | **closed 2026-04-27** — ~11× attr ingest |
| P0-2 | [#6](https://gitlab.com/devnw/zig/otel/-/work_items/6) | **closed 2026-04-27** — ~1.97× span record |
| P0-4 | [#15](https://gitlab.com/devnw/zig/otel/-/work_items/15) | **closed 2026-04-27** — 3 → 0 allocs/metric |
| PR-1 | [#135](https://gitlab.com/devnw/zig/otel/-/work_items/135) | **closed 2026-04-27** — per-instrument mutex; -2.6% counter / -0.4% histogram (within ±5%) |
| PR-2 | [#36](https://gitlab.com/devnw/zig/otel/-/work_items/36) | **closed 2026-04-27** — deferred-compaction `Writer.toOwnedSlice`; flat 50 K spans/s at 64 / 512 / 4096 batch sizes (was super-linear) |
| P-N1 | [#122](https://gitlab.com/devnw/zig/otel/-/work_items/122) | **closed 2026-04-27** — retry backoff sleeps |
| P-N2 | [#126](https://gitlab.com/devnw/zig/otel/-/work_items/126) | **closed 2026-04-27** — retry backoff sleeps |
| P0-9 | [#22](https://gitlab.com/devnw/zig/otel/-/work_items/22) | CHANGELOG-validated (`schedule_delay_ms` wired); leave open until A/B captured |
| P0-10 | [#28](https://gitlab.com/devnw/zig/otel/-/work_items/28) | CHANGELOG-validated (default flipped to BSP); leave open until A/B captured |

### Deferred bench probes (BENCH-BASELINES-MISSING #166 — Partial close, remaining work)

Each row below is a perf gap whose **bench probe has not been authored yet**.
Until a probe lands in `benchmarks/micro/main.zig` (or `benchmarks/integration/main.zig`)
and the harness emits a stable `wall_ns_p50/p95/p99 + alloc_count` row, no
A/B baseline can be captured under `docs/performance/`. The probe-authoring
work is the unblocker; the baseline capture is mechanical (re-run
`make slo-check`, dump the relevant rows under
`docs/performance/<date>-<id>/results/`).

| Gap | Issue | Subject of the missing probe | Probe layer |
|---|---|---|---|
| **P0-3** | [#10](https://gitlab.com/devnw/zig/otel/-/work_items/10) | `Span.setName` arena-only path — re-name overwrite cost on a long-lived span (compare bytes-overwritten vs new-arena-alloc) | micro |
| **P0-5** | [#17](https://gitlab.com/devnw/zig/otel/-/work_items/17) | `attributeKey` scratch buffer — folded into P0-4 closure, but no dedicated probe captured the per-op delta | micro (folded) |
| **P0-7** | [#18](https://gitlab.com/devnw/zig/otel/-/work_items/18) | `Histogram.record` bucket binary-search — currently linear; needs `record` probe under varying bucket counts (8 / 32 / 128) | micro |
| **P0-8** | [#21](https://gitlab.com/devnw/zig/otel/-/work_items/21) | BSP queue contention — N producers × 1 drainer; needs `bench-integration` scenario, not micro | integration |
| **P-N3** | [#128](https://gitlab.com/devnw/zig/otel/-/work_items/128) | Loopback HTTP keep-alive cost — needs `bench-integration` round-trip probe | integration |
| **P-N4** | [#129](https://gitlab.com/devnw/zig/otel/-/work_items/129) | Loopback concurrency (multiple in-flight POST) — `bench-integration` | integration |
| **P-N5** | [#130](https://gitlab.com/devnw/zig/otel/-/work_items/130) | Loopback stack-buffer reuse — folds with P-N3 | integration |
| **P-N6** | [#131](https://gitlab.com/devnw/zig/otel/-/work_items/131) | `stdout_json` exporter arena hoist — needs `bench-micro` "encode + write to /dev/null" probe | micro |
| **P-N7** | [#132](https://gitlab.com/devnw/zig/otel/-/work_items/132) | File exporter arena hoist — same shape as P-N6, different sink | micro |
| **P1-1** | [#36](https://gitlab.com/devnw/zig/otel/-/work_items/36) | Alias of PR-2; covered by `2026-04-27-pr-2-encoder/` baseline (this commit) — close as duplicate | — |
| **P1-2** | [#40](https://gitlab.com/devnw/zig/otel/-/work_items/40) | `writeVarint` stack buffer — needs micro-probe over varint widths (1B / 5B / 10B) | micro |
| **P1-3** | [#41](https://gitlab.com/devnw/zig/otel/-/work_items/41) | `drainLocked` allocation — `bench-integration` BSP-drain probe | integration |
| **P1-6** | [#44](https://gitlab.com/devnw/zig/otel/-/work_items/44) | `collect()` pre-sizing — micro probe at varying instrument fan-out (8 / 32 / 128 attrs) | micro |
| **P1-7** | [#45](https://gitlab.com/devnw/zig/otel/-/work_items/45) | `sortedEntries` cache — needs probe that exercises both encode and JSON paths back-to-back | micro |
| **P1-8** | [#46](https://gitlab.com/devnw/zig/otel/-/work_items/46) | `Prometheus.render` pre-sizing — needs render-many-metrics micro probe | micro |
| **P1-10** | [#56](https://gitlab.com/devnw/zig/otel/-/work_items/56) | UnsupportedTransport fail-fast — micro probe verifying error-path latency floor | micro |
| **P1-11** | [#70](https://gitlab.com/devnw/zig/otel/-/work_items/70) | Persistent `GrpcClient` — `bench-integration` cold-start vs warm-call probe | integration |
| **P1-13** | [#82](https://gitlab.com/devnw/zig/otel/-/work_items/82) | `SpanState` layout — needs cache-line probe (steady-state span p99 with deliberately-mis-aligned struct) | micro |

**Unblock steps for each row:**

1. Author the probe in `benchmarks/{micro,integration}/main.zig` per the
   `framework.Scenario` shape.
2. Commit the probe + verify `make ci` (which includes `slo-check`) still passes.
3. Run `make slo-check` (or `zig build bench-integration -Doptimize=ReleaseFast`).
4. Extract the relevant rows from `benchmarks/results/micro-latest.json`
   (or the integration JSON) into `docs/performance/<YYYY-MM-DD>-<id>/results/{baseline,latest}.json`.
5. Author `docs/performance/<YYYY-MM-DD>-<id>/results.md` documenting subject, build flags,
   capture date, source PR / gap pointer, and a numbers table (see
   `docs/performance/2026-04-27-pr-2-encoder/results.md` for the canonical layout).

**Won't-do row:** P1-12 (#75) — auto-closed by P0-1; no probe to author.
P1-4 (#42) — subsumed by P0-2; no probe to author.
PR-* and P0-9 / P0-10 — already covered by 2026-04-26 P0-2/P0-4 + the
P0-9/P0-10 CHANGELOG-validated A/B follow-up tracker.

---

## Findings by area

### `area::api` (5 + 1 validated)

- **PR-6** Baggage.put dupe-before-dedup ([#139](https://gitlab.com/devnw/zig/otel/-/work_items/139)) — score 72
- **PR-10** json_codec redundant arena.dupe ([#144](https://gitlab.com/devnw/zig/otel/-/work_items/144)) — score 56
- **P0-3** setName arena-only ([#10](https://gitlab.com/devnw/zig/otel/-/work_items/10)) — score 24
- **P1-7** sortedEntries cache or drop ([#45](https://gitlab.com/devnw/zig/otel/-/work_items/45)) — score 16
- **P1-13** SpanState layout ([#82](https://gitlab.com/devnw/zig/otel/-/work_items/82)) — score 4 (suspected)
- ~~**P0-1** AttributeSet.put~~ ✅ closed 2026-04-27
- ~~**P0-2** SpanState pool~~ ✅ closed 2026-04-27

### `area::sdk` (8 + 2 validated)

- ~~**PR-1** pointFor concurrency race~~ ✅ closed 2026-04-27 ([#135](https://gitlab.com/devnw/zig/otel/-/work_items/135)) — per-instrument mutex; tests in `test/metrics_concurrency.zig`
- **PR-8** clock.now() 2× per record ([#141](https://gitlab.com/devnw/zig/otel/-/work_items/141)) — score 64
- **P0-5** attributeKey scratch (folded into P0-4) ([#17](https://gitlab.com/devnw/zig/otel/-/work_items/17)) — score 48
- **P0-7** Histogram bucket binary search ([#18](https://gitlab.com/devnw/zig/otel/-/work_items/18)) — score 48
- **P0-8** BSP queue contention ([#21](https://gitlab.com/devnw/zig/otel/-/work_items/21)) — score 32
- **PR-11** companion bucket scan ([#148](https://gitlab.com/devnw/zig/otel/-/work_items/148)) — score 24
- **P1-3** drainLocked alloc ([#41](https://gitlab.com/devnw/zig/otel/-/work_items/41)) — score 16
- **P1-4** exportBatch parallel alloc (subsumed) ([#42](https://gitlab.com/devnw/zig/otel/-/work_items/42)) — score 8
- **P1-6** collect pre-sizing ([#44](https://gitlab.com/devnw/zig/otel/-/work_items/44)) — score 8
- **P1-12** Resource.merge cascade ([#75](https://gitlab.com/devnw/zig/otel/-/work_items/75)) — score 4
- ~~**P0-4** pointFor zero-alloc~~ ✅ closed 2026-04-27
- (P0-9, P0-10 CHANGELOG-validated; A/B pending)

### `area::exporters` (12)

- ~~**PR-2** commitSubMessage copyForwards quadratic~~ ✅ closed 2026-04-27 ([#36](https://gitlab.com/devnw/zig/otel/-/work_items/36)) — deferred-compaction `Writer.toOwnedSlice`; tests in `src/generated/otlp.zig` (6) + `test/otlp_wire_parity.zig` (3); bench `micro_encode_spans_proto_{64,512,4096}` flat ~50 K spans/s
- **PR-3** items[0]-only scope encoder ([#136](https://gitlab.com/devnw/zig/otel/-/work_items/136)) — score 78
- **PR-7** Prometheus per-bucket label re-sort ([#146](https://gitlab.com/devnw/zig/otel/-/work_items/146)) — score 82
- **PR-4 / P1-9** Persistent `std.http.Client` ([#47](https://gitlab.com/devnw/zig/otel/-/work_items/47)) — score 76
- **PR-5** groupByScope linear scan ([#138](https://gitlab.com/devnw/zig/otel/-/work_items/138)) — score 72
- **PR-9** OTLP/gRPC endpoint reparsed ([#143](https://gitlab.com/devnw/zig/otel/-/work_items/143)) — score 58
- **PR-12** exporter-level per-export arena ([#153](https://gitlab.com/devnw/zig/otel/-/work_items/153)) — score 24
- **PR-13** sanitizeMetricName cache ([#155](https://gitlab.com/devnw/zig/otel/-/work_items/155)) — score 12
- **P1-2** writeVarint stack buffer ([#40](https://gitlab.com/devnw/zig/otel/-/work_items/40)) — score 24
- **P-N6** stdout_json arena hoist ([#131](https://gitlab.com/devnw/zig/otel/-/work_items/131)) — score 24
- **P-N7** file exporter arena hoist ([#132](https://gitlab.com/devnw/zig/otel/-/work_items/132)) — score 24
- **P1-8** Prometheus.render pre-size ([#46](https://gitlab.com/devnw/zig/otel/-/work_items/46)) — score 8
- **P1-10** UnsupportedTransport fail-fast ([#56](https://gitlab.com/devnw/zig/otel/-/work_items/56)) — score 8
- **P1-11** Persistent `GrpcClient` ([#70](https://gitlab.com/devnw/zig/otel/-/work_items/70)) — score 48

### `area::bench` (5 + tracking)

- **BENCH-BASELINES-MISSING** ([#166](https://gitlab.com/devnw/zig/otel/-/work_items/166)) — tracking
- **PERF-SLO-DEFINE** ([#167](https://gitlab.com/devnw/zig/otel/-/work_items/167)) — **closed 2026-04-27** — `docs/performance/SLO.md` + `benchmarks/check_hard_criteria.zig` Rules 3-4 + `make slo-check`
- **P-N3** loopback keep-alive ([#128](https://gitlab.com/devnw/zig/otel/-/work_items/128)) — score 24
- **P-N4** loopback concurrency ([#129](https://gitlab.com/devnw/zig/otel/-/work_items/129)) — score 16
- **P-N5** stack buffers (folds with P-N3) ([#130](https://gitlab.com/devnw/zig/otel/-/work_items/130)) — score 8
- ~~**BENCH-HARNESS**~~ ✅ closed

---

## Cross-link map (shared fixes)

| Anchor | Cascade-fixes / co-fixes |
|---|---|
| **PR-1** ([#135](https://gitlab.com/devnw/zig/otel/-/work_items/135)) | Hardens the post-P0-4 zero-alloc fingerprint cache. Touches the same struct as PR-8 (clock.now consolidation) — co-implement. |
| **PR-2** ([#36](https://gitlab.com/devnw/zig/otel/-/work_items/36)) | Subsumes original P1-1 line-range. Two-pass encoder rewrite also lands **P1-2** ([#40](https://gitlab.com/devnw/zig/otel/-/work_items/40)) stack-buffer fix. PR-3 ([#136](https://gitlab.com/devnw/zig/otel/-/work_items/136)) wire-shape fix is in the same encoder; co-implement. |
| **PR-3** ([#136](https://gitlab.com/devnw/zig/otel/-/work_items/136)) ↔ **PR-5** ([#138](https://gitlab.com/devnw/zig/otel/-/work_items/138)) | PR-3 introduces groupByScope; PR-5 replaces its linear scan with a hash-keyed bucket table. |
| **PR-4** ([#47](https://gitlab.com/devnw/zig/otel/-/work_items/47)) ↔ **PR-9** ([#143](https://gitlab.com/devnw/zig/otel/-/work_items/143)) ↔ **P1-11** ([#70](https://gitlab.com/devnw/zig/otel/-/work_items/70)) | Same struct shape: lift transport client + parsed endpoint to exporter init, mutex on call. Bundle. |
| **PR-6** ([#139](https://gitlab.com/devnw/zig/otel/-/work_items/139)) | Same defect class as P0-1 (closed). Cross-link Quality M5 (#38). |
| **PR-7** ([#146](https://gitlab.com/devnw/zig/otel/-/work_items/146)) ↔ **P1-8** ([#46](https://gitlab.com/devnw/zig/otel/-/work_items/46)) ↔ **PR-13** ([#155](https://gitlab.com/devnw/zig/otel/-/work_items/155)) | Same Prometheus render path: hoist label sort, pre-size buffer, cache sanitized names. One worktree. |
| **PR-11** ([#148](https://gitlab.com/devnw/zig/otel/-/work_items/148)) | Co-implement with **P0-7** ([#18](https://gitlab.com/devnw/zig/otel/-/work_items/18)) — one helper, two call sites. |
| **PR-12** ([#153](https://gitlab.com/devnw/zig/otel/-/work_items/153)) | Same shape as P-N6 ([#131](https://gitlab.com/devnw/zig/otel/-/work_items/131)) and P-N7 ([#132](https://gitlab.com/devnw/zig/otel/-/work_items/132)); bundle the three exporter arena hoists. |
| **BENCH-BASELINES-MISSING** ([#166](https://gitlab.com/devnw/zig/otel/-/work_items/166)) | Gate for every other validate-and-close step. |
| **PERF-SLO-DEFINE** ([#167](https://gitlab.com/devnw/zig/otel/-/work_items/167)) | Provides the numeric target for `bench-ci` regression gate. |

---

## Roadmap

### Quick wins (< 1 day each, mechanical)

| ID | Issue | Score | Why first |
|---|---|---:|---|
| PR-8 | [#141](https://gitlab.com/devnw/zig/otel/-/work_items/141) | 64 | Capture `now_ns` once; thread through. Pure mechanical. |
| PR-10 | [#144](https://gitlab.com/devnw/zig/otel/-/work_items/144) | 56 | Drop redundant arena.dupe at 3 sites. Verify lifetime once. |
| PR-13 | [#155](https://gitlab.com/devnw/zig/otel/-/work_items/155) | 12 | Add sanitized-name cache to PR-7 worktree. |
| P0-7 | [#18](https://gitlab.com/devnw/zig/otel/-/work_items/18) | 48 | `std.sort.lowerBound` swap. Bundle with PR-11. |
| P1-2 | [#40](https://gitlab.com/devnw/zig/otel/-/work_items/40) | 24 | 8-line stack-buffer fix; lands inside PR-2 rewrite. |
| P1-6 | [#44](https://gitlab.com/devnw/zig/otel/-/work_items/44) | 8 | Single line `ensureTotalCapacity`. |
| P1-10 | [#56](https://gitlab.com/devnw/zig/otel/-/work_items/56) | 8 | Remove one switch arm. No bench needed. |

### Medium (1-5 days)

| ID | Issue | Score | Notes |
|---|---|---:|---|
| **PR-1** | [#135](https://gitlab.com/devnw/zig/otel/-/work_items/135) | **92** | Move pointFor lookup inside instrument mutex. Add 2-thread regression test. **Highest priority.** |
| **PR-3** | [#136](https://gitlab.com/devnw/zig/otel/-/work_items/136) | **78** | groupByScope pass + multi-scope encoder. Correctness defect. |
| **PR-7** | [#146](https://gitlab.com/devnw/zig/otel/-/work_items/146) | **82** | Hoist Prometheus label sort. Bundle with P1-8 + PR-13. |
| PR-4 | [#47](https://gitlab.com/devnw/zig/otel/-/work_items/47) | 76 | Persistent `std.http.Client`; co-implement with PR-9 + P1-11. |
| PR-5 | [#138](https://gitlab.com/devnw/zig/otel/-/work_items/138) | 72 | Hash-keyed bucket table. After PR-3. |
| PR-6 | [#139](https://gitlab.com/devnw/zig/otel/-/work_items/139) | 72 | Baggage dedup-before-dupe. Co-implement with Quality M5. |
| PR-9 | [#143](https://gitlab.com/devnw/zig/otel/-/work_items/143) | 58 | Memoize parsed endpoint. Bundle with PR-4. |
| P0-3 | [#10](https://gitlab.com/devnw/zig/otel/-/work_items/10) | 24 | Move `name` into the arena. Lands cleanest now that P0-2 closed. |
| P1-3 / P1-4 | [#41](https://gitlab.com/devnw/zig/otel/-/work_items/41) [#42](https://gitlab.com/devnw/zig/otel/-/work_items/42) | 16 / 8 | P1-4 closed by P0-2; P1-3 still open. |
| P1-7 | [#45](https://gitlab.com/devnw/zig/otel/-/work_items/45) | 16 | Cache-the-sort. |
| P-N6 / P-N7 / PR-12 | [#131](https://gitlab.com/devnw/zig/otel/-/work_items/131) [#132](https://gitlab.com/devnw/zig/otel/-/work_items/132) [#153](https://gitlab.com/devnw/zig/otel/-/work_items/153) | 24/24/24 | Three exporter arena hoists; one worktree. |

### Strategic (> 5 days)

| ID | Issue | Score | Notes |
|---|---|---:|---|
| **PR-2** | [#36](https://gitlab.com/devnw/zig/otel/-/work_items/36) | **88** | Two-pass encoder (drop `copyForwards`). Wire-format hot path; parity test required. |
| P0-8 | [#21](https://gitlab.com/devnw/zig/otel/-/work_items/21) | 32 | Sharded MPSC queue. Only after P0-9 lands. |
| P1-11 | [#70](https://gitlab.com/devnw/zig/otel/-/work_items/70) | 48 | Persistent `GrpcClient`; needs `grpc-zig` reusability check. |
| P1-13 | [#82](https://gitlab.com/devnw/zig/otel/-/work_items/82) | 4 | Measure-first; only ship if `perf stat` shows measurable miss-rate delta. |

### Tracking / infrastructure

- **BENCH-BASELINES-MISSING** ([#166](https://gitlab.com/devnw/zig/otel/-/work_items/166)) — gate for validating every other open perf item.
- **PERF-SLO-DEFINE** ([#167](https://gitlab.com/devnw/zig/otel/-/work_items/167)) — defines numeric targets + CI regression gate.

---

## Recommended execution sequence

1. **Tracking infra first.** Land #166 (baselines) and #167 (SLOs + bench-ci gate) before anything else; otherwise the next 25+ fixes have no acceptance test.
2. **Correctness P0s in parallel** — **PR-1** (#135 metrics race) and **PR-3** (#136 multi-scope encoder). Each in its own worktree with a regression test that fails on main.
3. **Encoder rewrite** — **PR-2** (#36 quadratic copyForwards) bundling P1-2 (#40 stack buffer) and PR-5 (#138 groupByScope hash). Single worktree; parity test.
4. **Prometheus bundle** — **PR-7** (#146 label sort hoist) + P1-8 (#46 pre-size) + PR-13 (#155 sanitize cache).
5. **Exporter transport bundle** — **PR-4** (#47) + PR-9 (#143) + P1-11 (#70) + PR-12 (#153) + P-N6 (#131) + P-N7 (#132). Single struct refactor; six closes.
6. **Mechanical** — PR-8 (#141), PR-10 (#144), P0-7 (#18) + PR-11 (#148), P0-3 (#10), P1-6 (#44), P1-10 (#56).
7. **Tail** — PR-6 (#139 baggage), P1-3 (#41), P1-7 (#45).
8. **Strategic** — P0-8 (#21 BSP queue contention) after P0-9 A/B is captured.

---

## Phase 3 perf-reviewer findings (2026-04-27)

Thirteen new findings + escalations from the Phase 3 perf-reviewer pass. Three are P0 (race correctness, encoder quadratic, scope mislabel). Seven are P1 (Prometheus sort, persistent client, groupByScope, baggage dedup, double clock.now, endpoint reparse, redundant dupe). Two P2 (companion bucket scan, exporter arena pattern). One P3 (sanitize cache).

| ID | PerfSeverity | PerfScore | File:Line | Issue | Fix shape |
|---|:---:|---:|:---|:---|:---|
| **PR-1** | **P0** | **92** | `src/sdk/metrics.zig:268-304,591-649` | [#135](https://gitlab.com/devnw/zig/otel/-/work_items/135) | Move pointFor lookup inside instrument mutex; 2-thread regression test. |
| **PR-2** | **P0** | **88** | `src/generated/otlp.zig:142-169` | [#36](https://gitlab.com/devnw/zig/otel/-/work_items/36) | Two-pass encoder; drop `copyForwards`. Escalated from P1-1. |
| **PR-3** | **P0** | **78** | `src/exporters/otlp_http.zig:1055-1093` | [#136](https://gitlab.com/devnw/zig/otel/-/work_items/136) | Insert groupByScope; emit one ScopeSpans per bucket. |
| **PR-7** | P1 | **82** | `src/exporters/prometheus.zig:70-80,162-177` | [#146](https://gitlab.com/devnw/zig/otel/-/work_items/146) | Hoist label sort above bucket loop; cache sorted slice. |
| **PR-4** | P1 | **76** | `src/exporters/otlp_http.zig:243` | [#47](https://gitlab.com/devnw/zig/otel/-/work_items/47) | Persistent `std.http.Client`; lazy-init; mutex on call. |
| **PR-5** | P1 | 72 | `src/exporters/otlp_http.zig:402-423` | [#138](https://gitlab.com/devnw/zig/otel/-/work_items/138) | `AutoHashMap(*const InstrumentationScope, …)` for buckets. |
| **PR-6** | P1 | 72 | `src/api/baggage.zig:56-73` | [#139](https://gitlab.com/devnw/zig/otel/-/work_items/139) | Defer-dupe; search first, then alloc. |
| **PR-8** | P1 | 64 | `src/sdk/metrics.zig` (clock.now ×2) | [#141](https://gitlab.com/devnw/zig/otel/-/work_items/141) | Capture `now_ns` once; thread through. |
| **PR-9** | P1 | 58 | `src/exporters/otlp_grpc.zig:65,129,177` | [#143](https://gitlab.com/devnw/zig/otel/-/work_items/143) | Memoize parsed endpoint at init. |
| **PR-10** | P1 | 56 | `src/internal/json_codec.zig:50,75,100` | [#144](https://gitlab.com/devnw/zig/otel/-/work_items/144) | Drop redundant `arena.dupe(buf.items)` at 3 sites. |
| **PR-11** | P2 | 24 | `src/sdk/metrics.zig` (companion bucket scan) | [#148](https://gitlab.com/devnw/zig/otel/-/work_items/148) | Co-implement with P0-7. |
| **PR-12** | P2 | 24 | exporter per-export arena (third site) | [#153](https://gitlab.com/devnw/zig/otel/-/work_items/153) | Hoist arena to exporter struct. |
| **PR-13** | P3 | 12 | `src/exporters/prometheus.zig` (sanitizeMetricName) | [#155](https://gitlab.com/devnw/zig/otel/-/work_items/155) | StringHashMap-keyed cache. |

All confidence::confirmed except PR-12 (site verification needed during fix).

---

## Open unknowns / what would unblock evidence

- **#166** is the universal unblocker for measured baselines.
- **#167** defines the numeric SLOs; without it `bench-ci` has no threshold.
- **PR-12** site needs final verification during fix (likely `otlp_http` per-export arena before PR-4 lifts the client).
- **P0-8** severity at scale needs `bench_bsp_producer_scaling` at 1/2/4/8 producer threads.
- **P1-11** assumes `grpc-zig`'s `GrpcClient` is reusable across calls — needs a 30-min read of upstream source.
- **P1-13** layout effect needs Linux `perf stat -e L1-dcache-load-misses,LLC-load-misses` access on the bench host.
- **P1-7** Option 2 (drop sort) needs a survey of JSON consumers to confirm no one relies on key order.
