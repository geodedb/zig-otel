# Gap Analysis

> Source of truth: GitLab issue tracker at <https://gitlab.com/devnw/zig/otel/-/issues>
> This file is a flatfile mirror of issues labelled `gap`. Issue tracker is authoritative.
>
> **Last sync:** 2026-04-26 (PM re-audit — Phase 4 gap-sync)
> **Source:** `docs/audit/GAP_DETECTION.md` (37 Gap-IDs classified by Phase 3) + 1 docs gap added in PM re-audit (GAP-BENCH-LOOPBACK-UNDOCUMENTED)

## Status / Severity Summary

| Severity | Open | Resolved | Total |
|----------|------|----------|-------|
| Critical | 6 | 0 | 6 |
| High     | 11 | 0 | 11 |
| Medium   | 12 | 1 | 13 |
| Low      | 7  | 1 | 8 |
| **Total**| **36** | **2** | **38** |

> PM re-audit delta (2026-04-26): **GAP-BENCH-NOT-WIRED** (#78, Medium) closed — moved to GAP_ANALYSIS_RESOLVED.md. **GAP-BENCH-LOOPBACK-UNDOCUMENTED** (#112, Low) added.

| Status          | Count |
|-----------------|-------|
| Not Implemented | 30    |
| Partial         | 6     |
| Implemented     | 2 (moved to GAP_ANALYSIS_RESOLVED.md) |
| Unknown         | 0     |

## Gap Index (Open)

| Gap-ID | Title | Status | Severity | Issue |
|--------|-------|--------|----------|-------|
| GAP-INSTRUMENTATION-SCOPE-PROPAGATION | Tracer scope never reaches SpanState (one-line bug at src/sdk/trace.zig:254) | Not Implemented | Critical | [#1](https://gitlab.com/devnw/zig/otel/-/issues/1) |
| GAP-OTLP-WIRE-INSTRUMENTATION-SCOPE | ScopeSpans.scope.name always empty in OTLP wire output | Not Implemented | Critical | [#3](https://gitlab.com/devnw/zig/otel/-/issues/3) |
| GAP-EXPORTER-FACTORY | OTEL_*_EXPORTER env vars parsed but never construct an exporter | Not Implemented | Critical | [#4](https://gitlab.com/devnw/zig/otel/-/issues/4) |
| GAP-OTLP-METRIC-EXPORT | No OTLP metric export path (HTTP /v1/metrics or gRPC MetricsService/Export) | Not Implemented | Critical | [#7](https://gitlab.com/devnw/zig/otel/-/issues/7) |
| GAP-OTLP-LOG-EXPORT | No OTLP log export path (HTTP /v1/logs or gRPC LogsService/Export) | Not Implemented | Critical | [#8](https://gitlab.com/devnw/zig/otel/-/issues/8) |
| GAP-OTLP-WIRE-EVENTS-LINKS | Span events (field 11) and links (field 13) never written to OTLP wire | Not Implemented | Critical | [#9](https://gitlab.com/devnw/zig/otel/-/issues/9) |
| GAP-PROPAGATOR-B3 | B3 propagator never constructed even when OTEL_PROPAGATORS=b3 | Not Implemented | High | [#23](https://gitlab.com/devnw/zig/otel/-/issues/23) |
| GAP-PROPAGATOR-JAEGER | Jaeger uber-trace-id propagator never constructed when OTEL_PROPAGATORS=jaeger | Not Implemented | High | [#24](https://gitlab.com/devnw/zig/otel/-/issues/24) |
| GAP-OTLP-PROFILES-EXPORT | docs claim /v1development/profiles support but API returns UnsupportedTransport | Not Implemented | High | [#25](https://gitlab.com/devnw/zig/otel/-/issues/25) |
| GAP-OTLP-WIRE-SCHEMA-URL | schema_url tracked on Resource but never emitted on the wire | Not Implemented | High | [#26](https://gitlab.com/devnw/zig/otel/-/issues/26) |
| GAP-OTLP-COMPRESSION | gzip enum declared but encoder never applies it (HTTP or gRPC) | Not Implemented | High | [#27](https://gitlab.com/devnw/zig/otel/-/issues/27) |
| GAP-PERIODIC-METRIC-READER | PeriodicExportingMetricReader missing — long-running services emit no metrics until shutdown | Not Implemented | High | [#29](https://gitlab.com/devnw/zig/otel/-/issues/29) |
| GAP-OBSERVABLE-INSTRUMENTS | Observable Counter/UpDownCounter/Gauge API absent | Not Implemented | High | [#30](https://gitlab.com/devnw/zig/otel/-/issues/30) |
| GAP-REDACT-NOT-WIRED | redact helpers exist but never invoked by any exporter — credential leakage risk | Partial | High | [#31](https://gitlab.com/devnw/zig/otel/-/issues/31) |
| GAP-GRPC-STATUS-PROPAGATION | grpc-status trailers invisible to OTLP retry loop — server-side back-pressure dropped | Partial | High | [#32](https://gitlab.com/devnw/zig/otel/-/issues/32) |
| GAP-ENV-BSP | OTEL_BSP_* env vars not parsed — BatchSpanProcessor unreconfigurable from env | Not Implemented | High | [#33](https://gitlab.com/devnw/zig/otel/-/issues/33) |
| GAP-ENV-METRIC-INTERVAL | OTEL_METRIC_EXPORT_INTERVAL/_TIMEOUT env vars not parsed | Not Implemented | High | [#35](https://gitlab.com/devnw/zig/otel/-/issues/35) |
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
| GAP-DEVNW-TLS-UNUSED | -Dotel_use_devnw_tls actually toggles std.http.Client; flag name is misleading | Partial | Low | [#95](https://gitlab.com/devnw/zig/otel/-/issues/95) |
| GAP-ENV-OTLP-PER-SIGNAL-INSECURE | OTEL_EXPORTER_OTLP_*_INSECURE env vars not parsed | Not Implemented | Low | [#96](https://gitlab.com/devnw/zig/otel/-/issues/96) |
| GAP-ENV-OTLP-MTLS | mTLS env vars not parsed; no fields for cert/key in OtlpConfig | Not Implemented | Low | [#97](https://gitlab.com/devnw/zig/otel/-/issues/97) |
| GAP-ENV-BLRP | OTEL_BLRP_* env vars not parsed (no log batch processor exists yet) | Not Implemented | Low | [#98](https://gitlab.com/devnw/zig/otel/-/issues/98) |
| GAP-FUZZ-DISABLED | zig-fuzz CI job disabled pending Zig 0.16 stdlib bug fix (upstream) | Not Implemented | Low | [#99](https://gitlab.com/devnw/zig/otel/-/issues/99) |
| GAP-WINDOWS-TESTS-DISABLED | Windows test jobs disabled pending devnw/ci-catalog fix (upstream) | Not Implemented | Low | [#100](https://gitlab.com/devnw/zig/otel/-/issues/100) |
| GAP-BENCH-LOOPBACK-UNDOCUMENTED | bench loopback server (benchmarks/integration/loopback_server.zig) not declared in DEPENDENCIES.md or SPEC_COMPLIANCE.md | Partial | Low | [#112](https://gitlab.com/devnw/zig/otel/-/issues/112) |

## Dependency Graph

```text
#4 GAP-EXPORTER-FACTORY (Critical, gates many)
   ├─> #7  GAP-OTLP-METRIC-EXPORT     (Critical)
   ├─> #8  GAP-OTLP-LOG-EXPORT        (Critical)
   ├─> #25 GAP-OTLP-PROFILES-EXPORT   (High)
   ├─> per-signal env vars: #60, #63, #64, #66, #96
   │   (without a factory, OTEL_*_EXPORTER and per-signal vars cannot affect runtime)
   └─> #23 GAP-PROPAGATOR-B3, #24 GAP-PROPAGATOR-JAEGER
       (OTEL_PROPAGATORS=b3 today picks the enum but no propagator is constructed)

#7 GAP-OTLP-METRIC-EXPORT
   ├─> #29 GAP-PERIODIC-METRIC-READER (no point scheduling collect() if there is no exporter)
   └─> #35 GAP-ENV-METRIC-INTERVAL

#8 GAP-OTLP-LOG-EXPORT
   └─> #98 GAP-ENV-BLRP

#48 GAP-VENDOR-PROTO
   └─> Reproducible regression coverage for #7, #8, #9, #25, #26

#49 GAP-VENDOR-SEMCONV
   └─> #50 GAP-SEMCONV-COVERAGE

#30 GAP-OBSERVABLE-INSTRUMENTS
   └─> Implicitly needed before #29 can deliver async metrics

#1 GAP-INSTRUMENTATION-SCOPE-PROPAGATION  ←→  #3 GAP-OTLP-WIRE-INSTRUMENTATION-SCOPE
   (sibling pair — same root-cause bug at src/sdk/trace.zig:254; one fix closes both)
```

## Recommended Implementation Order

1. **Sibling pair** #1 + #3 — one-line fix at `src/sdk/trace.zig:254`, closes 2 Critical
2. **#4 GAP-EXPORTER-FACTORY** — gates per-signal env-var family
3. **#7 + #8 in parallel** — OTLP metric and log exporters
4. **Per-signal env-var family** — #60, #63, #64, #66, #96 — small once #4 lands
5. **Propagators** — #23, #24
6. **Vendor schemas + semconv expansion** — #48, #49, #50

## Per-Gap Detail

For full evidence, spec citations, recommended fixes, and acceptance criteria, see the issue body on GitLab. Phase 3 source notes live in `docs/audit/GAP_DETECTION.md`.
