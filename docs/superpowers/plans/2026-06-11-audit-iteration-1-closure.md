# Audit Iteration 1 — Gap & Bug Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every actionable correctness, security, maintainability, and bounded-performance finding from the 2026-06-11 audit pass (`docs/APPSEC_REVIEW_2026-06-11_src.md` + the gap/quality/perf reviewer reports) so a re-review surfaces no new issues.

**Architecture:** The Zig 0.16 OTel SDK is whole-program compiled with a shared `build.zig`. Tests live under `test/` and are wired into `build.zig`'s `test_files` array — **inline `test {}` blocks under `src/` are never executed** (confirmed empirically). Every fix is therefore validated by a test added to an existing wired `test/` file. Tasks are grouped into five **file-disjoint batches** (A–E) that may be implemented in any order but are each verified with `zig build test` before commit. Larger perf refactors and upstream-blocked items are recorded in the tracking docs (Batch F), not implemented here.

**Tech Stack:** Zig 0.16.0, `std.http.Client`, DevNW grpc-zig/tls, manual allocator discipline.

**Verification command (per task):** `zig build` (compile) then `zig build test --summary all` (full suite; baseline is 243 PASS / 27 SKIP / 0 FAIL). A new regression test must FAIL before the fix and PASS after.

---

## Batch A — Security & exporter hardening

Files: `src/sdk/config.zig`, `src/exporters/otlp_http/exporter.zig`, `src/exporters/otlp_grpc.zig`, `src/exporters/prometheus.zig`. Tests: `test/security.zig`, `test/config.zig`.

### Task A1: Enforce SSRF endpoint guard at exporter construction (AS-1 / GAP-NEW-1, High)

**Files:**

- Modify: `src/sdk/config.zig` — change `fn validateEndpoint` (line 98) to `pub fn validateEndpoint`.
- Modify: `src/exporters/otlp_http/exporter.zig:73-86` (`OtlpHttpExporter.init`) — after the existing scheme check, call the guard.
- Modify: `src/exporters/otlp_grpc.zig` (`OtlpGrpcExporter.init`) — add the same guard at construction.
- Test: `test/security.zig`.

- [ ] **Step 1: Failing tests** in `test/security.zig`:
  - `OtlpHttpExporter.init` with `.{ .endpoint = "http://169.254.169.254/latest/meta-data/" }` returns `error.InvalidEndpoint`.
  - Same for `"http://[fe80::1]"` and (without `allow_loopback`) `"http://127.0.0.1:4318"`.
  - `TracerProvider.initFromConfig` with a hand-built `Config{ .traces = .{ .exporter = .otlp_http, .otlp = .{ .endpoint = "http://169.254.169.254" } } }` (NOT routed through `resolve()`) returns an error.
  - Positive: default `http://localhost:4318` still constructs; `allow_loopback = true` with `http://127.0.0.1:4318` still constructs.
- [ ] **Step 2:** Run `zig build test`; expect the new asserts to FAIL.
- [ ] **Step 3: Implement.** Make `validateEndpoint` `pub`. In `OtlpHttpExporter.init`, after the `startsWith http(s)://` check, add `try config_mod.validateEndpoint(config.endpoint, config.allow_loopback);` (import the config module; the field is `OtlpConfig.allow_loopback`). Mirror in `OtlpGrpcExporter.init`. Preserve the spec-default grandfathering (already inside `validateEndpoint`). Note: gRPC endpoints may be scheme-less host:port — confirm `validateEndpoint` tolerates the gRPC endpoint form, or normalize before calling; if the gRPC endpoint is stored without a scheme, gate the call to the form `validateEndpoint` accepts (do NOT weaken the HTTP check).
- [ ] **Step 4:** Run `zig build test`; expect PASS (243+new).
- [ ] **Step 5: Commit** `fix(security): enforce SSRF endpoint guard at exporter init (AS-1)`.

### Task A2: Escape Prometheus `# HELP` description (AS-2 / GAP-NEW-2, Low)

**Files:**

- Modify: `src/exporters/prometheus.zig:38` and add an `escapeHelp` helper.
- Test: `test/security.zig` (or extend any wired prometheus assertion; `test/security.zig` is wired).

- [ ] **Step 1: Failing test** — render a metric whose `description` is `"line1\nline2"` (literal newline) and assert output contains `line1\\nline2` on a single `# HELP` line, with no injected exposition line.
- [ ] **Step 2:** Run; expect FAIL (currently emits a raw newline).
- [ ] **Step 3: Implement** `escapeHelp(allocator, s)` that maps `\\`→`\\\\` and `\n`→`\\n` (HELP does NOT escape `"`), use it at line 38, `defer` free the result.
- [ ] **Step 4:** Run; expect PASS.
- [ ] **Step 5: Commit** `fix(prometheus): escape backslash/newline in HELP text (AS-2)`.

---

## Batch B — Metrics correctness & concurrency hygiene

Files: `src/sdk/metrics.zig`, `src/sdk/periodic_metric_reader.zig`. Tests: `test/observable_instruments.zig`, `test/periodic_metric_reader.zig`.

### Task B1: Guard observable double→int observation (QN-NEW-4, Medium — latent panic)

**Files:**

- Modify: `src/sdk/metrics.zig:842` (`observerObserveDouble`, the `.sum_int` arm).
- Test: `test/observable_instruments.zig`.

- [ ] **Step 1: Failing test** — register an `observable_up_down_counter` (backed by `sum_int`) whose callback observes a non-finite/out-of-range `f64` (e.g. `std.math.nan(f64)` and `1e30`); assert `collect()` does NOT panic and the bad observation is skipped (value unchanged / no point emitted) rather than producing garbage.
- [ ] **Step 2:** Run; in ReleaseSafe/Debug expect a panic (illegal `@intFromFloat`) → test fails/crashes.
- [ ] **Step 3: Implement.** In the `.sum_int` arm at `metrics.zig:842`, mirror the existing `.sum_uint` guard at 843-845: reject `std.math.isNan(value)` / non-finite and out-of-`i64`-range before `@intFromFloat`. Apply the same guard to any `gauge_double`→int path.
- [ ] **Step 4:** Run; expect PASS.
- [ ] **Step 5: Commit** `fix(metrics): guard non-finite/out-of-range double in observable sum_int (QN-NEW-4)`.

### Task B2: Surface export errors from PeriodicMetricReader.forceFlush (QN-NEW-5, Medium)

**Files:**

- Modify: `src/sdk/periodic_metric_reader.zig` — `collectAndExport` (lines ~337/340 `catch {}`), `forceFlush` (thread path ~242-255), add a `failed_exports`/last-error field.
- Test: `test/periodic_metric_reader.zig`.

- [ ] **Step 1: Failing test** — wire a stub exporter whose `exportMetrics` returns an error; call `forceFlush` and assert it surfaces the failure (returns an error OR increments an observable `failed_exports` counter that the test reads). Use the inline (non-threaded) path so the result is deterministic.
- [ ] **Step 2:** Run; expect FAIL (today returns success).
- [ ] **Step 3: Implement.** Capture the export error in `collectAndExport` (replace `catch {}` with capturing the error into a reader field and/or returning it); propagate it through `forceFlush` on both the inline and started-thread paths; at minimum increment a `failed_exports` counter (mirror BSP `dropped`). Do not break the existing `error.ExportTimeout` semantics.
- [ ] **Step 4:** Run; expect PASS.
- [ ] **Step 5: Commit** `fix(metrics): surface export failure from PeriodicMetricReader.forceFlush (QN-NEW-5)`.

### Task B3: De-duplicate the Mutex wrapper (QN-NEW-2, High maintainability)

**Files:**

- Modify: `src/sdk/metrics.zig:38-53` (delete `InstrumentMutex`, use `@import("../internal/sync.zig").Mutex`).
- Modify: `src/sdk/periodic_metric_reader.zig:40-54` (delete `ReaderMutex`, use the shared `Mutex`); evaluate hoisting `ReaderCondition` if it is byte-identical to a shared primitive (only if a shared condition exists — otherwise leave the condition in place and note it).
- Test: existing `test/metrics_concurrency.zig` + `test/periodic_metric_reader.zig` must stay green (this is a refactor; no behavior change).

- [ ] **Step 1:** Confirm `src/internal/sync.zig`'s `Mutex` (lines 31-45) is API-compatible with the two local copies (`lock`/`unlock` shape).
- [ ] **Step 2: Implement** the swap; delete the duplicate definitions; fix references.
- [ ] **Step 3:** Run `zig build test`; expect the existing concurrency tests to PASS unchanged.
- [ ] **Step 4: Commit** `refactor(metrics): use shared internal/sync.Mutex, drop duplicate wrappers (QN-NEW-2)`.

### Task B4: Remove dead inline tests from metrics reader files (QN-NEW-7, partial)

**Files:**

- Modify: `src/sdk/periodic_metric_reader.zig:356-374` (1 inline test) — delete after confirming `test/periodic_metric_reader.zig` covers the same assertion (add it there if missing).

- [ ] **Step 1:** Diff the inline test's assertions against `test/periodic_metric_reader.zig`; port any unique assertion into the wired file.
- [ ] **Step 2:** Delete the inline `test {}` block from `src/`.
- [ ] **Step 3:** Run `zig build test`; expect PASS.
- [ ] **Step 4: Commit** `test(metrics): move reader inline test into wired test/, drop dead src test (QN-NEW-7)`.

---

## Batch C — Logs: correlation, redaction, encoder de-dup

Files: `src/sdk/logs.zig`, `src/instrumentation/std_log.zig`, `src/api/events.zig`, `src/exporters/otlp_http/encode_logs.zig`, `src/exporters/otlp_http/encode_proto.zig`. Tests: `test/logs.zig`, `test/otlp_logs_wire.zig`.

### Task C1: Wire trace↔span correlation into the primary log emit path (QN-NEW-1, High)

**Files:**

- Modify: `src/sdk/logs.zig` — `onEmit` (165-168) and `simpleEmit` (42-46) to pull the active `Context` and call `correlate` (171) before dispatch.
- Modify: `src/instrumentation/std_log.zig:67-68` and `src/api/events.zig:65` to route through the same `correlate` helper instead of hand-rolling.
- Test: `test/logs.zig`.

- [ ] **Step 1: Failing test** — start a span, make it current in a `Context`, then call the public logger `emit(.{...})` (NOT `correlate` directly) inside that context; assert the emitted record's `trace_id`/`span_id` equal the active span's IDs.
- [ ] **Step 2:** Run; expect FAIL (IDs come back `.invalid`).
- [ ] **Step 3: Implement.** Have `onEmit`/`simpleEmit` read the active `Context` (same accessor the instrumentation bridges use) and call `correlate(parent, record)` before dispatching to the processor; redirect `std_log.zig`/`events.zig` to the shared helper. Keep the encoder's existing omit-when-invalid behavior.
- [ ] **Step 4:** Run; expect PASS.
- [ ] **Step 5: Commit** `fix(logs): apply trace/span correlation on the primary emit path (QN-NEW-1)`.

### Task C2: Redact string log bodies (QN-NEW-8, Medium security-adjacent)

**Files:**

- Modify: `src/exporters/otlp_http/encode_logs.zig:262-272` (`writeBody`).
- Test: `test/otlp_logs_wire.zig`.

- [ ] **Step 1: Failing test** — encode a log record whose string body contains a secret-shaped value the redactor recognizes (e.g. a body the value-pattern redactor should mask, such as a token-looking string) and assert the wire output masks it, consistent with how attribute values are masked at `:282`. If `redact` is strictly key-driven (no value-pattern API), instead assert the documented carve-out: add a user-facing doc note AND a value-pattern redaction pass.
- [ ] **Step 2:** Run; expect FAIL (body emitted verbatim).
- [ ] **Step 3: Implement.** Apply value-pattern redaction to string bodies in `writeBody` (reuse `redact`'s value-scanning entry point; if only `maskString(key, value)` exists, pass a synthetic key like `"body"` is NOT sufficient — use the value-pattern path or add one). Replace the inline rationalization comment with a precise note. If a true value-pattern redactor does not exist, the minimal correct fix is to add one to `src/internal/redact.zig` (small) and call it here.
- [ ] **Step 4:** Run; expect PASS.
- [ ] **Step 5: Commit** `fix(logs): redact secret-shaped string log bodies (QN-NEW-8)`.

### Task C3: Extract shared scope-grouping + key/value encoder (QN-NEW-3, High maintainability)

**Files:**

- Modify: `src/exporters/otlp_http/encode_proto.zig` — export `ScopeKey3`/`ScopeKey3Context` and `writeKeyValue` (or move to a new `src/exporters/otlp_http/otlp_codec.zig`).
- Modify: `src/exporters/otlp_http/encode_logs.zig:86-143,274-290` — import and reuse them; delete the copies.
- Test: existing `test/otlp_logs_wire.zig` + `test/otlp_spans_multi_scope.zig` stay green (refactor).

- [ ] **Step 1:** Make the shared symbols `pub` in `encode_proto.zig` (or new shared file) with no behavior change.
- [ ] **Step 2:** Replace the duplicated definitions in `encode_logs.zig` with imports; the hash-key (Wyhash seed + `eql`) and the `redact.maskString` + `else => {}` policy now live in one place.
- [ ] **Step 3:** Run `zig build test`; expect PASS unchanged.
- [ ] **Step 4: Commit** `refactor(otlp): share scope-grouping + writeKeyValue between span and log encoders (QN-NEW-3)`.

### Task C4: Remove dead inline test from encode_logs (QN-NEW-7, partial)

**Files:** Modify `src/exporters/otlp_http/encode_logs.zig:292-296` — delete inline test after confirming `test/otlp_logs_wire.zig` covers it.

- [ ] **Step 1:** Port any unique assertion to `test/otlp_logs_wire.zig`. **Step 2:** Delete inline block. **Step 3:** `zig build test` PASS. **Step 4: Commit** `test(otlp): drop dead inline test in encode_logs (QN-NEW-7)`.

---

## Batch D — Propagation: leak fix, de-dup, doc/dead-code

Files: `src/propagation/propagator.zig`, `src/propagation/jaeger.zig`, `src/propagation/baggage.zig`, new `src/propagation/percent.zig`. Tests: `test/propagator.zig`, `test/baggage.zig`, `test/propagator_jaeger.zig`.

### Task D1: Fix Baggage leak on Composite.extract merge-error path (QN-NEW-9, Medium)

**Files:** Modify `src/propagation/propagator.zig:150-156`. Test: `test/propagator.zig`.

- [ ] **Step 1: Failing test** — use a composite extractor of two baggage-yielding propagators under a `std.testing.FailingAllocator` (or one that triggers `error.BaggageFull` by exceeding the entry cap) so the merge-into-existing `put` fails; assert no leak (run under the testing allocator which reports leaks).
- [ ] **Step 2:** Run; expect FAIL (leak detected) or a leak on the error path.
- [ ] **Step 3: Implement.** In the merge-into-existing branch, replace the trailing `part.deinit()` with `defer part.deinit();` placed immediately after `part` is obtained, so cleanup runs on both success and the `put`-error early return.
- [ ] **Step 4:** Run; expect PASS, no leak.
- [ ] **Step 5: Commit** `fix(propagation): free baggage on Composite.extract merge-error path (QN-NEW-9)`.

### Task D2: De-duplicate percent-codec + hex helpers (QN-NEW-10, Low)

**Files:**

- Create: `src/propagation/percent.zig` exporting `percentEncode`, `percentDecode`, `isUnreserved`, `hexUpper`, `nibble`.
- Modify: `src/propagation/jaeger.zig:266-305`, `src/propagation/baggage.zig:64-112` to import from it; remove duplicates.
- Test: existing `test/baggage.zig` + `test/propagator_jaeger.zig` stay green (refactor); add one round-trip unit test for `percent.zig`.

- [ ] **Step 1:** Create `percent.zig` with the canonical implementations (copy the existing, identical bodies). **Step 2:** Replace duplicates with imports. **Step 3:** Add a `percentEncode∘percentDecode` round-trip test in `test/baggage.zig`. **Step 4:** `zig build test` PASS. **Step 5: Commit** `refactor(propagation): extract shared percent-codec (QN-NEW-10)`.

### Task D3: Fix Jaeger firehose doc comment + drop unused re-export (QN-NEW-12 + QN-NEW-14, Low)

**Files:** Modify `src/propagation/jaeger.zig:15-16` (comment → "bit 3 = firehose (0x08)") and delete `:37` `pub const MapCarrier = ...` (unused; `b3.zig` omits it).

- [ ] **Step 1:** Edit the comment to match `flag_firehose = 0x08` (bit 3). **Step 2:** Confirm `MapCarrier` at `jaeger.zig:37` is unreferenced in `src/` and `test/` (grep), then delete it. **Step 3:** `zig build test` PASS. **Step 4: Commit** `docs(propagation): correct jaeger firehose bit comment; drop unused re-export (QN-NEW-12/14)`.

---

## Batch E — Proto writer & redaction (bounded perf)

Files: `src/generated/otlp.zig`, `src/internal/redact.zig`. Tests: `test/otlp.zig`, `test/security.zig`.

### Task E1: Fast-reject in redact.isSensitive (PN-NEW-7, P2)

**Files:** Modify `src/internal/redact.zig:26-49`. Test: `test/security.zig`.

- [ ] **Step 1:** Confirm semantics-preserving: add an O(1) screen at the top of `isSensitive` (e.g. skip the 512-byte normalize + 6 `indexOf` scans when the key is empty or longer than the longest sensitive token + reasonable margin, or when its lowercased first byte is not in the set of sensitive-token first bytes `{p,s,t,a,c}`). Must NOT change which keys are classified sensitive.
- [ ] **Step 2: Test** — assert the existing redaction test set still classifies every sensitive key as before and every known-non-sensitive key as non-sensitive (extend `test/security.zig` with a table covering `password/secret/token/api_key/apikey/authorization/credential` → masked and `user/host/count/region` → not masked).
- [ ] **Step 3:** Run; expect PASS (behavior identical, faster path).
- [ ] **Step 4: Commit** `perf(redact): O(1) fast-reject before normalize+scan in isSensitive (PN-NEW-7)`.

### Task E2: Pre-size proto Writer buffer + in-place compaction (PN-NEW-3 + PN-NEW-4, P2/P3)

**Files:** Modify `src/generated/otlp.zig:21-23,90-119,139-146`. Test: `test/otlp.zig`.

- [ ] **Step 1:** `ensureTotalCapacity` on `self.buf` at encode entry using a cheap size estimate (e.g. seed from item count when available; otherwise a modest constant) to cut byte-at-a-time realloc churn in `writeVarint`.
- [ ] **Step 2:** Make `toOwnedSlice` compact in place (shift submessage payloads left within `self.buf`, then `buf.toOwnedSlice`) to drop the second full-size buffer + memcpy where feasible; if in-place compaction is too invasive, at least pre-size the destination to avoid grow-reallocs.
- [ ] **Step 3: Test** — existing `test/otlp.zig` wire-parity tests MUST stay byte-identical (this is a perf-only change; correctness unchanged). Add an assertion that a known span batch encodes to the same bytes before/after.
- [ ] **Step 4:** Run `zig build test`; expect PASS, byte-identical output.
- [ ] **Step 5: Commit** `perf(otlp): pre-size encoder buffer, compact in place (PN-NEW-3/4)`.

> Note: PN-NEW-9 (staged packed-field writes) is optional polish; include only if it stays byte-identical and trivially small. Otherwise track it.

---

## Batch F — Tracking-only (record, do not implement here)

Update the gap-analysis docs so a re-review classifies these as known (not new). No code.

- [ ] **PERF_GAP_ANALYSIS.md:** add `PN-NEW-1` (per-export gzip 64 KiB window; couple to PR-4 persistent-client), `PN-NEW-2`+`PN-NEW-8` (collect() per-point AttributeSet deep-clone inside lock; flat-snapshot + off-lock refactor), `PN-NEW-5` (OTLP logs default to per-record sync export; needs `BatchLogRecordProcessor`), `PN-NEW-6`/`PN-NEW-9` (low). Status `triage`, with file:line + cost.
- [ ] **QUALITY_GAP_ANALYSIS.md:** add `QN-NEW-6` (frame/frameGzip production-dead over gRPC; coupled to GAP-OTLP-COMPRESSION #27), `QN-NEW-11` (trace/span ID length validation inconsistent across propagators), `QN-NEW-13` (numeric env vars silently default; no breadcrumb/cross-field validation). Note any inline-test cleanup remaining in `exporter_factory.zig:415-502` (14 tests) + `compression.zig:83-112` (QN-NEW-7 remainder) as a follow-up task.
- [ ] **GAP_ANALYSIS.md:** add `GAP-NEW-4` (gRPC loopback test permanently skipped — no e2e gRPC CI; coupled to upstream grpc-zig HTTP/2 framing). Mark `GAP-BENCH-LOOPBACK-UNDOCUMENTED #112` as closure candidate (docs now present). Record `AS-3` (tls dep version-label mismatch) as a supply-chain hygiene item requiring `zig fetch` re-pin verification (network) + a CI lint asserting `?ref` tag == `hash` version label across pinned deps; record `AS-4` (trace IDs from seeded PRNG — informational) and `AS-5` (plain http allowed — by design) as accepted/known.
- [ ] **SECURITY_GAP_ANALYSIS.md:** record AS-1 closed (link to the Batch A commit), AS-2 closed, and AS-3/AS-4/AS-5 with their dispositions.

---

## Self-Review

- **Spec coverage:** AS-1→A1, AS-2→A2, AS-3→F, AS-4→F, AS-5→F; QN-NEW-1→C1, QN-NEW-2→B3, QN-NEW-3→C3, QN-NEW-4→B1, QN-NEW-5→B2, QN-NEW-6→F, QN-NEW-7→B4+C4+F, QN-NEW-8→C2, QN-NEW-9→D1, QN-NEW-10→D2, QN-NEW-11→F, QN-NEW-12→D3, QN-NEW-13→F, QN-NEW-14→D3; PN-NEW-3/4→E2, PN-NEW-7→E1, PN-NEW-1/2/5/6/8/9→F; GAP-NEW-4→F. All findings mapped.
- **Batch disjointness:** A {config,exporter,otlp_grpc,prometheus}; B {metrics,periodic_metric_reader}; C {logs,std_log,events,encode_logs,encode_proto}; D {propagator,jaeger,baggage,percent}; E {otlp.zig,redact}. No file appears in two batches → safe to run sequentially or isolated.
- **build.zig:** No batch edits `build.zig` (all tests target already-wired test files). New file `src/propagation/percent.zig` is `@import`-ed by existing src files, so it compiles with the module — no build.zig change. New `otlp_codec.zig` (if chosen in C3) likewise imported, not separately wired.
- **Risk note (A1 gRPC):** verify `validateEndpoint` accepts the gRPC endpoint string form before calling; if gRPC stores host:port without scheme, adapt rather than weaken.
