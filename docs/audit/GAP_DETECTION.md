# otel-zig — Phase 3 Gap Detection (Classified Inventory)

Date: 2026-04-26
Auditor: Phase 3 (gap-detection)
Repo: `gitlab.com/devnw/zig/otel`
Branch: `main`
Source: `docs/audit/GAP_SCAN.md` (Phase 2)
Spec targets: OpenTelemetry Specification 1.56.0, OTLP 1.10.0, Semantic Conventions 1.40.0, Declarative Configuration 1.0.0

## Conventions

- **Gap-IDs are preserved verbatim from Phase 2.** They are stable, descriptive identifiers (e.g. `GAP-OTLP-METRIC-EXPORT`) already in use across `GAP_SCAN.md`, `SECURITY_SCAN.md`, `QUALITY_SCAN.md`, and `PERF_SCAN.md`. Renumbering to a `GAP-XXXX` scheme would orphan those references; gap-sync (Phase 4) should resolve `GAP-XXXX` issue numbers via the GitHub issue tracker, not rename the inventory.
- **Status** uses the codepros gap-analysis taxonomy: `Implemented` / `Partial` / `Not Implemented` / `Unknown`. Phase 2 produced no `Unknown` — every gap has direct file-level evidence.
- **Severity** is assigned from spec impact × operator-visible blast radius × default-build reachability. A gap that silently corrupts wire-shape on the default path outranks a gap reachable only behind an opt-in flag.
- **Effort** estimates: Small ≤ 1 dev-day, Medium ≤ 1 dev-week, Large ≥ 1 dev-week or requires upstream/external work.
- **Spec citations** point to the relevant document sub-section (specification-version + path). All references are to the docs claimed by `docs/SPEC_COMPLIANCE.md`.

---

## Summary

- **Total gaps classified:** 37 distinct Gap-IDs (Phase 2's "29" is a category-aggregate; Phase 2 actually enumerated 37 distinct IDs including paired root-cause/symptom siblings such as `GAP-OTLP-WIRE-INSTRUMENTATION-SCOPE` ↔ `GAP-INSTRUMENTATION-SCOPE-PROPAGATION`).
- **Status:** Partial: 6 | Not Implemented: 30 | Unknown: 0 | Implemented (note-only): 1 (`GAP-DEPRECATED-SPAN-EVENTS-FLAG`)
- **By severity:** Critical: 6 | High: 11 | Medium: 13 | Low: 7
- **Top blockers (Critical):** `GAP-OTLP-METRIC-EXPORT`, `GAP-OTLP-LOG-EXPORT`, `GAP-OTLP-WIRE-EVENTS-LINKS`, `GAP-OTLP-WIRE-INSTRUMENTATION-SCOPE`, `GAP-INSTRUMENTATION-SCOPE-PROPAGATION` (sibling), `GAP-EXPORTER-FACTORY`
- **Default build is clean** (no failing tests, no in-source TODO/FIXME); gaps surface as missing surface area or dead enum values.

### Severity counts by category

| Category | Critical | High | Medium | Low | Total |
|----------|----------|------|--------|-----|-------|
| Spec compliance (wire / propagator) | 4 | 4 | 1 | 0 | 9 |
| Env var family | 0 | 2 | 5 | 3 | 10 |
| Vendor / dependency | 0 | 1 | 4 | 1 | 6 |
| Configuration / wiring | 2 | 4 | 1 | 0 | 7 |
| Build / CI | 0 | 0 | 2 | 3 | 5 |
| **Total** | **6** | **11** | **13** | **7** | **37** |

---

## Gap Priority Matrix

| Severity | Count | Gap-IDs |
|----------|-------|---------|
| **Critical** | 6 | `GAP-OTLP-METRIC-EXPORT`, `GAP-OTLP-LOG-EXPORT`, `GAP-OTLP-WIRE-EVENTS-LINKS`, `GAP-OTLP-WIRE-INSTRUMENTATION-SCOPE`, `GAP-INSTRUMENTATION-SCOPE-PROPAGATION`, `GAP-EXPORTER-FACTORY` |
| **High** | 11 | `GAP-PROPAGATOR-B3`, `GAP-PROPAGATOR-JAEGER`, `GAP-OTLP-PROFILES-EXPORT`, `GAP-OTLP-WIRE-SCHEMA-URL`, `GAP-OTLP-COMPRESSION`, `GAP-PERIODIC-METRIC-READER`, `GAP-OBSERVABLE-INSTRUMENTS`, `GAP-REDACT-NOT-WIRED`, `GAP-GRPC-STATUS-PROPAGATION`, `GAP-ENV-BSP`, `GAP-ENV-METRIC-INTERVAL` |
| **Medium** | 13 | `GAP-VENDOR-PROTO`, `GAP-VENDOR-SEMCONV`, `GAP-SEMCONV-COVERAGE`, `GAP-DEVNW-GRPC-H2C-ONLY`, `GAP-PARTIAL-SUCCESS-PARSE`, `GAP-DECLARATIVE-CONFIG-DEPTH`, `GAP-ENV-OTLP-PER-SIGNAL-PROTOCOL`, `GAP-ENV-OTLP-PER-SIGNAL-TIMEOUT`, `GAP-ENV-OTLP-PER-SIGNAL-HEADERS`, `GAP-ENV-OTLP-PER-SIGNAL-COMPRESSION`, `GAP-ENV-ATTR-LIMITS`, `GAP-BENCH-NOT-WIRED`, `GAP-INTEGRATION-SUITE-MISSING` |
| **Low** | 7 | `GAP-DEVNW-TLS-UNUSED`, `GAP-ENV-OTLP-PER-SIGNAL-INSECURE`, `GAP-ENV-OTLP-MTLS`, `GAP-ENV-BLRP`, `GAP-FUZZ-DISABLED`, `GAP-WINDOWS-TESTS-DISABLED`, `GAP-DEPRECATED-SPAN-EVENTS-FLAG` |

---

## Dependency Graph

```text
GAP-EXPORTER-FACTORY  (Critical, gates many)
   ├─> GAP-OTLP-METRIC-EXPORT     (Critical)
   ├─> GAP-OTLP-LOG-EXPORT        (Critical)
   ├─> GAP-OTLP-PROFILES-EXPORT   (High)
   ├─> per-signal env vars: GAP-ENV-OTLP-PER-SIGNAL-PROTOCOL/TIMEOUT/HEADERS/COMPRESSION/INSECURE
   │   (without a factory, OTEL_*_EXPORTER and per-signal vars cannot affect runtime)
   └─> GAP-PROPAGATOR-B3, GAP-PROPAGATOR-JAEGER
       (OTEL_PROPAGATORS=b3 today picks the enum but no propagator is constructed)

GAP-OTLP-METRIC-EXPORT
   └─> GAP-PERIODIC-METRIC-READER  (no point scheduling collect() if there is no exporter)
   └─> GAP-ENV-METRIC-INTERVAL

GAP-OTLP-LOG-EXPORT
   └─> GAP-ENV-BLRP

GAP-VENDOR-PROTO
   └─> Reproducible regression coverage for GAP-OTLP-METRIC-EXPORT / GAP-OTLP-LOG-EXPORT
       (golden tests that pin wire shape need .proto files)

GAP-VENDOR-SEMCONV
   └─> GAP-SEMCONV-COVERAGE  (a generator needs upstream YAML to expand coverage)

GAP-OBSERVABLE-INSTRUMENTS
   └─> Implicitly needed before GAP-PERIODIC-METRIC-READER can deliver async metrics

GAP-OTLP-WIRE-INSTRUMENTATION-SCOPE  ←→  GAP-INSTRUMENTATION-SCOPE-PROPAGATION
   (sibling pair — same root-cause bug at src/sdk/trace.zig:240; one fix closes both)
   ├─> independent of all other gaps; fix unblocks correct ScopeSpans grouping for any backend
   └─> resolution lets GAP-OTLP-METRIC-EXPORT / GAP-OTLP-LOG-EXPORT inherit the correct scope shape
```

Implementation order recommendation for Phase 4: fix the scope-propagation pair first (one-line bug, closes two Critical Gap-IDs), then `GAP-EXPORTER-FACTORY`, then the per-signal exporters and the per-signal env-var family, then propagators.

---

## Gap Inventory

### Critical

#### GAP-OTLP-METRIC-EXPORT

- **Status:** Not Implemented
- **Severity:** Critical
- **Category:** Feature / Spec compliance
- **Spec citation:** OTLP 1.10.0 §3.1 OTLP/HTTP — `/v1/metrics`; OTLP 1.10.0 §3.2 OTLP/gRPC — `MetricsService/Export`
- **Requirement source:** `docs/SPEC_COMPLIANCE.md` "supports metrics … `/v1/metrics`"
- **Current state (evidence):**
  - `src/exporters/otlp_http.zig` — no `expMetrics`, no `metricExporter()` method on `OtlpHttpExporter`; `/v1/metrics` literal absent.
  - `src/exporters/otlp_grpc.zig` — no `MetricsService/Export` route.
  - Only `spanExporter()` exists on both OTLP transports.
- **Why this is a gap:** `docs/SPEC_COMPLIANCE.md` claims OTLP metric export is supported; code path does not exist. Operators setting `OTEL_METRICS_EXPORTER=otlp` get nothing.
- **User impact:** Metrics are silently dropped — there is no OTLP path. Anyone using this SDK for metric pipelines is collecting data in process and shipping nothing.
- **Effort:** Large (encoder, exporter wrapper for both HTTP and gRPC, golden tests, integration in collector matrix)
- **Dependencies:** Blocks `GAP-PERIODIC-METRIC-READER` and `GAP-ENV-METRIC-INTERVAL`. Needs `GAP-VENDOR-PROTO` for golden coverage. Resolution requires `GAP-EXPORTER-FACTORY` to be wired so the exporter can be picked from config.
- **Recommended fix:** Add `encodeMetricsProto`/`encodeMetricsJson`, an `expMetrics` send path mirroring `expSpans`, and `metricExporter()` on both OTLP transports. Add `/v1/metrics` and `MetricsService/Export` route constants.
- **Acceptance criteria:** Default build emits valid OTLP/HTTP `ExportMetricsServiceRequest` bytes for Counter/UpDown/Histogram/Gauge; golden test pins protobuf field-numbers; live collector accepts the payload (extend `otlp-integration-live` job).

#### GAP-OTLP-LOG-EXPORT

- **Status:** Not Implemented
- **Severity:** Critical
- **Category:** Feature / Spec compliance
- **Spec citation:** OTLP 1.10.0 §3.1 — `/v1/logs`; OTLP 1.10.0 §3.2 — `LogsService/Export`
- **Requirement source:** `docs/SPEC_COMPLIANCE.md` "supports logs … `/v1/logs`"
- **Current state (evidence):**
  - `src/exporters/otlp_http.zig` — no `expLogs`, no `logExporter()`.
  - `src/exporters/otlp_grpc.zig` — no `LogsService/Export` route.
  - `src/api/logs.zig` + `src/sdk/logs.zig` produce log records with no OTLP sink.
- **Why this is a gap:** Same shape as `GAP-OTLP-METRIC-EXPORT`. The Logs API and SDK exist end-to-end, but there is no OTLP egress.
- **User impact:** Structured logs created via `Logger.emit` cannot reach an OTLP collector at all; users either lose the data or have to write a custom sink.
- **Effort:** Medium (smaller payload than metrics; reuses the OTLP transport scaffolding)
- **Dependencies:** Same as above — blocks `GAP-ENV-BLRP`. Requires `GAP-EXPORTER-FACTORY`.
- **Recommended fix:** Add `encodeLogsProto`/`encodeLogsJson`, `logExporter()` on both OTLP transports. Wire severity_number/severity_text/body/attributes/timestamps per OTLP 1.10.0.
- **Acceptance criteria:** Round-trip test: emit a log via `Logger.emit`, encode to OTLP, decode back, asserting all fields are preserved.

#### GAP-OTLP-WIRE-EVENTS-LINKS

- **Status:** Not Implemented
- **Severity:** Critical
- **Category:** Bug / Spec compliance
- **Spec citation:** OTLP 1.10.0 `trace.proto` `Span.events` (field 11), `Span.links` (field 13)
- **Requirement source:** OTLP wire-shape contract; `src/generated/otlp.zig:159-162` reserves the field numbers expecting them to be written.
- **Current state (evidence):**
  - `src/exporters/otlp_http.zig:230-289` — `encodeSpansProto` writes attributes, status, timestamps, parent_span_id; never writes `fn_span_events` or `fn_span_links`.
  - `src/internal/json_codec.zig` `spanToJson` — same omission on the JSON side.
  - `src/generated/otlp.zig:159-162` — field numbers `fn_span_events=11`, `fn_span_links=13` defined but referenced only here.
- **Why this is a gap:** Span events and links are core OTLP fields; `Span.addEvent` (gated behind `-Ddeprecated_span_events`) and `Span.addLink` are exposed in the public API but never make it to the wire. Backends never see them.
- **User impact:** Distributed traces lose all event annotations and cross-trace links. Debug info captured at the span site disappears between SDK and collector.
- **Effort:** Small (encoder additions in two functions; field numbers already defined)
- **Dependencies:** Independent. After fix, `GAP-DEPRECATED-SPAN-EVENTS-FLAG` becomes the only blocker for end-to-end events on the default build.
- **Recommended fix:** Extend `encodeSpansProto` and `spanToJson` to emit `events` (name, time_unix_nano, attributes, dropped_count) and `links` (trace_id, span_id, trace_state, attributes, dropped_count, flags).
- **Acceptance criteria:** Golden test in `test/otlp.zig` asserting protobuf bytes for a span with one event and one link match canonical output (decoded via vendored .proto once `GAP-VENDOR-PROTO` lands, or hand-built bytes until then).

#### GAP-OTLP-WIRE-INSTRUMENTATION-SCOPE

- **Status:** Not Implemented (effectively a regression — assigned but immediately overwritten)
- **Severity:** Critical
- **Category:** Bug
- **Spec citation:** OTLP 1.10.0 `common.proto` `InstrumentationScope`; OTLP 1.10.0 `trace.proto` `ScopeSpans.scope`
- **Requirement source:** OpenTelemetry Specification 1.56.0 — Tracer Provider §"InstrumentationScope identifies an instrumentation library uniquely"
- **Current state (evidence):**
  - `src/sdk/trace.zig:235` — `var state = try trace_api.SpanState.init(self.allocator, name, sc, .{ .name = "" }, start_ns);` (correctly threads scope, but with empty name placeholder)
  - `src/sdk/trace.zig:240` — `state.instrumentation_scope = .{ .name = "" };` overwrites whatever was set above with an explicit blank — and the comment on line 239 says "Attach scope from the caller's tracer."
  - `src/exporters/otlp_http.zig:248-249` — `try w.writeString(otlp.fn_scope_name, items[0].instrumentation_scope.name);` therefore always writes "" for `scope.name`.
- **Why this is a gap:** Bug — the line is the inverse of what the comment claims and what the spec requires. Every span in OTLP wire output reports `scope.name == ""`, breaking the standard backend assumption that `scope.name == library name`.
- **User impact:** Backends that group/route by instrumentation scope (every major collector and most observability vendors do) collapse all spans into one anonymous bucket. Library attribution is impossible.
- **Effort:** Small (one-line fix: `state.instrumentation_scope = self.scope;` or equivalent — verify the field path)
- **Dependencies:** None; trivially fixable. Resolution corrects scope shape for any subsequent metric/log exporter that copies the trace pattern.
- **Recommended fix:** Replace `src/sdk/trace.zig:240` with assignment from the tracer's stored scope (`self.instrumentation_scope` or whatever the field is called on the parent Tracer). Confirm `Tracer` actually carries name/version through `getTracer`.
- **Acceptance criteria:** A test that creates `tracerProvider.getTracer("foo", "1.2.3")`, starts and ends a span, and asserts `encodeSpansProto` output decodes to `scope.name=="foo"` and `scope.version=="1.2.3"`.

#### GAP-INSTRUMENTATION-SCOPE-PROPAGATION

- **Status:** Not Implemented (sibling of `GAP-OTLP-WIRE-INSTRUMENTATION-SCOPE`)
- **Severity:** Critical
- **Category:** Bug / Configuration / Wiring
- **Spec citation:** OpenTelemetry Specification 1.56.0 — Tracer §"Tracer is associated with an InstrumentationScope (name + version + schema_url)"
- **Requirement source:** `Tracer.getTracer(name, version, schema_url)` API contract
- **Current state (evidence):**
  - `src/sdk/trace.zig:235-240` — Span init receives a placeholder scope `.{ .name = "" }` and is then *re-overwritten* by line 240's `state.instrumentation_scope = .{ .name = "" };` instead of being assigned `self.scope` from the parent `Tracer`.
  - The Tracer struct holds the scope; the line never reads from it.
- **Why this is a gap:** This is the *propagation* side of `GAP-OTLP-WIRE-INSTRUMENTATION-SCOPE`. They are tracked separately because:
  - The propagation bug (this gap) is the root cause — the Tracer's scope never reaches the SpanState.
  - The wire bug (the sibling) is the visible symptom — the OTLP encoder writes `""`.
  - Either fix lives in the same line (`src/sdk/trace.zig:240`); resolving this gap automatically resolves the sibling. Phase 4 should treat them as one issue with two visible failure modes.
- **User impact:** Same as `GAP-OTLP-WIRE-INSTRUMENTATION-SCOPE` — every span loses its library attribution.
- **Effort:** Small (one-line fix; same line as the sibling)
- **Dependencies:** None. Trivial. This and `GAP-OTLP-WIRE-INSTRUMENTATION-SCOPE` should be closed together.
- **Recommended fix:** Replace `src/sdk/trace.zig:240` with assignment from the tracer's scope (`state.instrumentation_scope = self.scope;`).
- **Acceptance criteria:** Test creating `tracerProvider.getTracer("foo", "1.2.3").startSpan(...)` and asserting `span.state.instrumentation_scope.name == "foo"` and `.version == "1.2.3"` *before* OTLP encoding; the wire-side test under `GAP-OTLP-WIRE-INSTRUMENTATION-SCOPE` then passes for free.

#### GAP-EXPORTER-FACTORY

- **Status:** Not Implemented
- **Severity:** Critical
- **Category:** Feature / Configuration
- **Spec citation:** OpenTelemetry Specification 1.56.0 — Configuration §"`OTEL_TRACES_EXPORTER`/`OTEL_METRICS_EXPORTER`/`OTEL_LOGS_EXPORTER` MUST select the configured exporter"
- **Requirement source:** OpenTelemetry env-var convention; Declarative Configuration 1.0.0 (exporter selection from YAML)
- **Current state (evidence):**
  - `src/sdk/config.zig:14-31` — `ExporterKind` enum + `fromString` parser exist.
  - `src/sdk/config.zig:142-150` — env vars set the enum value.
  - No `factoryFor(kind: ExporterKind, ...) !*Exporter` function exists anywhere in `src/sdk/` or `src/exporters/`.
  - Examples (`examples/basic.zig`, `examples/http_client.zig`) wire exporters by hand.
- **Why this is a gap:** The whole point of `OTEL_TRACES_EXPORTER` is that a deployment can swap between `otlp`, `console`, `none`, etc. without recompiling. Today the env var sets a parsed enum nobody reads.
- **User impact:** Operator sets `OTEL_TRACES_EXPORTER=otlp`, no exporter is created. Span data is dropped silently. Default-build behavior contradicts every spec-compliant SDK.
- **Effort:** Medium (factory functions for spans now; for metrics/logs once their exporters land)
- **Dependencies:** Blocks effective use of all per-signal exporter and endpoint env vars. Required by `GAP-OTLP-METRIC-EXPORT` and `GAP-OTLP-LOG-EXPORT` for any wire-up that respects config.
- **Recommended fix:** Add `pub fn buildExporter(allocator, signal: Signal, kind: ExporterKind, otlp: OtlpConfig, io: ?Io) !ExporterUnion` (or per-signal helpers). Wire it into `TracerProvider.init`/`MeterProvider.init`/`LoggerProvider.init` so providers consume `Config` and create exporters.
- **Acceptance criteria:** A test that sets `OTEL_TRACES_EXPORTER=otlp` + endpoint env, calls the standard provider builder, ends a span, and asserts the OTLP transport received the span.

---

### High

#### GAP-PROPAGATOR-B3

- **Status:** Not Implemented
- **Severity:** High
- **Category:** Feature / Spec compliance
- **Spec citation:** OpenTelemetry Specification 1.56.0 — Context Propagation §"`b3` and `b3multi` MUST be implementable" (B3 is in the propagator MUST list for cross-language interop)
- **Requirement source:** `OTEL_PROPAGATORS=b3` is a documented value; `src/sdk/config.zig:84,185` accepts it
- **Current state (evidence):**
  - `src/sdk/config.zig:84` — `propagator: enum { tracecontext, baggage, b3, jaeger, composite }` — `b3` enum value present
  - `src/sdk/config.zig:185` — `if (std.mem.eql(u8, v, "b3")) cfg.propagator = .b3;`
  - No `src/propagation/b3.zig` file. `composite.zig:22-39` only composes tracecontext + baggage.
- **Why this is a gap:** Setting `OTEL_PROPAGATORS=b3` parses cleanly but produces no functional propagator at runtime — operators get a silent fall-through to whichever default the call-site uses.
- **User impact:** Cross-service correlation with B3-emitting peers (Zipkin, legacy Spring Cloud Sleuth, many service meshes) is impossible. Trace context is lost on every hop.
- **Effort:** Medium (`b3` single-header + `b3multi` multi-header; spec is well-defined)
- **Dependencies:** None; can land independently. Resolution is a precondition for `OTEL_PROPAGATORS=b3` to do anything (and indirectly clears the way for `GAP-EXPORTER-FACTORY` to wire propagators from config).
- **Recommended fix:** Add `src/propagation/b3.zig` with `B3Propagator` (single + multi header forms). Wire it into a propagator factory similar to the exporter factory.
- **Acceptance criteria:** Round-trip injection/extraction test against fixtures from openzipkin/b3-propagation README.

#### GAP-PROPAGATOR-JAEGER

- **Status:** Not Implemented
- **Severity:** High
- **Category:** Feature / Spec compliance
- **Spec citation:** OpenTelemetry Specification 1.56.0 — Context Propagation §"jaeger propagator"
- **Current state (evidence):** `src/sdk/config.zig:84,186` — enum value + env-var handling but no `src/propagation/jaeger.zig`
- **Why this is a gap:** Same shape as B3.
- **User impact:** `uber-trace-id` headers from Jaeger-instrumented upstreams are dropped on extraction.
- **Effort:** Medium (single-header format; documented at jaegertracing.io)
- **Dependencies:** Same factory wiring as `GAP-PROPAGATOR-B3`.
- **Recommended fix:** Add `src/propagation/jaeger.zig` with `uber-trace-id` parser/serializer.
- **Acceptance criteria:** Round-trip test against canonical Jaeger header fixtures.

#### GAP-OTLP-PROFILES-EXPORT

- **Status:** Not Implemented
- **Severity:** High (Critical-adjacent — but profiles are spec-development, downgraded)
- **Category:** Feature / Spec compliance
- **Spec citation:** OTLP 1.10.0 development — `/v1development/profiles`, `pprofile/profiles.proto`
- **Requirement source:** `docs/SPEC_COMPLIANCE.md` claims `/v1development/profiles` path support
- **Current state (evidence):**
  - `src/api/profiles.zig:53-66` — `noopEmit` returns `error.UnsupportedTransport` even with `-Dotel_profiles=true`
  - No exporter path; OTLP exporters have no `profileExporter()`
- **Why this is a gap:** The doc claim is unsupported by code. The API stub itself returns the error message reserved for transport gating.
- **User impact:** Operators enabling profiles get an error — no path to OTLP collector.
- **Effort:** Large (profiles is still a developing OTLP signal; pprofile encoding + collector compat surface is non-trivial)
- **Dependencies:** Requires `GAP-EXPORTER-FACTORY` and probably `GAP-VENDOR-PROTO` (pprofile.proto) for golden coverage.
- **Recommended fix:** Either implement (encoder + exporter + sample collector route) or downgrade `docs/SPEC_COMPLIANCE.md` to mark profiles as "not supported".
- **Acceptance criteria:** Either OTLP profile bytes accepted by a `/v1development/profiles` endpoint, or the doc is updated and the API surface returns a clear "not yet supported" error rather than `UnsupportedTransport`.

#### GAP-OTLP-WIRE-SCHEMA-URL

- **Status:** Not Implemented
- **Severity:** High
- **Category:** Bug / Spec compliance
- **Spec citation:** OTLP 1.10.0 `trace.proto` `ResourceSpans.schema_url` (field 3); `ScopeSpans.schema_url` (field 3)
- **Requirement source:** Semantic Conventions 1.40.0 schema URL contract; OTLP wire shape
- **Current state (evidence):**
  - `src/generated/otlp.zig:147` — `pub const fn_schema_url = 3;` defined.
  - `src/exporters/otlp_http.zig:230-289` — `encodeSpansProto` never references `fn_schema_url`.
  - `src/sdk/resource.zig` tracks `schema_url`; nothing emits it.
- **Why this is a gap:** Spec mandates schema_url on Resource and Scope so downstream tooling can validate attribute names against a known semantic-conventions release. We track it but never ship it.
- **User impact:** Backends cannot look up which Semantic Conventions version produced the data; schema-aware collectors and dashboards fall back to "unknown" or warn.
- **Effort:** Small (two `writeString` calls in `encodeSpansProto` and the JSON codec)
- **Dependencies:** Independent.
- **Recommended fix:** Emit `fn_schema_url` on `Resource`/`ScopeSpans` from the resource's tracked URL.
- **Acceptance criteria:** Golden test: set `Resource.schema_url`, encode spans, assert the field appears in the protobuf bytes and JSON output.

#### GAP-OTLP-COMPRESSION

- **Status:** Not Implemented
- **Severity:** High
- **Category:** Feature / Performance
- **Spec citation:** OTLP 1.10.0 §3.1 OTLP/HTTP — "MAY support `gzip`"; gRPC §3.2 — `compressed=1` byte semantics
- **Requirement source:** `OtlpConfig.compression` enum + `OTEL_EXPORTER_OTLP_COMPRESSION` env var
- **Current state (evidence):**
  - `src/sdk/config.zig:52` — `compression: enum { none, gzip }` declared
  - `src/exporters/otlp_http.zig` — gzip encoder never invoked, no `Content-Encoding: gzip` header
  - `src/exporters/otlp_grpc.zig:198-201` — `out[0] = 0;` hard-coded compression byte
- **Why this is a gap:** The config field exists; no encoder applies it. Network bandwidth on large span batches is wasted.
- **User impact:** Operators setting `OTEL_EXPORTER_OTLP_COMPRESSION=gzip` see no behavioural change. Egress bills for trace data are 5-10× higher than they need to be.
- **Effort:** Medium (need a gzip encoder — std.compress in 0.16, or a vendored impl; plus gRPC-message-flag wire bit)
- **Dependencies:** Couples with `GAP-ENV-OTLP-PER-SIGNAL-COMPRESSION` for full env-var coverage.
- **Recommended fix:** Add gzip path in `expSpans` (and future metric/log paths). Set `Content-Encoding: gzip` for HTTP. For gRPC, encode body with gzip and set the leading compression flag byte.
- **Acceptance criteria:** Round-trip test: encode spans with compression, send to a test server, assert the decompressed body matches the uncompressed encoder output byte-for-byte.

#### GAP-PERIODIC-METRIC-READER

- **Status:** Not Implemented
- **Severity:** High
- **Category:** Feature
- **Spec citation:** OpenTelemetry Specification 1.56.0 — Metrics SDK §"PeriodicExportingMetricReader"
- **Requirement source:** `MetricsConfig.interval_ms = 60_000` documented default
- **Current state (evidence):**
  - `src/sdk/metrics.zig:31-47` — `MetricReader` vtable exists; `interval_ms` field present; no scheduler thread/timer.
  - Caller must invoke `collect()` manually.
- **Why this is a gap:** Periodic export is the default for SDK metrics in spec; without it, metrics only flush when shutdown is called or test harness drives `collect()`.
- **User impact:** Long-running services emit no metrics until they shut down — i.e. never. Operators see "instrument exists, no data points reach collector".
- **Effort:** Medium (timer thread + cancellation; existing `BatchSpanProcessor` async path provides a template)
- **Dependencies:** Blocked by `GAP-OTLP-METRIC-EXPORT` (no point scheduling exports if there is no exporter); coupled with `GAP-ENV-METRIC-INTERVAL` for runtime tuning.
- **Recommended fix:** Add `PeriodicReader` that wraps an exporter, runs `collect()` on `interval_ms` cadence (similar gating as the async batch processor), and respects `OTEL_METRIC_EXPORT_INTERVAL`/`_TIMEOUT`.
- **Acceptance criteria:** Test that drives a `PeriodicReader` with a mocked clock, asserts `collect()` is called every interval, and shutdown drains pending data.

#### GAP-OBSERVABLE-INSTRUMENTS

- **Status:** Not Implemented
- **Severity:** High
- **Category:** Feature
- **Spec citation:** OpenTelemetry Specification 1.56.0 — Metrics API §"createObservableCounter/UpDownCounter/Gauge"
- **Requirement source:** API surface; `ObservableCallback` type already declared
- **Current state (evidence):**
  - `src/api/metrics.zig:76-79` — `ObservableCallback` type defined.
  - `src/api/metrics.zig:81-89` — `Observer` struct with `observeIntFn`/`observeDoubleFn`.
  - `Meter` has no `register*Observer`/`createObservable*` API.
  - `src/sdk/metrics.zig` `collect()` never invokes any callback.
- **Why this is a gap:** The async metric-collection pattern is unimplemented despite the type scaffolding being present. Async observers (CPU%, memory, queue depth) cannot be registered.
- **User impact:** Cannot instrument pull-style metrics — system gauges, queue lengths, on-demand counters are unavailable.
- **Effort:** Medium (Meter registration API + storage of callbacks + collect()-time invocation)
- **Dependencies:** Pairs with `GAP-PERIODIC-METRIC-READER` to deliver async data into the export pipeline.
- **Recommended fix:** Add `Meter.createObservableCounter/UpDownCounter/Gauge(name, unit, description, callback, user_ctx)`. Store callbacks on the Meter. `MetricReader.collect()` walks all registered callbacks and produces observation points.
- **Acceptance criteria:** Test that registers an observable gauge returning a counter value, calls `collect()`, and asserts the produced data point matches the callback's most recent value.

#### GAP-REDACT-NOT-WIRED

- **Status:** Partial / Not Wired
- **Severity:** High
- **Category:** Security / Configuration
- **Spec citation:** OpenTelemetry Specification 1.56.0 — Common §"SDK SHOULD provide a way to redact sensitive attribute values" (recommended practice; not a MUST but the helper exists already)
- **Requirement source:** `src/internal/redact.zig` constants list (`password/secret/token/api.key/authorization/credential`); also referenced in `docs/SPEC_COMPLIANCE.md` and `SECURITY_SCAN.md`
- **Current state (evidence):**
  - `src/internal/redact.zig:53` — `isSensitive` and `maskString` helpers exist.
  - Only caller: `tools/golden.zig:155`.
  - No exporter path (HTTP/gRPC/file/stdout) and no attribute-set writer invokes redaction.
- **Why this is a gap:** Redaction surface exists but is not wired into the egress pipeline. Sensitive values placed into spans, logs, or attributes by application code are exported verbatim.
- **User impact:** Application that includes `password=...` or an `Authorization: Bearer ...` attribute on a span ships it to every downstream collector and any log file. PII / credential leakage is a real production risk.
- **Effort:** Small (call site is the attribute-writer for OTLP encoders; gate on a config flag if back-compat matters)
- **Dependencies:** Independent of other gaps; touches every encoder once landed.
- **Recommended fix:** Add a config flag `Redaction.enabled` (default true). In `writeKeyValue` (and equivalent for JSON / stdout / file), call `redact.maskString` when `redact.isSensitive(kv.key)` is true.
- **Acceptance criteria:** Test that sets a span attribute named `authorization=Bearer abc123`, encodes via OTLP, decodes, and asserts the value is masked.

#### GAP-GRPC-STATUS-PROPAGATION

- **Status:** Partial
- **Severity:** High
- **Category:** Bug / Observability
- **Spec citation:** gRPC HTTP/2 spec — `grpc-status` trailer; OTLP 1.10.0 §3.2 "non-OK gRPC status maps to retry behavior"
- **Requirement source:** gRPC protocol; OTLP retry contract
- **Current state (evidence):**
  - `src/exporters/otlp_grpc.zig:185-190` — comment reads: "grpc-zig's client surfaces neither the trailers nor the `grpc-status` value — `call()` either returns the response bytes or errors. A clean return therefore implies status OK".
- **Why this is a gap:** gRPC-level rejections (RESOURCE_EXHAUSTED, UNAVAILABLE, INTERNAL) are not visible to the retry loop. Only IO-layer errors trigger the `RetryPolicy`. A successful HTTP/2 stream that the server rejected via `grpc-status: 8` is treated as success.
- **User impact:** Lost telemetry: server-side back-pressure (RESOURCE_EXHAUSTED) reads as success; the client doesn't retry; the data is dropped. Debugging connection-tier issues is opaque.
- **Effort:** Large (requires upstream change in DevNW grpc-zig to surface trailers — or a temporary fix to read trailers via the underlying h2 client)
- **Dependencies:** Upstream `devnw/grpc-zig` change. Track as an upstream issue.
- **Recommended fix:** File issue against grpc-zig to surface trailers; once available, parse `grpc-status` and `grpc-message`, map to retryable/non-retryable per OTLP spec.
- **Acceptance criteria:** Test that boots an in-process gRPC server returning `grpc-status: 14 UNAVAILABLE` and asserts the OTLP exporter retries.

#### GAP-ENV-BSP

- **Status:** Not Implemented
- **Severity:** High
- **Category:** Configuration / Spec compliance
- **Spec citation:** OpenTelemetry Specification 1.56.0 — SDK Environment Variables §"BatchSpanProcessor": `OTEL_BSP_MAX_QUEUE_SIZE`, `OTEL_BSP_SCHEDULE_DELAY`, `OTEL_BSP_MAX_EXPORT_BATCH_SIZE`, `OTEL_BSP_EXPORT_TIMEOUT`
- **Requirement source:** `BatchSpanProcessorOptions` struct exists; spec env vars do not flow into it
- **Current state (evidence):** `src/sdk/config.zig:122-188` does not parse any `OTEL_BSP_*` var.
- **Why this is a gap:** Spec-mandated tunables for the default batching processor are unreachable from operator-controlled env. Production workloads cannot tune queue depth or schedule delay without a recompile.
- **User impact:** Operator hits queue overflow under load; cannot increase queue size without code change. Standard OTel ops playbooks don't apply.
- **Effort:** Small (four env-var reads into existing struct)
- **Dependencies:** None.
- **Recommended fix:** In `applyEnv`, read the four `OTEL_BSP_*` vars into a `BatchSpanProcessorOptions` field on Config. Provider builders pass the options through.
- **Acceptance criteria:** Test setting `OTEL_BSP_MAX_QUEUE_SIZE=2048` and asserting the resulting processor's queue size matches.

#### GAP-ENV-METRIC-INTERVAL

- **Status:** Not Implemented
- **Severity:** High
- **Category:** Configuration / Spec compliance
- **Spec citation:** OpenTelemetry Specification 1.56.0 — SDK Environment Variables §"PeriodicExportingMetricReader": `OTEL_METRIC_EXPORT_INTERVAL` (default 60000 ms), `OTEL_METRIC_EXPORT_TIMEOUT` (default 30000 ms)
- **Current state (evidence):** `src/sdk/config.zig:122-188` does not read either var; `interval_ms` field is set in code only.
- **Why this is a gap:** Spec env vars for the metric export cadence are not honored.
- **User impact:** Operators cannot tune metric export cadence per environment; default builds collect data too often (or not at all once `GAP-PERIODIC-METRIC-READER` lands).
- **Effort:** Small (two env-var reads)
- **Dependencies:** Functional only after `GAP-PERIODIC-METRIC-READER` is implemented. Until then this is a no-op fix.
- **Recommended fix:** Read both vars into `MetricsConfig`; the periodic reader consumes them.
- **Acceptance criteria:** Test setting `OTEL_METRIC_EXPORT_INTERVAL=5000` and asserting the reader's interval matches.

---

### Medium

#### GAP-VENDOR-PROTO

- **Status:** Not Implemented
- **Severity:** Medium
- **Category:** Vendor / Test infrastructure
- **Spec citation:** OTLP 1.10.0 — `*.proto` schemas (opentelemetry-proto repo, v1.10.0 tag)
- **Requirement source:** `third_party/opentelemetry-proto-v1.10.0/` directory exists with intent to vendor schemas
- **Current state (evidence):** `ls third_party/opentelemetry-proto-v1.10.0/` returns LICENSE only; no `.proto` files.
- **Why this is a gap:** Without vendored .proto files, golden tests cannot decode wire bytes against the canonical schema. Today's tests assert on field-numbers we wrote ourselves — circular.
- **User impact:** Wire-shape regressions can land silently. Phase-4 reviewer cannot verify changes against canonical proto.
- **Effort:** Small (vendor the schemas; maybe Medium if a small `protoc`-style decoder is added for tests)
- **Dependencies:** Strongly enables higher-confidence acceptance for `GAP-OTLP-METRIC-EXPORT`, `GAP-OTLP-LOG-EXPORT`, `GAP-OTLP-WIRE-EVENTS-LINKS`, `GAP-OTLP-WIRE-SCHEMA-URL`, `GAP-OTLP-PROFILES-EXPORT`.
- **Recommended fix:** Vendor opentelemetry-proto v1.10.0 contents under `third_party/opentelemetry-proto-v1.10.0/`. Consider a small Zig proto decoder for golden assertions, or a build-time `protoc` invocation behind an off-by-default flag.
- **Acceptance criteria:** `.proto` files present; at least one golden test references them (e.g., decodes `encodeSpansProto` output and asserts a structured field).

#### GAP-VENDOR-SEMCONV

- **Status:** Not Implemented
- **Severity:** Medium
- **Category:** Vendor
- **Spec citation:** Semantic Conventions 1.40.0 — YAML schema repository
- **Current state (evidence):** `ls third_party/semantic-conventions-v1.40.0/` returns LICENSE only.
- **Why this is a gap:** No upstream YAML to drive a `weaver`-style codegen; coverage of `src/generated/semconv.zig` is a hand-curated subset.
- **User impact:** New attributes from spec releases require manual code edits. Easy to drift out of sync.
- **Effort:** Small (vendor the YAML); Large if a generator is wired
- **Dependencies:** Required by `GAP-SEMCONV-COVERAGE` for sustainable expansion.
- **Recommended fix:** Vendor the upstream `model/` YAML tree at the v1.40.0 tag. Optionally wire `weaver` (or a small Zig codegen) under `tools/`.
- **Acceptance criteria:** YAML present; CI fails if `src/generated/semconv.zig` is out of sync with the vendored schemas.

#### GAP-SEMCONV-COVERAGE

- **Status:** Partial
- **Severity:** Medium
- **Category:** Spec compliance
- **Spec citation:** Semantic Conventions 1.40.0 stable surface (DB, RPC, messaging, GenAI, k8s, cloud, container, FaaS, browser, code, deployment, gRPC, GraphQL, …)
- **Current state (evidence):** `src/generated/semconv.zig:1-103` — ~60 attributes across 11 groupings.
- **Why this is a gap:** "Constants generated" claim in `docs/SPEC_COMPLIANCE.md` over-states what exists. Spec stable surface is hundreds of attributes.
- **User impact:** Library users hand-stringify standard attribute names (`http.request.method`, `db.system.name`, `rpc.system`, etc.) for anything not in the curated subset; typos drift from the spec; backends cannot match.
- **Effort:** Large (depends on `GAP-VENDOR-SEMCONV` + a generator). Low priority versus the wire-shape Critical bugs.
- **Dependencies:** Blocked by `GAP-VENDOR-SEMCONV`.
- **Recommended fix:** After vendoring schemas, add a code generator (Zig-native, or `weaver`) and regenerate `src/generated/semconv.zig` against v1.40.0 stable. Document the regen command in README.
- **Acceptance criteria:** `src/generated/semconv.zig` covers all attribute groups marked stable in v1.40.0; CI fails on regeneration drift.

#### GAP-DEVNW-GRPC-H2C-ONLY

- **Status:** Partial
- **Severity:** Medium
- **Category:** Vendor / Security
- **Spec citation:** OTLP 1.10.0 §3.2 "OTLP/gRPC: TLS strongly recommended for production"
- **Current state (evidence):**
  - `src/exporters/otlp_grpc.zig:131-149` — `OtlpConfig.endpoint` parser strips the scheme.
  - `docs/DEPENDENCIES.md` "gRPC row" — h2c-only.
- **Why this is a gap:** Production OTLP collectors run TLS; h2c-only restricts the gRPC exporter to internal/dev environments.
- **User impact:** Cannot point the gRPC exporter at any production collector that requires TLS.
- **Effort:** Large (requires TLS-wrapped gRPC support upstream in `devnw/grpc-zig`)
- **Dependencies:** Upstream feature in `devnw/grpc-zig`. Document the limitation and provide HTTP+TLS as the production path until landed.
- **Recommended fix:** Track upstream, document clearly in README/SPEC_COMPLIANCE that gRPC is dev-only. Recommend OTLP/HTTP for production.
- **Acceptance criteria:** Either gRPC over TLS works against a real collector, or doc clearly states gRPC is h2c-only and HTTP is the supported production transport.

#### GAP-PARTIAL-SUCCESS-PARSE

- **Status:** Partial
- **Severity:** Medium
- **Category:** Bug / Observability
- **Spec citation:** OTLP 1.10.0 §"Partial Success" — `ExportTracePartialSuccess.rejected_spans`, `error_message`
- **Current state (evidence):**
  - `src/exporters/otlp_http.zig:216` — 207 mapped to `error.PartialSuccess`.
  - Body captured into `last_response_body`; not parsed for `rejected_*_count`.
- **Why this is a gap:** Caller cannot retry only the rejected items, nor surface the error message to operators. Today every partial-success looks like a uniform failure.
- **User impact:** When a collector partially rejects a batch (e.g., one malformed span), the SDK has no way to selectively retry; the whole batch is treated as failed.
- **Effort:** Small (parse the proto body into `rejected_spans: u64` and `error_message: []const u8`)
- **Dependencies:** Cleaner once `GAP-VENDOR-PROTO` lands.
- **Recommended fix:** Add `decodePartialSuccess(body) !PartialSuccessInfo`; surface counts via the public exporter API.
- **Acceptance criteria:** Test that mocks a 207 with a body containing `rejected_spans=3, error_message="bad span"` and asserts the parsed values.

#### GAP-DECLARATIVE-CONFIG-DEPTH

- **Status:** Partial
- **Severity:** Medium
- **Category:** Spec compliance
- **Spec citation:** Declarative Configuration 1.0.0 — full YAML tree shape
- **Current state (evidence):** `src/sdk/config.zig:222-287` (in-repo loader) handles top-level + one nested mapping; no anchors, multi-doc, or flow nodes.
- **Why this is a gap:** Real declarative config files have deep trees (samplers, processors, processor options, resource detectors, attribute limits). Today's loader rejects most published examples.
- **User impact:** Operators cannot use spec-compliant `otel.yaml` files; have to hand-translate to env vars or Zig structs.
- **Effort:** Medium-Large (full YAML 1.2 support is its own project; the DevNW path partially covers via `:373-486` but is gated on `-Dotel_use_devnw_yaml`)
- **Dependencies:** Optionally rely on the gated DevNW YAML loader; the in-repo loader needs anchors + nesting at minimum.
- **Recommended fix:** Either (a) extend the in-repo loader to cover spec-required tree depth + anchors, or (b) make `-Dotel_use_devnw_yaml=true` the recommended default and document it.
- **Acceptance criteria:** Test against an `otel.yaml` covering tracer_provider/processors/exporters/samplers/resource detectors with a 3-level nested mapping.

#### GAP-ENV-OTLP-PER-SIGNAL-PROTOCOL

- **Status:** Not Implemented
- **Severity:** Medium
- **Category:** Configuration / Spec compliance
- **Spec citation:** OpenTelemetry Specification 1.56.0 — Env Vars §"OTEL_EXPORTER_OTLP_TRACES_PROTOCOL", "OTEL_EXPORTER_OTLP_METRICS_PROTOCOL", "OTEL_EXPORTER_OTLP_LOGS_PROTOCOL"
- **Current state (evidence):** `src/sdk/config.zig:160-166` reads the unprefixed `OTEL_EXPORTER_OTLP_PROTOCOL`; per-signal forms not parsed.
- **Why this is a gap:** Operator cannot set traces=http and metrics=grpc, for instance.
- **User impact:** Mixed-transport deployments (common for staged migrations) cannot be configured by env.
- **Effort:** Small (three env-var reads mirroring lines 160-166)
- **Dependencies:** Per-signal exporters become useful only after `GAP-OTLP-METRIC-EXPORT` and `GAP-OTLP-LOG-EXPORT` land.
- **Recommended fix:** Read three per-signal vars into the per-signal `OtlpConfig` rather than the shared one.
- **Acceptance criteria:** Test setting `OTEL_EXPORTER_OTLP_TRACES_PROTOCOL=grpc` and `OTEL_EXPORTER_OTLP_METRICS_PROTOCOL=http/protobuf` resolves to two different transports.

#### GAP-ENV-OTLP-PER-SIGNAL-TIMEOUT

- **Status:** Not Implemented
- **Severity:** Medium
- **Category:** Configuration / Spec compliance
- **Spec citation:** OpenTelemetry Specification 1.56.0 — Env Vars §"OTEL_EXPORTER_OTLP_{TRACES,METRICS,LOGS}_TIMEOUT"
- **Current state (evidence):** `src/sdk/config.zig:167-174` reads only the unprefixed form.
- **Why this is a gap:** Per-signal SLOs vary; same issue as protocol.
- **User impact:** Cannot give metrics a 30s timeout while keeping logs at 5s, etc.
- **Effort:** Small
- **Dependencies:** Same as above.
- **Recommended fix:** Mirror lines 167-174 with three per-signal reads.
- **Acceptance criteria:** Test setting per-signal timeouts independently.

#### GAP-ENV-OTLP-PER-SIGNAL-HEADERS

- **Status:** Not Implemented
- **Severity:** Medium
- **Category:** Configuration / Spec compliance
- **Spec citation:** OpenTelemetry Specification 1.56.0 — Env Vars §"OTEL_EXPORTER_OTLP_{TRACES,METRICS,LOGS}_HEADERS"
- **Current state (evidence):** `src/sdk/config.zig:175-179` reads only the unprefixed form.
- **Why this is a gap:** Per-signal auth headers (different API tokens for traces vs logs) cannot be configured.
- **User impact:** Multi-tenant collector setups cannot route by signal.
- **Effort:** Small
- **Dependencies:** Same.
- **Recommended fix:** Mirror lines 175-179 with three per-signal reads.
- **Acceptance criteria:** Test setting `OTEL_EXPORTER_OTLP_TRACES_HEADERS="Authorization=Bearer t1"` and `_LOGS_HEADERS="Authorization=Bearer t2"`; asserts headers diverge per exporter.

#### GAP-ENV-OTLP-PER-SIGNAL-COMPRESSION

- **Status:** Not Implemented
- **Severity:** Medium
- **Category:** Configuration / Spec compliance
- **Spec citation:** OpenTelemetry Specification 1.56.0 — Env Vars §"OTEL_EXPORTER_OTLP_{,TRACES_,METRICS_,LOGS_}COMPRESSION"
- **Current state (evidence):** No env-var reader for compression at all.
- **Why this is a gap:** No way to enable gzip from env even once `GAP-OTLP-COMPRESSION` lands.
- **User impact:** Once compression works, operators still cannot enable it without a recompile.
- **Effort:** Small (four env-var reads)
- **Dependencies:** Functional only after `GAP-OTLP-COMPRESSION`.
- **Recommended fix:** Add four reads (`OTEL_EXPORTER_OTLP_COMPRESSION` shared; per-signal overrides).
- **Acceptance criteria:** Test setting `OTEL_EXPORTER_OTLP_COMPRESSION=gzip` and asserting the encoder applies it.

#### GAP-ENV-ATTR-LIMITS

- **Status:** Not Implemented
- **Severity:** Medium
- **Category:** Configuration / Spec compliance
- **Spec citation:** OpenTelemetry Specification 1.56.0 — Env Vars §"OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT", "OTEL_ATTRIBUTE_COUNT_LIMIT", "OTEL_SPAN_ATTRIBUTE_*", "OTEL_SPAN_EVENT_*", "OTEL_SPAN_LINK_*"
- **Current state (evidence):** `src/internal/attributes.zig:11-13` — hard-coded `128 attrs / 256-byte keys / 4096-byte values`.
- **Why this is a gap:** Spec defines these as operator-tunable; today they are constants.
- **User impact:** Cannot tighten limits to reduce egress cost; cannot loosen for high-cardinality services.
- **Effort:** Small (read env into runtime config; thread through attribute-set constructors)
- **Dependencies:** None.
- **Recommended fix:** Move limits from `comptime` constants to a runtime `AttributeLimits` struct read from env at SDK init. Default values unchanged.
- **Acceptance criteria:** Test setting `OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT=64` and asserting attribute values longer than 64 bytes are truncated.

#### GAP-BENCH-NOT-WIRED

- **Status:** Not Implemented
- **Severity:** Medium
- **Category:** Test / CI
- **Spec citation:** N/A
- **Requirement source:** `build.zig:391-401` declares `bench`, `bench-micro`, `scale-bench`, `compare-bench` steps
- **Current state (evidence):** All four steps are `bench_step.dependOn(&fmt_check.step)` — i.e., they run `fmt-check` and lie about being benchmarks. `benchmarks/*.zig` is template scaffolding.
- **Why this is a gap:** Performance regressions cannot be detected in CI; the public `bench` API surface is misleading.
- **User impact:** Contributors think benchmarks exist when they do not.
- **Effort:** Medium (one or two real benchmarks against the wire encoders + the in-memory exporter; integrate with `native-benchmarks` plugin if desired)
- **Dependencies:** None.
- **Recommended fix:** Either delete the bench steps and benchmarks/ scaffolding, or wire them to real benchmarks (see `native-benchmarks` skill for the harness contract).
- **Acceptance criteria:** `zig build bench-micro` runs an actual benchmark binary and prints durations; CI captures regression deltas.

#### GAP-INTEGRATION-SUITE-MISSING

- **Status:** Not Implemented
- **Severity:** Medium
- **Category:** Test
- **Current state (evidence):** `build.zig:349-353` — `test-integration` and `test-stress` are aliases for `test`; no separate test binaries.
- **Why this is a gap:** CI matrix runs the same set of tests three times under different names; integration/stress claims have no actual coverage.
- **User impact:** Reviewers think there is dedicated integration coverage; there isn't.
- **Effort:** Medium (build a separate test step that targets `test/` only or routes through a tagged subset; or create real long-running stress tests)
- **Dependencies:** None.
- **Recommended fix:** Either delete the aliases (and the matching CI rows) or wire them to dedicated test targets.
- **Acceptance criteria:** `zig build test-integration` runs a different test binary than `zig build test`.

---

### Low

#### GAP-DEVNW-TLS-UNUSED

- **Status:** Partial (semantic drift)
- **Severity:** Low
- **Category:** Vendor / Code quality
- **Current state (evidence):**
  - `docs/DEPENDENCIES.md` (TLS row) — DevNW tls is QUIC-first.
  - `build.zig:67-76` — pin only; `tls13_full` module imported solely to prove resolution; no callers in otel.
  - `-Dotel_use_devnw_tls=true` actually toggles `std.http.Client` (stdlib), not the DevNW package.
- **Why this is a gap:** Flag name claims one thing, behaviour does another. Code-quality risk; no operator-facing failure mode today.
- **User impact:** Confused contributors; future TLS work may go to the wrong layer.
- **Effort:** Small (rename flag or actually plumb DevNW tls)
- **Dependencies:** None.
- **Recommended fix:** Rename `-Dotel_use_devnw_tls` to `-Dotel_use_stdlib_https` (or accurate equivalent). Document the QUIC-first nature of DevNW tls and explain why it is pinned.
- **Acceptance criteria:** Flag name reflects the underlying transport; build/CI matrix references match.

#### GAP-ENV-OTLP-PER-SIGNAL-INSECURE

- **Status:** Not Implemented
- **Severity:** Low
- **Category:** Configuration
- **Spec citation:** OpenTelemetry Specification 1.56.0 — Env Vars §"OTEL_EXPORTER_OTLP_{,TRACES_,METRICS_,LOGS_}INSECURE"
- **Current state (evidence):** `OtlpConfig.insecure` field exists; no env-var reader; not surfaced anywhere.
- **Why this is a gap:** Operators cannot disable TLS via env on a per-signal basis.
- **User impact:** Minor — most production setups never set INSECURE=true; still a spec env-var miss.
- **Effort:** Small.
- **Dependencies:** Functional only once HTTPS is wired and `insecure` actually gates anything.
- **Recommended fix:** Read four env vars into config.
- **Acceptance criteria:** Test that `OTEL_EXPORTER_OTLP_INSECURE=true` flips the field.

#### GAP-ENV-OTLP-MTLS

- **Status:** Not Implemented
- **Severity:** Low
- **Category:** Configuration / Security
- **Spec citation:** OpenTelemetry Specification 1.56.0 — Env Vars §"OTEL_EXPORTER_OTLP_CERTIFICATE", "_CLIENT_KEY", "_CLIENT_CERTIFICATE" (plus per-signal forms)
- **Current state (evidence):** None of these are parsed; no field exists in `OtlpConfig` for them.
- **Why this is a gap:** mTLS to OTLP collectors not configurable.
- **User impact:** Customers requiring mTLS to their collector cannot use this SDK.
- **Effort:** Medium (requires actual mTLS in the HTTP/gRPC client, not just env-var parsing)
- **Dependencies:** Coupled with TLS plumbing in `GAP-DEVNW-TLS-UNUSED`.
- **Recommended fix:** Add fields + env reads + plumb through the HTTP client's TLS config.
- **Acceptance criteria:** Loopback test using cert+key against a TLS server requiring client auth.

#### GAP-ENV-BLRP

- **Status:** Not Implemented
- **Severity:** Low (depends on log batch processor, which doesn't exist yet)
- **Category:** Configuration / Spec compliance
- **Spec citation:** OpenTelemetry Specification 1.56.0 — Env Vars §"BatchLogRecordProcessor": `OTEL_BLRP_*`
- **Current state (evidence):** No `BatchLogRecordProcessor` exists; env vars naturally absent.
- **Why this is a gap:** Spec env vars not honored.
- **User impact:** None today (no log batching), but follows naturally from `GAP-OTLP-LOG-EXPORT`.
- **Effort:** Small (after a BLRP exists, add four reads)
- **Dependencies:** Blocked by `GAP-OTLP-LOG-EXPORT` and a log batching processor.
- **Recommended fix:** Implement `BatchLogRecordProcessor` first; then add env-var reads.
- **Acceptance criteria:** Test setting `OTEL_BLRP_MAX_QUEUE_SIZE` and asserting the processor's queue size matches.

#### GAP-FUZZ-DISABLED

- **Status:** Not Implemented (blocked upstream)
- **Severity:** Low
- **Category:** CI / Test
- **Current state (evidence):** `.gitlab-ci.yml:237-239` — `zig-fuzz-0.16.0` rule `when: never`; comment cites Zig 0.16 stdlib bug at `test_runner.zig:566`.
- **Why this is a gap:** Fuzz coverage suppressed.
- **User impact:** None today; fuzzing just doesn't run.
- **Effort:** Small (re-enable once Zig stdlib fix lands); upstream-bound
- **Dependencies:** Upstream Zig.
- **Recommended fix:** Track the upstream issue; add a CI re-enable on a new Zig minor version. Re-enable when fixed.
- **Acceptance criteria:** Fuzz job runs green on Zig ≥0.17 (or whichever ships the fix).

#### GAP-WINDOWS-TESTS-DISABLED

- **Status:** Not Implemented (blocked upstream)
- **Severity:** Low
- **Category:** CI
- **Current state (evidence):** `.gitlab-ci.yml:241-251` — Windows test jobs disabled pending ci-catalog PowerShell wrapper fix.
- **Why this is a gap:** Windows is an unverified target.
- **User impact:** Windows-platform users have no CI guarantee.
- **Effort:** Small (re-enable once ci-catalog fix lands); upstream-bound
- **Dependencies:** Upstream `devnw/ci-catalog`.
- **Recommended fix:** Track the upstream PR; add a smoke job once available.
- **Acceptance criteria:** Windows test job runs green in CI.

#### GAP-DEPRECATED-SPAN-EVENTS-FLAG

- **Status:** Implemented (note-only — not actually a gap; called out in Phase 2 for visibility)
- **Severity:** Low
- **Category:** Code quality / Docs
- **Current state (evidence):** `src/api/trace.zig:215-218` — `Span.addEvent` requires `-Ddeprecated_span_events=true` to compile.
- **Why this is flagged:** The deprecated path is unreachable in default builds. Not a spec violation (spec deprecated this surface), but worth documenting so users do not try to compose deprecated events with `Logger.emit` event-name bridging unaware they need the flag.
- **User impact:** None — by design.
- **Effort:** Trivial (doc note only)
- **Dependencies:** None.
- **Recommended fix:** Add a one-paragraph note in `docs/SPEC_COMPLIANCE.md` clarifying the deprecation gate and pointing readers to `EventBuilder.emit`.
- **Acceptance criteria:** Docs reference the flag; no code change required.

---

## Files Referenced

- `/data/home/benji/src/devnw/zig/otel/docs/audit/GAP_SCAN.md` — Phase 2 source
- `/data/home/benji/src/devnw/zig/otel/src/sdk/config.zig`
- `/data/home/benji/src/devnw/zig/otel/src/sdk/trace.zig`
- `/data/home/benji/src/devnw/zig/otel/src/sdk/metrics.zig`
- `/data/home/benji/src/devnw/zig/otel/src/sdk/export.zig`
- `/data/home/benji/src/devnw/zig/otel/src/sdk/resource.zig`
- `/data/home/benji/src/devnw/zig/otel/src/api/metrics.zig`
- `/data/home/benji/src/devnw/zig/otel/src/api/profiles.zig`
- `/data/home/benji/src/devnw/zig/otel/src/api/trace.zig`
- `/data/home/benji/src/devnw/zig/otel/src/exporters/otlp_http.zig`
- `/data/home/benji/src/devnw/zig/otel/src/exporters/otlp_grpc.zig`
- `/data/home/benji/src/devnw/zig/otel/src/internal/redact.zig`
- `/data/home/benji/src/devnw/zig/otel/src/internal/attributes.zig`
- `/data/home/benji/src/devnw/zig/otel/src/generated/otlp.zig`
- `/data/home/benji/src/devnw/zig/otel/src/generated/semconv.zig`
- `/data/home/benji/src/devnw/zig/otel/build.zig`
- `/data/home/benji/src/devnw/zig/otel/.gitlab-ci.yml`
- `/data/home/benji/src/devnw/zig/otel/docs/DEPENDENCIES.md`
- `/data/home/benji/src/devnw/zig/otel/docs/SPEC_COMPLIANCE.md`
- `/data/home/benji/src/devnw/zig/otel/third_party/opentelemetry-proto-v1.10.0/`
- `/data/home/benji/src/devnw/zig/otel/third_party/semantic-conventions-v1.40.0/`

## Hand-off to Phase 4 (gap-sync)

- All 37 Gap-IDs from Phase 2 are preserved verbatim. (User prompt's "29" was a category-aggregate; Phase 2's bullet list under "Gap Inventory" enumerates 37 distinct IDs.)
- `GAP-OTLP-WIRE-INSTRUMENTATION-SCOPE` and `GAP-INSTRUMENTATION-SCOPE-PROPAGATION` are a sibling pair (same root-cause line). Phase 4 may open one issue cross-linked to both Gap-IDs, or two issues with explicit "fix together" wording.
- `GAP-DEPRECATED-SPAN-EVENTS-FLAG` is marked Implemented/note-only; Phase 4 should open a docs-only issue (or skip it).
- Implementation order follows the dependency graph above: start with the one-line scope-propagation bug, then the exporter factory, then per-signal exporters and env-var families.
- Cross-cutting prerequisites for high-confidence acceptance: vendor `opentelemetry-proto` and `semantic-conventions` schemas (`GAP-VENDOR-PROTO`, `GAP-VENDOR-SEMCONV`) before scoring later wire-shape work.
