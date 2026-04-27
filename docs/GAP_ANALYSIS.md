# Gap Analysis

> Source of truth: GitLab issue tracker at <https://gitlab.com/devnw/zig/otel/-/issues>
> This file is a flatfile mirror of issues labelled `gap`. Issue tracker is authoritative.
>
> **Last sync:** 2026-04-27 (Phase 4 gap-sync — registry from `docs/audit/gap-detector/REGISTRY.md`)
> **Source:** Phase 3 canonical registry (`docs/audit/gap-detector/REGISTRY.md`) + Phase 4 SYNC_PLAN (`docs/audit/gap-detector/SYNC_PLAN.md`)
>
> **Security note (2026-04-27):** Security findings live in
> `docs/SECURITY_GAP_ANALYSIS.md`, not in this flatfile. The only
> outstanding security item is **H-7 (#80)** —
> `OTEL_INTEGRATION_AUTH_HEADER` rotation. **Status: Blocked
> (operator-pending), deadline 2026-05-03.** Code-side closed
> `43330db`; the operator unblock checklist is in
> `docs/SECURITY_GAP_ANALYSIS.md` §2.1 and the runbook is at
> `docs/runbooks/h7-token-rotation.md`.

## Blocked-upstream callouts (2026-04-27)

- **GAP-GRPC-STATUS-PROPAGATION (#32)** — Blocked on
  `gitlab.com/devnw/zig/grpc-zig`. The pinned client at
  `zig-pkg/grpc_zig-0.1.0-7FnvpLrAAQAMxd1Mf0GfWePI0Ijw1vX-ZsEc6RCsIsq6/src/client.zig:43-64`
  exposes `pub fn call(...) ![]u8`, returning only the response bytes —
  HTTP/2 trailers (which carry `grpc-status` + `grpc-message` +
  `Retry-After` per the gRPC HTTP/2 spec) are not surfaced. Without
  trailer access, OTLP retry classification cannot use spec-mandated
  gRPC status codes (e.g. `RESOURCE_EXHAUSTED`, `UNAVAILABLE`,
  `DEADLINE_EXCEEDED`). The exporter at
  `src/exporters/otlp_grpc.zig:291-295` documents this gap inline.
  **Unblock steps:**
  1. Open issue on `gitlab.com/devnw/zig/grpc-zig` requesting trailer
     access in the client response API (e.g. extend `call` to return
     a struct exposing both body and trailer headers).
  2. Once the upstream change lands and is version-bumped, return to
     issue #32 to consume the new API and wire `grpc-status` into the
     retry classifier in `src/exporters/otlp_grpc.zig`.
  - Operator todo tracked in `docs/runbooks/upstream-asks.md`.

- **GAP-FUZZ-DISABLED (#99)** — Blocked on upstream Zig 0.16 stdlib.
  CI job `zig-fuzz-0.16.0` at `.gitlab-ci.yml:237-239` is `when: never`
  pending a fix to the `std.testing.fuzz` corpus-reseed crash. Closest
  candidate upstream issues:
  [ziglang/zig#26040](https://github.com/ziglang/zig/issues/26040)
  ("Running multiple fuzz tests segfaults" in 0.16.0-dev) and
  [ziglang/zig#21410](https://github.com/ziglang/zig/issues/21410)
  ("Fuzz tests are not discovered by test runner when re-running with
  same `--seed` argument"). **Unblock criteria:** Awaiting upstream Zig
  fix for the 0.16 stdlib `std.testing.fuzz` crash on corpus reseed.
  (a) upstream fix lands and reaches a tagged release the project
  consumes, OR (b) we wait for Zig 0.17 and re-pin. **Owner action
  items:** (1) confirm/file the upstream `ziglang/zig` issue (the two
  candidates above need verification — file only if neither matches the
  observed reseed crash); (2) record the link in
  `docs/runbooks/upstream-asks.md`; (3) when upstream lands the fix,
  flip `.gitlab-ci.yml:237-239` to `when: on_schedule`, run one full
  corpus, then close this gap.

- **GAP-WINDOWS-TESTS-DISABLED (#100)** — Blocked on upstream
  `gitlab.com/devnw/ci-catalog`. The three Windows test jobs
  `zig-test-windows-{unit,integration,stress}-0.16.0` at
  `.gitlab-ci.yml:241-251` are `when: never` because the ci-catalog
  PowerShell wrapper reports `NativeCommandError` on benign stderr
  writes even when zig exits 0 (block-comment evidence at
  `.gitlab-ci.yml:225-235`). **Unblock criteria:** Awaiting
  `gitlab.com/devnw/ci-catalog` to ship a PowerShell-tolerant runner.
  **Owner action items:** (1) confirm/file the upstream ci-catalog
  issue and link it from `docs/runbooks/upstream-asks.md`; (2) when
  the runner lands, set `rules: - when: on_success` at
  `.gitlab-ci.yml:241-251` and verify against a sample MR.

## Status / Severity Summary

| Severity | Open | Resolved | Total |
|----------|-----:|---------:|------:|
| Critical | 2    | 4        | 6     |
| High     | 9    | 2        | 11    |
| Medium   | 13   | 1        | 14    |
| Low      | 7    | 1        | 8     |
| **Total**| **31** | **8**  | **39**|

> **2026-04-27 Phase 4 deltas:**
>
> - `GAP-INSTRUMENTATION-SCOPE-PROPAGATION` (#1, Critical) closed → moved to `GAP_ANALYSIS_RESOLVED.md`
> - `GAP-OTLP-WIRE-INSTRUMENTATION-SCOPE` (#3, Critical) closed (sibling of #1) → moved to `GAP_ANALYSIS_RESOLVED.md`
> - `GAP-REDACT-NOT-WIRED` (#31, High) closed (coalesced with GAP-SEC-H-6 commit `0cb9a79`) → moved to `GAP_ANALYSIS_RESOLVED.md`
> - `GAP-DISABLED-TRACER-DOC` (#133, Medium) created (Phase 2 finding N1, verified Medium by Phase 3)
>
> Net flatfile gap counts (`gap`-labelled): −3 closed +1 created → 35 → **33 open** (then −1 Won't Do GAP-OTLP-PROFILES-EXPORT #25 → **32 open**).
>
> Note: The Phase 3 REGISTRY.md "scanner-corrected" 54-open figure folds in 17 quality / perf / security items that are tracked under separate labels (not `gap`). This flatfile mirrors only the `gap` label, so the count differs by design.

| Status          | Count |
|-----------------|-------|
| Not Implemented | 25    |
| Partial         | 6     |
| Implemented     | 7 (moved to `GAP_ANALYSIS_RESOLVED.md`) |
| Won't Do        | 1 (GAP-OTLP-PROFILES-EXPORT #25 — moved to `GAP_ANALYSIS_RESOLVED.md`) |
| Unknown         | 0     |

## Gap Index (Open)

| Gap-ID | Title | Status | Severity | Issue |
|--------|-------|--------|----------|-------|
| GAP-EXPORTER-FACTORY | OTEL_*_EXPORTER env vars parsed but never construct an exporter | Closed (`src/sdk/exporter_factory.zig` `Owned{Span,Metric,Log}Exporter` + `{span,metric,log}ExporterFromConfig` factories cover `none`/`stdout`/`in_memory`/`otlp_http`/`otlp_grpc`/`prometheus` mapping with protocol normalisation; `src/sdk/trace.zig:initFromConfig` + `src/sdk/logs.zig:initFromConfig` + `src/sdk/metrics.zig:initFromConfig` provider helpers; `MetricsConfig.default_exporter` + `MeterProvider.owned_exporter` + `TracerProvider.owned_exporter` + `LoggerProvider.owned_exporter` ownership tracking; `src/otel.zig` re-export `sdk.exporter_factory`; regression `test/exporter_factory.zig` covers env-var → kind dispatch, prometheus signal compatibility, lifecycle (testing-allocator leak detection), and `*Provider.initFromConfig` integration) | Critical | [#4](https://gitlab.com/devnw/zig/otel/-/issues/4) |
| GAP-OTLP-LOG-EXPORT | No OTLP log export path (HTTP /v1/logs or gRPC LogsService/Export) | Closed (`src/exporters/otlp_http/encode_logs.zig` `encodeLogsProto` + `groupLogsByScope`, `src/exporters/otlp_http/encode_json.zig:encodeLogsJson` (DevNW + stdlib paths), `src/exporters/otlp_http/logs.zig:expLogs` HTTP route at `/v1/logs`, `src/exporters/otlp_http/exporter.zig:logExporter` factory; gRPC route `src/exporters/otlp_grpc.zig:expLogs` at `/opentelemetry.proto.collector.logs.v1.LogsService/Export` + `logExporter` factory; DevNW parity `src/exporters/otlp_http/encode_proto_devnw.zig:encodeLogsProtoDevnw`; field-number constants `src/generated/otlp.zig:fn_resource_logs..fn_lr_event_name`; regression `test/otlp_logs_wire.zig`) | Critical | [#8](https://gitlab.com/devnw/zig/otel/-/issues/8) |
| GAP-OTLP-WIRE-EVENTS-LINKS | Span events (field 11) and links (field 13) never written to OTLP wire | Closed (`src/exporters/otlp_http/encode_proto.zig:281-291` Span.events at field 11 + dropped_events_count at field 12 + Span.links at field 13 + dropped_links_count at field 14, `:310-323` `writeEvent` helper, `:332-344` `writeLink` helper; `src/exporters/otlp_http/encode_proto_devnw.zig:124-156` Event/Link descriptors, `:173-191` Span.events / dropped_events_count / Span.links / dropped_links_count fields with field-numbers 11-14, `:312-340` populating events/links in `encodeSpansProtoDevnw`; regression `test/otlp_span_events_links.zig`) | Critical | [#9](https://gitlab.com/devnw/zig/otel/-/issues/9) |
| GAP-PROPAGATOR-B3 | B3 propagator never constructed even when OTEL_PROPAGATORS=b3 | Closed (`src/propagation/b3.zig` single + multi header propagators, `src/sdk/config.zig:propagatorBundleFromConfig` factory + `b3multi`/`none` env tokens, `src/propagation/propagator.zig` pluggable Composite; regression `test/propagator_b3.zig` covers 5+ positive + 4+ negative vectors per mode + 4 round-trip + composite end-to-end) | High | [#23](https://gitlab.com/devnw/zig/otel/-/issues/23) |
| GAP-PROPAGATOR-JAEGER | Jaeger uber-trace-id propagator never constructed when OTEL_PROPAGATORS=jaeger | Closed (`src/propagation/jaeger.zig` `uber-trace-id` SpanContext + `uberctx-*` per-entry baggage with URL-encoding; carrier iteration plumbing in `src/propagation/trace_context.zig` (`Carrier.iter` + `MapCarrier.iterFn`); factory wiring in `src/sdk/config.zig propagatorBundleFromConfig`; regression `test/propagator_jaeger.zig` covers 6 positive + 6 negative `uber-trace-id` vectors, 2 round-trip including baggage URL-encoding, and 2 end-to-end via the env-var → factory → Composite path) | High | [#24](https://gitlab.com/devnw/zig/otel/-/issues/24) |
| GAP-OTLP-WIRE-SCHEMA-URL | schema_url tracked on Resource but never emitted on the wire | Closed (`src/exporters/otlp_http/encode_proto.zig:333-342` ResourceSpans field 3, `:106-113` ResourceMetrics field 3, `src/exporters/otlp_http/encode_proto_devnw.zig:160-172,201-205`; regression `test/otlp_resource_schema_url.zig`) | High | [#26](https://gitlab.com/devnw/zig/otel/-/issues/26) |
| GAP-OTLP-COMPRESSION | gzip enum declared but encoder never applies it (HTTP or gRPC) | Not Implemented | High | [#27](https://gitlab.com/devnw/zig/otel/-/issues/27) |
| GAP-PERIODIC-METRIC-READER | PeriodicExportingMetricReader missing — long-running services emit no metrics until shutdown | Not Implemented | High | [#29](https://gitlab.com/devnw/zig/otel/-/issues/29) |
| GAP-OBSERVABLE-INSTRUMENTS | Observable Counter/UpDownCounter/Gauge API absent | Closed (`src/api/metrics.zig:81-` `ObservableCallback` + `Observer` + `ObservableRegistration` + `ObservableCounter`/`ObservableUpDownCounter`/`ObservableGauge` + `Meter.createObservable*`/`registerCallback`/`unregisterCallback` vtable; `src/sdk/metrics.zig:` `InstrumentBackend.callbacks` + `next_callback_id`, `makeObservableCounter`/`makeObservableUpDownCounter`/`makeObservableGauge`, `appendCallback`/`registerExtraCallback`/`unregisterCallback`, `ObserverCtx` + `observerObserveInt`/`observerObserveDouble`, `invokeCallbacksLocked` invoked at the head of `collect()` under `inst.mu` so concurrent sync writers cannot race observe-vs-snapshot; reuses the P0-1 hash-indexed `pointIndexFor` path; regression `test/observable_instruments.zig` covers single-callback, multi-callback registration order, idempotent unregister, double-precision gauge, cumulative last-write-wins, and sync+async coexistence) | High | [#30](https://gitlab.com/devnw/zig/otel/-/issues/30) |
| GAP-GRPC-STATUS-PROPAGATION | grpc-status trailers invisible to OTLP retry loop — server-side back-pressure dropped | **Blocked (upstream-grpc_zig)** | High | [#32](https://gitlab.com/devnw/zig/otel/-/issues/32) |
| GAP-ENV-BSP | OTEL_BSP_* env vars not parsed — BatchSpanProcessor unreconfigurable from env | Closed (`src/sdk/config.zig:193-198,415-422`, `src/sdk/export.zig:146-149`, `src/sdk/trace.zig:121-124,212`) | High | [#33](https://gitlab.com/devnw/zig/otel/-/issues/33) |
| GAP-ENV-METRIC-INTERVAL | OTEL_METRIC_EXPORT_INTERVAL/_TIMEOUT env vars not parsed | Closed (`src/sdk/config.zig:209-212,231,445-446`) — env-var parse only; reader wiring tracked under #29 | High | [#35](https://gitlab.com/devnw/zig/otel/-/issues/35) |
| GAP-VENDOR-PROTO | opentelemetry-proto v1.10.0 not vendored — golden tests cannot decode against canonical schema | Not Implemented | Medium | [#48](https://gitlab.com/devnw/zig/otel/-/issues/48) |
| GAP-VENDOR-SEMCONV | semantic-conventions v1.40.0 YAML not vendored | Not Implemented | Medium | [#49](https://gitlab.com/devnw/zig/otel/-/issues/49) |
| GAP-SEMCONV-COVERAGE | generated semconv covers ~60 attrs vs hundreds in stable v1.40.0 surface | Partial | Medium | [#50](https://gitlab.com/devnw/zig/otel/-/issues/50) |
| GAP-DEVNW-GRPC-H2C-ONLY | gRPC exporter cannot reach TLS-only production OTLP collectors | Partial | Medium | [#51](https://gitlab.com/devnw/zig/otel/-/issues/51) |
| GAP-PARTIAL-SUCCESS-PARSE | 207 Partial Success body never parsed for rejected counts / error_message | Partial | Medium | [#52](https://gitlab.com/devnw/zig/otel/-/issues/52) |
| GAP-DECLARATIVE-CONFIG-DEPTH | in-repo YAML loader rejects most spec-compliant otel.yaml trees | Partial | Medium | [#59](https://gitlab.com/devnw/zig/otel/-/issues/59) |
| GAP-ENV-OTLP-PER-SIGNAL-PROTOCOL | per-signal OTLP_*_PROTOCOL env vars not parsed | Not Implemented | Medium | [#60](https://gitlab.com/devnw/zig/otel/-/issues/60) |
| GAP-ENV-OTLP-PER-SIGNAL-TIMEOUT | per-signal OTLP_*_TIMEOUT env vars not parsed | Not Implemented | Medium | [#63](https://gitlab.com/devnw/zig/otel/-/issues/63) |
| GAP-ENV-OTLP-PER-SIGNAL-HEADERS | per-signal OTLP_*_HEADERS env vars not parsed | Not Implemented | Medium | [#64](https://gitlab.com/devnw/zig/otel/-/issues/64) |
| GAP-ENV-OTLP-PER-SIGNAL-COMPRESSION | no env var reader for compression at all | Not Implemented | Medium | [#66](https://gitlab.com/devnw/zig/otel/-/issues/66) |
| GAP-ENV-ATTR-LIMITS | spec attribute-limit env vars not parsed; limits hard-coded constants | Not Implemented | Medium | [#76](https://gitlab.com/devnw/zig/otel/-/issues/76) |
| GAP-INTEGRATION-SUITE-MISSING | test-integration and test-stress are aliases for test (no separate coverage) | Not Implemented | Medium | [#79](https://gitlab.com/devnw/zig/otel/-/issues/79) |
| GAP-DISABLED-TRACER-DOC | disabled-mode tracer no-op contract undocumented and untested | Partial | Medium | [#133](https://gitlab.com/devnw/zig/otel/-/issues/133) |
| GAP-DEVNW-TLS-UNUSED | -Dotel_use_devnw_tls actually toggles std.http.Client; flag name is misleading | Partial | Low | [#95](https://gitlab.com/devnw/zig/otel/-/issues/95) |
| GAP-ENV-OTLP-PER-SIGNAL-INSECURE | OTEL_EXPORTER_OTLP_*_INSECURE env vars not parsed | Not Implemented | Low | [#96](https://gitlab.com/devnw/zig/otel/-/issues/96) |
| GAP-ENV-OTLP-MTLS | mTLS env vars not parsed; no fields for cert/key in OtlpConfig | Not Implemented | Low | [#97](https://gitlab.com/devnw/zig/otel/-/issues/97) |
| GAP-ENV-BLRP | OTEL_BLRP_* env vars not parsed (no log batch processor exists yet) | Not Implemented | Low | [#98](https://gitlab.com/devnw/zig/otel/-/issues/98) |
| GAP-FUZZ-DISABLED | zig-fuzz CI job disabled pending Zig 0.16 stdlib bug fix (upstream) | **Blocked (upstream-zig-stdlib)** | Low | [#99](https://gitlab.com/devnw/zig/otel/-/issues/99) |
| GAP-WINDOWS-TESTS-DISABLED | Windows test jobs disabled pending devnw/ci-catalog fix (upstream) | **Blocked (upstream-devnw-ci-catalog)** | Low | [#100](https://gitlab.com/devnw/zig/otel/-/issues/100) |
| GAP-BENCH-LOOPBACK-UNDOCUMENTED | bench loopback server (benchmarks/integration/loopback_server.zig) not declared in DEPENDENCIES.md or SPEC_COMPLIANCE.md | Partial | Low | [#112](https://gitlab.com/devnw/zig/otel/-/issues/112) |

## Dependency Graph

```text
#4 GAP-EXPORTER-FACTORY (Critical, gates many)
   ├─> #8  GAP-OTLP-LOG-EXPORT        (Critical)
   ├─> per-signal env vars: #60, #63, #64, #66, #96
   │   (without a factory, OTEL_*_EXPORTER and per-signal vars cannot affect runtime)
   └─> #23 GAP-PROPAGATOR-B3, #24 GAP-PROPAGATOR-JAEGER
       (OTEL_PROPAGATORS=b3 today picks the enum but no propagator is constructed)

(Closed) #7 GAP-OTLP-METRIC-EXPORT
   └─> still gates #29 GAP-PERIODIC-METRIC-READER and #35 GAP-ENV-METRIC-INTERVAL on the
       reader/interval side; exporter path itself is now landed.

#8 GAP-OTLP-LOG-EXPORT
   └─> #98 GAP-ENV-BLRP

#48 GAP-VENDOR-PROTO
   └─> Reproducible regression coverage for #8, #9, #26

#49 GAP-VENDOR-SEMCONV
   └─> #50 GAP-SEMCONV-COVERAGE

#30 GAP-OBSERVABLE-INSTRUMENTS
   └─> Implicitly needed before #29 can deliver async metrics

#133 GAP-DISABLED-TRACER-DOC
   └─> Independent — doc + test only (no code change required)
```

## Recommended Implementation Order

1. **#4 GAP-EXPORTER-FACTORY** — gates per-signal env-var family
2. **#8 GAP-OTLP-LOG-EXPORT** — pair with #98 (env BLRP) once factory lands
3. **#9 GAP-OTLP-WIRE-EVENTS-LINKS** — Critical wire shape
4. **Per-signal env-var family** — #60, #63, #64, #66, #96 — small once #4 lands
5. **Propagators** — #23, #24
6. **#29 + #30 + #35** — periodic metric reader + observable instruments + interval env
7. **Vendor schemas + semconv expansion** — #48, #49, #50
8. **#133 GAP-DISABLED-TRACER-DOC** — opportunistic; one test + one paragraph

## Per-Gap Detail

For full evidence, spec citations, recommended fixes, and acceptance criteria, see the issue body on GitLab. Phase 3 source notes live in `docs/audit/gap-detector/REGISTRY.md`. Phase 4 sync mutations are recorded in `docs/audit/gap-detector/SYNC_PLAN.md`.
