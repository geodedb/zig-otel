# otel-zig — Phase 2 Implementation Gap Scan

Date: 2026-04-26
Auditor: Phase 2 (gap-detector input)
Repo: `gitlab.com/devnw/zig/otel`
Branch: `main`
Zig: 0.16.0

## Repository Profile

- Language: Zig 0.16
- Surface: 36 .zig source files, 7080 LOC under `src/`
- Layout: `src/api/` `src/sdk/` `src/exporters/` `src/internal/` `src/propagation/` `src/generated/` `src/instrumentation/`
- Test surface: 16 files under `test/`, ~113 total `test {}` blocks (71 in-source + 42 in `test/`)
- Spec target (per docs): OpenTelemetry 1.56.0, OTLP 1.10.0, Semantic Conventions 1.40.0, Declarative Configuration 1.0.0
- Build entry: `build.zig` (402 LOC), config `build.zig.zon` pins 9 DevNW deps behind `-Dotel_use_devnw_*` flags.

## Build / Test Infrastructure

| Action | Command | Config | Status |
|--------|---------|--------|--------|
| Build  | `zig build build` | `build.zig` | PASS (cached, no errors) |
| Check  | `zig build check` | `build.zig:194` | PASS |
| Fmt    | `zig build fmt-check` | `build.zig:330` | PASS |
| Test   | `zig build test --summary all` | `build.zig:201-235` | 33/43 pass, 10 skipped (skips are flag-gated DevNW paths) |
| CI     | `.gitlab-ci.yml` | shared ci-catalog v1.22.0 | matrix: Linux Debug/ReleaseSafe/ReleaseFast/ReleaseSmall + integration + stress; macOS gated; Windows disabled (catalog bug); fuzz disabled (Zig 0.16 stdlib bug); `otlp-integration-live` against gitlab-o11y |

Notes:

- `test-integration` and `test-stress` are aliases for `test` (`build.zig:349-353`); no separate suites.
- `bench`, `bench-micro`, `scale-bench`, `compare-bench` are `fmt_check` stubs (`build.zig:391-401`); the `benchmarks/*.zig` tree is template scaffolding not wired against the API.
- Build is hermetic by default; every DevNW dep is opt-in.

## Documented vs Implemented — Status per Spec Area

| Area | Doc claim | Status | Evidence | Notes |
|------|-----------|--------|----------|-------|
| Trace API | OpenTelemetry 1.56.0 stable surface | Implemented | `src/api/trace.zig:132-236`, `src/sdk/trace.zig:121-256` | Span, Tracer, TracerProvider, samplers (AlwaysOn/Off/ParentBased/TraceIdRatioBased), kinds, status, recordException. |
| Metrics API | Counter/UpDown/Histogram/Gauge + observable | Partial | `src/api/metrics.zig`, `src/sdk/metrics.zig` | Sync instruments fully wired; observable instruments declared (kinds + `ObservableCallback` type at `src/api/metrics.zig:76`) but NEVER bound — Meter has no `register*Observer` and the SDK does not invoke callbacks at collect-time. |
| Logs API | LoggerProvider, severity 24 levels, correlation | Implemented | `src/api/logs.zig`, `src/sdk/logs.zig` | Logger.emit + Severity enum + correlate. |
| Events | event.name builder bridged to logs | Implemented | `src/api/events.zig:15-71` | EventBuilder.emit injects `event.name`. |
| Baggage | W3C 180/4096/256 limits | Implemented | `src/api/baggage.zig:9-110`, `src/propagation/baggage.zig` | Validate, percent-encode/decode, max enforced. |
| Context | Immutable propagation envelope | Implemented | `src/api/context.zig:15-94` | SpanContext + Baggage borrows, `withSpan*`. |
| Propagators (W3C tracecontext) | inject/extract, malformed errors, lower-hex, ff-version, zero-id rejection | Implemented | `src/propagation/trace_context.zig:62-208` | Strict-55, lowercase hex, version+flags+IDs validated; tracestate preserved verbatim. |
| Propagators (W3C baggage) | inject/extract round-trip | Implemented | `src/propagation/baggage.zig:14-90` | percent-encode/decode + size cap. |
| Propagators (Composite) | sequential trace-context + baggage | Implemented | `src/propagation/composite.zig:22-39` | Inject both; extract tolerates malformed pieces. |
| Propagators (B3) | spec lists `b3` as MUST-implement | **Not Implemented** | `src/sdk/config.zig:84,185` | `b3` only present as enum value + env-var literal; no `propagation/b3.zig` file. |
| Propagators (Jaeger) | spec lists `jaeger` propagator | **Not Implemented** | `src/sdk/config.zig:84,186` | Same: enum value only, no implementation. |
| Resource | telemetry.sdk.* + merge + env detector | Implemented | `src/sdk/resource.zig:13-157` | env / process / OS / host detectors. |
| Semantic Conventions 1.40.0 | "constants generated" | **Partial** | `src/generated/semconv.zig:1-103` | Only ~60 constants in 11 groupings. Spec 1.40.0 ships hundreds of attributes (DB, RPC, messaging, GenAI, k8s, cloud, container, FaaS, browser, code, deployment, gRPC, GraphQL, etc.). No generator (`weaver`) wired. `third_party/semantic-conventions-v1.40.0/` contains only LICENSE. |
| Configuration env vars | `OTEL_*` documented in README | **Partial** | `src/sdk/config.zig:122-188` | See "Per-signal env vars" section below. |
| Declarative Configuration 1.0.0 | YAML loader | Partial | `src/sdk/config.zig:222-287` (in-repo) + `:373-486` (DevNW) | Subset only: top-level + one nested mapping; no anchors/multi-doc/flow nodes; covers `tracer_provider`/`meter_provider`/`logger_provider` mappings. |
| OTLP wire (traces) | protobuf + JSON encoders | Partial | `src/exporters/otlp_http.zig:230-321` | spans encoded; **events, links, schema_url, instrumentation_scope.attributes never emitted**; `parent_span_id` emitted, status emitted. |
| OTLP wire (metrics) | "/v1/metrics path" + "supports metrics" | **Not Implemented** | `src/exporters/otlp_http.zig` | No `expMetrics`, no `metricExporter()` on `OtlpHttpExporter`/`OtlpGrpcExporter`; only `spanExporter()`. The `/v1/metrics` path is not referenced. SPEC_COMPLIANCE.md claim is unsupported. |
| OTLP wire (logs) | "/v1/logs path" + "supports logs" | **Not Implemented** | `src/exporters/otlp_http.zig` | No `expLogs`, no `logExporter()` on OTLP exporters. Same as metrics. |
| OTLP wire (profiles) | "/v1development/profiles path" | **Not Implemented** | `src/exporters/otlp_http.zig` + `src/api/profiles.zig:53-66` | Profiler stub returns `error.UnsupportedTransport` even when `-Dotel_profiles=true` is set; no exporter path; SPEC_COMPLIANCE.md claim is unsupported. |
| OTLP/HTTP transport | std.http.Client + std.crypto.tls behind `-Dotel_use_devnw_tls` | Implemented (gated) | `src/exporters/otlp_http.zig:108-163` | Returns `UnsupportedTransport` without flag + plumbed `Io`. Loopback test in `test/tls_loopback.zig`. |
| OTLP/gRPC transport | DevNW grpc-zig unary, h2c only | Implemented (gated, h2c) | `src/exporters/otlp_grpc.zig:64-191` | TLS-wrapped gRPC NOT supported (h2c only — see `docs/DEPENDENCIES.md` "gRPC row"). gRPC client never inspects trailers / `grpc-status` (`otlp_grpc.zig:185-190`). |
| HTTPS via DevNW tls | DevNW tls is QUIC-first | Deferred / Not Implemented | `docs/DEPENDENCIES.md` (TLS row), `build.zig:67-76` | Pin only; no callers in otel; `tls13_full` module imported solely to prove resolution. |
| Retry policy | 100 ms initial, x2, max 5 s, max 30 s, full jitter | Implemented | `src/sdk/export.zig:542-561`, `src/exporters/otlp_http.zig:191-227` | Tested in `test/otlp.zig: retries on 503`. |
| Partial success | 207 → `error.PartialSuccess` | Implemented | `src/exporters/otlp_http.zig:216` | But OTLP `ExportXxxPartialSuccess` proto message body is captured into `last_response_body` only; not parsed for `rejected_*_count`. |
| Compression | enum `none\|gzip` declared | **Not Implemented** | `src/sdk/config.zig:52`, `src/exporters/otlp_http.zig` | gzip path is never invoked; no compression on HTTP body, gRPC frame compression byte hard-coded to 0. |
| Schema URL emission | `fn_schema_url=3` field number defined | **Not Implemented** | `src/generated/otlp.zig:147`, no callers | `Resource.schema_url` is tracked but never written to the OTLP wire payload. |
| Span events / links wire | `fn_span_events=11`, `fn_span_links=13` defined | **Not Implemented** | `src/generated/otlp.zig:159-162` (constants only); no encoder uses them | Both `encodeSpansProto` and `encodeSpansJson`/`spanToJson` skip events + links. |
| Periodic metric reader | `MetricsConfig.interval_ms = 60_000` documented | **Not Implemented** | `src/sdk/metrics.zig:31-47` | `MetricReader` vtable exists; no `PeriodicReader`/scheduler implementation — `interval_ms` is unused. Caller must invoke `collect()` manually. |
| Exporter factory | `ExporterKind` enum + `OTEL_*_EXPORTER` parsing | **Not Implemented** | `src/sdk/config.zig:14-31` | No factory function maps `ExporterKind` → instantiated exporter; callers wire exporters by hand. |
| Redaction enforcement | `password/secret/token/api.key/authorization/credential` | **Partial / Not Wired** | `src/internal/redact.zig:53` | Helper exists; no exporter or attribute-set caller invokes it (only used in `tools/golden.zig:155`). Sensitive values pass through untouched. |
| Attribute limits | 128 attrs / 256-byte keys / 4096-byte values | Implemented (hard-coded) | `src/internal/attributes.zig:11-13` | Constants only; no `OTEL_ATTRIBUTE_*_LIMIT`, `OTEL_SPAN_ATTRIBUTE_*` env-var override path. |
| Vendored proto | `third_party/opentelemetry-proto-v1.10.0/` | **Not Implemented** | `ls third_party/opentelemetry-proto-v1.10.0/` returns LICENSE only | No `.proto` files vendored. |
| Vendored semconv | `third_party/semantic-conventions-v1.40.0/` | **Not Implemented** | `ls third_party/semantic-conventions-v1.40.0/` returns LICENSE only | No YAML schema files vendored. |
| Async BatchSpanProcessor | `-Dotel_use_devnw_pool=true` + `async_workers > 0` | Implemented (gated) | `src/sdk/export.zig:139-435` | Polled `pending_tasks` counter; export_mutex serialises drain calls; tested in `test/batch_async.zig` (skip when flag off). |
| Examples | `basic.zig`, `http_client.zig` | Implemented | `examples/` | Build via `zig build run-basic` / `zig build run-http-client`. |
| Benchmarks | `benchmarks/*` advisory | **Not wired** | `build.zig:391-401` | All bench steps stubbed; `benchmarks/bench.zig` is template scaffolding. |

## Stubs / Placeholders / Incomplete Code

| File:Line | Type | Content | Related GAP |
|-----------|------|---------|-------------|
| `src/exporters/otlp_http.zig:88-97` | sentinel transport | `httpTransport` always returns `error.UnsupportedTransport`; real impl is `httpTransportImpl` gated on `-Dotel_use_devnw_tls=true` | GAP-OTLP-HTTP-TRANSPORT-DEFAULT |
| `src/exporters/otlp_http.zig:109-110` | gate | `if (!build_options.use_devnw_tls) return error.UnsupportedTransport` + `io orelse return error.UnsupportedTransport` | GAP-OTLP-HTTP-TRANSPORT-DEFAULT |
| `src/exporters/otlp_grpc.zig:69-70` | gate | `if (!build_options.use_devnw_grpc) return error.UnsupportedTransport` + `io orelse return error.UnsupportedTransport` | GAP-OTLP-GRPC-TRANSPORT-DEFAULT |
| `src/exporters/otlp_grpc.zig:185-190` | grpc-status not inspected | comment: "grpc-zig's client surfaces neither the trailers nor the `grpc-status` value" | GAP-GRPC-STATUS-PROPAGATION |
| `src/api/profiles.zig:59-65` | profiler stub | `if (!enabled) return error.UnsupportedTransport;` and `noopEmit` returns same | GAP-PROFILES-EXPORTER |
| `src/sdk/config.zig:483-485` | yaml stub | DevNW yaml loader fallback returns `error.UnsupportedTransport` when flag off | OK (gate) |
| `src/sdk/config.zig:84` | enum-only propagator | `propagator: enum { tracecontext, baggage, b3, jaeger, composite }` — `b3` and `jaeger` literals only | GAP-PROPAGATOR-B3, GAP-PROPAGATOR-JAEGER |
| `src/sdk/metrics.zig:378` | compat shim | `pub fn setActiveProvider(_: *MeterProvider) void {}` — comment "compatibility shim retained for tests" | minor / dead surface |
| `src/sdk/trace.zig:240` | empty scope | `state.instrumentation_scope = .{ .name = "" };` overrides whatever was set 5 lines above | GAP-INSTRUMENTATION-SCOPE-PROPAGATION |
| `build.zig:391-401` | bench step stubs | `bench_step.dependOn(&fmt_check.step)` for all four bench steps | GAP-BENCH-NOT-WIRED |
| `third_party/opentelemetry-proto-v1.10.0/` | LICENSE-only dir | no .proto files | GAP-VENDOR-PROTO |
| `third_party/semantic-conventions-v1.40.0/` | LICENSE-only dir | no YAML files | GAP-VENDOR-SEMCONV |

No `TODO`/`FIXME`/`XXX`/`HACK`/`@panic`/`unreachable` markers found in `src/`.

## Per-signal Env Var Coverage

| Spec env var | Implemented | Evidence |
|--------------|-------------|----------|
| `OTEL_SDK_DISABLED` | Yes | `src/sdk/config.zig:123` |
| `OTEL_LOG_LEVEL` | Yes | `:126-132` |
| `OTEL_TRACES_SAMPLER` | Yes | `:133-138` |
| `OTEL_TRACES_SAMPLER_ARG` | Yes | `:139-141` |
| `OTEL_TRACES_EXPORTER` | Yes (descriptive only) | `:142-144` — no factory wiring |
| `OTEL_METRICS_EXPORTER` | Yes (descriptive only) | `:145-147` |
| `OTEL_LOGS_EXPORTER` | Yes (descriptive only) | `:148-150` |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Yes | `:151-155` |
| `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` | Yes | `:156` |
| `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` | Yes | `:157` |
| `OTEL_EXPORTER_OTLP_LOGS_ENDPOINT` | Yes | `:158` |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | Yes | `:160-166` |
| `OTEL_EXPORTER_OTLP_TRACES_PROTOCOL` | **No** | absent |
| `OTEL_EXPORTER_OTLP_METRICS_PROTOCOL` | **No** | absent |
| `OTEL_EXPORTER_OTLP_LOGS_PROTOCOL` | **No** | absent |
| `OTEL_EXPORTER_OTLP_TIMEOUT` | Yes | `:167-174` |
| `OTEL_EXPORTER_OTLP_TRACES_TIMEOUT` | **No** | absent |
| `OTEL_EXPORTER_OTLP_METRICS_TIMEOUT` | **No** | absent |
| `OTEL_EXPORTER_OTLP_LOGS_TIMEOUT` | **No** | absent |
| `OTEL_EXPORTER_OTLP_HEADERS` | Yes | `:175-179` |
| `OTEL_EXPORTER_OTLP_TRACES_HEADERS` | **No** | absent |
| `OTEL_EXPORTER_OTLP_METRICS_HEADERS` | **No** | absent |
| `OTEL_EXPORTER_OTLP_LOGS_HEADERS` | **No** | absent |
| `OTEL_EXPORTER_OTLP_COMPRESSION` (and per-signal) | **No** | enum exists in OtlpConfig but no env reader and no encode-time use |
| `OTEL_EXPORTER_OTLP_INSECURE` (and per-signal) | **No** | `OtlpConfig.insecure` field exists, no env reader |
| `OTEL_EXPORTER_OTLP_CERTIFICATE` / `_CLIENT_KEY` / `_CLIENT_CERTIFICATE` | **No** | absent |
| `OTEL_SERVICE_NAME` | Yes | `:180`, plus `src/sdk/resource.zig:70-76` |
| `OTEL_RESOURCE_ATTRIBUTES` | Yes | `:181`, `resource.zig:77-84` |
| `OTEL_PROPAGATORS` | Partial | `:182-187` parses `tracecontext\|baggage\|b3\|jaeger`; `b3`+`jaeger` are dead-end |
| `OTEL_CONFIG_FILE` | Yes | `:102-114` |
| `OTEL_BSP_MAX_QUEUE_SIZE` / `_SCHEDULE_DELAY` / `_MAX_EXPORT_BATCH_SIZE` / `_EXPORT_TIMEOUT` | **No** | not read; `BatchSpanProcessorOptions` is in-code only |
| `OTEL_BLRP_*` (BatchLogRecordProcessor) | **No** | no batch log processor exists at all |
| `OTEL_METRIC_EXPORT_INTERVAL` / `_TIMEOUT` | **No** | `interval_ms` is structural only |
| `OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT` / `_COUNT_LIMIT` | **No** | hard-coded constants `src/internal/attributes.zig:11-13` |
| `OTEL_SPAN_ATTRIBUTE_*`, `OTEL_SPAN_EVENT_*`, `OTEL_SPAN_LINK_*` | **No** | absent |

## Known infrastructure gaps from `.gitlab-ci.yml`

| Item | Source |
|------|--------|
| Zig fuzz target compile-fails on Zig 0.16 stdlib (`test_runner.zig:566`); `zig-fuzz-0.16.0` rule `when: never` | `.gitlab-ci.yml:237-239` |
| Windows test jobs disabled pending ci-catalog PowerShell wrapper fix | `.gitlab-ci.yml:241-251` |
| `otlp-integration-live` job points at gitlab-o11y endpoints (https/grpc on 14318/14317); requires `OTEL_INTEGRATION_AUTH_HEADER` | `.gitlab-ci.yml:264-286` |

## Test Failures / Skips Observed (`zig build test`)

```text
Build Summary: 30/30 steps succeeded; 33/43 tests passed (10 skipped)
```

10 skips correspond to flag-gated DevNW paths (devnw_grpc, devnw_tls, devnw_json, devnw_protobuf, devnw_pool, devnw_metrics, devnw_config) and `tls_loopback` / `grpc_loopback`. No failing tests in the hermetic default build.

## Gap Inventory (GAP-IDs for Phase 3)

### High-priority spec compliance

- **GAP-PROPAGATOR-B3** — Closed (#23). `src/propagation/b3.zig` implements the single + multi header forms; `src/sdk/config.zig propagatorBundleFromConfig` wires `OTEL_PROPAGATORS={b3,b3multi}` (and comma-separated lists) onto a runtime-dispatched `Composite`; regression `test/propagator_b3.zig` covers positive (canonical, debug, parent-id, padded 16-hex), negative (empty/missing/all-zero/non-hex/bad-sampled), round-trip, and end-to-end via the env-var driven factory.
- **GAP-PROPAGATOR-JAEGER** — Closed (#24). `src/propagation/jaeger.zig` implements `uber-trace-id` SpanContext (16/32-hex trace-id padding, debug-flag collapse to sampled, parent-id shape-validate-and-discard, firehose drop) + `uberctx-<key>` per-entry baggage with RFC 3986 percent-encoding. `src/propagation/trace_context.zig` gained `Carrier.iter`/`MapCarrier.iterFn` so the `uberctx-` scan can run on any carrier that surfaces an iterator. Factory wiring in `src/sdk/config.zig propagatorBundleFromConfig`; regression `test/propagator_jaeger.zig` (20 tests) covers positive + negative + round-trip + composite end-to-end.
- **GAP-OTLP-METRIC-EXPORT** — `OtlpHttpExporter`/`OtlpGrpcExporter` have no `metricExporter()`; `/v1/metrics` path unreachable; SPEC_COMPLIANCE.md claim contradicted by `src/exporters/otlp_http.zig`.
- **GAP-OTLP-LOG-EXPORT** — Same: no `logExporter()`; `/v1/logs` unreachable.
- **GAP-OTLP-PROFILES-EXPORT** — `/v1development/profiles` claimed, never wired; `src/api/profiles.zig:59` always returns `error.UnsupportedTransport`.
- **GAP-OTLP-WIRE-EVENTS-LINKS** — Span events and span links never written to OTLP protobuf or JSON. `encodeSpansProto`/`spanToJson` skip them entirely.
- **GAP-OTLP-WIRE-SCHEMA-URL** — Resource `schema_url` and ScopeSpans `schema_url` defined as field-numbers but never emitted.
- **GAP-OTLP-WIRE-INSTRUMENTATION-SCOPE** — `src/sdk/trace.zig:240` overwrites the tracer's instrumentation scope to empty `.{ .name = "" }` after attaching it 5 lines earlier; the OTLP scope name is therefore always blank.
- **GAP-OTLP-COMPRESSION** — Partial closure (2026-04-27). HTTP path fully wired: `src/exporters/otlp_http/compression.zig` `gzipBody`/`gunzipBody` (Zig 0.16 `std.compress.flate.Compress` with `.gzip` container) + `src/exporters/otlp_http/exporter.zig:dispatchTransport` `maybeGzip` helper that gzips the body and appends `content-encoding=gzip` to the headers passed to the transport when `OtlpConfig.compression == .gzip`. gRPC body compression runs through grpc-zig's existing zlib path (`unaryExport` now forwards `OtlpConfig.compression` into `client.call`), and `frame()` accepts a `compressed: bool` parameter so the framing byte is wire-correct (`1`) when callers emit compressed frames themselves. Tests: `test/otlp_compression.zig` pins HTTP `.none` baseline + `.gzip` round-trip + header-merge + 96 KiB payload + empty payload + gRPC `frame(.., true)` + `frameGzip` end-to-end. Follow-up still pending: `grpc-encoding: gzip` request metadata header is not set (grpc-zig's `client.call` does not expose request metadata), and upstream `transport.writeMessage` still emits the framing flag as `0` regardless of compression (pre-existing — the gRPC loopback test already self-skips because of the same module's structural issue). `OTEL_EXPORTER_OTLP_COMPRESSION` env-var parsing is also still pending.

### Per-signal env var family

- **GAP-ENV-OTLP-PER-SIGNAL-PROTOCOL** — `OTEL_EXPORTER_OTLP_{TRACES,METRICS,LOGS}_PROTOCOL` not parsed.
- **GAP-ENV-OTLP-PER-SIGNAL-TIMEOUT** — `OTEL_EXPORTER_OTLP_{TRACES,METRICS,LOGS}_TIMEOUT` not parsed.
- **GAP-ENV-OTLP-PER-SIGNAL-HEADERS** — `OTEL_EXPORTER_OTLP_{TRACES,METRICS,LOGS}_HEADERS` not parsed.
- **GAP-ENV-OTLP-PER-SIGNAL-COMPRESSION** — `OTEL_EXPORTER_OTLP_{,TRACES_,METRICS_,LOGS_}COMPRESSION` not parsed.
- **GAP-ENV-OTLP-PER-SIGNAL-INSECURE** — `OTEL_EXPORTER_OTLP_{,TRACES_,METRICS_,LOGS_}INSECURE` not parsed.
- **GAP-ENV-OTLP-MTLS** — `OTEL_EXPORTER_OTLP_CERTIFICATE`, `_CLIENT_KEY`, `_CLIENT_CERTIFICATE` (and per-signal) not parsed.
- **GAP-ENV-BSP** — `OTEL_BSP_*` env vars (queue size, schedule delay, batch size, export timeout) not parsed; `BatchSpanProcessorOptions` only configurable in code.
- **GAP-ENV-BLRP** — `OTEL_BLRP_*` env vars not parsed; no `BatchLogRecordProcessor` exists.
- **GAP-ENV-METRIC-INTERVAL** — `OTEL_METRIC_EXPORT_INTERVAL` / `_TIMEOUT` not parsed.
- **GAP-ENV-ATTR-LIMITS** — `OTEL_ATTRIBUTE_VALUE_LENGTH_LIMIT`, `OTEL_ATTRIBUTE_COUNT_LIMIT`, `OTEL_SPAN_ATTRIBUTE_*`, `OTEL_SPAN_EVENT_*`, `OTEL_SPAN_LINK_*` not parsed; limits hard-coded.

### Vendor / dependency gaps

- **GAP-VENDOR-PROTO** — `third_party/opentelemetry-proto-v1.10.0/` contains LICENSE only; no `.proto` files vendored. Reproducible OTLP wire shape cannot be validated against canonical schemas without these.
- **GAP-VENDOR-SEMCONV** — `third_party/semantic-conventions-v1.40.0/` contains LICENSE only; no YAML schemas. No generator (`weaver`) wired.
- **GAP-SEMCONV-COVERAGE** — `src/generated/semconv.zig` covers ~60 attributes across 11 groupings vs Semantic Conventions 1.40.0 stable surface (DB, RPC, messaging, GenAI, k8s, cloud, container, FaaS, browser, code, deployment, gRPC, GraphQL, …). Documented as "stable areas required by the spec" but the term is under-defined.
- **GAP-DEVNW-TLS-UNUSED** — DevNW `tls` is QUIC-first per `docs/DEPENDENCIES.md`; pinned but never invoked. The `-Dotel_use_devnw_tls=true` flag actually toggles `std.http.Client` (stdlib), not the DevNW package — semantics drift from the flag name.
- **GAP-DEVNW-GRPC-H2C-ONLY** — gRPC client supports h2c only (no TLS). `OtlpConfig.endpoint` parser strips the scheme (`src/exporters/otlp_grpc.zig:131-149`).
- **GAP-GRPC-STATUS-PROPAGATION** — `unaryExport` cannot read trailers/`grpc-status` (`src/exporters/otlp_grpc.zig:185-190`); a clean call return is treated as OK regardless of OTel partial-success or server-side rejection. PartialSuccess only reachable via io errors.

### Configuration / wiring gaps

- **GAP-EXPORTER-FACTORY** — `ExporterKind` enum parsed from env/YAML/code but no factory function instantiates the chosen exporter; callers must wire by hand. `OTEL_TRACES_EXPORTER=otlp` therefore has no behavioural effect.
- **GAP-PERIODIC-METRIC-READER** — `MetricsConfig.interval_ms = 60_000` field but no `PeriodicReader` runs; `MetricReader` vtable exists, no scheduler.
- **GAP-OBSERVABLE-INSTRUMENTS** — `ObservableCallback` type at `src/api/metrics.zig:76` and observable_* kinds in enum; Meter has no `register*Observer`/`createObservable*` API and the SDK collect() never invokes any callback.
- **GAP-REDACT-NOT-WIRED** — `src/internal/redact.zig` exposes `maskString`/`isSensitive` but no exporter or attribute writer calls them; sensitive values pass through to OTLP wire / stdout / file unredacted. Only `tools/golden.zig` invokes the helper.
- **GAP-INSTRUMENTATION-SCOPE-PROPAGATION** — `src/sdk/trace.zig:235-240` immediately overwrites the just-attached scope with `.{ .name = "" }` so all spans report scope.name=""; the OTLP encoder then emits an empty scope name.
- **GAP-DECLARATIVE-CONFIG-DEPTH** — In-repo YAML loader covers one level of nesting only; no anchors, multi-doc, or flow nodes. The Declarative Configuration 1.0.0 spec defines deeper trees (samplers, processors, processor options, resource detector configs).
- **GAP-PARTIAL-SUCCESS-PARSE** — 207 maps to `error.PartialSuccess` but the OTLP `ExportXxxPartialSuccess` body is not parsed for `rejected_*_count`; callers cannot retry only the rejected items.
- **GAP-DEPRECATED-SPAN-EVENTS-FLAG** — `Span.addEvent` requires `-Ddeprecated_span_events=true` to compile (`src/api/trace.zig:215-218`); not a gap per se, but worth flagging that the deprecated path is not reachable in default builds.

### Build / CI gaps

- **GAP-BENCH-NOT-WIRED** — `bench`, `bench-micro`, `scale-bench`, `compare-bench` all stubbed to `fmt_check` (`build.zig:391-401`); `benchmarks/*.zig` is template scaffolding.
- **GAP-FUZZ-DISABLED** — `zig-fuzz-0.16.0` job blocked by upstream Zig 0.16 stdlib bug (`.gitlab-ci.yml:237-239`).
- **GAP-WINDOWS-TESTS-DISABLED** — Windows test jobs blocked by ci-catalog PowerShell wrapper bug (`.gitlab-ci.yml:241-251`).
- **GAP-INTEGRATION-SUITE-MISSING** — `test-integration` and `test-stress` are aliases for `test`; no separate suites.

## Files Referenced

- `/data/home/benji/src/devnw/zig/otel/src/otel.zig` — root module
- `/data/home/benji/src/devnw/zig/otel/src/api/{trace,metrics,logs,events,baggage,context,profiles}.zig`
- `/data/home/benji/src/devnw/zig/otel/src/sdk/{trace,metrics,logs,resource,config,export}.zig`
- `/data/home/benji/src/devnw/zig/otel/src/exporters/{in_memory,stdout_json,file,prometheus,otlp_http,otlp_grpc,otlp_grpc_test_server}.zig`
- `/data/home/benji/src/devnw/zig/otel/src/propagation/{trace_context,baggage,composite}.zig`
- `/data/home/benji/src/devnw/zig/otel/src/internal/{attributes,clock,id,redact,ring_buffer,json_codec}.zig`
- `/data/home/benji/src/devnw/zig/otel/src/generated/{otlp,semconv}.zig`
- `/data/home/benji/src/devnw/zig/otel/build.zig`
- `/data/home/benji/src/devnw/zig/otel/build.zig.zon`
- `/data/home/benji/src/devnw/zig/otel/.gitlab-ci.yml`
- `/data/home/benji/src/devnw/zig/otel/docs/{DEPENDENCIES,SPEC_COMPLIANCE}.md`
- `/data/home/benji/src/devnw/zig/otel/test/*.zig`
- `/data/home/benji/src/devnw/zig/otel/third_party/{opentelemetry-proto-v1.10.0,semantic-conventions-v1.40.0,grpc_zig}/`

## Summary for Phase 3 Detector

29 GAP-IDs identified across:

- 9 high-priority spec compliance gaps (B3, Jaeger, OTLP metric/log/profile export, OTLP wire events/links/schema_url/scope, compression)
- 10 per-signal env var family gaps (per-signal protocol/timeout/headers/compression/insecure, mTLS, BSP, BLRP, metric interval, attribute limits)
- 6 vendor / dependency gaps (proto vendored, semconv vendored, semconv coverage, DevNW tls unused, DevNW grpc h2c-only, gRPC status propagation)
- 7 configuration / wiring gaps (exporter factory, periodic reader, observable instruments, redact wiring, scope propagation, declarative config depth, partial-success parsing)
- 4 build / CI gaps (bench, fuzz, windows, integration suite)

The hermetic default build is clean: `zig build check`, `zig build fmt-check`, `zig build test` all pass with 33/43 tests passing and 10 flag-gated skips. The codebase has zero `TODO`/`FIXME`/`@panic`/`unreachable` markers — gaps surface as missing surface area or dead enum values rather than in-code stubs.
