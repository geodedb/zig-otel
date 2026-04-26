# Quality Gap Analysis

Last updated: 2026-04-26

This document tracks the codepros Phase-3 quality findings, their
PriorityScore, GitLab issue links, and current remediation status.
Source: `docs/audit/QUALITY_REVIEW.md` (Phase 3) re-scoring
`docs/audit/QUALITY_SCAN.md` (Phase 2).

PriorityScore = `SeverityWeight × BlastRadius × FixConfidence`
(weights: Critical=8, High=4, Medium=2, Low=1; Blast 1-3; FixConf 1-3).

## Summary

**Total findings:** 31. **Filed issues:** 24 (3 findings folded into the
dead-code cleanup bundle: M3, L7, L10).

| Severity | Count |
|----------|-------|
| Critical | 3     |
| High     | 8     |
| Medium   | 10    |
| Low      | 10    |

**Top 5 risks (by PriorityScore):**

1. **H7** — `Span.recordException` swallows allocation failures (`!void` lies). Score 36.
2. **C3** — `BatchSpanProcessorOptions.schedule_delay_ms` silently ignored; low-volume telemetry stalls. Score 32.
3. **C2** — Metric export pipeline half-built; `MetricReader.collect` never invoked. Score 24.
4. **H1** — `OtlpConfig.compression` / `skip_tls_verify` / `insecure` are dead config fields. Score 24.
5. **H2** — 4-way attribute formatter duplication; arrays silently dropped. Score 24.

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
