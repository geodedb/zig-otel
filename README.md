# otel — OpenTelemetry for Zig

[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16.0-orange.svg)](https://ziglang.org/)

Production-grade OpenTelemetry client library for Zig 0.16. Implements the
stable surface of OpenTelemetry Specification 1.56.0 (traces, metrics, logs,
events, propagation, resources, semantic conventions, and OTLP export) with
the experimental profiles signal behind a build flag.

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
- Pluggable transport seam — production HTTP/gRPC implementations bind to
  TLS/HTTP2 once those dependencies are wired (see
  [`docs/DEPENDENCIES.md`](docs/DEPENDENCIES.md)).
- `OTEL_*` environment variables and `OTEL_CONFIG_FILE` YAML loader. Code
  &gt; YAML &gt; env &gt; defaults precedence with fail-closed validation.
- Generated semantic-convention constants (resource, HTTP, network, process,
  host, OS, service, exception, log, runtime, event, profile).
- Secret redaction (`password`, `secret`, `token`, `api.key`,
  `authorization`, `credential`) with separator-aware matching.
- `std.log` bridge, HTTP client/server helpers, runtime/process metric
  helper.
- Experimental profiles signal behind `-Dotel_profiles=true`.
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

`-Dotel_profiles=true` enables the experimental profiles signal.
`-Ddeprecated_span_events=true` re-enables the legacy `Span.addEvent` shim
(bridged to logs).

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
