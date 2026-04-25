# Specification Compliance

This document lists every stable OpenTelemetry `MUST`/`REQUIRED` clause
implemented by this library, the source file that satisfies it, and the
test that demonstrates the behaviour. Items still tracking experimental or
optional sections are listed under "Limitations" with a short rationale.

| Spec area                  | Version | Status |
|----------------------------|---------|--------|
| OpenTelemetry Specification| 1.56.0  | implemented |
| OTLP Specification         | 1.10.0  | implemented (HTTP wire format complete; HTTP/HTTPS transport via `std.http.Client` when `-Dotel_use_devnw_tls=true`; HTTP/2 deferred) |
| Semantic Conventions       | 1.40.0  | constants generated |
| Declarative Configuration  | 1.0.0   | YAML subset, env vars, code overrides |

## Trace API

| Requirement                                            | File                              | Test |
|--------------------------------------------------------|-----------------------------------|------|
| TracerProvider.init takes allocator + config            | `src/sdk/trace.zig`               | `test/trace.zig: tracer end-to-end` |
| Tracer.startSpan returns a Span value                  | `src/sdk/trace.zig`               | `test/trace.zig` |
| Span.end(end_unix_nano) finalises the span             | `src/api/trace.zig`               | `test/trace.zig` |
| AlwaysOn / AlwaysOff samplers                          | `src/sdk/trace.zig`               | `test/trace.zig: alwaysOff` |
| ParentBased and TraceIdRatioBased samplers             | `src/sdk/trace.zig`               | unit tests in `src/sdk/trace.zig` |
| Sampling decision attached to SpanContext flags        | `src/sdk/trace.zig: startSpan`    | `test/trace.zig` |
| Status: setStatus(Ok) drops description                | `src/api/trace.zig: setStatus`    | covered by `test/trace.zig` end-to-end |
| Span.recordException records canonical attributes      | `src/api/trace.zig: recordException` | unit-tested via `test {}` block |
| Span.addEvent gated behind build flag                  | `src/api/trace.zig: addEvent`     | compile-time check |

## Propagation

| Requirement                                            | File                                  | Test |
|--------------------------------------------------------|---------------------------------------|------|
| W3C Trace Context inject                               | `src/propagation/trace_context.zig: inject` | `test/trace.zig`, golden `trace-context` |
| W3C Trace Context extract                              | `src/propagation/trace_context.zig: extract` | unit tests in `src/propagation/trace_context.zig` |
| Reject malformed traceparent (typed error)             | same                                  | golden `invalid-traceparent` |
| Reject upper-case version hex                          | same                                  | unit + golden |
| Reject ff version (forwards-incompat)                  | same                                  | unit |
| Reject zero trace/span ids                             | same                                  | unit |
| W3C Baggage inject/extract                             | `src/propagation/baggage.zig`         | `test/baggage.zig` |
| Baggage 180 entries, 4096 bytes, 256-byte key limits   | `src/api/baggage.zig`                 | `src/api/baggage.zig` unit tests |
| Composite propagator                                   | `src/propagation/composite.zig`       | unit tests in same file |

## Metrics API

| Requirement                                            | File                              | Test |
|--------------------------------------------------------|-----------------------------------|------|
| Counter / UpDownCounter / Histogram / Gauge            | `src/api/metrics.zig`             | `test/metrics.zig` |
| Cumulative + delta temporality                         | `src/sdk/metrics.zig`             | `test/metrics.zig: delta vs cumulative` |
| Explicit-bucket histogram                              | `src/sdk/metrics.zig: pointFor`   | `test/metrics.zig: histogram bucket layout` |
| Observable instruments (descriptor)                    | `src/api/metrics.zig`             | descriptor coverage |
| Per-attribute-set point identity                       | `src/sdk/metrics.zig: attributeKey` | implicit in metrics test |

## Logs API

| Requirement                                            | File                              | Test |
|--------------------------------------------------------|-----------------------------------|------|
| LoggerProvider.init takes allocator + config            | `src/sdk/logs.zig`                | `test/logs.zig` |
| Severity enum (24 levels)                               | `src/api/logs.zig`                | `test/logs.zig: severity short text` |
| LogRecord trace/span correlation                        | `src/sdk/logs.zig: correlate`     | `test/logs.zig: logger correlates` |
| Event builder injects `event.name`                      | `src/api/events.zig`              | unit test in same file |

## Resources

| Requirement                                            | File                              | Test |
|--------------------------------------------------------|-----------------------------------|------|
| defaultResource carries telemetry.sdk.* attributes      | `src/sdk/resource.zig`            | `src/sdk/resource.zig` unit tests |
| Resource merge (right-hand wins)                        | `src/sdk/resource.zig: merge`     | unit |
| Env detector reads OTEL_SERVICE_NAME / OTEL_RESOURCE_ATTRIBUTES | `src/sdk/resource.zig: envDetect` | unit |
| Process / OS / Host detectors                           | `src/sdk/resource.zig`            | run-basic example |

## Configuration

| Requirement                                            | File                              | Test |
|--------------------------------------------------------|-----------------------------------|------|
| `OTEL_*` environment variables                          | `src/sdk/config.zig: applyEnv`    | `test/config.zig` |
| `OTEL_CONFIG_FILE` YAML loader (subset)                 | `src/sdk/config.zig: applyYaml`   | unit test in same file |
| Precedence: code &gt; YAML &gt; env &gt; defaults       | `src/sdk/config.zig: resolve`     | covered by env + code-overrides test |
| Validation fails closed                                 | `src/sdk/config.zig: validate`    | `test/config.zig: validate rejects empty endpoint` |

## OTLP Export

| Requirement                                            | File                                 | Test |
|--------------------------------------------------------|--------------------------------------|------|
| HTTP endpoint default `http://localhost:4318`          | `src/sdk/config.zig: OtlpConfig`     | unit |
| gRPC endpoint default `http://localhost:4317`          | same                                 | unit |
| Paths `/v1/traces`, `/v1/metrics`, `/v1/logs`,         | `src/exporters/otlp_http.zig`        | code review |
| `/v1development/profiles` (experimental)               | `src/exporters/otlp_http.zig`        | profile gate |
| Timeout 10 s default                                   | `src/sdk/config.zig: OtlpConfig`     | unit |
| Retry backoff 100 ms initial, x2, max 5 s, max 30 s, full jitter | `src/sdk/export.zig: nextBackoff` | unit + `test/otlp.zig: retries on 503` |
| Partial success returns `error.PartialSuccess`         | `src/exporters/otlp_http.zig`        | `test/otlp.zig: PartialSuccess on 207` |
| HTTPS TLS validation on by default                     | `src/sdk/config.zig: OtlpConfig.skip_tls_verify` (default false) | doc |
| HTTP/HTTPS transport (real client, not just vtable)    | `src/exporters/otlp_http.zig: httpTransportImpl` (uses `std.http.Client` + `std.crypto.tls`) | `test/tls_loopback.zig: round-trips a span` (gated on `-Dotel_use_devnw_tls=true`) |
| Protobuf wire encoder for spans                        | `src/exporters/otlp_http.zig: encodeSpansProto` | unit |
| JSON wire encoder for spans                            | `src/exporters/otlp_http.zig: encodeSpansJson`  | unit |
| gRPC unary 5-byte length prefix                        | `src/exporters/otlp_grpc.zig: frame` | `test/otlp.zig: gRPC frame prefix` |
| OTLP/gRPC unary transport (real client)                | `src/exporters/otlp_grpc.zig: unaryExport` (uses DevNW `grpc-zig`) | `test/grpc_loopback.zig: round-trips a span` (gated on `-Dotel_use_devnw_grpc=true`) |

## Security

| Requirement                                            | File                              | Test |
|--------------------------------------------------------|-----------------------------------|------|
| Redaction of password/secret/token/api.key/authorization/credential | `src/internal/redact.zig` | `test/security.zig` |
| Case-insensitive matching                              | `src/internal/redact.zig: isSensitive` | `test/security.zig: case-insensitive` |
| Max 128 attributes                                     | `src/internal/attributes.zig`     | `src/internal/attributes.zig` unit |
| Max 256-byte attribute keys                            | `src/internal/attributes.zig`     | unit |
| Max 4096-byte string values                            | `src/internal/attributes.zig`     | `test/security.zig: caps strings` |
| HTTPS scheme validation in OTLP exporter               | `src/exporters/otlp_http.zig`     | `test/security.zig: rejects ftp` |

## Limitations &amp; deferred work

- **HTTP/HTTPS transport**: `OtlpHttpExporter` ships with a vtable seam
  for tests. The real HTTP/HTTPS client (powered by `std.http.Client`
  with built-in `std.crypto.tls`) is wired behind
  `-Dotel_use_devnw_tls=true`; the flag's name is preserved from the
  pre-pivot Phase 6 plan but its semantics are now "switch the
  transport from the `UnsupportedTransport` stub to the real
  `std.http.Client` path". Without the flag (or without an `Io` plumbed
  into the exporter), `httpTransport` returns
  `error.UnsupportedTransport` so misconfigurations remain loud. See
  `docs/DEPENDENCIES.md` (TLS row) for the rationale and `test/tls_loopback.zig`
  for the round-trip acceptance test.
- **HTTP/2 + gRPC transport**: `OtlpGrpcExporter` ships with both the
  framing primitives (`frame()`) and a real unary transport powered by
  DevNW `grpc-zig` (HTTP/2 + h2c) behind `-Dotel_use_devnw_grpc=true`.
  Without the flag (or without an `Io` plumbed into the exporter),
  `expSpans` returns `error.UnsupportedTransport`. The pin includes a
  one-line patch to grpc-zig's `transport.zig::ioWrite` that fixes a
  Zig-0.16 stdlib underflow when the additional-buffers slice is empty
  — see `docs/DEPENDENCIES.md` (gRPC row) for the full rationale and
  `test/grpc_loopback.zig` for the round-trip acceptance test.
- **BatchSpanProcessor**: ships in synchronous-drain form. The 0.16
  `std.Io` API moved background coordination behind an `Io` instance; once
  the SDK accepts an `Io` (planned), the worker-thread variant returns
  with the original sub-second flush cadence.
- **YAML parser**: covers the OTel declarative-config 1.0.0 mappings
  required by `tracer_provider`, `meter_provider`, `logger_provider`, and
  the top-level scalars (`disabled`, `log_level`, `file_format`). Anchors,
  multi-document streams, and complex flow nodes are not supported.
- **Profiles**: signal types and the OTLP exporter path are wired but
  gated behind `-Dotel_profiles=true`. The default build ships an inert
  stub that returns `error.UnsupportedTransport`.
