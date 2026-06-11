# Application Security Review — `src/` (OTLP/OpenTelemetry Zig SDK)

**Date:** 2026-06-11
**Reviewer scope:** Full source-tree review of `src/` (54 Zig files), prioritizing the network / parser / exporter / config attack surface.
**Standards:** OWASP Top 10:2025, CIS Controls v8.1.2.
**Working tree:** clean (no diff). Repo `/data/home/benji/src/devnw/zig/otel`, branch `main`.

---

## 1. Scope and Assumptions

**Reviewed (read in full):**
`src/sdk/config.zig`, `src/sdk/exporter_factory.zig`, `src/sdk/export.zig`, `src/sdk/trace.zig` (relevant sections), `src/exporters/otlp_http/{transport,headers,compression,exporter}.zig`, `src/exporters/otlp_http/encode_proto.zig` (attribute path), `src/exporters/otlp_grpc.zig`, `src/exporters/otlp_grpc_test_server.zig`, `src/exporters/file.zig`, `src/exporters/prometheus.zig`, `src/exporters/stdout_json.zig`, `src/internal/{redact,id,json_codec,attributes}.zig`, `src/propagation/{trace_context,baggage,b3,jaeger}.zig`, `src/instrumentation/http.zig`, `build.zig.zon`, `build.zig` (TLS/manifest sections), `Makefile` (gate).

**Reviewed by grep/targeted read:** redact integration across all exporters, TLS-verify knobs, logging/leak surface, hardcoded-value regressions.

**Not exhaustively reviewed:** `src/generated/*` (vendored, integrity-gated), `src/api/*` (non-security primitives), DevNW dependency *internals* (pinned, out of source scope), the `encode_proto_devnw.zig` / `encode_logs.zig` / `encode_json.zig` bodies beyond their redact call sites, `sdk/metrics.zig` / `sdk/logs.zig` beyond `initFromConfig`, and `test/`.

**Assumptions:**

- The library is linked into a host service; it exposes **no inbound network listener** of its own (the only server, `otlp_grpc_test_server.zig`, is build-flag-gated test scaffolding).
- Attacker-controlled inputs are: (a) inbound propagation headers parsed by `src/propagation/*`, (b) OTLP endpoint/headers/config sourced from env/YAML/code, (c) collector responses, (d) telemetry attribute values that may carry secrets/PII.
- Threat model inferred per the task brief (no formal model supplied).
- The prior baseline (`docs/SECURITY_GAP_ANALYSIS.md`, synced 2026-04-27, 22 closed findings) is the regression reference.

---

## 2. Executive Summary

- **The SSRF endpoint guard is real but not enforced on the primary construction path (`initFromConfig` → factory → exporter `init`).** `validateEndpoint()` (which blocks `169.254.169.254`, link-local, and loopback) runs **only** inside `Config.validate()`, which is called **only** by `config.resolve()`. A host that builds a `Config` via `applyYamlString`/`applyEnvFromMap`/a struct literal and passes it straight to `TracerProvider.initFromConfig` exports to **any** attacker-supplied host with no metadata-endpoint guard. This is a **High** defense-in-depth regression risk against the baseline's "SSRF guard on OTLP endpoints" control. **(CONFIRMED, A10/A06)**
- **TLS verification is correctly enforced with no disable knob.** `skip_tls_verify` was deliberately removed; the HTTP transport uses `std.http.Client.fetch` (verify-on default) and there is no escape hatch in the source. The gRPC path refuses `https://` rather than silently downgrading. **(Positive — Secure Design)**
- **Propagation parsers (traceparent, tracestate, baggage, b3, jaeger) are well-bounded** — strict length caps, charset validation, member-count limits, and bounded percent-decoding with no OOB. No memory-safety or unbounded-allocation issue found on the inbound header hot paths. **(Positive)**
- **The file exporter symlink/traversal hardening (O_NOFOLLOW + O_CREAT|O_EXCL + component-wise `..` rejection) is intact.** **(Positive — regression check passed)**
- **Redaction is consistently invoked across every exporter** (JSON, proto, proto-devnw, logs, prometheus). Prometheus label escaping and CSPRNG-seeded ID generation are intact. **(Positive — regression checks passed)**
- **Two low-severity confirmed issues:** a `tls` dependency tag/hash label mismatch in `build.zig.zon` (supply-chain hygiene), and an unescaped Prometheus `# HELP` description line (output-format integrity). One low informational note on trace-ID predictability (non-CSPRNG PRNG stream).

**Overall confidence:** High for the SSRF-enforcement gap (traced source-to-sink) and the regression checks; Medium-High for the supply-chain note (verified the on-disk manifest, not the upstream tag).

---

## 3. Findings Table

| ID | Severity | Confidence | Title | Location | OWASP | Status |
|----|----------|-----------|-------|----------|-------|--------|
| AS-1 | High | High | SSRF guard bypassed on factory/`initFromConfig` construction path (validation not enforced outside `resolve`) | `sdk/exporter_factory.zig:124-148`, `sdk/trace.zig:283-305`, `exporters/otlp_http/exporter.zig:73-86`, `sdk/config.zig:243-259,354` | A10 / A06 | Open (CONFIRMED) |
| AS-2 | Low | High | Prometheus `# HELP` description emitted unescaped (exposition-format injection) | `exporters/prometheus.zig:38` | A05 / A03 | Open (CONFIRMED) |
| AS-3 | Low | Medium | `tls` dependency tag/hash label mismatch (`?ref=v0.1.9` vs `hash=tls-0.1.8-…`) | `build.zig.zon:36-39` | A03 / A08 | Open (CONFIRMED) |
| AS-4 | Low | High | Trace/Span IDs drawn from non-CSPRNG PRNG stream (xoshiro seeded by 64-bit CSPRNG) | `internal/id.zig:128-146,215-231` | A04 | Open (CONFIRMED, informational) |
| AS-5 | Info | High | Plain `http://` OTLP endpoints permitted (no transport-level TLS enforcement) | `sdk/config.zig:105-113`, `exporters/otlp_http/exporter.zig:75-77` | A02 | By design (note) |

---

## 4. Finding Details

### AS-1 — SSRF guard not enforced on the factory / `initFromConfig` construction path **(High, CONFIRMED)**

**OWASP:** A10 Mishandling of Exceptional Conditions / A06 Insecure Design · **CWE-918 (SSRF), CWE-1287 (improper validation of specified type of input)** · **CIS v8.1.2:** 16.10 (secure design — validate before use), 18 (penetration testing surface), 13 (network monitoring/SSRF egress).

**Evidence:**
The SSRF/metadata-endpoint defense is implemented correctly in `validateEndpoint()` (`sdk/config.zig:98-164`) — it rejects non-`http(s)` schemes, `169.254.0.0/16` (covers `169.254.169.254`), `fe80::/10`, IPv4-mapped link-local, and (opt-in) loopback. But it is invoked from exactly one place:

```zig
// sdk/config.zig:243-259  (Config.validate)
try validateEndpoint(self.traces.otlp.endpoint, self.traces.otlp.allow_loopback);
try validateEndpoint(self.metrics.otlp.endpoint, self.metrics.otlp.allow_loopback);
try validateEndpoint(self.logs.otlp.endpoint, self.logs.otlp.allow_loopback);
```

…and `Config.validate()` is called from exactly one place:

```zig
// sdk/config.zig:354  (resolve)
try cfg.validate();
```

The provider/factory construction path **never calls `validate()`**:

```zig
// sdk/trace.zig:283-284  (TracerProvider.initFromConfig)
pub fn initFromConfig(allocator, cfg: *const config_mod.Config) !TracerProvider {
    var owned = try exporter_factory.spanExporterFromConfig(allocator, cfg);   // no validate
```

```zig
// sdk/exporter_factory.zig:124-148
pub fn spanExporterFromConfig(allocator, cfg) ... {
    return spanExporterFor(allocator, cfg.traces.exporter, cfg.traces.otlp);   // reads otlp directly
}
// spanExporterFor(.otlp_http) -> buildSpanOtlpHttp -> OtlpHttpExporter.init
```

And the exporter's own `init` only checks the **scheme prefix**, not the host:

```zig
// exporters/otlp_http/exporter.zig:73-77  (OtlpHttpExporter.init)
if (config.endpoint.len == 0) return error.InvalidEndpoint;
if (!std.mem.startsWith(u8, config.endpoint, "http://") and
    !std.mem.startsWith(u8, config.endpoint, "https://")) return error.InvalidEndpoint;
// no link-local / metadata / loopback check here
```

`metricExporterFromConfig` / `logExporterFromConfig` and the `*For` lower-level helpers (public API, used by tests and any embedder) have the same gap. `spanExporterFor(allocator, kind, otlp)` takes a **raw `OtlpConfig`** and performs no endpoint validation whatsoever.

**Attack scenario (non-destructive):**
A host service loads OTLP config from a source it considers semi-trusted but does not route through `resolve()` — e.g. it parses a YAML/JSON deployment file with `applyYamlString` (`config.zig:500`) or populates env via `applyEnvFromMap` (`config.zig:371`) and then calls `TracerProvider.initFromConfig(alloc, &cfg)` directly (a documented, public entry point). An attacker who can influence that endpoint value (a tenant-supplied collector URL, a compromised config map, a Helm value) sets `endpoint = "http://169.254.169.254/latest/meta-data/iam/security-credentials/"`. Because no `validate()` runs, the exporter POSTs telemetry to the cloud metadata service on every flush. While OTLP POSTs to the metadata service are unusual, the **egress to an arbitrary internal/control-plane host** is the SSRF primitive — internal-only collectors, link-local addresses, and loopback services become reachable, and the response body (up to 1024 bytes) is captured in `lastResponseBody()` for the caller to read back.

**Impact:** Server-side request forgery to internal/control-plane endpoints (cloud metadata, internal admin services, loopback daemons), bypassing the very guard the 2026-04-27 baseline closed under "Endpoint scheme/host validation (SSRF guard)". The guard exists but is only wired into one of (at least) two supported construction paths, so the control is **partially regressed**.

**Root cause:** Validation is attached to `Config.resolve()` rather than to the trust boundary where an endpoint is consumed (exporter `init`). The factory and `initFromConfig` were added (GAP-EXPORTER-FACTORY #4) as new construction paths without re-asserting the endpoint invariant.

**Remediation (smallest safe fix):** Enforce the endpoint invariant at the point of use, so it holds regardless of construction path. Make `validateEndpoint` (and `allow_loopback`) reachable and call it inside the exporter constructors:

```zig
// exporters/otlp_http/exporter.zig  (OtlpHttpExporter.init), and the gRPC init:
pub fn init(allocator, config: OtlpConfig) !OtlpHttpExporter {
    try config_mod.validateEndpoint(config.endpoint, config.allow_loopback); // make pub
    ...
}
```

Alternatively (or additionally) have the factory call `cfg.validate()` before building any OTLP exporter, and the `*For` helpers validate their `otlp` argument. Prefer the exporter-`init` approach because it closes the lower-level `spanExporterFor(kind, otlp)` and any future direct-construction caller in one place. Keep `validateEndpoint`’s existing semantics (it already grandfathers the spec default and honors `allow_loopback`).

**Regression tests:**

- `OtlpHttpExporter.init` rejects `http://169.254.169.254/...` with `error.InvalidEndpoint` (and the metrics/logs/grpc equivalents).
- `TracerProvider.initFromConfig` with a hand-built `Config{ .traces = .{ .otlp = .{ .endpoint = "http://169.254.169.254" }, .exporter = .otlp_http } }` (no `resolve`) returns an error.
- `spanExporterFor(alloc, .otlp_http, .{ .endpoint = "http://fe80::1" })` returns `error.InvalidEndpoint`.
- Positive: the spec default `http://localhost:4318` still constructs; `allow_loopback=true` still permits explicit loopback.

---

### AS-2 — Prometheus `# HELP` description emitted unescaped **(Low, CONFIRMED)**

**OWASP:** A05 Injection (output-format/exposition injection) · **CWE-116 (improper output encoding)** · **CIS v8.1.2:** 16 (secure application development).

**Evidence:**
Metric `name` is sanitized (`sanitize`, `prometheus.zig:88`) and label values are escaped (`escapeLabelValue`, `prometheus.zig:125`) and redacted. But the metric `description` is interpolated raw into the `# HELP` line:

```zig
// exporters/prometheus.zig:38
try buf.print(self.allocator, "# HELP {s} {s}\n", .{ sanitized, m.description });
```

Per the Prometheus 0.0.4 exposition format, HELP text must escape `\` as `\\` and newline as `\n`; a literal `\n` in `description` terminates the HELP line and injects subsequent bytes as new exposition lines.

**Attack scenario:** A metric description containing a newline (e.g. a developer or a semconv-derived description that embeds `\n`, or any code path that lets an external value reach `MetricData.description`) produces `# HELP name first line\n<attacker-controlled metric line>`. A scraping Prometheus could ingest a forged metric/series. In this codebase descriptions are generally developer-set (not inbound-attacker-set), which is why this is **Low** — but it is a genuine output-encoding defect and the only un-escaped sink in the Prometheus renderer.

**Impact:** Corruption/forgery of the Prometheus exposition output if any newline reaches a description. Confidentiality/integrity of the metrics scrape, not the host.

**Root cause:** `description` was treated as trusted free text; the escaper that already exists for label values was not applied to HELP text.

**Remediation:** Escape HELP text. Prometheus only requires `\` → `\\` and `\n` → `\n` for HELP (note: `"` is *not* escaped in HELP, unlike label values), so add a minimal helper:

```zig
fn escapeHelp(allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8){};
    for (s) |c| switch (c) {
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        else => try out.append(allocator, c),
    };
    return out.toOwnedSlice(allocator);
}
// then:
const help = try escapeHelp(self.allocator, m.description);
defer self.allocator.free(help);
try buf.print(self.allocator, "# HELP {s} {s}\n", .{ sanitized, help });
```

**Regression test:** render a metric whose description contains `"line1\nline2"` and assert the output contains `line1\\nline2` on a single `# HELP` line and no injected line.

---

### AS-3 — `tls` dependency tag/hash label mismatch **(Low, CONFIRMED)**

**OWASP:** A03 Software Supply Chain Failures / A08 Software & Data Integrity · **CWE-1357 (reliance on insufficiently trustworthy component), CWE-353** · **CIS v8.1.2:** 2.x (third-party component inventory / trusted & supported dependencies), 16.4 (component provenance).

**Evidence:**

```zig
// build.zig.zon:36-39
.tls = .{
    .url  = "git+https://gitlab.com/devnw/zig/tls.git?ref=v0.1.9#0cbbf1a4f0389c46ddde6947979c62d7afbcf076",
    .hash = "tls-0.1.8-mtEaLMyREwAyFXsLS6tyxvJlWznML_yff7il9qBjJp_D",
},
```

The URL ref/tag is `v0.1.9` (and the most recent commit is `chore(deps): converge tls onto v0.1.9 (GAP-0838 diamond sync)`), but the `hash` label encodes `tls-0.1.8-…`. The other eight deps are SHA-pinned with self-consistent labels.

**Why it matters / why Low:** Zig verifies the package content against the multihash `hash` field, so the *bytes* are pinned and reproducible — there is no integrity bypass at fetch time (the SHA in the URL plus the content hash both pin the artifact). The risk is **provenance ambiguity**: the human-readable version label (`0.1.8`) disagrees with the tag the team believes they converged onto (`v0.1.9`). If the tag `v0.1.9` was later re-pointed upstream, or if a future regeneration trusts the `?ref=` tag over the commit SHA, the mismatch masks a version-drift that an auditor or SBOM tool would otherwise catch. This is the kind of label/tag inconsistency that supply-chain hygiene checks (CIS 2.x) exist to surface.

**Impact:** SBOM/version-inventory inaccuracy; potential for silent version drift on the TLS dependency (the component most security-relevant to the exporter’s confidentiality guarantees).

**Root cause:** The diamond-sync that re-pointed the `?ref=` tag to v0.1.9 (commit `a43c525`) updated the URL ref and commit SHA but the regenerated `hash` field still carries the `0.1.8` version label — likely the v0.1.9 tag points at a commit whose `build.zig.zon` still declares `version = "0.1.8"`, or the hash was not regenerated.

**Remediation:** Regenerate the dependency hash from the intended v0.1.9 tag (`zig fetch --save` against the pinned SHA) so the `hash` label and the `?ref=` tag agree, or correct the upstream `tls` package version to `0.1.9` and re-pin. Confirm the pinned commit SHA `0cbbf1a4…` is the one the `v0.1.9` tag actually references. Add a CI lint that asserts the `hash`-embedded version matches the `?ref=` tag for every SHA-pinned dep.

**Verification step:** `zig build` resolves cleanly (proves the bytes match the hash); then diff the resolved `tls` package’s own `build.zig.zon` `version` against `0.1.9`.

---

### AS-4 — Trace/Span IDs from a non-CSPRNG PRNG stream **(Low, CONFIRMED, informational)**

**OWASP:** A04 Cryptographic Failures · **CWE-330 (use of insufficiently random values)** · **CIS v8.1.2:** 16.x (secure design).

**Evidence:**

```zig
// internal/id.zig:128-146
pub const Random = struct {
    prng: std.Random.DefaultPrng,            // xoshiro256++ — non-crypto
    pub fn initFromCsprng() Random {
        return .{ .prng = std.Random.DefaultPrng.init(csprngU64()) };   // 64-bit CSPRNG seed
    }
};
// randomTraceId/randomSpanId draw 16/8 bytes from this PRNG (id.zig:215-231)
```

`TracerProvider.init` defaults to `initFromCsprng()` (`sdk/trace.zig:209-214`), so production IDs come from a **xoshiro256++ stream seeded by 64 bits of OS entropy**, not from a CSPRNG per ID.

**Why this is Low/informational:** The baseline requirement ("CSPRNG, not the old hardcoded `0xC0DE_C0DE` seed") is satisfied — the seed is genuinely from `getrandom(2)`/`arc4random_buf`, eliminating cross-process correlation, and the generator is pluggable (callers needing crypto-grade IDs can supply their own `IdGenerator`). W3C trace IDs are not a security boundary in this SDK (no authorization decision is made on them). The residual property is that xoshiro256++ is not state-recovery-resistant: an adversary who can observe a sufficient run of emitted 128-bit trace IDs could, in principle, reconstruct PRNG state and predict subsequent IDs. That matters only in a deployment that (incorrectly) treats trace/span IDs as unguessable capability tokens.

**Impact:** Predictability of future trace IDs by an observer of past IDs, in the narrow case where IDs are misused as secrets. No direct impact on telemetry confidentiality/integrity otherwise.

**Remediation (optional):** If any downstream treats IDs as unguessable, document that they must plug in a CSPRNG-backed `IdGenerator`; or change the default `randomTraceId`/`randomSpanId` to draw directly from `csprngU64()`/`fillCsprngBytes` (the OS CSPRNG) instead of the seeded xoshiro stream. The helper already exists (`fillCsprngBytesPub`), so this is a small change with a minor per-ID syscall cost.

**Verification:** unit test asserting two `TracerProvider`s produce disjoint ID streams (already implied by the CSPRNG seed); document the security posture of IDs in `docs/`.

---

### AS-5 — Plain `http://` OTLP endpoints permitted **(Info / by design)**

**OWASP:** A02 Security Misconfiguration · **CWE-319 (cleartext transmission)** · **CIS v8.1.2:** 3.10 (encrypt data in transit).

**Evidence:** `validateEndpoint` (`config.zig:105-113`) and `OtlpHttpExporter.init` (`exporter.zig:75-77`) both accept `http://` as well as `https://`. Telemetry — which may carry PII attributes and rides alongside an `Authorization` header — can be sent in cleartext to a non-loopback collector.

**Assessment:** This is consistent with the OTel spec (the default endpoint is `http://localhost:4318`) and the codebase correctly refuses to silently downgrade gRPC `https://` to h2c (`otlp_grpc.zig:80-89`, GAP-SEC-C-2). TLS verification, when `https://` is used, is enforced with no disable knob. So this is a deployment-posture note, not a defect: an operator can misconfigure a cleartext non-loopback endpoint. **Recommendation:** consider warning (or, behind a strict flag, refusing) non-loopback `http://` endpoints when an `Authorization`/secret-bearing header is configured, so an auth token is never paired with cleartext transport.

---

## 5. Secure Design Notes (positive controls observed)

- **TLS verification enforced, no bypass:** `skip_tls_verify` was intentionally removed (`config.zig:57-64`); the HTTP transport relies on `std.http.Client.fetch` default verification, and there is no source path that disables peer verification. The gRPC exporter refuses `https://` rather than silently downgrading to plaintext (`otlp_grpc.zig:80-89`). *(Regression check: PASS.)*
- **Inbound propagation parsers are tightly bounded** (answers Q3): traceparent is fixed-length-55 with strict positional `-` checks and lowercase-hex validation (`trace_context.zig:135-170`); tracestate caps length (512) and member count (32) with charset validation (`trace_context.zig:172-188`); baggage caps serialized size and bounds percent-decoding with no OOB (`baggage.zig:37-91`); b3 and jaeger validate hex, field counts, and flag widths, padding 16-hex IDs safely (`b3.zig:112-251`, `jaeger.zig:121-293`). No unbounded allocation or overflow found on these hot paths.
- **File exporter anti-symlink / anti-traversal intact** (answers Q5): component-wise `..`/absolute/empty rejection (`file.zig:102-109`) plus `openFile(.follow_symlinks=false)` and `createFile(.exclusive=true)` for TOCTOU-safe `O_NOFOLLOW + O_CREAT|O_EXCL` semantics (`file.zig:50-96`). *(Regression check: PASS.)*
- **Redaction consistently invoked across every exporter** (answers Q4 for the attribute path): `redact.maskString(key, value)` is wired into the JSON codec (`json_codec.zig:178`), in-repo proto (`encode_proto.zig:490`), DevNW proto (`encode_proto_devnw.zig:532`), logs (`encode_logs.zig:282`), encode_json (`encode_json.zig:172,401`), and Prometheus label values (`prometheus.zig:200`). *(Regression check: PASS.)*
- **No leakage of auth headers or response bodies into logs/errors** (answers Q4): grep found no `std.log`/`slog`/`debug.print` of `config.headers` or response bodies anywhere in `src/exporters/`. The response stash is bounded to 1024 bytes (`transport.zig:24`) and exposed only via an explicit accessor.
- **HTTP header parser hardened** (answers part of Q4): RFC 7230 token validation on names, control-byte rejection on values (blocks CR/LF response splitting, NUL smuggling, DEL), length caps (256/4096), and a forced drop of user-supplied `content-type` (`headers.zig:37-92`). *(Regression check: PASS.)*
- **No inbound decode of collector responses** (answers Q6): production exporters never parse the response body; the only length-prefix construction (`frame`, `otlp_grpc.zig:401-408`) guards against `u32` truncation with `error.MessageTooLarge` (GAP-SEC-M-7). gzip *decompression* (`gunzipBody`) is test-only — no decompression-bomb surface on the response path.
- **CSPRNG seeding from the OS entropy source** (`getrandom`/`arc4random_buf`, `id.zig:171-213`) with an explicit, non-security-claiming fallback; trace IDs default to it (`trace.zig:209-214`). *(Regression check: the hardcoded `0xC0DE_C0DE` seed is gone — PASS; see AS-4 for the residual PRNG note.)*
- **gRPC test server is build-flag-gated, loopback-bound at the harness level, and uses a per-run CSPRNG token** (`otlp_grpc_test_server.zig:42-130`). The `0.0.0.0` bind is upstream grpc-zig behavior, confined to gated test scaffolding, and the token is freshly generated (GAP-SEC-M-1). *(Regression check: PASS — no hardcoded token, no production bind.)*
- **Vendored proto/semconv integrity gate intact** (NEW-H-1): `verify-proto-manifest` / `verify-semconv-manifest` / `verify-manifests` build steps exist (`build.zig:431-467`) and CI gates on them (`Makefile:122 ci: … verify-manifests`). *(Regression check: PASS.)*
- **Config robustness:** NaN sampler-arg rejected, OTLP timeout capped (`config.zig:243-259`), malformed numeric env vars fall back to defaults rather than crashing (A10-aligned graceful handling). Memory ownership is tracked with `*_owned` flags and idempotent `deinit` to avoid double-free.

---

## 6. Coverage Gaps and Questions

- **DevNW dependency internals not reviewed.** `tls`, `grpc-zig`, `json`, `yaml`, `protobuf`, `slog` are pinned by SHA and out of `src/` scope. The exporter’s confidentiality guarantees depend on the `tls` package’s actual verification behavior (assumed correct via `std.http.Client`; the build does not currently route HTTPS through the DevNW `tls` dep — see `transport.zig:112-118`). Recommend a focused review of the `std.http.Client` TLS path under `-Dotel_use_devnw_tls=true`.
- **`encode_proto_devnw.zig`, `encode_logs.zig`, `encode_json.zig` reviewed only at their redact call sites,** not in full. The redact integration is correct; the rest of those encoders (varint/length handling) was not line-audited.
- **No dynamic testing performed.** All findings are from static reading; AS-1’s exploit path is traced through the source but not executed. Recommend the regression tests in AS-1 to confirm.
- **Open question (AS-1):** Is `TracerProvider.initFromConfig` (and the metrics/logs equivalents) documented/intended to be called with a `Config` that did **not** pass through `resolve()`? If the team’s contract is "always go through `resolve()`," the severity is mitigated to Medium operationally — but the public API still permits the unvalidated path, so the fix belongs at the exporter boundary regardless.
- **Open question (AS-3):** Does the `v0.1.9` tag of `devnw/zig/tls` actually declare `version = "0.1.9"`, or is the upstream package version still `0.1.8` at that tag? This determines whether AS-3 is a label cosmetic or a genuine version-drift.
- **Redact taxonomy is allow-list-by-token** (`redact.zig:12-20`): `password/secret/token/api.key/apikey/authorization/credential`. Keys like `session`, `cookie`, `private_key`, `pwd`, `passwd`, `bearer`, `x-api-*` (without the literal token), or PII like `email`/`ssn` are **not** redacted. Not a regression (consistent with baseline), but the taxonomy is narrow — flagged for product awareness, not as a finding.

---

## 7. Prioritized Next Actions

1. **Fix AS-1 (High):** Call `validateEndpoint(config.endpoint, config.allow_loopback)` inside `OtlpHttpExporter.init` and `OtlpGrpcExporter.init` (make the function `pub`), so the SSRF/metadata guard holds on the factory, `initFromConfig`, and direct-construction paths — not just `resolve()`. Add the four regression tests listed under AS-1. This closes the only material gap and restores the baseline control on every construction path.
2. **Confirm and correct AS-3 (Low, supply chain):** Verify the `v0.1.9` tag → commit `0cbbf1a4…` mapping and regenerate the `tls` `hash` so its version label matches the ref; add a CI lint asserting `hash`-version == `?ref`-tag across all pinned deps.
3. **Fix AS-2 (Low):** Add `escapeHelp` and apply it to the Prometheus `# HELP` line; add the newline-injection regression test.
4. **Decide on AS-4 (Low):** Either document that IDs are not unguessable capabilities (and that callers needing crypto-grade IDs plug in their own `IdGenerator`), or switch the default ID generator to draw directly from the OS CSPRNG.
5. **Consider AS-5 / redact-taxonomy hardening:** Optionally warn/refuse non-loopback `http://` endpoints when a secret-bearing header is configured, and broaden the redact token list (`session`, `cookie`, `private_key`, `pwd`, `bearer`) — both are posture improvements, not defects.

> No confirmed memory-safety (UAF/double-free/OOB), injection-to-RCE, or auth-bypass vulnerabilities were found in the reviewed scope. The headline risk is the **enforcement gap** in AS-1: a correct control wired into only one of the supported construction paths.

---

*This report was produced by static review only; no untrusted code was executed and no secrets were extracted or normalized. Findings marked CONFIRMED were observed directly in the cited source; AS-3 is rated Medium confidence pending upstream-tag verification.*
