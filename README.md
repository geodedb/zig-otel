# otel — OpenTelemetry for Zig

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org/)

Production-grade OpenTelemetry client library for Zig 0.16. Implements the
stable surface of OpenTelemetry Specification 1.56.0 (traces, metrics, logs,
events, propagation, resources, semantic conventions, and OTLP export).

> **Profiles signal: NOT IMPLEMENTED.** The upstream OTLP profiles proto is
> still under `opentelemetry/proto/profiles/v1development/` (unstable). This
> repo ships an inert API stub that returns
> `error.UnsupportedTransport`; no exporter wire path exists. Tracking under
> [GAP-OTLP-PROFILES-EXPORT (#25)](https://gitlab.com/devnw/zig/otel/-/issues/25)
> — closed Won't Do until the upstream proto reaches `v1`. Will revisit when
> the spec stabilizes.

| Layer            | Spec version |
|------------------|--------------|
| OpenTelemetry    | 1.56.0       |
| OTLP             | 1.10.0       |
| Semantic conv.   | 1.40.0       |
| Declarative cfg. | 1.0.0        |

## Highlights

- W3C Trace Context + Baggage propagators with typed errors.
- TracerProvider, MeterProvider, LoggerProvider — caller-supplied allocator,
  clock, RNG, and IO. No hidden globals, no auto-spawned threads.
- Samplers: AlwaysOn, AlwaysOff, ParentBased, TraceIdRatioBased.
- Metric instruments: Counter, UpDownCounter, Histogram, Gauge plus
  observable variants. Cumulative and delta temporality, explicit-bucket
  histograms, exemplar-ready data point shape.
- Exporters: in-memory, stdout JSON, file JSONL, Prometheus text format,
  OTLP/HTTP (protobuf and JSON), unary OTLP/gRPC framing helper.
- Pluggable transport seam — production HTTP/HTTPS via `std.http.Client`
  behind `-Dotel_use_devnw_tls=true`; OTLP/gRPC unary via DevNW `grpc-zig`
  behind `-Dotel_use_devnw_grpc=true` (**experimental**: refuses
  `https://` endpoints and any non-empty `headers` until the upstream
  client gains TLS and metadata support — see GAP-SEC-C-2 / GAP-SEC-C-3);
  async `BatchSpanProcessor` worker pool via DevNW `thread-pool` behind
  `-Dotel_use_devnw_pool=true`. See
  [`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md).
- `OTEL_*` environment variables and `OTEL_CONFIG_FILE` YAML loader. Code
  &gt; YAML &gt; env &gt; defaults precedence with fail-closed validation.
- Generated semantic-convention constants (resource, HTTP, network, process,
  host, OS, service, exception, log, runtime, event, profile).
- Secret redaction (`password`, `secret`, `token`, `api.key`,
  `authorization`, `credential`) with separator-aware matching. Redaction
  applies to attribute **values** (matched by key heuristic). Log record
  **bodies** are free-form and are NOT automatically redacted — scrub
  secrets from log bodies before emitting.
- `std.log` bridge, HTTP client/server helpers, runtime/process metric
  helper.
- Profiles signal: NOT IMPLEMENTED — upstream proto is `/v1development/`
  (unstable). The `-Dotel_profiles=true` build flag compiles the API
  scaffolding but every emit returns `error.UnsupportedTransport`.
  Tracking under issue #25; will revisit when proto reaches v1.
- Deterministic tests — fixed IDs, stepped clocks, in-memory exporter.

## Install

Drop the library in `build.zig.zon` once a public commit is pinned:

```zig
.dependencies = .{
    .otel = .{
        .url = "git+https://github.com/devnw/zig-otel#<commit-sha>",
        .hash = "<package-hash>",
    },
},
```

Then in `build.zig`:

```zig
const otel = b.dependency("otel", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("otel", otel.module("otel"));
```

## Quick start

```zig
const std = @import("std");
const otel = @import("otel");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var resource = try otel.sdk.resource.defaultResource(allocator);
    defer resource.deinit();
    try resource.attributes.putString(otel.semconv.service_name, "my-service");

    var stdout = otel.exporters.stdout_json.StdoutJson.init(allocator);
    var tp = try otel.sdk.trace.TracerProvider.init(allocator, .{
        .resource = &resource,
        .default_exporter = stdout.spanExporter(),
    });
    defer tp.deinit();

    const tracer = tp.tracer(.{ .name = "my-component" });
    const span = try tracer.startSpan(.empty(), "request", .{ .kind = .server });
    span.setStatus(.ok, "");
    span.end(null);
}
```

### Log/trace correlation

Spans are not made "current" automatically (the SDK follows OpenTelemetry's
explicit-activation model). To have logs emitted on this thread carry the
active span's `trace_id`/`span_id`, activate the span with `makeCurrent()`
and restore the prior context when the scope ends:

```zig
var span = try tracer.startSpan(.empty(), "work", .{});
defer span.end(null);

const scope = span.makeCurrent();        // span is now the ambient context
defer otel.api.context.restore(scope);   // pop back on scope exit (LIFO)

logger.emit(.{ .severity = .info, .body = .{ .string = "in span" } });
// ^ trace_id/span_id are stamped from `span` automatically.
```

Correlation is fill-if-empty: a record that already carries an explicit
trace/span identity is never overwritten, and emits outside any active span
stay uncorrelated.

See [`examples/basic.zig`](examples/basic.zig) and
[`examples/http_client.zig`](examples/http_client.zig) for runnable demos.

## Configuration

```text
OTEL_SDK_DISABLED               true|false (default false)
OTEL_LOG_LEVEL                  trace|debug|info|warn|error
OTEL_TRACES_SAMPLER             always_on|always_off|parentbased_*|traceidratio
OTEL_TRACES_SAMPLER_ARG         0.0..1.0
OTEL_TRACES_EXPORTER            otlp|console|memory|none
OTEL_METRICS_EXPORTER           otlp|console|prometheus|none
OTEL_LOGS_EXPORTER              otlp|console|none
OTEL_EXPORTER_OTLP_ENDPOINT     http(s)://host:port (default http://localhost:4318)
OTEL_EXPORTER_OTLP_PROTOCOL     http/protobuf|http/json|grpc
OTEL_EXPORTER_OTLP_TIMEOUT      milliseconds (default 10000)
OTEL_EXPORTER_OTLP_HEADERS      key=val,key=val (passed verbatim)
OTEL_SERVICE_NAME               service.name resource attribute
OTEL_RESOURCE_ATTRIBUTES        comma-separated k=v list
OTEL_PROPAGATORS                tracecontext|baggage|b3|jaeger|composite
OTEL_CONFIG_FILE                path to YAML declarative config
```

YAML schema (subset, see [`docs/SPEC_COMPLIANCE.md`](docs/SPEC_COMPLIANCE.md)):

```yaml
file_format: 1.0.0
disabled: false
log_level: info
tracer_provider:
  exporter: otlp
  endpoint: http://localhost:4318
  protocol: http/protobuf
meter_provider:
  exporter: prometheus
logger_provider:
  exporter: console
```

Code-supplied overrides win over YAML, which wins over env, which wins over
defaults. Validation failures are fatal (return `error.InvalidConfig`).

## Build, test, golden

```bash
zig version                                        # must print 0.16.0
zig fmt --check build.zig src test tools examples  # zero diff
zig build test -Doptimize=Debug                    # leak-free
zig build test -Doptimize=ReleaseSafe              # leak-free
zig build golden -- trace-context                  # exact stdout match
zig build golden -- signals                        # exact stdout match
zig build golden -- invalid-traceparent            # exit 2, stderr message
zig build golden -- redaction                      # exact stdout match
zig build run-basic                                # examples/basic.zig
zig build run-http-client                          # examples/http_client.zig
```

`-Dotel_profiles=true` compiles the experimental profiles API surface but
the export path is **not** implemented — every emit returns
`error.UnsupportedTransport`. The upstream proto is still under
`/v1development/` (unstable); see issue #25.
`-Ddeprecated_span_events=true` re-enables the legacy `Span.addEvent` shim
(bridged to logs).

## Optional DevNW backends

Build flags that swap an in-repo seam for the equivalent DevNW package
(or, for `tls`, the stdlib HTTP/HTTPS client). All default to `false` so
the hermetic stdlib build keeps working.

| Flag                               | Replaces                                                | Pinned upstream                          |
|------------------------------------|---------------------------------------------------------|------------------------------------------|
| `-Dotel_use_devnw_slog=true`       | `std.log` bridge formatter                              | `gitlab.com/devnw/zig/slog`              |
| `-Dotel_use_devnw_json=true`       | OTLP/JSON envelope encoder                              | `gitlab.com/devnw/zig/json`              |
| `-Dotel_use_devnw_config=true`     | `OTEL_CONFIG_FILE` YAML loader                          | `gitlab.com/devnw/zig/yaml` + `config`   |
| `-Dotel_use_devnw_protobuf=true`   | OTLP protobuf encoder (parallel, byte-parity gated)     | `gitlab.com/devnw/zig/protobuf`          |
| `-Dotel_use_devnw_metrics=true`    | Mirror metric writes into a DevNW Prometheus registry   | `gitlab.com/devnw/zig/metrics`           |
| `-Dotel_use_devnw_tls=true`        | OTLP/HTTP transport stub → real `std.http.Client` path  | `gitlab.com/devnw/zig/tls` (pinned for QUIC follow-on) |
| `-Dotel_use_devnw_grpc=true`       | OTLP/gRPC unary transport (with one upstream patch)     | `gitlab.com/devnw/zig/grpc-zig`          |
| `-Dotel_use_devnw_pool=true`       | Async `BatchSpanProcessor` worker (`async_workers > 0`) | `gitlab.com/devnw/zig/thread-pool`       |

Every flag is independently testable; the stdlib path remains the
default for hermetic CI. Pinned commit SHAs and Zig package hashes live
in `build.zig.zon`. See `docs/DEPENDENCIES.md` for the per-row
rationale, including known caveats (e.g. the gRPC loopback test is
currently skipped pending an upstream HTTP/2 framing fix).

## Compatibility

- Zig: exactly 0.16.0 (uses `std.process.Init`, `std.Io.Writer`,
  `std.os.linux.clock_gettime`).
- Platforms: Linux x86_64 and macOS aarch64. Other targets compile but the
  process-detector falls back to empty.
- Tests: hermetic — no network access, no environment dependence outside
  the explicit `OTEL_*` cases under test.

## Out of scope

Collector, vendor authentication beyond static headers, zero-code
instrumentation, kernel/eBPF profilers, persistent storage backends.

## License

Apache License 2.0. See [`LICENSE`](LICENSE) and
[`third_party/`](third_party/) for upstream notices.
