# Full Codebase Audit Summary

**Date:** 2026-04-26
**Audit invocation:** `/codepros:audit`
**Scope:** entire repository
**Pipeline:** 4 domains × 4 phases (orientation → scan → review → tracking) → unified summary

## Repository

- **Project:** otel-zig (OpenTelemetry SDK for Zig)
- **Platform:** GitLab — `gitlab.com/devnw/zig/otel` (public)
- **Languages:** Zig 0.16.0 (single-language)
- **Specs targeted:** OTel 1.56.0, OTLP 1.10.0, SemConv 1.40.0, Declarative Config 1.0.0
- **Sources:** 36 files / ~7,080 LOC (`src/`), 16 test files / ~1,309 LOC / 112 tests (`test/`, embedded)
- **Build:** `zig build` matrix Linux/macOS; Windows zeroed; `pre-commit` + GitLab CI catalog components

## Domain Results

### Gap Analysis (37 Gap-IDs)

| Status | Count | Pct |
|---|---:|---:|
| Implemented | 1 | 3% |
| Partial | 6 | 16% |
| Not Implemented | 30 | 81% |
| Unknown | 0 | 0% |

| Severity | Count | Issues |
|---|---:|---|
| Critical | 6 | #1, #3, #4, #7, #8, #9 |
| High | 11 | #23–#27, #29–#33, #35 |
| Medium | 13 | #48–#52, #59–#60, #63–#64, #66, #76, #78–#79 |
| Low | 7 | #95–#101 |

**Open gaps:** 36 (1 resolved, note-only).
**Top blocker:** scope-propagation pair (`src/sdk/trace.zig:240`) — one-line fix closes #1 and #3.
**Hub gap:** `GAP-EXPORTER-FACTORY` (#4) gates the entire per-signal env-var family.

### Code Quality (24 issues)

| Severity | Count |
|---|---:|
| Critical | 3 |
| High | 8 |
| Medium | 10 |
| Low | 10 |

**PriorityScore top finding:** H7 — `Span.recordException` swallows allocation failures (`src/api/trace.zig:194-207`) — score 36 (#11).
**Notable promotion:** M9 — `applyEnv` thread-local slice aliasing (`src/sdk/config.zig:122-217`) — only confirmed memory-corruption bug; cross-references Security C-1 (#34).

### Performance (23 issues + 1 blocker)

| PerfSeverity | Count |
|---|---:|
| P0 | 9 |
| P1 | 13 |
| P2 | 11 (informational, not filed) |
| P3 | 5 (informational, not filed) |

**PerfScore top findings (5 tied at 72):**

1. P0-1 — `AttributeSet.put` O(n²) with arena dupe before dedup (`src/internal/attributes.zig:106-127`) (#5)
2. P0-2 — per-span `SpanState`+arena+`dupe(name)` allocation churn (`src/api/trace.zig:103-118`) (#6)
3. P0-4 — `MeterProvider.pointFor` 3–7 allocs per record (`src/sdk/metrics.zig:254-285`) (#15)
4. P0-9 — `async_workers=0` default = inline export (`src/sdk/export.zig:147`) (#22)
5. P0-10 — `SimpleSpanProcessor` is the default = one HTTP per span (`src/sdk/trace.zig:172-178`) (#28)

**Hard blocker:** `benchmarks/bench.zig:55-71` calls non-existent `lib.init` and `benchmarks/micro/` is empty (#2). Until this lands, no A/B validation runs.

### Security (22 issues; 7 confidential)

| Risk Level | Count |
|---|---:|
| Critical | 3 |
| High | 7 |
| Medium | 8 |
| Low | 4 (L-1, L-3 deliberately skipped) |

**Top 5 by Risk Score:**

| ID | Risk | Title | Issue |
|---|---:|---|---|
| C-2 | 25 | gRPC strips `https://`, runs h2c — cleartext traces | #61 [CONF][IMM] |
| C-1 | 25 | Env-var slice aliasing leaks bearer tokens | #54 [CONF][IMM] |
| H-1 | 20 | CRLF injection in headers parser | #69 [CONF] |
| H-7 | 20 | Live integration test prints bearer/body in CI logs | #80 [CONF][IMM] |
| C-3 | 16 | gRPC silently drops `OtlpConfig.headers` | #67 [IMM] |

**Immediate operational actions (out-of-band, owner: <benji@codepros.org>):**

1. Rotate `OTEL_INTEGRATION_AUTH_HEADER` GitLab CI/CD variable.
2. Audit last 30 days of CI logs for bearer-token leakage (`Bearer eyJ`, `gitlab-o11y.com`).
3. Scrub `last_response_body` printer in `test/remote_otlp.zig:188-208` before next default-branch CI run.
4. Block next release on landing C-1, C-2, C-3, H-1, M-5.

## Cross-Domain Summary

| Domain | Findings | Issues Created | Issues Updated | Issues Closed |
|---|---:|---:|---:|---:|
| Gap Analysis | 37 | 37 | 0 | 0 |
| Quality | 31 | 24 (3 folded into bundle) | 0 | 0 |
| Performance | 39 (P0+P1=23) | 23 | 0 | 0 |
| Security | 25 | 22 (2 deliberately skipped) | 0 | 0 |
| **Total** | **132** | **106** | **0** | **0** |

## Docs Updated

| File | Domain | Action |
|---|---|---|
| `docs/audit/GAP_SCAN.md` | Gap | created (Phase 2) |
| `docs/audit/GAP_DETECTION.md` | Gap | created (Phase 3) |
| `docs/audit/QUALITY_SCAN.md` | Quality | created (Phase 2) |
| `docs/audit/QUALITY_REVIEW.md` | Quality | created (Phase 3) |
| `docs/audit/PERF_SCAN.md` | Perf | created (Phase 2) |
| `docs/audit/PERF_REVIEW.md` | Perf | created (Phase 3) |
| `docs/audit/SECURITY_SCAN.md` | Security | created (Phase 2) |
| `docs/audit/SECURITY_REVIEW.md` | Security | created (Phase 3) |
| `docs/GAP_ANALYSIS.md` | Gap | created (Phase 4) |
| `docs/GAP_ANALYSIS_RESOLVED.md` | Gap | created (Phase 4) |
| `docs/QUALITY_GAP_ANALYSIS.md` | Quality | created (Phase 4) |
| `docs/PERF_GAP_ANALYSIS.md` | Perf | created (Phase 4) |
| `docs/SECURITY_GAP_ANALYSIS.md` | Security | created (Phase 4) |
| `docs/audit/AUDIT_SUMMARY.md` | All | created (Phase 5, this file) |

## Top 10 Cross-Domain Findings

Ranked by user-visible blast radius and severity. Many findings are siblings — the same defect surfaces in multiple domains.

| # | Domain | Finding | Severity | Score | Issue |
|---|---|---|---|---:|---|
| 1 | Security | C-2: gRPC strips `https://`, runs h2c — cleartext traces | Critical | Risk 25 | #61 [CONF] |
| 2 | Security | C-1: Env-var slice aliasing leaks bearer tokens | Critical | Risk 25 | #54 [CONF] |
| 3 | Quality | M9 (= Security C-1): `applyEnv` thread-local aliasing memory bug | Medium | PriorityScore 18 | #34 |
| 4 | Security | H-1: CRLF injection in OTLP headers parser | High | Risk 20 | #69 [CONF] |
| 5 | Security | H-7: Live integration test exfiltrates bearer/body to CI logs | High | Risk 20 | #80 [CONF] |
| 6 | Gap | GAP-EXPORTER-FACTORY: hub gap blocking per-signal env-var family | Critical | — | #4 |
| 7 | Gap | INSTRUMENTATION-SCOPE-PROPAGATION: one-line bug at `src/sdk/trace.zig:240` blanks scope name on the wire | Critical | — | #1, #3 |
| 8 | Perf | P0-10: `SimpleSpanProcessor` is the default — one HTTP per span | P0 | PerfScore 72 | #28 |
| 9 | Perf | P0-1: `AttributeSet.put` O(n²) on the per-span hot path | P0 | PerfScore 72 | #5 |
| 10 | Quality | H7: `Span.recordException` swallows allocation failures | High | PriorityScore 36 | #11 |

## Cross-Domain Bridges

- **C-1 (Sec) ↔ M9 (Qual)** — same `applyEnv` defect, two views (memory + bearer leak).
- **C-3 (Sec) ↔ H6 (Qual)** — gRPC exporter ignores config; pairs with broken loopback test.
- **C-2 (Sec) ↔ H4 (Qual)** — TLS plumbing gap on both transports.
- **H-1 (Sec) ↔ H1 (Qual)** — header validation must precede compression.
- **H-6 (Sec) ↔ M1 (Qual)** — README markets redaction; module unwired.
- **P0-9 (Perf) ↔ C3 (Qual)** — `schedule_delay_ms` declared but never read; same fix.
- **P0-1 (Perf) ↔ M9/C-1** — fixing `AttributeSet` does NOT fix env aliasing; separate.
- **GAP-EXPORTER-FACTORY (Gap) ↔ 10 downstream gaps** — single hub.

## Blockers

- **Perf A/B validation blocked**: `benchmarks/bench.zig` calls non-existent `lib.init`; `benchmarks/micro/` is empty (#2). Must land before any P0/P1 fix can be verified.
- **Spec compliance blocked**: GAP-EXPORTER-FACTORY (#4) gates the per-signal env-var family — fixing per-signal env vars before the factory exists is wasted work.
- **Security release gate**: 5 issues block next release per Phase 3 review (C-1, C-2, C-3, H-1, M-5).

## Recommended Sequencing

Tier 1 — immediate (this week):

1. Operational rotation/scrub (4 actions above) — non-code.
2. `src/sdk/trace.zig:240` one-liner closing #1 + #3.
3. C-1 / M9 — `applyEnv` slice ownership rewrite (#54, #34).
4. C-2 / C-3 — gRPC TLS + headers plumbing (#61, #67).
5. H-1 — CRLF validation in OTLP header parser (#69).
6. H-7 — scrub the response-body printer + revisit CI body capture (#80).
7. M-5 — endpoint scheme/host validation, SSRF block (#86).

Tier 2 — next sprint:

1. `GAP-EXPORTER-FACTORY` (#4) → unblocks 10 follow-up gaps.
2. Bench harness fix + 13 micros (#2) → unblocks all perf A/B.
3. H7 quality fix (#11), C3 quality fix (#12).

Tier 3 — incremental:

- Per-signal env-var family (#23–#27, #66, #96).
- OTLP metric/log export (#7, #8) plus events/links/scope wire encoding (#9, #3).
- B3/Jaeger propagators.
- Top 5 perf P0s (#5, #6, #15, #22, #28).

Tier 4 — long tail:

- SemConv expansion, vendor third_party, observable instruments, declarative config depth.

## Methodology

- All findings backed by `file:line` evidence.
- Phase 3 reviewers re-read source — zero downgrades, three findings flagged Suspected and filed for runtime confirmation.
- 7 security findings filed `--confidential`; 15 public; 2 deliberately skipped (false-positive + note-only).
- Cross-domain bridges recorded in issue bodies and sibling gap-analysis docs.

## Sub-Agent Outputs

| Agent | Phase | Doc |
|---|---|---|
| gap-collector | 1 | (orientation memo, summarized in Phase-1 output) |
| quality-inventory | 1 | (orientation memo) |
| perf-context | 1 | (orientation memo) |
| security-inventory | 1 | (orientation memo) |
| gap-scanner | 2 | `docs/audit/GAP_SCAN.md` |
| quality-scanner | 2 | `docs/audit/QUALITY_SCAN.md` |
| perf-scanner | 2 | `docs/audit/PERF_SCAN.md` |
| security-scanner | 2 | `docs/audit/SECURITY_SCAN.md` |
| gap-detector | 3 | `docs/audit/GAP_DETECTION.md` |
| quality-reviewer | 3 | `docs/audit/QUALITY_REVIEW.md` |
| perf-reviewer | 3 | `docs/audit/PERF_REVIEW.md` |
| security-reviewer | 3 | `docs/audit/SECURITY_REVIEW.md` |
| gap-sync | 4 | `docs/GAP_ANALYSIS.md`, `docs/GAP_ANALYSIS_RESOLVED.md` |
| quality-issue-tracker | 4 | `docs/QUALITY_GAP_ANALYSIS.md` |
| perf-issue-tracker | 4 | `docs/PERF_GAP_ANALYSIS.md` |
| security-issue-tracker | 4 | `docs/SECURITY_GAP_ANALYSIS.md` |
