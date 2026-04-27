# Gap-Detector Registry — devnw/zig/otel

> Generated: 2026-04-27
> Phase 3 (gap-detector) canonical output
> Inputs:
>
> - Phase 1: `docs/audit/gap-collector/catalog.{json,csv}` (108 open issues)
> - Phase 2: `docs/audit/gap-scanner/SCAN_RESULTS.md` (5 Implemented / 18 Partial / 73 Not Impl / 12 Unknown)
> Output contract: registry only — no platform mutations. Phase 4 (gap-sync) will reconcile to GitLab.

## Naming convention

Project uses **semantic Gap-IDs** (e.g. `GAP-EXPORTER-FACTORY`) rather than numeric `GAP-NNNN`. New IDs proposed below follow the same convention. Existing 37 `gap`-labelled IIDs already have semantic IDs in `docs/GAP_ANALYSIS.md`.

## Severity model

| Severity | Criteria as applied here |
|----------|--------------------------|
| Critical | OTel spec MUST clause unmet on a primary signal (trace/metric/log) wire path; data loss; security-vuln in production attack surface. |
| High     | OTel spec SHOULD clause unmet, or feature documented as supported but absent (silent misconfig); spec-relevant env var unwired; partial-on-paper retry/back-pressure semantics. |
| Medium   | Quality / maintainability / non-default code paths; vendor-schema gaps; per-signal env vars when transport already works; quality M-tier and PriorityScore 8–18. |
| Low      | Docs, naming, dead code, low-PriorityScore quality, bench-only hardening, upstream-blocked CI. |

Mapping vs catalog labels: `priority::critical → Critical`, `priority::high → High`, `priority::medium → Medium`, `priority::low → Low`. Quality items use `severity::*` labels which were re-checked against the same rubric (no re-grades required).

---

## Final severity histogram (OPEN gaps)

| Severity | Count |
|----------|------:|
| Critical |   5   |
| High     |  12   |
| Medium   |  17   |
| Low      |  20   |
| **Total**| **54**|

> Histogram is the **scanner-corrected** view: it removes the 4 tracker-stale rows (#1, #3, #7 already resolved-and-removed from open, #31 partial-actually-implemented) and adds the 1 new Medium gap (`GAP-DISABLED-TRACER-DOC`) detected in Phase 2. It includes the 37 catalog `gap` items + the 17 highest-impact quality/perf/security items that map 1:1 onto an open gap obligation. Pure perf P1/P2 items remain tracked under `performance` but aren't double-counted as `gap`.

---

## Top 10 OPEN gaps (priority order)

| Rank | Gap-ID | IID | Severity | Status | File:line |
|----:|--------|----:|----------|--------|-----------|
| 1 | GAP-EXPORTER-FACTORY | #4 | Critical | Closed | `src/sdk/exporter_factory.zig` (`Owned{Span,Metric,Log}Exporter` + `{span,metric,log}ExporterFromConfig`); provider helpers `src/sdk/trace.zig:initFromConfig`, `src/sdk/logs.zig:initFromConfig`, `src/sdk/metrics.zig:initFromConfig`; `test/exporter_factory.zig` (22 tests; 199→221 baseline → 248 total) |
| 2 | GAP-OTLP-LOG-EXPORT | #8 | Critical | Closed | `src/exporters/otlp_http/encode_logs.zig` (proto), `encode_json.zig:encodeLogsJson` (JSON), `logs.zig:expLogs` (`/v1/logs`), `exporter.zig:logExporter`; gRPC `src/exporters/otlp_grpc.zig:expLogs`+`logExporter` (`LogsService/Export`); DevNW parity `encode_proto_devnw.zig:encodeLogsProtoDevnw`; `test/otlp_logs_wire.zig` (12 tests) |
| 3 | GAP-OTLP-WIRE-EVENTS-LINKS | #9 | Critical | Not Impl | `src/generated/otlp.zig:191,193` (constants exist, 0 use sites in `src/exporters/`) |
| 4 | Q-METRIC-PIPELINE-HALF-BUILT (#13) | #13 | Critical | Partial | `MetricReader.collect` never invoked — gates #29 |
| 5 | Q-BSP-SCHEDULE-IGNORED (#12) | #12 | Critical | Not Impl | `BatchSpanProcessorOptions.schedule_delay_ms` — wiring landed (`454de77`); verify Phase-4 |
| 6 | GAP-PROPAGATOR-B3 | #23 | High | Closed | `src/propagation/b3.zig` (single + multi header), `src/sdk/config.zig` factory + `b3multi`/`none` env tokens, `src/propagation/propagator.zig` pluggable Composite; `test/propagator_b3.zig` (23 tests) |
| 7 | GAP-PROPAGATOR-JAEGER | #24 | High | Closed | `src/propagation/jaeger.zig` (uber-trace-id + uberctx baggage, URL-encoding), `src/propagation/trace_context.zig` (`Carrier.iter`), `src/sdk/config.zig` factory wiring; `test/propagator_jaeger.zig` (20 tests) |
| 8 | GAP-OTLP-WIRE-SCHEMA-URL | #26 | High | Not Impl | `src/exporters/otlp_http.zig` — 0 hits for `schema_url`; missing field constants |
| 9 | GAP-OTLP-COMPRESSION | #27 | High | Partial — HTTP closed, gRPC body-only | HTTP path fully wired: `src/exporters/otlp_http/compression.zig` (`gzipBody`/`gunzipBody` over Zig 0.16 `std.compress.flate.Compress` with `.gzip` container) + `src/exporters/otlp_http/exporter.zig` (`maybeGzip` helper in `dispatchTransport` gzips the body and appends `content-encoding=gzip` to the headers passed to the transport when `OtlpConfig.compression == .gzip`); `src/exporters/otlp_grpc.zig` `frame()` now takes a `compressed: bool` parameter so callers can emit the wire-correct framing flag, `frameGzip()` integrated helper gzips + frames in one shot, and `unaryExport` forwards `OtlpConfig.compression` into grpc-zig's `client.call` so upstream zlib runs. Re-exported `gzipBody`/`gunzipBody` on `otel.exporters.otlp_http`. Tests: `test/otlp_compression.zig` (8 cases: HTTP `.none` baseline, `.gzip` round-trip, headers merge, 96 KiB payload, empty payload, gRPC `frame(false)`, `frame(true)`, `frameGzip` end-to-end) + 3 inline tests in `otlp_grpc.zig` for `frame()` flag/compressed/`frameGzip` round-trip + 2 inline tests in `compression.zig`. Follow-up: `grpc-encoding: gzip` request metadata header still not set (no upstream API in grpc-zig), and the framing byte emitted by upstream `transport.writeMessage` stays `0` regardless of `client.call`'s algorithm (pre-existing — gRPC loopback already self-skips). |
| 10 | GAP-PERIODIC-METRIC-READER | #29 | High | Closed | `src/sdk/periodic_metric_reader.zig` (`PeriodicMetricReader` with futex-backed `ReaderMutex`/`ReaderCondition` so the reader is build-flag-independent); routes through `MeterProvider.collect()` so PR-1 #135 `InstrumentMutex` is preserved; re-exported as `otel.sdk.periodic_metric_reader`; `test/periodic_metric_reader.zig` (6 tests: interval cadence, force-flush, prompt-shutdown ~89us, observable-counter integration, before-start inline path, in-memory exporter end-to-end). |

(Continuing down: #32 GRPC-STATUS-PROPAGATION-Partial, #33 ENV-BSP, #35 ENV-METRIC-INTERVAL — all High. #30 GAP-OBSERVABLE-INSTRUMENTS now Closed — `src/api/metrics.zig` `Meter.createObservable*`/`registerCallback`/`unregisterCallback` vtable; `src/sdk/metrics.zig` `InstrumentBackend.callbacks` + `invokeCallbacksLocked` invoked at the head of `collect()` under `inst.mu`; `test/observable_instruments.zig`.)

---

## New gaps proposed (NOT in catalog as of Phase 1)

Phase 2 surfaced 4 candidates outside the catalog. After file:line verification only **one** survives as a real gap; the other three reduce to non-issues or are already-tracked.

### GAP-DISABLED-TRACER-DOC — disabled-mode tracer is silent (proposed: Medium, Docs/Code Quality)

- **Phase 2 finding:** `src/sdk/trace.zig:251-252` returns `Tracer{ .scope = scope }` when `build_options.otel_disabled` or `cfg.disabled` is true.
- **Verification:** `src/api/trace.zig:308` declares `startSpanFn = noopStart` as the **default** — so the disabled-mode return is **safe** (calls fall through to noopStart, no null deref). Phase 2 N1 mis-classified this as a critical hazard.
- **Real residual gap:** the disabled-mode contract is undocumented; callers cannot tell from the API whether a span returned by a disabled provider behaves as no-op (it does, but only by virtue of the default `startSpanFn`). Spec-level alignment: OTel SDK §"Disabled SDK" requires no-op semantics — met behaviourally, but not asserted by a test or documented in `docs/SPEC_COMPLIANCE.md`.
- **Severity: Medium** (Code Quality / Test). Fix: add `test "disabled provider returns no-op tracer"` and a one-paragraph note in SPEC_COMPLIANCE.md.
- **Acceptance criteria:** test exercises `cfg.disabled=true` path, asserts `tracer.startSpan()` returns a span whose `state == null`; SPEC_COMPLIANCE.md row for §Disabled SDK cites the test.
- **Recommended Phase-4 action:** open a new GitLab issue; label `gap; quality; priority::medium; type::enhancement`.

### GAP-METRIC-ENCODER-PLACEHOLDERS — REJECTED (not a gap)

- **Phase 2 finding:** `src/exporters/otlp_http.zig:523,559` empty `{}` blocks "unreachable for X-shaped instruments".
- **Verification:** Read of the surrounding switch (lines 515–561) shows the empty arms are switch exhaustiveness padding — `pt.value` is a tagged union and the comment correctly states the alternate tag cannot occur for the dispatching encoder. Behaviour is silent no-op (correct for unreachable arms in proto3 emitters); no UB in safe builds.
- **Disposition:** Not a gap. No new issue.

### GAP-GRPC-BUILD-FLAG-DIAGNOSTIC — REJECTED (already covered by #56)

- **Phase 2 finding:** `src/exporters/otlp_grpc.zig:113-114,169-170` returns `error.UnsupportedTransport` silently when `build_options.use_devnw_grpc=false`.
- **Verification:** Issue **#56** (`P1-10: Retry on UnsupportedTransport (fail-fast for misconfig)`) already tracks this exact diagnostic. The retry loop today retries on `UnsupportedTransport` (line 137) when it should fail-fast.
- **Disposition:** Not a new gap; covered by **#56 (P1-10)**. Already in catalog as `perf::p1`. No new issue.

### GAP-INTEGRATION-STRESS-ALIASING — REJECTED (subsumed by #79)

- **Phase 2 finding:** `build.zig:399,402` keeps `test-integration` and `test-stress` as aliases for `test`.
- **Verification:** Issue **#79** (`GAP-INTEGRATION-SUITE-MISSING`) already tracks this. The "no separate stress matrix" callout is a sub-bullet of the same gap.
- **Disposition:** Not a new gap. No new issue.

> **Net new gaps for Phase 4 (gap-sync):** **1** (GAP-DISABLED-TRACER-DOC, Medium).

---

## Tracker-stale issues recommended for closure

Phase-2 already classified 5 as Implemented-but-tracker-stale; Phase-3 verifies the evidence supports closure for **3 of the 4 functional rows** (#1, #3, #31). #7 was already closed 2026-04-27 (out of `open` set as of Phase-1 collection).

| IID | Gap-ID | Recommended action | Resolution evidence |
|----:|--------|--------------------|---------------------|
| #1  | GAP-INSTRUMENTATION-SCOPE-PROPAGATION | **Close** | `src/sdk/trace.zig:289-296` passes `scope` on both reused and fresh paths; `test/trace.zig:57,83-87` asserts `scope.name == "demo"` / `"lib-a"` plus `version` and `schema_url` round-trip. Title's `:240` line reference is stale (current code path is `:289-296`). |
| #3  | GAP-OTLP-WIRE-INSTRUMENTATION-SCOPE | **Close** (sibling of #1) | `src/exporters/otlp_http.zig:1057-1058` writes `fn_scope_name`/`fn_scope_version` from the now-correct `instrumentation_scope`. Wire-level golden in `test/otlp_wire_parity.zig`. |
| #31 | GAP-REDACT-NOT-WIRED | **Close** | `src/exporters/otlp_http.zig:644,873,1108,1386`, `src/exporters/prometheus.zig:201`, `src/internal/json_codec.zig:173` all invoke `redact.maskString(kv.key, s)`. Already covered by SEC-H-6 closure (commit `0cb9a79`) but the functional `gap` row was not closed in lockstep. |
| #7  | GAP-OTLP-METRIC-EXPORT | (already closed) | Closed 2026-04-27, present in `GAP_ANALYSIS_RESOLVED.md`. |

> **Recommended Phase-4 close candidates:** **3** functional gaps (#1, #3, #31). Each has an explicit test reference and code reference; the gap-sync agent will mark these `state::closed` on GitLab with the evidence above as the closure note.

---

## Updated severity histogram after recommended closures

| Severity | Open after closures |
|----------|--------------------:|
| Critical | 4 (was 5; #1/#3 were Critical-pair; sibling closure removes 2 rows but #13/#12 remain → net −2 +0 → **3**) |
| High     | 11 (was 12; #31 was High → **−1**) |
| Medium   | 18 (was 17; **+1** for new GAP-DISABLED-TRACER-DOC → **18**) |
| Low      | 20 (unchanged) |
| **Total**| **52** |

---

## Artifacts written

| Path | Purpose |
|------|---------|
| `docs/audit/gap-detector/REGISTRY.md` | this canonical Phase-3 registry |
| `docs/audit/gap-detector/SYNC_PLAN.md` | Phase-4 sync plan (separate file, generated alongside) |

The gap-sync agent (Phase 4) will read this REGISTRY.md and SYNC_PLAN.md and produce GitLab mutations only — no further edits to `docs/GAP_ANALYSIS.md` or `docs/GAP_ANALYSIS_RESOLVED.md` happen at Phase 3.
