# Dependencies

This library is intentionally hermetic in its initial release: it builds and
tests without fetching any third-party Zig packages. The DevNW open-source
catalogue is the preferred upstream for every component below; the
substitution column lists the seam where the in-repo implementation can be
swapped for the external package once a stable 0.16-compatible commit is
pinned.

## Source-of-truth order

For every component the resolution order is:

1. `github.com/devnw/zig/<package>` — when public and Zig 0.16 compatible.
2. `gitlab.com/devnw/zig/<package>` — when GitHub source is unavailable.
3. Zig stdlib or this repo's own implementation — recorded with reason.

The current state is captured below. License names are taken from each
upstream's `LICENSE` file. All listed candidates are MIT, Apache-2.0, BSD,
or ISC.

| Component             | Used by                                                | Source-of-truth candidate (DevNW)             | License     | Current implementation | Reason for current state |
|-----------------------|--------------------------------------------------------|-----------------------------------------------|-------------|------------------------|--------------------------|
| Structured logger     | `src/instrumentation/std_log.zig` (`std.log` bridge)   | `gitlab.com/devnw/zig/slog`                    | Apache-2.0  | `std.log` callback shim | Hermetic build; slog adds 5 transitive deps |
| Thread pool           | Future `BatchSpanProcessor` worker variant             | `gitlab.com/devnw/zig/thread-pool`             | Apache-2.0  | None — synchronous drain | 0.16's `std.Io` requires an Io context per `Mutex/Condition`; thread-pool integration deferred until the SDK takes an `Io` |
| Protobuf encoder      | `src/generated/otlp.zig`                                | `gitlab.com/devnw/zig/protobuf`                | Apache-2.0  | Hand-rolled varint encoder | Avoids pulling protoc into the build, keeps wire format introspectable for golden tests |
| gRPC client           | `src/exporters/otlp_grpc.zig`                          | `gitlab.com/devnw/zig/grpc-zig`                | Apache-2.0  | Length-prefix framing only; transport returns `UnsupportedTransport` | grpc-zig depends on zlib + HTTP/2 + tls; landing as a follow-on once those compile on 0.16 |
| TLS                   | `src/exporters/otlp_http.zig` (HTTPS)                   | `gitlab.com/devnw/zig/tls`                     | Apache-2.0  | Transport vtable seam; default returns `UnsupportedTransport` | TLS bring-up tracked separately — keeps tests offline |
| JSON encoder/decoder  | `src/internal/json_codec.zig` and OTLP/JSON path       | `gitlab.com/devnw/zig/json`                    | Apache-2.0  | Hand-rolled stable-shape encoder | Golden tests pin exact byte-level output; in-repo encoder gives that without a dep boundary |
| YAML parser           | `src/sdk/config.zig` declarative config loader         | `gitlab.com/devnw/zig/yaml` (via `config`)    | Apache-2.0  | In-repo subset parser | Spec-required subset is small; full YAML deferred to avoid pulling in `config`'s transitive graph |
| Configuration         | `src/sdk/config.zig`                                   | `gitlab.com/devnw/zig/config`                  | Apache-2.0  | In-repo `Config` struct + env layer | Same rationale as the YAML parser |
| String helpers        | Internal formatters                                    | `gitlab.com/devnw/zig/strings`                 | Apache-2.0  | `std.fmt` / `std.mem` | stdlib is sufficient for the small set used here |
| Metrics               | `src/sdk/metrics.zig` aggregation                      | `gitlab.com/devnw/zig/metrics`                 | Apache-2.0  | In-repo aggregation pipeline | OpenTelemetry data-point shape differs from `metrics`' Prometheus-first model; in-repo keeps the SDK contract isolated |
| URI parsing           | `src/sdk/config.zig` endpoint validation               | `gitlab.com/devnw/zig/uri`                     | MIT         | scheme prefix check    | Endpoint validation is a single substring match — full URI parsing not needed yet |
| DNS                   | Future endpoint resolution                              | `gitlab.com/devnw/zig/dns`                     | Apache-2.0  | None                  | Resolution lives inside the HTTP transport (stdlib) when we land it |
| Write-ahead log       | Future durable export queue                             | `gitlab.com/devnw/zig/wal`                     | Apache-2.0  | None                  | Out of scope for this release |

## Pinning a DevNW dependency

When wiring any of the above, edit `build.zig.zon` to add the dependency
with an immutable commit SHA and the Zig package hash:

```zig
.dependencies = .{
    .slog = .{
        .url = "git+https://gitlab.com/devnw/zig/slog#<commit-sha>",
        .hash = "slog-<version>-<hash>",
    },
},
```

Then edit `build.zig` to call `b.dependency("slog", ...)` and pass the
returned module to the `otel_module` import list. Tests should be re-run
with a clean cache. The build system rejects floating branches at lock
resolution time.

## Third-party LICENSE notices

The OpenTelemetry Proto and Semantic Conventions repositories are
referenced as data only; the relevant LICENSE excerpts live under
`third_party/opentelemetry-proto-v1.10.0/LICENSE` and
`third_party/semantic-conventions-v1.40.0/LICENSE`.
