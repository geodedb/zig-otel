# Gap Analysis -- Resolved

> Resolved or invalidated gaps. Source: GitLab issue tracker at <https://gitlab.com/devnw/zig/otel/-/issues>.
>
> **Last sync:** 2026-04-26 (PM re-audit Phase 4 gap-sync) — adds GAP-BENCH-NOT-WIRED to the functional-closure ledger.

---

## Security (closed 2026-04-26)

The 16-commit security closure run (`d19b65b..cd9f906`) closed 20 gaps fully and 2 gaps on the code side. Verification report: `docs/audit/SECURITY_VERIFY.md` (Step 3 — GREEN; 78/88 tests pass, 10 skipped, 0 fail). Plan: `docs/audit/SECURITY_CLOSE_PLAN.md`. Master tracking file: `docs/SECURITY_GAP_ANALYSIS.md`.

### Fully Closed (20 gaps)

| Gap-ID | Title | Resolution Commit | Issue URL |
|--------|-------|-------------------|-----------|
| GAP-SEC-C-1 | Configuration env-var slice ownership [CONFIDENTIAL] | `d19b65b` | <https://gitlab.com/devnw/zig/otel/-/work_items/54> |
| GAP-SEC-C-2 | gRPC exporter scheme handling [CONFIDENTIAL] | `e508627` | <https://gitlab.com/devnw/zig/otel/-/work_items/61> |
| GAP-SEC-C-3 | gRPC exporter header propagation | `e508627` | <https://gitlab.com/devnw/zig/otel/-/work_items/67> |
| GAP-SEC-H-1 | HTTP header parser input validation [CONFIDENTIAL] | `553502b` | <https://gitlab.com/devnw/zig/otel/-/work_items/69> |
| GAP-SEC-H-2 | Prometheus exporter label escaping [CONFIDENTIAL] | `15c7702` | <https://gitlab.com/devnw/zig/otel/-/work_items/71> |
| GAP-SEC-H-3 | File exporter accepts arbitrary paths | `5d5aa31` | <https://gitlab.com/devnw/zig/otel/-/work_items/72> |
| GAP-SEC-H-4 | `OtlpConfig.skip_tls_verify` not plumbed | `cf518be` | <https://gitlab.com/devnw/zig/otel/-/work_items/73> |
| GAP-SEC-H-5 | Hardcoded `0xC0DE_C0DE` PRNG seed for trace IDs | `1d974c4` | <https://gitlab.com/devnw/zig/otel/-/work_items/74> |
| GAP-SEC-H-6 | Redact module never invoked by exporters | `0cb9a79` | <https://gitlab.com/devnw/zig/otel/-/work_items/77> |
| GAP-SEC-M-1 | Test gRPC server `loopback-secret` token, binds 0.0.0.0 | `9e54e99` | <https://gitlab.com/devnw/zig/otel/-/work_items/81> |
| GAP-SEC-M-2 | `src/generated/` files have no generator script | `252481c` | <https://gitlab.com/devnw/zig/otel/-/work_items/83> |
| GAP-SEC-M-4 | In-repo YAML loader use-after-free [CONFIDENTIAL] | `d19b65b` | <https://gitlab.com/devnw/zig/otel/-/work_items/85> |
| GAP-SEC-M-5 | No endpoint scheme/host validation (SSRF) [CONFIDENTIAL] | `ea94ef9` | <https://gitlab.com/devnw/zig/otel/-/work_items/86> |
| GAP-SEC-M-6 | `last_response_body` `pub`/`undefined` invites stale-byte read | `627947d` | <https://gitlab.com/devnw/zig/otel/-/work_items/87> |
| GAP-SEC-M-7 | `frame()`/`commitSubMessage` u64→u32 silent narrowing | `4222c9e` | <https://gitlab.com/devnw/zig/otel/-/work_items/88> |
| GAP-SEC-M-8 | Header parser allows duplicate `content-type` | `553502b` | <https://gitlab.com/devnw/zig/otel/-/work_items/89> |
| GAP-SEC-L-2 | Array attributes silently dropped / `<array>` literal in Prometheus | `cd9f906` | <https://gitlab.com/devnw/zig/otel/-/work_items/90> |
| GAP-SEC-L-4 | Resource attributes flow unredacted (downstream of H-6) | `0cb9a79` | <https://gitlab.com/devnw/zig/otel/-/work_items/91> |
| GAP-SEC-L-5 | Hardcoded `0xC0DE_C0FFEE` backoff seed | `1d974c4` | <https://gitlab.com/devnw/zig/otel/-/work_items/92> |
| GAP-SEC-L-6 | `OtlpConfig.timeout_ms` accepts `u64::MAX` | `ea94ef9` | <https://gitlab.com/devnw/zig/otel/-/work_items/93> |
| GAP-SEC-L-7 | `Config.validate` accepts `sampler_arg = NaN` | `ea94ef9` | <https://gitlab.com/devnw/zig/otel/-/work_items/94> |

> 21 rows above for 20 fully-closed gaps because L-6 and L-7 were coalesced with M-5 in commit `ea94ef9`. The 22nd in-scope gap (H-7) is partially closed below.

### Partially Closed (2 gaps — code side landed; out-of-band action remaining)

| Gap-ID | Title | Code-Side Commit | Outstanding Action | Issue URL |
|--------|-------|------------------|--------------------|-----------|
| GAP-SEC-H-7 | Live integration test response-body printer [CONFIDENTIAL] | `43330db` | Operator: rotate `OTEL_INTEGRATION_AUTH_HEADER` GitLab CI/CD variable; audit last 30 days of CI logs for bearer pattern. Owner: <benji@codepros.org>. Issue **#80 left open**. | <https://gitlab.com/devnw/zig/otel/-/work_items/77> (audit row), tracker <https://gitlab.com/devnw/zig/otel/-/issues/80> |
| GAP-SEC-M-3 | DevNW deps SHA-pinned but unsigned; no CVE scan | `f82e186` | DevNW upstream: publish Sigstore/cosign signatures for `config-*`, `dotenv-*`, `metric-*`, `prometheus-*`, `protobuf-*`, `runtime-*`, `thread_pool-*`, `tls-*` source tarballs. Issue **#84 left open**. | <https://gitlab.com/devnw/zig/otel/-/work_items/84> |

### Won't Do (4 items)

| Gap-ID | Title | Reason | Alternative Control |
|--------|-------|--------|---------------------|
| GAP-SEC-L-1 | Vendored `dotenv.zig` test fixture trips gitleaks (false positive) | False positive — fixture is dummy data inside the upstream `dotenv` test suite, not a real credential. No exploit. | `.gitleaksignore` excluding `zig-pkg/`, `.zig-cache/`, `third_party/`. No issue filed. |
| GAP-SEC-L-3 | `encodeSpansJson` static wrapping (note only) | Audit-record note only — no exploitable behaviour. | None required. No issue filed. |
| GAP-SEC-H-7 (operator side) | Rotate CI bearer + audit 30 days of CI logs | Out of repo scope — operator action; not a code change. | Tracked on issue #80; owner <benji@codepros.org>. |
| GAP-SEC-M-3 (signing infra side) | DevNW publishes Sigstore/cosign signatures upstream | Out of band — owned by DevNW upstream maintainers, not this repo. | osv-scanner CI job (`f82e186`) provides CVE coverage in the meantime; tracked on issue #84. |

### Verification

- **Tests:** baseline 33 → post-closure **78 passing / 10 skipped / 0 failing** (`zig build test --summary all`)
- **Build:** `zig build check` exit 0
- **Format:** `zig build fmt-check` exit 0
- **Pre-commit:** all 18 hooks pass
- **Gitleaks:** working tree + history clean across the 16-commit range
- **Generators:** `zig build gen-otlp` and `zig build gen-semconv` deterministic (working tree clean after regen)

Resolution evidence per Gap-ID is captured in `docs/audit/SECURITY_VERIFY.md` §2.

### Phase 3 re-audit signed-off 2026-04-26 PM

Independent re-audit run after the 2026-04-26 AM closure. **Result: GREEN — no production-side findings.**

- **Gitleaks:** **0 leaks** across the full 68-commit history scan.
- **Semgrep:** **0 findings** on the production tree.
- **LoopbackServer production-gating check:** **PASS** — bench loopback server is gated to test/bench builds, not present in the consumer runtime path.
- **New findings:** 4 bench-only (S-N1, S-N2, S-N3 = Info; S-N4 = Low). Tracked on GitLab as #119, #121, #125, #127 — all public, all `area::bench`, none on the production attack surface.
- **Outstanding from AM run:** H-7 operator rotation (#80, deadline 2026-05-03; quarterly cron next 2026-07-26) and M-3 upstream Sigstore signing (#84) remain open as previously scoped.

Re-audit verdict: **production attack surface unchanged from AM closure**; the 4 new entries are tracked-only hardening notes against the bench harness.

---

## Functional (closed 2026-04-26 PM)

The PM re-audit verified one functional gap closed since the morning sync.

| Gap-ID | Title | Resolution | Issue URL |
|--------|-------|------------|-----------|
| GAP-BENCH-NOT-WIRED | bench/bench-micro/scale-bench/compare-bench all run fmt-check, not benchmarks | Six bench artifacts wired in `build.zig:454-505` (`bench-micro`, `bench-integration`, `bench-ab`, `bench-smoke`, `compare-bench`, `hard-criterion-check`) plus a `bench-ci` aggregator. Resolution commits: `cc9592d`, `ac6e79a`, `d255da3`, `41672dd`, `b97cc47`, `69fddf1`, `5926bee`. Verified: `zig build hard-criterion-check` exits 0 (Phase 2). | <https://gitlab.com/devnw/zig/otel/-/issues/78> (closed 2026-04-26 PM) |

> Documentation follow-up tracked separately on issue [#112](https://gitlab.com/devnw/zig/otel/-/issues/112) (GAP-BENCH-LOOPBACK-UNDOCUMENTED) — bench loopback server needs a row in `DEPENDENCIES.md` and a sentence in `SPEC_COMPLIANCE.md`.

---

## Functional (closed 2026-04-27)

| Gap-ID | Title | Resolution | Issue URL |
|--------|-------|------------|-----------|
| GAP-OTLP-METRIC-EXPORT | No OTLP metric export path (HTTP `/v1/metrics` or gRPC `MetricsService/Export`) | OTLP/HTTP `metricExporter()` and OTLP/gRPC `metricExporter()` shipped. Encoder lives at `src/exporters/otlp_http.zig:encodeMetricsProto` and emits `ExportMetricsServiceRequest` per OTLP 1.10.0 (Sum / Gauge / Histogram with packed `bucket_counts`/`explicit_bounds`). HTTP path posts to `/v1/metrics` with retry/backoff parity to spans. gRPC path routes through `/opentelemetry.proto.collector.metrics.v1.MetricsService/Export`. JSON payload routes via `../json` (DevNW `streamingEncoder`) when `-Dotel_use_devnw_json=true`. New tests: 8 in `test/otlp_metrics.zig` (path/content-type assertions, retry behaviour, golden field-tag checks, JSON wire-shape) + a live-collector test in `test/remote_otlp.zig` ("OTLP/HTTPS live metric export to remote collector"). | <https://gitlab.com/devnw/zig/otel/-/issues/7> |

---

## GAP-DEPRECATED-SPAN-EVENTS-FLAG: docs note for -Ddeprecated_span_events build gate [RESOLVED — note-only, by design]

- **Issue:** [#101](https://gitlab.com/devnw/zig/otel/-/issues/101) (open as a docs follow-up; no code change required)
- **Category:** Code quality / Docs
- **Severity:** Low
- **Resolution:** Phase 3 classified this as **Implemented (note-only — not actually a gap)**. The deprecated `Span.addEvent` path requires `-Ddeprecated_span_events=true` to compile by design. The OpenTelemetry specification deprecated the surface; this build gate is the spec-compliant behavior.
- **Evidence:**
  - `src/api/trace.zig:215-218` — `Span.addEvent` requires `-Ddeprecated_span_events=true` build flag
  - Phase 3 GAP_DETECTION.md classification: `Status: Implemented (note-only — not actually a gap; called out in Phase 2 for visibility)`
- **Follow-up:** A docs-only note in `docs/SPEC_COMPLIANCE.md` clarifying the deprecation gate and pointing readers to `EventBuilder.emit` is tracked as #101. No code change is required.
- **Resolved date:** 2026-04-26 (carried over from Phase 3 classification)
