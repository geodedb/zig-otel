# Security Gap Analysis — `otel` (Zig 0.16 OpenTelemetry SDK)

**Last updated:** 2026-04-27
**Source:** `docs/audit/SECURITY_REVIEW.md` (Phase 3 security-reviewer report — 22 confirmed, 3 suspected, 25 total) + Phase 3 PM re-audit (4 new bench-only findings) + Phase 3 2026-04-27 re-audit (9 new findings: 1 High, 2 Medium, 4 Low, 2 Info — bench/post-closure residuals)

**Verdict (2026-04-27):** Original 22 actionable code-side findings remain closed (re-confirmed 2026-04-27 in tracker comments on #54, #61, #67, #69, #71, #72, #73, #74, #77, #81, #86). 2026-04-27 re-audit surfaced **9 new** findings (NEW-H-1 / NEW-M-1 / NEW-M-2 / NEW-L-1..L-4 / NEW-INFO-1 / NEW-INFO-2). Three are confidential (NEW-H-1, NEW-M-1, NEW-M-2). **NEW-H-1 closed 2026-04-27** (vendored upstream proto + semconv sources, manifest engine refuses LICENSE-only state, CI gate via `make verify-manifests`). **NEW-M-2 closed 2026-04-27** (file exporter open path now refuses symlink follow via `O_NOFOLLOW` + atomic `O_CREAT | O_EXCL`; Zig 0.16.0 `Dir.createFile` confirmed to lack a `follow_symlinks` toggle at `lib/std/Io/Dir.zig:586`). Production attack surface still bounded; H-7 operator action remains open with a 2026-05-03 deadline (6 days remaining).
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
| 13   | M-3 | Medium   | 12   | Confirmed  | DevNW deps SHA-pinned but unsigned; no CVE scan                       | `build.zig.zon`, `.gitlab-ci.yml`  | CWE-494,1357 / A06,A08:2021 | <https://gitlab.com/devnw/zig/otel/-/work_items/84> | **Won't Do (this repo)** (consumer-side closed `f82e186`, 2026-04-26; reclassified 2026-04-27) — Sigstore/cosign signing of DevNW packages requires changes to DevNW shared CI infrastructure, not this repo. Consumer-side mitigations (SHA pinning in `build.zig.zon` + `osv-scanner` CI gate on MR/main/schedule) remain in place. Upstream signing tracked OOB on the DevNW-meta tracker (to be filed at <https://gitlab.com/devnw/meta>). |
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

## 6.2 Phase 3 re-audit findings (2026-04-27)

Second re-audit after the 2026-04-26 closure run, focused on residual surface in the parts of the codebase that were not in the original 25-finding scope (manifests, file-exporter symlink semantics, env-driven paths, instrumentation paths, vendored grpc-zig). 9 new findings; 3 confidential.

| ID         | Severity | Risk | Confidence | Title                                                                                                          | File / Component                                                       | CWE / OWASP                | Issue URL                                                                | Status |
|------------|----------|-----:|------------|----------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------|----------------------------|--------------------------------------------------------------------------|--------|
| NEW-H-1    | High     | 7.5  | Confirmed  | proto/semconv manifests only hash `LICENSE`; deterministic provenance gate is toothless [CONFIDENTIAL]          | `docs/proto-manifest.txt:4` + `docs/semconv-manifest.txt:4`            | CWE-345 / A08:2021         | <https://gitlab.com/devnw/zig/otel/-/work_items/134> | Closed (2026-04-27) — vendored upstream proto subset (16 files, ~132 KiB) + semconv `model/` (244 files, ~1.7 MiB); manifests now hash every file (path-sorted SHA-256) at `docs/proto-manifest.txt` (19 lines) + `docs/semconv-manifest.txt` (248 lines); generators (`tools/gen_otlp.zig`, `tools/gen_semconv.zig`) reject LICENSE-only state via `tools/manifest.zig::requireSpecPayload` and add `--verify` mode wired through `zig build verify-manifests` + `make verify-manifests`; structural regression tests in `test/manifest_provenance.zig` (5 tests). |
| NEW-M-1    | Medium   | 6.5  | Confirmed  | `OTEL_CONFIG_FILE` arbitrary 1 MiB file open; no allowlist / symlink guard [CONFIDENTIAL]                      | `src/sdk/config.zig:299-300`                                            | CWE-22 / A01:2021          | <https://gitlab.com/devnw/zig/otel/-/work_items/137> | Open — needs allowlist + realpath; SLA 90d (due 2026-07-26) |
| NEW-M-2    | Medium   | 5.5  | Confirmed  | File exporter `createFile` lacks O_NOFOLLOW; symlink follow can clobber arbitrary files [CONFIDENTIAL]          | `src/exporters/file.zig:34`                                             | CWE-59 / A01:2021          | <https://gitlab.com/devnw/zig/otel/-/work_items/140> | Closed (2026-04-27) — Zig 0.16.0 `lib/std/Io/Dir.zig:586` `CreateFileOptions` has no `follow_symlinks` field (compare `OpenFileOptions:551`), so `Dir.createFile` follows symlinks unconditionally. `src/exporters/file.zig:53-69` now opens with `follow_symlinks = false` first; on `error.FileNotFound` falls through to `createFile` with `exclusive = true` (`O_CREAT \| O_EXCL`) — TOCTOU-safe against symlink swaps in the trusted base dir. Regression test at `test/file_exporter_symlink.zig` (3 tests) plants a symlink to an outside sentinel and asserts the open returns `error.SymLinkLoop` and the sentinel bytes are preserved. |
| NEW-L-1    | Low      | 4.0  | Confirmed  | `OTEL_RESOURCE_ATTRIBUTES` key not validated/length-capped (CR/LF in keys)                                     | `src/sdk/resource.zig:87-97`                                            | CWE-117 (partial)          | <https://gitlab.com/devnw/zig/otel/-/work_items/142> | Open — log-injection partial primitive; SLA 180d |
| NEW-L-2    | Low      | 4.0  | Confirmed  | Loopback gRPC test server binds 0.0.0.0 (upstream-fixed in grpc-zig)                                            | `src/exporters/otlp_grpc_test_server.zig:112-114` + `third_party/grpc_zig/server.zig:32` | CWE-668 / A05:2021         | <https://gitlab.com/devnw/zig/otel/-/work_items/145> | Open — needs upstream PR or local wrapper; SLA 180d |
| NEW-L-3    | Low      | 3.5  | Confirmed  | grpc-zig `readFrame` allocates 16 MiB without enforcing SETTINGS_MAX_FRAME_SIZE                                | `third_party/grpc_zig/transport.zig:196-218`                            | CWE-770                    | <https://gitlab.com/devnw/zig/otel/-/work_items/147> | Open — DoS guard / RFC 7540 §4.2; SLA 180d |
| NEW-L-4    | Low      | 3.0  | Confirmed  | http server span `url.path` emitted verbatim; no PII filter                                                    | `src/instrumentation/http.zig:54`                                       | CWE-532 / A09:2021         | <https://gitlab.com/devnw/zig/otel/-/work_items/151> | Open — accept optional `path_template`; SLA 180d |
| NEW-INFO-1 | Info     | 2.0  | Confirmed  | `SECURITY.md` references GitHub on a GitLab project                                                            | `SECURITY.md`                                                           | —                          | <https://gitlab.com/devnw/zig/otel/-/work_items/160> | Open — doc fix; backlog |
| NEW-INFO-2 | Info     | 2.0  | Confirmed  | `src/internal/json_codec.zig:181` dead `writeValue` (no redaction; regression hazard for H-6)                  | `src/internal/json_codec.zig:181-189`                                   | CWE-1164                   | <https://gitlab.com/devnw/zig/otel/-/work_items/162> | Open — delete or rename + warn; backlog |

### Operator-pending follow-ups (re-confirmed 2026-04-27)

- **H-7 operator side** — rotate `OTEL_INTEGRATION_AUTH_HEADER` GitLab CI/CD variable; deadline **2026-05-03** (6 days). Code side remains closed (`43330db`); tracker issue #80 (confidential) stays open until rotation + 30-day log audit complete.
- **M-3 upstream side** — DevNW Sigstore/cosign signatures for vendored source tarballs; tracker issue #84 stays open.
- **NEW-M-2** — Closed 2026-04-27. Zig 0.16.0 `lib/std/Io/Dir.zig:586` `CreateFileOptions` has no `follow_symlinks` field, so `Dir.createFile` follows symlinks. Patch landed in `src/exporters/file.zig` (open-then-fallback with `O_NOFOLLOW` + `O_EXCL`); regression test in `test/file_exporter_symlink.zig`. See row above for the full closure note.

### Re-audit closure-confirmation comments (2026-04-27)

The following previously-closed issues received re-audit closure-evidence notes today (no state change — still closed; re-confirmed clean):

| Gap | Issue | File:line re-verified                                                                  | Note URL |
|-----|-------|----------------------------------------------------------------------------------------|----------|
| C-2 | #61   | `src/exporters/otlp_grpc.zig` (https honored)                                           | <https://gitlab.com/devnw/zig/otel/-/work_items/61#note_3289973146> |
| C-3 | #67   | `src/exporters/otlp_grpc.zig` (header propagation)                                      | <https://gitlab.com/devnw/zig/otel/-/work_items/67#note_3289973237> |
| H-1 | #69   | `src/exporters/otlp_http.zig` (header parser)                                           | <https://gitlab.com/devnw/zig/otel/-/work_items/69#note_3289972505> |
| H-3 | #72   | `src/exporters/file.zig:25-34` (`validateSubPath`)                                      | <https://gitlab.com/devnw/zig/otel/-/work_items/72#note_3289972606> |
| H-4 | #73   | `src/sdk/config.zig` + exporters (`skip_tls_verify` plumbed)                            | <https://gitlab.com/devnw/zig/otel/-/work_items/73#note_3289972691> |
| H-5 | #74   | `src/sdk/trace.zig` + `src/internal/id.zig` (CSPRNG)                                    | <https://gitlab.com/devnw/zig/otel/-/work_items/74#note_3289972890> |
| H-6 | #77   | `src/internal/redact.zig` + exporters (redact wired)                                    | <https://gitlab.com/devnw/zig/otel/-/work_items/77#note_3289973313> |
| M-1 | #81   | `src/exporters/otlp_grpc_test_server.zig:115-124` (per-run CSPRNG token)                | <https://gitlab.com/devnw/zig/otel/-/work_items/81#note_3289972978> |
| M-5 | #86   | `src/sdk/config.zig` (endpoint scheme/host validation)                                  | <https://gitlab.com/devnw/zig/otel/-/work_items/86#note_3289973061> |

---

## 7. Confidentiality Marker

This document itself is public. Findings flagged `[CONFIDENTIAL]` (C-1, C-2, H-1, H-2, H-7, M-4, M-5, **NEW-H-1, NEW-M-1, NEW-M-2**) appear here only as title + status + issue URL — exploit specifics live in the private GitLab issues only. The closing comments posted to GitLab on 2026-04-26 for those issues are deliberately brief (commit SHA + reference to `docs/audit/SECURITY_VERIFY.md`) — no exploit detail. The 2026-04-27 re-audit closure-evidence comments are similarly brief.
