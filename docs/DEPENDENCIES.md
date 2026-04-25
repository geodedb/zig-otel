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
| Structured logger     | `src/instrumentation/std_log.zig` (`std.log` bridge)   | `gitlab.com/devnw/zig/slog`                    | Apache-2.0  | DevNW `slog` (pinned `65e0792d4140a736fb1e04a7b1ee84c9333d58a9`) when `-Dotel_use_devnw_slog=true`, stdlib otherwise | Hermetic build by default; slog adds 5 transitive deps when enabled |
| Thread pool           | `src/sdk/export.zig` `BatchSpanProcessor` async drain   | `gitlab.com/devnw/zig/thread-pool`             | Apache-2.0  | DevNW `thread-pool` (pinned `ad878c812a5ee000098bc32b6ec3508b45289354`) drives the off-producer drain when `-Dotel_use_devnw_pool=true` and the caller sets `BatchSpanProcessorOptions.async_workers > 0`; defaults to the synchronous drain otherwise. The pool wraps 0.16's `std.Io.Mutex` / `std.Io.Clock` behind the legacy zero-arg surface (`tp.sync.Mutex`, `tp.clock.nanoTimestamp`, `tp.clock.sleep`) so the processor doesn't have to plumb an `Io` through its public API. `forceFlush(timeout_ms)` polls a `pending_tasks` atomic + queue length until both reach zero, bounded by the timeout — the pool's `WaitGroup` API is available for future bulk-coordination use but the polled-counter path is deadlock-free even when the producer thread is itself a pool worker. | Hermetic build by default; the async path costs one futex per drain enqueue and one mutex acquire per export call |
| Protobuf encoder      | `src/generated/otlp.zig` and `src/exporters/otlp_http.zig` | `gitlab.com/devnw/zig/protobuf`                | Apache-2.0  | DevNW `protobuf` (pinned `f18747d87010afc0517a0f0e40cb00fd352e4191`) provides a sibling `encodeSpansProtoDevnw` exposed when `-Dotel_use_devnw_protobuf=true`; the in-repo hand-rolled varint encoder remains the default and is the byte-equality contract enforced by `test/otlp_wire_parity.zig` | Hermetic build by default; the parity test guarantees the typed DevNW path emits identical OTLP wire bytes before any production routing flips to it |
| gRPC client           | `src/exporters/otlp_grpc.zig`                          | `gitlab.com/devnw/zig/grpc-zig`                | Apache-2.0  | DevNW `grpc-zig` (pinned `fd5405b860f25e3dd9226b3d63b676ab58f183d4`) drives the real OTLP/gRPC unary transport when `-Dotel_use_devnw_grpc=true` and `OtlpGrpcExporter.io` is plumbed; without the flag (or without an `Io`), `expSpans` returns `UnsupportedTransport`. The build composes the upstream `grpc-client` + `grpc-server` modules into one umbrella module (`third_party/grpc_zig/all.zig`) so the library and its loopback test server can both consume them without the Zig 0.16 "same source file in two modules" error. The pin includes a one-line upstream patch (`src/transport.zig::ioWrite`) that fixes a `std.Io.Threaded.netWritePosix` integer-underflow panic when grpc-zig passes `&.{}` as the additional-buffers slice. | The transport-vtable seam stays in place so the framing helper (`frame()`) remains exported for callers driving a custom HTTP/2 stack; the loopback test (`test/grpc_loopback.zig`) exercises the full unary round trip against an in-process `grpc-zig` server, h2c only |
| TLS                   | `src/exporters/otlp_http.zig` (HTTPS)                   | `gitlab.com/devnw/zig/tls` (deferred — see notes) | Apache-2.0  | stdlib `std.http.Client` (with built-in `std.crypto.tls`) drives the real HTTP/HTTPS transport when `-Dotel_use_devnw_tls=true` and `OtlpHttpExporter.io` is plumbed; without the flag (or without an `Io`), `httpTransport` returns `UnsupportedTransport`. The DevNW `tls` package is pinned (`c0895db0adc841abdb44bd8ff6fe1edd3e321aa6`) for **future QUIC integration only** — it is QUIC-first (RFC 9001): `src/record.zig:28-33` documents that "the TLS record layer is NOT used for packet framing", and the public client API (`processCrypto(level, data)`) consumes QUIC CRYPTO frames rather than TCP bytes. The pinned dep currently has no callers in `otel`. | Phase 6 originally aimed to drive HTTPS through DevNW `tls`, but the package's QUIC-first architecture would have required a multi-thousand-line TLS-over-TCP record-layer driver. Pivoted to `std.http.Client` (Task 6.3 in the dispatch plan) which gives a working HTTP/HTTPS transport without that work. **The `-Dotel_use_devnw_tls=true` flag name is preserved** but its semantics are now "switch the transport from the `UnsupportedTransport` stub to the real `std.http.Client` path"; the DevNW `tls` dep remains pinned so the QUIC follow-on (e.g. OTLP/gRPC over QUIC) can land without re-pinning. The loopback test (`test/tls_loopback.zig`) round-trips a span against an in-process `std.http.Server` to gate the URL-build, header-plumbing, body-framing, and status-translation paths. |
| JSON encoder/decoder  | `src/internal/json_codec.zig` and OTLP/JSON path       | `gitlab.com/devnw/zig/json`                    | Apache-2.0  | DevNW `json` (pinned `30b3983dfaab83ebc827205567c32542e111616b`) wraps the OTLP/JSON body when `-Dotel_use_devnw_json=true`; in-repo `spanToJson` still produces per-span output (golden bytes unchanged), stdlib otherwise | Per-span JSON shape is gated by golden tests, so the dep is wired at the `{"resourceSpans":[...]}` seam only |
| YAML parser           | `src/sdk/config.zig` declarative config loader         | `gitlab.com/devnw/zig/yaml` (via `config`)    | Apache-2.0  | DevNW `yaml` (pinned `d2151db9c6da63a71538d3118a5f064079facbf7`) backs `applyYamlStringDevnw` and is dispatched from `resolve()` when `-Dotel_use_devnw_config=true`; in-repo subset parser remains the default | Hermetic build by default; full YAML pulls `thread-pool` plus the `config` transitive graph when enabled |
| Configuration         | `src/sdk/config.zig`                                   | `gitlab.com/devnw/zig/config`                  | Apache-2.0  | DevNW `config` (pinned `7eda77bda98f5bf48570f43ec292ec9219f71480`) is added to the dependency graph alongside `yaml` when `-Dotel_use_devnw_config=true`; in-repo `Config` struct + env layer is still the source of truth, with `config`'s layered loader reserved for follow-on work | Same flag gates both packages so the transitive graph (encrypted_secrets, environ, dotenv, parallel, …) only resolves on opt-in |
| String helpers        | Internal formatters                                    | `gitlab.com/devnw/zig/strings`                 | Apache-2.0  | `std.fmt` / `std.mem` | stdlib is sufficient for the small set used here |
| Metrics               | `src/sdk/metrics.zig` aggregation                      | `gitlab.com/devnw/zig/metrics`                 | Apache-2.0  | DevNW `metrics` (pinned `cdf63b99240a8c49eefd63475d9d88adcc3dd3ad`) is wired as a parallel Prometheus-shaped registry when `MetricsConfig.backend = .devnw` and `-Dotel_use_devnw_metrics=true`; the in-repo aggregation pipeline still owns the OpenTelemetry data-point shape returned by `collect()` and the SDK mirrors counter / up-down / histogram / gauge writes into the DevNW `Registry` so Prometheus exposure surfaces alongside OTLP | DevNW `metrics` is Prometheus-first (unlabelled, `u64` counters, `i64` gauges) and does not match OTLP's labelled / `f64` data-point shape; mirroring keeps the OTLP contract intact while exposing the DevNW registry for `writePrometheus` consumers |
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
