# Security Gap Analysis — `otel` (Zig 0.16 OpenTelemetry SDK)

**Last updated:** 2026-04-26 PM
**Source:** `docs/audit/SECURITY_REVIEW.md` (Phase 3 security-reviewer report — 22 confirmed, 3 suspected, 25 total) + Phase 3 PM re-audit (4 new bench-only findings)

**Verdict (2026-04-26 PM):** 22 actionable code-side findings closed 2026-04-26 AM; Phase 3 PM re-audit found 4 new (1 Low, 3 Info, all bench-only). Production attack surface unchanged. H-7 operator action and M-3 upstream signing remain open.
**Repository:** `gitlab.com/devnw/zig/otel`
**Scoring:** Risk Score = Likelihood (1–5) x Impact (1–5).
**Confidentiality policy:** This document is public. Findings flagged `[CONFIDENTIAL]` are tracked in private GitLab issues; this doc lists their title, status, and issue URL only — no exploit specifics, no PoC strings, no attack scenarios.

---

## 0. Closed in this run (2026-04-26)

`/codepros:gap-close` Step 2 landed 16 commits closing 20 gaps fully and 2 gaps on the code side (operator/OOB action still pending). Verification report: `docs/audit/SECURITY_VERIFY.md` (Step 3 — GREEN). Plan: `docs/audit/SECURITY_CLOSE_PLAN.md`.

| # | Commit | Date | Gap-IDs | Issues |
|--:|--------|------|---------|--------|
|  1 | `d19b65b` | 2026-04-26 | C-1, M-4 | #54 [CONF], #85 [CONF] |
|  2 | `ea94ef9` | 2026-04-26 | M-5, L-6, L-7 | #86 [CONF], #93, #94 |
|  3 | `e508627` | 2026-04-26 | C-2, C-3 | #61 [CONF], #67 |
|  4 | `553502b` | 2026-04-26 | H-1, M-8 | #69 [CONF], #89 |
|  5 | `15c7702` | 2026-04-26 | H-2 | #71 [CONF] |
|  6 | `5d5aa31` | 2026-04-26 | H-3 | #72 |
|  7 | `cf518be` | 2026-04-26 | H-4 | #73 |
|  8 | `0cb9a79` | 2026-04-26 | H-6, L-4 | #77, #91 |
|  9 | `1d974c4` | 2026-04-26 | H-5, L-5 | #74, #92 |
| 10 | `43330db` | 2026-04-26 | H-7 (code side) | #80 [CONF] — left open for operator action |
| 11 | `627947d` | 2026-04-26 | M-6 | #87 |
| 12 | `4222c9e` | 2026-04-26 | M-7 | #88 |
| 13 | `9e54e99` | 2026-04-26 | M-1 | #81 |
| 14 | `252481c` | 2026-04-26 | M-2 | #83 |
| 15 | `f82e186` | 2026-04-26 | M-3 (consumer side) | #84 — left open for upstream signing infra |
| 16 | `cd9f906` | 2026-04-26 | L-2 | #90 |

**Net status after this run:**

| Status | Count |
|--------|------:|
| Closed (fully) | 20 |
| Partially closed (code side; operator/upstream action remaining) | 2 (H-7, M-3) |
| Won't Do (handled out of band or no fix needed) | 4 (L-1, L-3, H-7-operator, M-3-signing) |
| Open / actionable in this repo | 0 |

**Tests:** baseline 33 passing → post-closure **78 passing / 10 skipped / 0 failing** (`zig build test --summary all`). Build, format, gitleaks (working tree + history), generators all green.

Closed and Won't-Do entries have been moved to `docs/GAP_ANALYSIS_RESOLVED.md` (Security section, 2026-04-26). The "Stack-Ranked Findings" table below retains a single row per gap with final status for cross-reference; resolution evidence lives in the resolved index.

---

## 1. Summary

| Severity | Count | Aggregate Risk |
|----------|------:|---------------:|
| Critical | 3     | 66             |
| High     | 7     | 113            |
| Medium   | 8     | 70             |
| Low      | 7     | 28             |
| **Total**| **25**| **277**        |

**Issues filed:** 22 (3 Critical + 7 High + 8 Medium + 4 Low). Skipped: L-1 (false positive — handle via `.gitleaksignore`), L-3 (note-only, no fix required).

**Confidential issues:** 7 (C-1, C-2, H-1, H-2, H-7, M-4, M-5). Public issues: 15.

### Top 5 by Risk Score (final status)

1. **C-2** (Risk 25) — gRPC exporter scheme handling — `[CONFIDENTIAL][IMMEDIATE]` — **Closed** (`e508627`)
2. **C-1** (Risk 25) — Configuration env-var slice ownership — `[CONFIDENTIAL][IMMEDIATE]` — **Closed** (`d19b65b`)
3. **H-1** (Risk 20) — HTTP header parser input validation — `[CONFIDENTIAL]` — **Closed** (`553502b`)
4. **H-7** (Risk 20) — Live integration test response-body printer — `[CONFIDENTIAL][IMMEDIATE]` — **Partially Closed (code side, `43330db`)**; operator rotation + 30-day CI log audit still pending (owner: <benji@codepros.org>)
5. **C-3** (Risk 16) — gRPC exporter header propagation — `[IMMEDIATE]` — **Closed** (`e508627`)

---

## 2. Immediate Operational Actions (out-of-band)

These actions are owned by **<benji@codepros.org>**. Items 3 and 4 are satisfied by the 2026-04-26 closure run; items 1 and 2 remain operator action and are tracked here as the only outstanding security work.

1. **Rotate** the `OTEL_INTEGRATION_AUTH_HEADER` GitLab CI/CD variable (H-7). Treat the previous value as compromised. **Deadline: 2026-05-03 (7 days from 2026-04-26).** **Status: PENDING — operator action; not a code change.**
2. **Audit** the last 90 days of GitLab CI logs for the bearer-token leakage pattern (`Authorization`, `Bearer<space>`, `5333796.otel.gitlab-o11y.com`) BEFORE rotation completes. **Status: PENDING — operator action; not a code change.**
3. **Scrub** the `last_response_body` printer in `test/remote_otlp.zig` *before* the next default-branch CI run. **Status: DONE** (`43330db`).
4. **Block the next release** on landing fixes for C-1, C-2, C-3, H-1, M-5. **Status: DONE** — all five landed (`d19b65b`, `e508627`, `e508627`, `553502b`, `ea94ef9`).
5. **Quarterly token-rotation cron**: schedule recurring rotation of `OTEL_INTEGRATION_AUTH_HEADER`. **Next rotation: 2026-07-26.** Owner: <benji@codepros.org>.

---

## 3. Stack-Ranked Findings (final status)

| Rank | ID  | Severity | Risk | Confidence | Title                                                                | Component                          | CWE / OWASP                  | Issue URL | Status |
|-----:|-----|----------|-----:|------------|----------------------------------------------------------------------|------------------------------------|------------------------------|-----------|--------|
| 1    | C-2 | Critical | 25   | Confirmed  | gRPC exporter scheme handling [CONFIDENTIAL]                          | `src/exporters/otlp_grpc.zig`      | CWE-319 / A02:2021           | <https://gitlab.com/devnw/zig/otel/-/work_items/61> | **Closed** (`e508627`, 2026-04-26) |
| 2    | C-1 | Critical | 25   | Confirmed  | Configuration env-var slice ownership [CONFIDENTIAL]                  | `src/sdk/config.zig`               | CWE-825 / A01:2021           | <https://gitlab.com/devnw/zig/otel/-/work_items/54> | **Closed** (`d19b65b`, 2026-04-26) |
| 3    | H-1 | High     | 20   | Confirmed  | HTTP header parser input validation [CONFIDENTIAL]                    | `src/exporters/otlp_http.zig`      | CWE-93,113,444 / A03:2021    | <https://gitlab.com/devnw/zig/otel/-/work_items/69> | **Closed** (`553502b`, 2026-04-26) |
| 4    | H-7 | High     | 20   | Confirmed  | Live integration test response-body printer [CONFIDENTIAL]            | `test/remote_otlp.zig`, `.gitlab-ci.yml` | CWE-532,200 / A09:2021       | <https://gitlab.com/devnw/zig/otel/-/work_items/77> | **Partially Closed (code side)** (`43330db`, 2026-04-26) — operator rotation + CI log audit pending |
| 5    | C-3 | Critical | 16   | Confirmed  | gRPC exporter header propagation                                      | `src/exporters/otlp_grpc.zig`      | CWE-693,285 / A07:2021       | <https://gitlab.com/devnw/zig/otel/-/work_items/67> | **Closed** (`e508627`, 2026-04-26) |
| 6    | H-2 | High     | 16   | Confirmed  | Prometheus exporter label escaping [CONFIDENTIAL]                     | `src/exporters/prometheus.zig`     | CWE-117 / A03:2021           | <https://gitlab.com/devnw/zig/otel/-/work_items/71> | **Closed** (`15c7702`, 2026-04-26) |
| 7    | H-4 | High     | 16   | Confirmed  | `OtlpConfig.skip_tls_verify` not plumbed                              | `src/sdk/config.zig`               | CWE-295 / A02:2021           | <https://gitlab.com/devnw/zig/otel/-/work_items/73> | **Closed** (`cf518be`, 2026-04-26) |
| 8    | H-6 | High     | 16   | Confirmed  | Redact module never invoked by exporters                              | `src/internal/redact.zig`, exporters | CWE-200 / A02:2021,A04:2021 | <https://gitlab.com/devnw/zig/otel/-/work_items/77> | **Closed** (`0cb9a79`, 2026-04-26) |
| 9    | M-4 | Medium   | 16   | Confirmed  | In-repo YAML loader use-after-free [CONFIDENTIAL]                     | `src/sdk/config.zig`               | CWE-416 / A03:2021           | <https://gitlab.com/devnw/zig/otel/-/work_items/85> | **Closed** (`d19b65b`, 2026-04-26) |
| 10   | M-5 | Medium   | 16   | Confirmed  | No endpoint scheme/host validation (SSRF) [CONFIDENTIAL]              | `src/sdk/config.zig`               | CWE-918 / A10:2021           | <https://gitlab.com/devnw/zig/otel/-/work_items/86> | **Closed** (`ea94ef9`, 2026-04-26) |
| 11   | H-3 | High     | 15   | Confirmed  | File exporter accepts arbitrary paths                                 | `src/exporters/file.zig`           | CWE-22,59,73 / A01:2021      | <https://gitlab.com/devnw/zig/otel/-/work_items/72> | **Closed** (`5d5aa31`, 2026-04-26) |
| 12   | H-5 | High     | 12   | Confirmed  | Hardcoded `0xC0DE_C0DE` PRNG seed for trace IDs                       | `src/sdk/trace.zig`, `src/internal/id.zig` | CWE-338 / A02:2021    | <https://gitlab.com/devnw/zig/otel/-/work_items/74> | **Closed** (`1d974c4`, 2026-04-26) |
| 13   | M-3 | Medium   | 12   | Confirmed  | DevNW deps SHA-pinned but unsigned; no CVE scan                       | `build.zig.zon`, `.gitlab-ci.yml`  | CWE-494,1357 / A06,A08:2021 | <https://gitlab.com/devnw/zig/otel/-/work_items/84> | **Partially Closed (consumer side)** (`f82e186`, 2026-04-26) — DevNW-side Sigstore/cosign signing infra remains OOB |
| 14   | L-4 | Low      | 12   | Confirmed  | Resource attributes flow unredacted (downstream of H-6)               | `src/exporters/*`, `src/sdk/resource.zig` | CWE-200 / A02:2021    | <https://gitlab.com/devnw/zig/otel/-/work_items/91> | **Closed** (`0cb9a79`, 2026-04-26) |
| 15   | M-1 | Medium   | 6    | Confirmed  | Test gRPC server `loopback-secret` token, binds 0.0.0.0               | `src/exporters/otlp_grpc_test_server.zig` | CWE-798 / A07:2021    | <https://gitlab.com/devnw/zig/otel/-/work_items/81> | **Closed** (`9e54e99`, 2026-04-26) |
| 16   | M-2 | Medium   | 6    | Confirmed  | `src/generated/` files have no generator script                       | `src/generated/`, `tools/`         | CWE-1357 / A06,A08:2021      | <https://gitlab.com/devnw/zig/otel/-/work_items/83> | **Closed** (`252481c`, 2026-04-26) |
| 17   | M-6 | Medium   | 6    | Suspected  | `last_response_body` `pub`/`undefined` invites stale-byte read        | `src/exporters/otlp_http.zig`      | CWE-908,457 / —              | <https://gitlab.com/devnw/zig/otel/-/work_items/87> | **Closed** (`627947d`, 2026-04-26) |
| 18   | M-7 | Medium   | 4    | Suspected  | `frame()`/`commitSubMessage` u64→u32 silent narrowing                 | `src/exporters/otlp_grpc.zig`, `src/generated/otlp.zig` | CWE-190,681 / —      | <https://gitlab.com/devnw/zig/otel/-/work_items/88> | **Closed** (`4222c9e`, 2026-04-26) |
| 19   | M-8 | Medium   | 4    | Confirmed  | Header parser allows duplicate `content-type`                         | `src/exporters/otlp_http.zig`      | CWE-436,444 / —              | <https://gitlab.com/devnw/zig/otel/-/work_items/89> | **Closed** (`553502b`, 2026-04-26) |
| 20   | L-2 | Low      | 4    | Confirmed  | Array attributes silently dropped / `<array>` literal in Prometheus   | `src/internal/json_codec.zig`, `src/exporters/prometheus.zig` | CWE-440,754 / — | <https://gitlab.com/devnw/zig/otel/-/work_items/90> | **Closed** (`cd9f906`, 2026-04-26) |
| 21   | L-5 | Low      | 4    | Confirmed  | Hardcoded `0xC0DE_C0FFEE` backoff seed                                | `src/exporters/otlp_http.zig`, `src/exporters/otlp_grpc.zig` | CWE-330 / —          | <https://gitlab.com/devnw/zig/otel/-/work_items/92> | **Closed** (`1d974c4`, 2026-04-26) |
| 22   | L-7 | Low      | 4    | Confirmed  | `Config.validate` accepts `sampler_arg = NaN`                         | `src/sdk/config.zig`               | CWE-20,1284 / —              | <https://gitlab.com/devnw/zig/otel/-/work_items/94> | **Closed** (`ea94ef9`, 2026-04-26) |
| 23   | L-6 | Low      | 2    | Suspected  | `OtlpConfig.timeout_ms` accepts `u64::MAX`                            | `src/sdk/config.zig`               | CWE-1284,400 / —             | <https://gitlab.com/devnw/zig/otel/-/work_items/93> | **Closed** (`ea94ef9`, 2026-04-26) |
| —    | L-1 | Low      | 1    | Confirmed  | Vendored `dotenv.zig` test fixture trips gitleaks (false positive)    | `zig-pkg/config-...`               | —                            | *Not filed — handle via `.gitleaksignore`* | **Won't Do** — false positive; mitigated via `.gitleaksignore` |
| —    | L-3 | Low      | 1    | Confirmed  | `encodeSpansJson` static wrapping (note only)                         | `src/exporters/otlp_http.zig`      | —                            | *Not filed — note for audit record only* | **Won't Do** — note for audit record only; no exploitable behaviour |

---

## 4. Findings by Area

### Configuration & Validation

- **C-1** — env-var slice ownership (Risk 25, CONFIDENTIAL) — **Closed** `d19b65b`
- **M-4** — YAML loader use-after-free (Risk 16, CONFIDENTIAL) — **Closed** `d19b65b`
- **M-5** — endpoint scheme/host validation / SSRF (Risk 16, CONFIDENTIAL) — **Closed** `ea94ef9`
- **L-6** — `timeout_ms` upper bound — **Closed** `ea94ef9`
- **L-7** — `sampler_arg = NaN` not rejected — **Closed** `ea94ef9`

### Exporters — OTLP/HTTP

- **H-1** — header parser input validation (Risk 20, CONFIDENTIAL) — **Closed** `553502b`
- **H-4** — `skip_tls_verify` not wired (Risk 16) — **Closed** `cf518be`
- **H-6** — `redact` not invoked (Risk 16) — **Closed** `0cb9a79`
- **M-6** — `last_response_body` exposure — **Closed** `627947d`
- **M-8** — duplicate `content-type` allowed — **Closed** `553502b`

### Exporters — OTLP/gRPC

- **C-2** — h2c silent downgrade (Risk 25, CONFIDENTIAL) — **Closed** `e508627`
- **C-3** — headers dropped (Risk 16) — **Closed** `e508627`
- **M-7** — u64→u32 narrowing in `frame()` — **Closed** `4222c9e`

### Exporters — Prometheus / File / JSON

- **H-2** — Prometheus label escaping (Risk 16, CONFIDENTIAL) — **Closed** `15c7702`
- **H-3** — File exporter path traversal (Risk 15) — **Closed** `5d5aa31`
- **L-2** — Array attribute handling — **Closed** `cd9f906`

### Identifiers & Cryptography

- **H-5** — non-CSPRNG trace-ID seed — **Closed** `1d974c4`
- **L-5** — hardcoded backoff seed (thundering herd) — **Closed** `1d974c4`

### Resource & Redaction

- **L-4** — resource attributes unredacted — **Closed** `0cb9a79`

### Supply Chain

- **M-2** — generator scripts missing — **Closed** `252481c`
- **M-3** — DevNW deps unsigned, no CVE scan — **Partially Closed (consumer side)** `f82e186` — osv-scanner CI job added; upstream signing infra (Sigstore/cosign) remains owned by DevNW (out of band)

### CI / Test Harness

- **H-7** — live integration test prints response bodies (Risk 20, CONFIDENTIAL, IMMEDIATE rotation) — **Partially Closed (code side)** `43330db` — body scrubber + endpoint hashing landed; operator-side credential rotation + 30-day CI log audit still pending (owner: <benji@codepros.org>)
- **M-1** — test gRPC server hardcoded token, 0.0.0.0 bind — **Closed** `9e54e99`

---

## 5. Roadmap

All Tier 1–3 items from the Step 1 plan landed in this run. The remaining roadmap items are out-of-scope follow-ups, not code closure:

### Out-of-band operator actions (not code)

- **H-7 operator side** — rotate `OTEL_INTEGRATION_AUTH_HEADER`; audit 30 days of GitLab CI logs for bearer pattern. Owner: <benji@codepros.org>.
- **M-3 upstream side** — DevNW publishes Sigstore/cosign signatures for `config-*`, `dotenv-*`, `metric-*`, `prometheus-*`, `protobuf-*`, `runtime-*`, `thread_pool-*`, `tls-*` source tarballs. Owner: DevNW upstream maintainers.

### Optional non-blocking follow-ups (from `docs/audit/SECURITY_VERIFY.md` §4)

- `src/internal/json_codec.zig:181` `writeValue` is dead code — delete or rename to `writeValueLiteral` to prevent future misuse as an un-redacted attribute writer.
- `src/sdk/config.zig:143-150` IPv6 link-local prefix check (`startsWith "fea"/"feb"/"fe9"`) over-matches plain hostnames like `feature.example.com`. Tighten to require an IPv6-shaped host (presence of `::` or hex-only labels).
- `test/remote_otlp.zig:264` "see body above" wording is stale (body now suppressed/hashed) — update message.

---

## 6. Cross-References

- **Quality M9** in `docs/audit/QUALITY_REVIEW.md` — same root cause as **C-1**; classified there as the codebase's only confirmed memory-corruption bug. **Resolution shared:** closed by `d19b65b` via the `Config.deinit` + owned-slice rewrite.
- **Quality L2** in `docs/audit/QUALITY_REVIEW.md` — same class as **H-5** and **L-5** (literal PRNG seeds). **Resolution shared:** closed by `1d974c4` via CSPRNG seeding.
- **C-1 ↔ M-4** — sibling lifetime/ownership bugs; share the `Config.deinit` fix. Both closed by `d19b65b`.
- **C-2 ↔ C-3** — same exporter, both silently disregard operator intent. Both closed by `e508627`.
- **C-2 ↔ H-4** — sibling TLS-plumbing gaps on the two exporters. C-2: `e508627`; H-4: `cf518be`.
- **H-1 ↔ M-8** — same HTTP header parser; complementary fixes. Both closed by `553502b`.
- **H-1 ↔ C-1** — corrupted env-var bytes from C-1 cross header boundaries through the unvalidated parser in H-1. Both root-cause and parser hardened (`d19b65b`, `553502b`).
- **H-6 ↔ L-4** — same fix family (apply `redact.maskString` at exporter and resource boundaries). Both closed by `0cb9a79`.
- **H-7 ↔ M-5 ↔ M-6** — exfiltration chain: SSRF response (M-5) → `last_response_body` (M-6) → CI logs (H-7). All three closed by independent commits (`ea94ef9`, `627947d`, `43330db` code side); operator-side rotation for H-7 still pending.
- **M-2 ↔ M-3** — sibling supply-chain hardening gaps. M-2: `252481c` (generators reproducible); M-3: `f82e186` (osv-scanner) consumer side.
- **L-7 ↔ M-5 ↔ L-6** — same `Config.validate` function; bundle the validation hardening. All three closed by `ea94ef9`.

---

## 6.1 Phase 3 re-audit findings (2026-04-26 PM)

Re-audit run after the 2026-04-26 AM closure. Scope: full re-scan (gitleaks 0 leaks across 68 commits, semgrep 0 findings, LoopbackServer production-gating PASS). Production attack surface unchanged. Four new findings, all bench-only:

| ID   | Severity | Risk | Title                                                                                  | File                                              | Issue URL                                                            | Status |
|------|----------|-----:|----------------------------------------------------------------------------------------|---------------------------------------------------|----------------------------------------------------------------------|--------|
| S-N1 | Info     | 1    | Bench loopback `wake()` uses raw Linux syscalls; track Zig stdlib `Server.shutdown()`  | `benchmarks/integration/loopback_server.zig:200-216` | <https://gitlab.com/devnw/zig/otel/-/work_items/119> | Open — track upstream stdlib |
| S-N2 | Info     | 1    | Bench loopback endpoint formats unauthenticated `http://` (by design — Info note only) | `benchmarks/integration/loopback_server.zig:73-75`   | <https://gitlab.com/devnw/zig/otel/-/work_items/121> | Open — note only, no fix required |
| S-N3 | Info     | 1    | `LoopbackServer.err` cross-thread field unguarded; refactor to atomic post-Zig-0.17    | `benchmarks/integration/loopback_server.zig:65-70,139,151` | <https://gitlab.com/devnw/zig/otel/-/work_items/125> | Open — track Zig 0.17 |
| S-N4 | Low      | 2    | `build.zig.zon` `paths` ships `benchmarks/` in tarball — VERDICT: keep                 | `build.zig.zon:49-66`                                | <https://gitlab.com/devnw/zig/otel/-/work_items/127> | Open — doc-only follow-up |

**S-N4 verdict:** **KEEP `benchmarks/` in `build.zig.zon` paths** — negligible size, useful for consumers, zero production exploit path. Document the trade-off in `docs/DEPENDENCIES.md` as the only follow-up.

**Severity-only entries here.** Per project policy, exploit detail is not in this public doc; see the per-issue bodies on GitLab for context (none of S-N1..S-N4 are confidential — bench-only, no production attack path).

---

## 7. Confidentiality Marker

This document itself is public. Findings flagged `[CONFIDENTIAL]` (C-1, C-2, H-1, H-2, H-7, M-4, M-5) appear here only as title + status + issue URL — exploit specifics live in the private GitLab issues only. The closing comments posted to GitLab on 2026-04-26 for those issues are deliberately brief (commit SHA + reference to `docs/audit/SECURITY_VERIFY.md`) — no exploit detail.
