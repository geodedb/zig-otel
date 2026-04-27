# Full Codebase Audit Summary — 2026-04-27

## Repository

- **Project:** devnw/zig/otel (Zig 0.16 OpenTelemetry SDK)
- **Platform:** GitLab (`gitlab.com/devnw/zig/otel`)
- **Languages:** Zig 0.16.0
- **Scope:** entire repo
- **Toolchain:** zig fmt + zig build check + zig build test (gitleaks 8.21.2, semgrep 1.161.0)
- **CI baseline:** `make ci` green (91 pass / 20 skip / 0 fail; fmt+check clean)

## Domain Results

### Gap Analysis

| Status | Count | Percentage |
|---|---:|---:|
| Implemented (tracker-stale) | 5 | 5% |
| Partial | 18 | 17% |
| Not Implemented | 73 | 67% |
| Unknown | 12 | 11% |

**Open gaps post-sync:** 52 — Critical: 3, High: 11, Medium: 18, Low: 20.

### Code Quality

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 3 |
| Medium | 9 |
| Low | 6 |

**Top finding:** `OTEL-Q-001` split `src/exporters/otlp_http.zig` (1407 LOC, triple-encoder family) — **PriorityScore 85**.

### Performance

| PerfSeverity | Count |
|---|---:|
| P0 | 3 |
| P1 | 7 |
| P2 | 4 |
| P3 | 2 |

**Top finding:** `PR-1` MeterProvider.pointFor concurrency race (`src/sdk/metrics.zig:268-304,591-649`) — **PerfScore 92** (correctness + perf P0).

### Security

| Risk Level | Count |
|---|---:|
| Critical | 0 |
| High | 1 |
| Medium | 4 |
| Low | 5 |
| Info | 4 |

**Top finding:** `NEW-H-1` proto/semconv manifests hash only LICENSE files — provenance gate is structurally toothless (CWE-345). Filed **confidential** as #134.

**Immediate operator actions:** 1 — H-7 token rotation deadline 2026-05-03 (6 days).

## Cross-Domain Summary

| Domain | Findings | Issues Created | Issues Updated | Issues Closed |
|---|---:|---:|---:|---:|
| Gap Analysis | 105 (catalogued) | 1 | 0 | 3 |
| Quality | 18 | 12 | 2 | 0 |
| Performance | 16 | 13 (incl. 2 tracking) | 2 | 5 |
| Security | 14 | 9 (3 confidential) | 0 | 9¹ |
| **Total** | **153** | **35** | **4** | **17** |

¹ Security closures are evidence-confirmation comments on already-closed items (H-1/H-3/H-4/H-5/M-1/M-5/C-2/C-3/H-6).

## Docs Updated

| File | Domain | Action |
|---|---|---|
| `docs/GAP_ANALYSIS.md` | Gap | rewritten — 33 open gaps, deltas applied |
| `docs/GAP_ANALYSIS_RESOLVED.md` | Gap | appended — 3 tracker-stale closures (Phase 4) |
| `docs/QUALITY_GAP_ANALYSIS.md` | Quality | 267 lines (+61) — Phase 3 ranked table + roadmap |
| `docs/PERF_GAP_ANALYSIS.md` | Performance | 270 lines (+62) — PR-1..PR-13 + closures + by-area |
| `docs/SECURITY_GAP_ANALYSIS.md` | Security | 262 lines (+40) — §6.2 re-audit + closure confirmations |
| `docs/audit/AUDIT_SUMMARY_2026-04-27.md` | Unified | this file |

Per-phase artifacts:

- `docs/audit/gap-collector/{ORIENTATION.md,catalog.json,catalog.csv}`
- `docs/audit/gap-scanner/SCAN_RESULTS.md`
- `docs/audit/gap-detector/{REGISTRY.md,SYNC_PLAN.md}`
- `/tmp/otel-{fmt,check,test}.log`, `/tmp/otel-fns.txt`, `/tmp/otel-quality-summary.txt`
- `/tmp/perf-scan/{allocs,exporter_allocs,concurrency,loops,deep_review}.txt`
- `/tmp/gitleaks.json`, `/tmp/semgrep.json`, `/tmp/grep-audit-{1..7}.txt`

## Top 10 Findings (cross-domain, by severity then score)

| # | Domain | ID | Finding | Severity | Score | File:Line |
|---|---|---|---|---|---|---|
| 1 | Perf+Correctness | **PR-1** (#135) | MeterProvider.pointFor concurrent record/collect race (torn ArrayList, dangling pointers after grow) | P0 | 92 | src/sdk/metrics.zig:268-304,591-649 |
| 2 | Perf | **PR-2** (#36) | `commitSubMessage` `copyForwards` quadratic shifts on nested OTLP encode | P0 | 88 | src/generated/otlp.zig:142-169 |
| 3 | Security | **NEW-H-1** (#134🔒) | proto/semconv manifests hash only LICENSE — provenance gate is decorative (CWE-345) | High | 7.5 | docs/proto-manifest.txt:4 |
| 4 | Quality | **OTEL-Q-001** (#149) | otlp_http.zig 1407 LOC, triple-encoder family — split by signal/encoder | High | 85 | src/exporters/otlp_http.zig |
| 5 | Quality | **OTEL-Q-NEW-A** (#163) | Fragile fn-pointer-identity dispatch sentinel (LTO/inline-fragile) | High | 82 | otlp_http.zig:303-306,372-375 |
| 6 | Perf | ~~**PR-7** (#146)~~ | ~~Prometheus per-bucket label re-sort (16× cost on default histograms)~~ — **closed 2026-04-27 (Won't Do — closed-by-other: P0-1 #5)**: re-investigation confirmed no sort call exists in `src/exporters/prometheus.zig`; insertion-order stability is guaranteed by `AttributeSet` (`src/internal/attributes.zig:31-44`). | P1 | 82 | src/exporters/prometheus.zig:67-77,159-189 |
| 7 | Quality | **OTEL-Q-002** (#150) | Extract `exportSignal` helper — `expSpans`/`expMetrics` byte-identical retry loops | High | 80 | otlp_http.zig:277-322 vs 348-392 |
| 8 | Perf+Correctness | **PR-3** (#136) | OTLP trace encoder uses `items[0].instrumentation_scope` only — multi-tracer batches mislabeled | P0 | 78 | otlp_http.zig:1055-1093 |
| 9 | Quality | **OTEL-Q-003** (#152) | OTLP log export missing — SimpleLogProcessor exists, no expLogs/encodeLogs | High | 78 | src/sdk/logs.zig:43 |
| 10 | Perf | **PR-4** (#47) | new `std.http.Client` per export — TCP/TLS handshake every BSP drain | P1 | 76 | otlp_http.zig:243 |

(🔒 = filed confidential)

## High-Impact Items Closed Today

| Domain | Item | Evidence |
|---|---|---|
| Gap | #1 Instrumentation scope propagation | src/sdk/trace.zig:289-296 + test/trace.zig:57,83-87 |
| Gap | #3 OTLP wire instrumentation scope | src/exporters/otlp_http.zig:1057-1058 |
| Gap | #31 Redact wired across exporters | otlp_http.zig:644,873,1108,1386 + prometheus.zig:201 + json_codec.zig:173 |
| Perf | #5 P0-1 AttributeSet dedup-before-dup (~11×) | src/internal/attributes.zig:147-150 |
| Perf | #6 P0-2 SpanState pool (~1.97×) | src/sdk/span_pool.zig + src/api/trace.zig:157-194 |
| Perf | #15 P0-4 pointFor 3→0 allocs | src/sdk/metrics.zig:271 |
| Perf | #122 P-N1 retry sleep (HTTP) | src/sdk/export.zig:673-680 |
| Perf | #126 P-N2 retry sleep (gRPC) | src/sdk/export.zig:678 |

## Operator-Pending Follow-Ups

1. **H-7 (#80, confidential)** — rotate `OTEL_INTEGRATION_AUTH_HEADER` by **2026-05-03** (6 days remaining); run `scripts/audit_ci_logs.sh` against last 90 days **before** rotation invalidates the token. Owner: <benji@codepros.org>.
2. **NEW-M-2 (#140, confidential)** — verify Zig 0.16 `std/fs/Dir.createFile` default `O_NOFOLLOW`; downgrade to Info if already nofollow, otherwise patch.
3. **M-3 (#84)** — DevNW upstream Sigstore/cosign signing (deferred to upstream).
4. **BENCH-BASELINES-MISSING (#166)** — capture A/B baselines for P0-3, P0-5, P0-7, P0-8, P-N3..N7, P1-1..P1-13.
5. **PERF-SLO-DEFINE (#167)** — set service-level p99 export latency / RPS / allocation-HWM SLO.
6. **CI dark spots** — re-enable zig-fuzz + Windows tests after upstream Zig 0.16 fix; flip benchmark-regression `allow_failure: false` after baselines land.
7. **Tracker drift (informational)** — #7 (GAP-OTLP-METRIC-EXPORT) and #101 (GAP-DEPRECATED-SPAN-EVENTS-FLAG) are tracked-open but resolved-doc; reconcile next sync.

## Blockers Encountered

- **No SBOM/CVE scanner installed locally** (osv-scanner / trivy / grype / syft / snyk) — security scan ran gitleaks + semgrep only. CI pipeline still has osv-scanner; locally untested.
- **Semgrep `--config auto` blocked by telemetry policy** — ran reduced ruleset (p/security-audit + p/secrets + p/owasp-top-ten, 65 rules).
- **No Zig linter beyond fmt+check** — duplication/complexity/dead-code findings rely on manual review and grep audits.
- **No coverage instrumentation** wired into build.zig or CI; coverage gates cannot be enforced.
- **Fuzz job + Windows test jobs** suppressed in CI (`when: never`) due to upstream Zig 0.16 bugs — fuzzing and cross-OS signal currently dark.

## Phase Verdicts

| Phase | Status | Notes |
|---|---|---|
| 1 — Orientation | OK | All 4 agents completed; auth healthy; bench harness mapped; threat model surfaced 8 abuse cases. |
| 2 — Scanning | OK | Build/check/test green; gitleaks 0 leaks / 81 commits; semgrep 0 findings / 65 rules. |
| 3 — Deep Analysis | OK | 1 P0 correctness defect (PR-3 trace encoder), 1 P0 race (PR-1), 1 High supply-chain (NEW-H-1) discovered. |
| 4 — Tracking | OK | 35 issues created (3 confidential), 4 updated, 17 closed; 5 docs updated. |
| 5 — Unified summary | OK (this file) | |

## Net Tracker Movement

- Before run: 108 open / 24 closed (132 total)
- After run: ~141 open / 41 closed (~178 total) — net +33 created, +17 closed.

## Gap Closures — 2026-04-27

Five-PR closure run executed end-to-end against `main` after the audit landed. Plan: `docs/audit/gap-closure/PLAN_2026-04-27.md`. Completion report: `docs/audit/gap-closure/COMPLETION_REPORT_2026-04-27.md`.

| Order | Gap | Issue | Commit | Domain | File evidence (primary) | New tests |
|------:|-----|------:|--------|--------|-------------------------|-----------|
| 1 | PR-1 — `MeterProvider.pointFor` race | [#135](https://gitlab.com/devnw/zig/otel/-/work_items/135) | `177708f` | Performance | `src/sdk/metrics.zig:90-95,305-360,644-790` + `freeSnapshot` | `test/metrics_concurrency.zig` (3) |
| 2 | PR-2 — two-pass OTLP encoder | [#36](https://gitlab.com/devnw/zig/otel/-/work_items/36) | `a8cce5b` | Performance | `src/generated/otlp.zig` (deferred-compaction `Writer.toOwnedSlice`) | 6 inline + 3 `bench-micro` scenarios (`micro_encode_spans_proto_{64,512,4096}`) |
| 3 | PR-3 — multi-scope trace encoder | [#136](https://gitlab.com/devnw/zig/otel/-/work_items/136) | `a092ca4` | Performance / Correctness | `src/exporters/otlp_http/encode_proto.zig:216` (`groupSpansByScope`) | `test/otlp_spans_multi_scope.zig` (5) |
| 4a | OTEL-Q-001 — split `otlp_http.zig` | [#149](https://gitlab.com/devnw/zig/otel/-/work_items/149) | `6f11474` | Quality | `src/exporters/otlp_http/{spans,metrics,headers,exporter,transport,encode_proto,encode_proto_devnw,encode_json}.zig` | refactor-only (existing suites preserved) |
| 4b | OTEL-Q-NEW-A — tagged-union Transport | [#163](https://gitlab.com/devnw/zig/otel/-/work_items/163) | `6f11474` | Quality | `src/exporters/otlp_http/transport.zig:57` (`Transport` union) | covered by existing OTLP suite |
| 5 | NEW-H-1 — proto/semconv manifest | [#134](https://gitlab.com/devnw/zig/otel/-/work_items/134) (CONFIDENTIAL) | `1e01147` | Security | `tools/manifest.zig` + `docs/{proto,semconv}-manifest.txt` + `third_party/*` (15 proto + 240 semconv files) | `test/manifest_provenance.zig` (5) |

**Verifier verdict:** ALL PASS. `zig build test --summary all` → **109/21/0** default, **114/16/0** with DevNW codecs. Zero regressions.

**Out of this run (operator follow-ups):** H-7 (#80), NEW-M-2 (#140), BENCH-BASELINES-MISSING (#166), PERF-SLO-DEFINE (#167) — all carry separate workflows and SLAs.

## Follow-ups Closed — 2026-04-27

Five deferred follow-up items from the §"Operator-Pending Follow-Ups" list above were addressed in a second close-out pass on the same day. Plan: `docs/audit/gap-closure/PLAN_2026-04-27_FOLLOWUPS.md`. Completion report: `docs/audit/gap-closure/COMPLETION_REPORT_2026-04-27_FOLLOWUPS.md`. Verifier verdict: ALL PASS (`zig build test --summary all` → **112/21/0** default, **117/16/0** with DevNW codecs; zero regressions).

| # | Gap | Issue | Commit | Status | Domain | Evidence |
|--:|-----|------:|--------|--------|--------|----------|
| 1 | M-3 — DevNW upstream Sigstore/cosign signing | [#84](https://gitlab.com/devnw/zig/otel/-/work_items/84) | `914579e` | Won't Do (this repo) | Security / Supply chain | `docs/SECURITY_GAP_ANALYSIS.md:115` row 13; reclassified from Partial → Won't Do — signing infra is owned by DevNW shared CI (tracked OOB at `gitlab.com/devnw/meta`); consumer-side mitigations (SHA pinning + osv-scanner CI gate) remain in place. |
| 2 | NEW-M-2 — File JSONL exporter follows symlinks | [#140](https://gitlab.com/devnw/zig/otel/-/work_items/140) (CONFIDENTIAL) | `d8dd8a5` | Closed | Security | `src/exporters/file.zig:50-69` — open path now uses `Dir.openFile(.{ .follow_symlinks = false })` first, falling through to `Dir.createFile(.{ .exclusive = true })` (`O_NOFOLLOW` + `O_CREAT \| O_EXCL`) on `error.FileNotFound`; TOCTOU window closed at the kernel level. Regression tests: `test/file_exporter_symlink.zig` (3 tests). |
| 3 | H-7 — CI bearer-token rotation | [#80](https://gitlab.com/devnw/zig/otel/-/work_items/80) (CONFIDENTIAL) | `b3301e7` | **Blocked (operator-pending)** — issue stays OPEN | Security / Operations | `scripts/audit_ci_logs.sh` smoke-checked (`--help` exit 0, bad-flag exit 2, syntax clean); evidence captured in `docs/audit/h7-audit-evidence-2026-04-27.txt`. Runbook `docs/runbooks/h7-token-rotation.md` hardened with a prominent "audit BEFORE rotate" warning + project URL + `glab auth login` pre-flight. 5-step operator checklist in `SECURITY_GAP_ANALYSIS.md` §2.1. Deadline **2026-05-03**. Owner `<benji@codepros.org>`. |
| 4 | PERF-SLO-DEFINE — service-level performance SLOs | [#167](https://gitlab.com/devnw/zig/otel/-/work_items/167) | `e82205d` | Closed | Performance | `docs/performance/SLO.md` (~290 lines) defines 4 hard-criterion rules; `benchmarks/check_hard_criteria.zig` extended with Rule 3 (`micro_attr_put_update` p99 ≤ 50 ns/op, 1.6× headroom over the 31.92 ns/op floor) and Rule 4 (`micro_counter_add_4_attrs_hit` allocs/op ≤ 0.005, 3.3× headroom over the 0.0015 allocs/op floor); `make slo-check` wired into `make ci`. |
| 5 | BENCH-BASELINES-MISSING — captured + enumerate deferred probes | [#166](https://gitlab.com/devnw/zig/otel/-/work_items/166) | `94866d2` | **Partial** — issue stays OPEN with reduced scope | Performance | `docs/performance/2026-04-27-pr-2-encoder/{results.md,results/baseline.json,results/latest.json}` frozen ReleaseFast snapshot for `micro_encode_spans_proto_{64,512,4096}`. Combined with 2026-04-26 P0-1 / P0-2 / P0-4 + zero-overhead-when-disabled dirs, every micro-scenario in `benchmarks/micro/main.zig` is covered. Remaining 18 deferred probes + 2 won't-do rows enumerated in `docs/PERF_GAP_ANALYSIS.md` §"Deferred bench probes" with a 5-step unblock recipe per row. |

**Issues closed on tracker:** 3 (#84, #140, #167).
**Issues kept open with status comment:** 2 (#80 — Blocked operator-pending, #166 — Partial / reduced scope).
**Net session estimate vs actual:** ~2.5 hours predicted; landed 5 commits (`914579e..94866d2`) on `main` (not yet pushed at hand-off).

**Doc reconciliation in this pass:** corrected `docs/PERF_GAP_ANALYSIS.md:99` and `CHANGELOG.md` to read "18 deferred + 2 won't-do" (was "14 untracked gaps"); the deferred-probes table itself was always 18 rows. Plan-time wording in `docs/audit/gap-closure/PLAN_2026-04-27_FOLLOWUPS.md` left as historical artefact.

## Top-Queue Day-1 Closures — 2026-04-27

Eight-item Day-1 batch from the 22-item Critical+High top-queue sweep landed against `main` in the same calendar day. Plan: `docs/audit/gap-closure/PLAN_2026-04-27_TOP_QUEUE.md`. Completion report: `docs/audit/gap-closure/COMPLETION_REPORT_2026-04-27_TOP_QUEUE.md`. Verifier verdict: **ALL PASS — `zig build test --summary all` → 132/25/0 default, 141/16/0 with DevNW codecs; zero regressions.**

| # | Gap | Issue | Commit | Status | Domain | Evidence (file:line + tests) |
|--:|-----|------:|--------|--------|--------|------------------------------|
| 1 | GAP-OTLP-METRIC-EXPORT (tracker drift) | [#7](https://gitlab.com/devnw/zig/otel/-/issues/7) | (already shipped `ac68bff`) | Closed | Functional / Exporters | `src/exporters/otlp_http/metrics.zig:39` `metric_path = "/v1/metrics"`; `src/exporters/otlp_grpc.zig:99` `metrics_export_method = "MetricsService/Export"`; `test/otlp_metrics.zig` (8) + `test/remote_otlp.zig` live test |
| 2 | GAP-DEPRECATED-SPAN-EVENTS-FLAG (docs-only) | [#101](https://gitlab.com/devnw/zig/otel/-/issues/101) | (Phase 3 classification, no code) | Closed | Quality / Docs | `src/api/trace.zig:215-218` — by-design build gate per spec deprecation |
| 3 | PR-8 — single `clock.now()` per metric record | [#141](https://gitlab.com/devnw/zig/otel/-/issues/141) | `b934ac3` | Closed | Performance (P1) | `src/sdk/metrics.zig:517,531,554,565,579,601,615,626`; SLO gate Rule 3 p99=28.97 ns/op, Rule 4 allocs/op=0.00150 |
| 4 | PR-9 — cache parsed gRPC endpoint at init | [#143](https://gitlab.com/devnw/zig/otel/-/issues/143) | `0f9de4f` | Closed | Performance (P1) | `src/exporters/otlp_grpc.zig` (`parsed_endpoint` cached at init); `test/otlp_grpc_endpoint_cache.zig` (5 tests) |
| 5 | PR-10 — `toOwnedSlice` replaces redundant `arena.dupe` | [#144](https://gitlab.com/devnw/zig/otel/-/issues/144) | `8bc8a09` | Closed | Performance (P1) | `src/internal/json_codec.zig:50,75,100`; wire-parity tests byte-identical |
| 6 | GAP-ENV-BSP — parse `OTEL_BSP_*` env vars | [#33](https://gitlab.com/devnw/zig/otel/-/issues/33) | `9539b8b` | Closed | Functional / SDK | `src/sdk/config.zig:193-198,415-422`; `src/sdk/export.zig:146-149`; `src/sdk/trace.zig:121-124,212`; 4 new `test/config.zig` cases |
| 7 | GAP-ENV-METRIC-INTERVAL — parse `OTEL_METRIC_EXPORT_INTERVAL/_TIMEOUT` | [#35](https://gitlab.com/devnw/zig/otel/-/issues/35) | `636d9e9` | Closed | Functional / SDK | `src/sdk/config.zig:209-212,231,445-446`; 3 new `test/config.zig` cases. Reader runtime wiring deferred to #29 |
| 8 | GAP-OTLP-WIRE-SCHEMA-URL — emit `Resource.schema_url` | [#26](https://gitlab.com/devnw/zig/otel/-/issues/26) | `d1d3bd7` | Closed | Functional / Exporters | `src/exporters/otlp_http/encode_proto.zig:333-342` (ResourceSpans field 3) + `:106-113` (ResourceMetrics field 3); DevNW path `:160-172,201-205`; `test/otlp_resource_schema_url.zig` (5 tests). Logs path deferred to #8 |
| 9 | GAP-OTLP-WIRE-EVENTS-LINKS — emit `Span.events`/`Span.links` | [#9](https://gitlab.com/devnw/zig/otel/-/issues/9) | `87875d1` | Closed | Functional / Exporters (Critical) | `src/exporters/otlp_http/encode_proto.zig:281-291,310-323,332-344`; DevNW path `:124-156,173-191,312-340`; `test/otlp_span_events_links.zig` (7 tests) |
| 10 | GAP-OTLP-PROFILES-EXPORT | [#25](https://gitlab.com/devnw/zig/otel/-/issues/25) | `c116d3e` | **Won't Do** | Functional / Exporters | Upstream proto under `/v1development/`; README + SPEC_COMPLIANCE flipped to NOT IMPLEMENTED; inert `error.UnsupportedTransport` stub preserved as forward-compat insurance. Re-open trigger: upstream `/v1/` promotion |
| 11 | GAP-GRPC-STATUS-PROPAGATION | [#32](https://gitlab.com/devnw/zig/otel/-/issues/32) | `9eaeec2` (docs flip only) | **Blocked (upstream)** — issue stays OPEN | Functional / Exporters | Pinned `grpc_zig.client.call(...) ![]u8` returns only response bytes; trailers (`grpc-status`, `grpc-message`, `Retry-After`) not surfaced. Source: `zig-pkg/grpc_zig-…/src/client.zig:43-64` + consumer-side `src/exporters/otlp_grpc.zig:291-295`. **Unblock runbook:** `docs/runbooks/upstream-asks.md` § ASK-GRPC-ZIG-TRAILERS (6-step checklist) |

**Issues closed on tracker:** 9 (#7, #9, #25, #26, #33, #35, #101, #141, #143, #144 — note #7 and #101 were already closed as tracker drift).
**Issues kept open with status comment:** 1 (#32 — Blocked-upstream).
**Commits on `main` this run:** 9 (`b934ac3..9eaeec2`), not yet pushed at hand-off.
**Net Day-1 capacity vs plan:** 8 Day-1 items planned (per `PLAN_2026-04-27_TOP_QUEUE.md` §3) + 2 carried tracker-drift = 10 items addressed; only #32 left in Blocked-upstream state.
