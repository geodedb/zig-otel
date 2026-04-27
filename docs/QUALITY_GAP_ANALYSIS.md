# Quality Gap Analysis

Last updated: 2026-04-27

This document tracks the codepros Phase-3 quality findings, their
PriorityScore, GitLab issue links, and current remediation status.
Source: `docs/audit/QUALITY_REVIEW.md` (Phase 3) re-scoring
`docs/audit/QUALITY_SCAN.md` (Phase 2), supplemented by the 2026-04-27
deep re-review (OTEL-Q-001..010 + OTEL-Q-NEW-A..E, see section
"Phase 3 deep re-review (2026-04-27)" below).

PriorityScore (legacy formula): `SeverityWeight × BlastRadius × FixConfidence`
(weights: Critical=8, High=4, Medium=2, Low=1; Blast 1-3; FixConf 1-3).

PriorityScore (2026-04-27 re-review formula): `Impact(1-5) × Likelihood(1-5) × 4`,
yielding 0-100. The two formulas coexist; rows are tagged with the
formula they were last scored under.

## Summary

**Total findings:** 55. **GitLab issues:** 45 (3 findings folded into the
dead-code cleanup bundle: M3, L7, L10; 9 from the 2026-04-26 re-audit:
Q32-Q38 + DOC-1, DOC-2; 12 from the 2026-04-27 deep re-review:
OTEL-Q-001/002/003/004/005/006/008/009/010 + OTEL-Q-NEW-A/B/D; 2 of the
2026-04-27 audit findings (OTEL-Q-007 and OTEL-Q-NEW-C) folded into
existing issues #19 and #53 via comment with audit Quality-ID; 1
(OTEL-Q-NEW-E) folded into OTEL-Q-004's body; OTEL-Q-011..016
catalogued as Low without dedicated issues — to be expanded if they
escalate).

| Severity | Count |
|----------|-------|
| Critical | 3     |
| High     | 11    |
| Medium   | 18    |
| Low      | 23    |

**Top 5 risks (by PriorityScore):**

1. **H7** — `Span.recordException` swallows allocation failures (`!void` lies). Score 36.
2. **C3** — `BatchSpanProcessorOptions.schedule_delay_ms` silently ignored; low-volume telemetry stalls. Score 32.
3. **C2** — Metric export pipeline half-built; `MetricReader.collect` never invoked. Score 24.
4. **H1** — `OtlpConfig.compression` / `skip_tls_verify` / `insecure` are dead config fields. Score 24.
5. **H2** — 4-way attribute formatter duplication; arrays silently dropped. Score 24.

> Phase 3 (2026-04-26 PM) net-new top finding: **Q35** — Linux comptime
> guard around `wake()` raw syscalls, Score 8. Highest score of the
> net-new batch; below the global Tier-1 cutoff but the most urgent of
> the loopback-server nits.

**Loopback server quality verdict (2026-04-26 PM):** ACCEPTABLE AS-IS
for benchmark-tier code. Three nits in Q35 / Q37 / Q38 are worth fixing
in-place; the rest of the file is well-factored.

**Cross-reference with Security Audit:** Quality M9 (`applyEnv`
thread-local slice aliasing) is the same defect as **Security C-1**
(env-var slice aliasing → bearer-token corruption). Fix once, close
both. Quality issue is public; security issue is confidential. See
issue #34.

## Stack-Ranked Findings

| Rank | ID  | Severity | Score | Category        | Finding                                                               | Component               | Evidence                                  | Issue URL                                                  | Status |
|------|-----|----------|-------|-----------------|-----------------------------------------------------------------------|-------------------------|-------------------------------------------|------------------------------------------------------------|--------|
| 1    | H7  | High     | 36    | api-contract    | `Span.recordException` swallows alloc failures despite `!void`        | api/trace               | `src/api/trace.zig:194-207`               | <https://gitlab.com/devnw/zig/otel/-/work_items/11>          | Open   |
| 2    | C3  | Critical | 32    | api-contract    | `BatchSpanProcessorOptions.schedule_delay_ms` declared but never read | sdk/export              | `src/sdk/export.zig:139-148`              | <https://gitlab.com/devnw/zig/otel/-/work_items/12>          | Open   |
| 3    | C2  | Critical | 24    | architecture    | `MetricReader.collect` / `MetricExporter` never invoked               | sdk/metrics             | `src/sdk/metrics.zig:38-47`               | <https://gitlab.com/devnw/zig/otel/-/work_items/13>          | Open   |
| 4    | H1  | High     | 24    | api-contract    | `OtlpConfig.compression`/`skip_tls_verify`/`insecure` dead            | sdk/config + exporters  | `src/sdk/config.zig:47-57`                | <https://gitlab.com/devnw/zig/otel/-/work_items/14>          | Open   |
| 5    | H2  | High     | 24    | maintainability | 4× attribute formatter; arrays silently dropped                       | exporters + json_codec  | `prometheus.zig:146` +3 sites             | <https://gitlab.com/devnw/zig/otel/-/work_items/16>          | Open   |
| 6    | H8  | High     | 24    | docs            | Public API surface lacks `///` doc comments                           | api/*                   | `src/api/trace.zig` (entire file)         | <https://gitlab.com/devnw/zig/otel/-/work_items/19>          | Open   |
| 7    | C1+H5 | Critical | 24+16 | ci-cd         | `benchmarks/bench.zig` calls non-existent `lib.init`; CI stubs        | benchmarks + build.zig  | `benchmarks/bench.zig:55-71`, `build.zig:391-401` | <https://gitlab.com/devnw/zig/otel/-/work_items/20>  | Open   |
| 8    | M9  | Medium   | 18    | api-contract    | `applyEnv` thread-local slice aliasing corrupts config (memory bug)   | sdk/config              | `src/sdk/config.zig:122-217`              | <https://gitlab.com/devnw/zig/otel/-/work_items/34>          | Open (≈ sec C-1) |
| 9    | H6  | High     | 16    | tests           | `test/grpc_loopback.zig` self-skips unconditionally                   | tests                   | `test/grpc_loopback.zig:31-32`            | <https://gitlab.com/devnw/zig/otel/-/work_items/37>          | Open   |
| 10   | M5  | Medium   | 12    | api-contract    | `Context.withBaggage` thread-local pinned-baggage clobber             | api/context             | `src/api/context.zig:57-94`               | <https://gitlab.com/devnw/zig/otel/-/work_items/38>          | Open   |
| 11   | H3  | High     | 12    | maintainability | Duplicate noop/shutdown shims across 5 exporters                      | exporters               | 5 file:lines (in_memory, stdout, file, otlp_http, otlp_grpc) | <https://gitlab.com/devnw/zig/otel/-/work_items/39> | Open |
| 12   | M6  | Medium   | 8     | maintainability | OTLP/HTTP and OTLP/gRPC retry loops diverge                           | exporters               | `otlp_http.zig:191-228`, `otlp_grpc.zig:87-120` | <https://gitlab.com/devnw/zig/otel/-/work_items/53>    | Open   |
| 13   | M4  | Medium   | 8     | tests           | Resource detectors untested; `processDetector` Linux-only             | sdk/resource            | `src/sdk/resource.zig:63-156`             | <https://gitlab.com/devnw/zig/otel/-/work_items/55>          | Open   |
| 14   | M7  | Medium   | 8     | api-contract    | OTLP partial-success body inaccessible to callers                     | exporters/otlp_http     | `src/exporters/otlp_http.zig:215-219`     | <https://gitlab.com/devnw/zig/otel/-/work_items/57>          | Open   |
| 15   | M1  | Medium   | 8     | api-contract    | `redact.maskString` not wired into export pipeline                    | internal/redact + exporters | `src/internal/redact.zig`             | <https://gitlab.com/devnw/zig/otel/-/work_items/58>          | Open   |
| 16   | H4  | High     | 8     | maintainability | OTLP HTTP/gRPC scheme-strip parsing duplicated                        | exporters               | `otlp_grpc.zig:132-150`, `otlp_http.zig:115-117` | <https://gitlab.com/devnw/zig/otel/-/work_items/62>   | Open   |
| 17   | L8  | Low      | 6     | maintainability | Provider init/deinit duplicated 3×                                    | sdk/{trace,logs,metrics}| `src/sdk/trace.zig:136-195` +2           | <https://gitlab.com/devnw/zig/otel/-/work_items/65>          | Open   |
| 18   | M3  | Medium   | 6     | cleanup         | `setActiveProvider` no-op shim                                        | sdk/metrics             | `src/sdk/metrics.zig:375-378`             | <https://gitlab.com/devnw/zig/otel/-/work_items/68> (bundle) | Open   |
| 19   | M8  | Medium   | 4     | tests           | Tests cluster on happy paths; no FailingAllocator sweep               | test/*                  | `test/` (multiple)                        | <https://gitlab.com/devnw/zig/otel/-/work_items/102>         | Open   |
| 20   | M10 | Medium   | 4     | api-contract    | `applyYamlString` silently truncates / accepts unknown keys           | sdk/config              | `src/sdk/config.zig:222-287`              | <https://gitlab.com/devnw/zig/otel/-/work_items/103>         | Open   |
| 21   | M2  | Medium   | 4     | cleanup         | `internal/ring_buffer.zig` dead code with misleading comment          | internal                | `src/internal/ring_buffer.zig:1-71`       | <https://gitlab.com/devnw/zig/otel/-/work_items/104>         | Open   |
| 22   | L2  | Low      | 4     | maintainability | Hard-coded magic seeds in PRNG init                                   | exporters + sdk/trace   | `otlp_http.zig:54`, `otlp_grpc.zig:44`, `trace.zig:163` | <https://gitlab.com/devnw/zig/otel/-/work_items/105> | Open |
| 23   | L4  | Low      | 4     | maintainability | Provider `init` lacks `errdefer` cleanup on partial state             | sdk/providers           | `src/sdk/trace.zig:136-184` +2            | <https://gitlab.com/devnw/zig/otel/-/work_items/106>         | Open   |
| 24   | L3  | Low      | 4     | api-contract    | `otel.Error` set incomplete relative to actual returns                | otel.zig                | `src/otel.zig:99-113`                     | <https://gitlab.com/devnw/zig/otel/-/work_items/107>         | Open   |
| 25   | L7  | Low      | 3     | cleanup         | `RetryPolicy.seed` field never read                                   | sdk/export              | `src/sdk/export.zig:542-548`              | <https://gitlab.com/devnw/zig/otel/-/work_items/68> (bundle) | Open   |
| 26   | L10 | Low      | 3     | cleanup         | `Span.addEvent` `@compileError` while pub                             | api/trace               | `src/api/trace.zig:213-224`               | <https://gitlab.com/devnw/zig/otel/-/work_items/68> (bundle) | Open   |
| 27   | L9  | Low      | 3     | readability     | `Severity.shortText` 25-arm switch                                    | api/logs                | `src/api/logs.zig:39-49`                  | <https://gitlab.com/devnw/zig/otel/-/work_items/111>         | Open   |
| 28   | L6  | Low      | 2     | docs            | `instrumentation/http.zig` stack-buf into `startSpan`                 | instrumentation/http    | `src/instrumentation/http.zig:26-34`      | <https://gitlab.com/devnw/zig/otel/-/work_items/110>         | Open   |
| 29   | L5  | Low      | 2     | cleanup         | `tools/golden.zig` mixes hex output styles                            | tools                   | `tools/golden.zig:79-95`                  | <https://gitlab.com/devnw/zig/otel/-/work_items/109>         | Open   |
| 30   | L1  | Low      | 1     | docs            | snake_case vs camelCase undocumented                                  | docs                    | (CONTRIBUTING absent)                     | <https://gitlab.com/devnw/zig/otel/-/work_items/108>         | Open   |

**Note on bundled findings:** M3, L7, and L10 are tracked under the
single mechanical dead-code cleanup PR (#68) per the Phase 3
recommendation; they are also listed individually above for
traceability.

## Phase 3 re-audit findings (2026-04-26 PM)

Net-new findings produced by the 2026-04-26 re-audit, focused on the
benchmarks suite (post F-2..F-5 landing) and on documentation drift
since the original Phase 3 pass. Loopback server file
(`benchmarks/integration/loopback_server.zig`) was assessed
holistically — verdict: ACCEPTABLE AS-IS for benchmark-tier code; the
3 nits below (Q35 / Q37 / Q38) are worth fixing in-place.

| Q-ID  | Severity | Score | Category        | Finding                                                                       | Component               | Evidence                                              | Issue URL                                                  | Status |
|-------|----------|-------|-----------------|-------------------------------------------------------------------------------|-------------------------|-------------------------------------------------------|------------------------------------------------------------|--------|
| Q35   | Medium   | 8     | ci-cd           | Add Linux comptime guard around `wake()` raw syscalls (highest net-new)       | benchmarks/integration  | `benchmarks/integration/loopback_server.zig:200-216`  | <https://gitlab.com/devnw/zig/otel/-/work_items/116>          | Open   |
| Q32   | Low      | 3     | cleanup         | DRY: hoist duplicated `fakeTransport` into `framework.fakeOtlpTransport`      | benchmarks              | `benchmarks/integration/main.zig:263-273` + `benchmarks/compare_bench.zig:290-300` | <https://gitlab.com/devnw/zig/otel/-/work_items/113> | Open |
| Q33   | Low      | 2     | maintainability | Eliminate file-scope global `g_loopback_server`; pass via `Scenario.user_data`| benchmarks/integration  | `benchmarks/integration/main.zig:32`                  | <https://gitlab.com/devnw/zig/otel/-/work_items/114>          | Open   |
| Q34   | Low      | 2     | api-contract    | Enforce `LoopbackServer.err` join-only contract via debug-assert              | benchmarks/integration  | `benchmarks/integration/loopback_server.zig:65-85`    | <https://gitlab.com/devnw/zig/otel/-/work_items/115>          | Open   |
| Q36   | Low      | 2     | maintainability | Replace fixed-size `[sync.len + 16]Scenario` with comptime `sync ++ async`    | benchmarks/integration  | `benchmarks/integration/main.zig:60-65`               | <https://gitlab.com/devnw/zig/otel/-/work_items/117>          | Open   |
| Q37   | Low      | 2     | api-contract    | Propagate body-stream errors in `handleOne` (don't `catch {}`)                | benchmarks/integration  | `benchmarks/integration/loopback_server.zig:179`      | <https://gitlab.com/devnw/zig/otel/-/work_items/118>          | Open   |
| Q38   | Low      | 2     | readability     | Rename `request_count` → `connections_handled` (counts attempts, not OKs)     | benchmarks/integration  | `benchmarks/integration/loopback_server.zig:60-64,150-156` | <https://gitlab.com/devnw/zig/otel/-/work_items/120>     | Open   |
| DOC-1 | Medium   | n/a   | docs            | Populate CHANGELOG `[Unreleased]` with F-2..F-5 entries                       | docs                    | `CHANGELOG.md`                                        | <https://gitlab.com/devnw/zig/otel/-/work_items/123>          | Open   |
| DOC-2 | Medium   | n/a   | docs            | README section: runtime kill-switch precedence + async-pool flag + loopback bench mode | docs           | `README.md`                                           | <https://gitlab.com/devnw/zig/otel/-/work_items/124>          | Open   |

> **Sequencing**: Q35 first (only net-new with Score ≥ 8); DOC-1 + DOC-2
> in parallel with the next docs PR. Q32-Q34 / Q36-Q38 cluster naturally
> into one bench-cleanup PR (all touch `benchmarks/integration/*`).

## Phase 3 deep re-review (2026-04-27)

A targeted re-review of the exporter, SDK, and config layers produced
18 findings (0 Critical / 3 High / 9 Medium / 6 Low). Scoring formula
is `Impact(1-5) × Likelihood(1-5) × 4`, range 0-100. New issues use the
**OTEL-Q-NNN** prefix; two findings (OTEL-Q-007, OTEL-Q-NEW-C) mapped
onto existing work items via comments with audit Quality-ID rather
than creating duplicates; OTEL-Q-NEW-E was folded into OTEL-Q-004's
body.

| Q-ID            | Severity | Score | Category        | Finding                                                              | Component                | Evidence                                              | Issue URL                                                     | Status |
|-----------------|----------|-------|-----------------|----------------------------------------------------------------------|--------------------------|-------------------------------------------------------|---------------------------------------------------------------|--------|
| OTEL-Q-001      | High     | 85    | architecture    | Split `exporters/otlp_http.zig` (~1407 lines) by signal/encoder      | exporters                | `src/exporters/otlp_http.zig:1407` (pre-fix) → split into `src/exporters/otlp_http/{exporter,transport,headers,encode_proto,encode_proto_devnw,encode_json,spans,metrics}.zig`; facade at `src/exporters/otlp_http.zig:1` (85 LOC) | <https://gitlab.com/devnw/zig/otel/-/work_items/149>          | Closed |
| OTEL-Q-NEW-A    | High     | 82    | architecture    | Replace fragile fn-ptr identity sentinel with tagged-union Transport | exporters                | pre-fix: `self.transport == httpTransport` at `otlp_http.zig:303-306, 372-375` → `Transport = union(enum) { stdlib_io, custom: CustomFn }` at `src/exporters/otlp_http/transport.zig:58`; dispatch is now `switch (self.transport)` at `src/exporters/otlp_http/exporter.zig:163` | <https://gitlab.com/devnw/zig/otel/-/work_items/163>          | Closed |
| OTEL-Q-002      | High     | 80    | maintainability | Extract `exportSignal` helper from OTLP/HTTP                          | exporters                | `src/exporters/otlp_http.zig:277-322, 348-392`        | <https://gitlab.com/devnw/zig/otel/-/work_items/150>          | Open   |
| OTEL-Q-003      | High     | 78    | api-contract    | Implement OTLP log export (HTTP + gRPC)                               | sdk + exporters          | Closed: `src/exporters/otlp_http/encode_logs.zig`, `logs.zig`, `encode_json.zig:encodeLogsJson`, `exporter.zig:logExporter`; gRPC `src/exporters/otlp_grpc.zig:expLogs`+`logExporter`; DevNW parity `encode_proto_devnw.zig:encodeLogsProtoDevnw`; `test/otlp_logs_wire.zig` | <https://gitlab.com/devnw/zig/otel/-/work_items/152>          | Closed |
| OTEL-Q-004      | Medium   | 70    | maintainability | Replace 13× `catch {}` with breadcrumb logger (folds OTEL-Q-NEW-E)    | sdk/export, propagation  | `src/sdk/export.zig:121,267,303,363,528 +8`; `propagation/composite.zig:29-37` | <https://gitlab.com/devnw/zig/otel/-/work_items/154>          | Open   |
| OTEL-Q-005      | Medium   | 60    | maintainability | Replace `applyEnvFromMap` if-chain with comptime `env_table`          | sdk/config               | `src/sdk/config.zig:328-392`                          | <https://gitlab.com/devnw/zig/otel/-/work_items/156>          | Open   |
| OTEL-Q-NEW-B    | Medium   | 60    | maintainability | Move `encode*Proto/Json` to shared `exporters/otlp_codec.zig`         | exporters                | `src/exporters/otlp_grpc.zig:122`                     | <https://gitlab.com/devnw/zig/otel/-/work_items/164>          | Open   |
| OTEL-Q-006      | Medium   | 55    | readability     | Hoist `last_response_body[1024]` magic size to named const            | exporters                | `src/exporters/otlp_http.zig:45`                      | <https://gitlab.com/devnw/zig/otel/-/work_items/157>          | Open   |
| OTEL-Q-007      | Medium   | 55    | docs            | Add public-API doc comments (api/metrics + `propagation/*` + `internal/*`) | api + propagation + internal | `src/api/metrics.zig` + `src/propagation/*` + `src/internal/*` | <https://gitlab.com/devnw/zig/otel/-/work_items/19> (existing H8 — note added) | Open |
| OTEL-Q-NEW-C    | Medium   | 55    | maintainability | HTTP retry classifier missing 408/425; extract `retryClassifyHttp`    | exporters                | `src/exporters/otlp_http.zig:296-321`                 | <https://gitlab.com/devnw/zig/otel/-/work_items/53> (existing M6 — note added) | Open |
| OTEL-Q-008      | Medium   | 50    | maintainability | Split `validateEndpoint` into focused validators                       | sdk/config               | `src/sdk/config.zig:95-161`                           | <https://gitlab.com/devnw/zig/otel/-/work_items/158>          | Open   |
| OTEL-Q-009      | Medium   | 45    | maintainability | Collapse `setOwned*` helpers to a single comptime helper               | sdk/config               | `src/sdk/config.zig:260-279`                          | <https://gitlab.com/devnw/zig/otel/-/work_items/159>          | Open   |
| OTEL-Q-010      | Medium   | 45    | architecture    | Centralize feature flags in `feature_matrix.zig` + `docs/FEATURES.md` | build + sdk              | `build.zig` + 13 `build_options.*` fan-out             | <https://gitlab.com/devnw/zig/otel/-/work_items/161>          | Open   |
| OTEL-Q-NEW-D    | Low      | 30    | cleanup         | Promote duplicated shutdown timeout to `default_shutdown_timeout_ms`   | sdk/export               | `src/sdk/export.zig:303` + sibling                    | <https://gitlab.com/devnw/zig/otel/-/work_items/165>          | Open   |
| OTEL-Q-NEW-E    | Low      | 25    | maintainability | propagation breadcrumb (folded under OTEL-Q-004)                       | propagation              | `src/propagation/composite.zig:29-37`                  | (folded into OTEL-Q-004 #154)                                  | Open   |
| OTEL-Q-011..016 | Low      | ≤25   | (mixed)         | Lower-priority items deferred (no individual issues yet)              | various                  | see Phase-3 review                                    | n/a (catalogued)                                               | Deferred |

> **Sequencing (2026-04-27 re-review):**
>
> 1. **Tier-A (Score ≥ 78)**: OTEL-Q-001 → OTEL-Q-NEW-A → OTEL-Q-002 → OTEL-Q-003. These four are all in the exporter critical path; sequencing is mechanical because OTEL-Q-001 (split) enables OTEL-Q-002 (extract), which enables OTEL-Q-003 (logs export), and OTEL-Q-NEW-A (tagged-union Transport) is best landed inside the OTEL-Q-002 extraction PR.
> 2. **Tier-B (Score 50-70)**: OTEL-Q-004 (breadcrumbs), OTEL-Q-005 (env_table) and OTEL-Q-NEW-B (shared codec) — independent tracks, run in parallel.
> 3. **Tier-C (Score ≤ 50)**: OTEL-Q-006/008/009/010 + OTEL-Q-NEW-D — warm-up commits and central refactors; pair with Tier-B tracks where the surfaces overlap (e.g. OTEL-Q-009 lands cleanly with #34 M9).

## Findings by Category

### api-contract (8)

H7 (#11), C3 (#12), C2 (#13), H1 (#14), M9 (#34), M5 (#38), M7 (#57),
M1 (#58), L3 (#107), M10 (#103) — 9 if you count M10's parser
contract.

### maintainability (7)

H2 (#16), H3 (#39), M6 (#53), H4 (#62), L8 (#65), L2 (#105), L4 (#106).

### tests (3)

H6 (#37), M4 (#55), M8 (#102).

### docs (3)

H8 (#19), L1 (#108), L6 (#110).

### cleanup (5)

M2 (#104), L5 (#109), and bundle #68 (M3 + L7 + L10).

### ci-cd (1)

C1+H5 bundle (#20).

### architecture (1)

C2 (#13).

### readability (1)

L9 (#111).

## Roadmap

### Phase-3 deep re-review (2026-04-27) overlay

The 2026-04-27 re-review uses a different scoring formula
(Impact*Likelihood*4) so its tier breaks differ from the legacy roadmap.
Combined sequencing recommendation:

1. Land **OTEL-Q-001/002/NEW-A** as one PR family (exporter file-split + exportSignal helper + tagged-union Transport) — unblocks **OTEL-Q-003** (OTLP logs export) and **OTEL-Q-NEW-B** (shared codec module).
2. Land **OTEL-Q-004** (breadcrumb logger) before any other reliability work — gives operators visibility on the failure modes uncovered by the rest of this audit.
3. Land **OTEL-Q-NEW-C** (retry classifier 408/425) as part of the existing **#53 M6** PR — already commented there.
4. **OTEL-Q-007** (public-API docs) folds into existing **#19 H8** PR — already commented there.
5. Sequence Medium-tier config items (**OTEL-Q-005/008/009**) inside the same `sdk/config.zig` rewrite that closes **#34 M9** — single touchpoint, lower review cost.
6. **OTEL-Q-006/NEW-D** are warm-up commits — assign to first-time contributors.
7. **OTEL-Q-010** (feature_matrix + FEATURES.md) closes the README half of **DOC-2 #124** — schedule with the docs PR.

### Tier 1 — Score ≥ 24 (7 issues, top of the queue)

Sequence per Phase 3 recommendation: H7 → C3 → C2 → H1 → H2 → H8 → C1+H5.

- **#11** H7 (mechanical, blocks honest API contract — 1 file edit + 1 test)
- **#12** C3 (mechanical timer wiring + 1 test)
- **#13** C2 (design call: push or pull, then sweep — largest item)
- **#14** H1 (compression + TLS — gates dead-code cleanup #68)
- **#16** H2 (shared attribute formatter — bundles with H3 + L8)
- **#19** H8 (`///` doc sweep — runs in parallel with code work)
- **#20** C1+H5 (delete or rewrite the bench file + un-stub CI)

### Tier 2 — Score 12-18 (4 issues)

- **#34** M9 — memory-corruption bug; cross-linked with Security C-1; treat as Tier-1-immediate.
- **#37** H6 — restore gRPC loopback coverage.
- **#38** M5 — baggage threadlocal lifetime trap.
- **#39** H3 — exporter shim duplication (PR with H2).

### Tier 3 — Score 6-8 (7 issues, plus #68 bundle)

Cluster the dead-code cleanup (#68: M3 + L7 + L10) once H1 (#14) and
C2 (#13) lock their design decisions. Land M1 (#58) alongside H2's
attribute formatter — both touch the same JSON / proto codec entry
points.

- **#53** M6, **#55** M4, **#57** M7, **#58** M1, **#62** H4, **#65** L8, **#68** dead-code bundle.

### Tier 4 — Score ≤ 4 (8 issues, warm-up commits)

Schedule when contributors need entry-point work. **#111 L9** is the
cheapest finding in the entire scan (4-line patch) — ideal first PR.

- **#102** M8, **#103** M10, **#104** M2, **#105** L2, **#106** L4, **#107** L3, **#108** L1, **#109** L5, **#110** L6, **#111** L9.

## Cross-References with Other Audits

- **Security C-1** (confidential) ↔ Quality M9 (#34) — same defect; close together.
- **Security C-2** (gRPC TLS knob missing) ↔ Quality H4 (#62) — same parsing path.
- **Security C-3** (`OtlpConfig.headers` dropped on gRPC) ↔ Quality H6 (#37) — same exporter.
- **Security H-1** (CRLF / control-byte injection) ↔ Quality H1 (#14) — header validation must precede compression.
- **Security H-6** ("Secret redaction" README claim) ↔ Quality M1 (#58) — same redaction wiring.

## Methodology Notes

- All `confidence::confirmed` findings were re-verified via direct
  code read against the cited file and any callers identified by `rg`.
  No findings downgraded.
- L4 remains `confidence::suspected` pending the FailingAllocator
  sweep promised under M8 (#102).
- M9 is the only confirmed memory-corruption finding; flagged for
  Tier-2-immediate attention despite Medium severity. The Phase 3
  reviewer notes: "every config field except the last one read points
  at corrupt memory once a second env-var read happens. The fact that
  tests don't catch it is itself the bug."
