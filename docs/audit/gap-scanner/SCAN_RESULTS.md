# Gap-Scanner Results — devnw/zig/otel

> Generated: 2026-04-27
> Scope: 108 open requirements from gap-collector catalog (catalog.json)
> Method: file:line tracing in src/, test/, build.zig + targeted greps + `zig build check`
> Build status at scan time: `zig build check` exit 0 (clean)

## Status histogram (open issues, n=108)

| Status            | Count | Notes |
|-------------------|------:|-------|
| Implemented       |     5 | Tracker-stale: code+tests already landed (#1, #3, #7, #31 partial, plus tests). |
| Partial           |    18 | Mostly perf P1/P2 items partially done; partial-success status detection but no body parse. |
| Not Implemented   |    73 | Includes #4, #8, #9, #23, #24, #26, #27, #29, #30, #33, #35, all per-signal env vars, mTLS, etc. |
| Unknown           |    12 | Quality/perf items requiring deeper bench harness review. |

(Counts are scanner-side reconciliation; tracker totals unchanged.)

## Top-10 highest-priority OPEN gaps with file:line evidence

| Rank | IID | Gap | Status | Evidence | Tests |
|----:|----:|-----|--------|----------|-------|
| 1 | #4 | EXPORTER-FACTORY: env vars parsed but no exporter is constructed | Not Implemented | `src/sdk/config.zig:342-350` parses `OTEL_TRACES/METRICS/LOGS_EXPORTER` into `ExporterKind` enum but no consumer of `cfg.traces.exporter` builds an exporter; `grep -rn "buildExporter\|exporterFromConfig"` returns 0 hits. | None. |
| 2 | #8 | OTLP-LOG-EXPORT: no `/v1/logs` or `LogsService.Export` path | Not Implemented | `grep -rn "/v1/logs\|LogsService\|encodeLogsProto"` -> 0 hits in `src/exporters/`. `src/sdk/logs.zig:40,126` only emits to in-process processors. | None. |
| 3 | #9 | OTLP-WIRE-EVENTS-LINKS: span events (field 11) and links (field 13) never written | Not Implemented | `src/generated/otlp.zig:191,193` declare `fn_span_events`/`fn_span_links` but `grep` shows zero use sites in `src/exporters/`. `src/api/trace.zig:138` only iterates events on deinit. | None. |
| 4 | #23 | PROPAGATOR-B3 never constructed | Not Implemented | `src/propagation/` only contains `baggage.zig`, `composite.zig`, `trace_context.zig` — no `b3.zig`. `cfg.propagator = .b3` set in `src/sdk/config.zig:389` is a dead enum branch. | None. |
| 5 | #24 | PROPAGATOR-JAEGER never constructed | Not Implemented | Same dir; no `jaeger.zig`. `src/sdk/config.zig:390` same dead enum. | None. |
| 6 | #26 | OTLP-WIRE-SCHEMA-URL never emitted | Not Implemented | `grep -rn "schema_url" src/exporters/otlp_http.zig` -> 0 hits; `fn_resource_schema_url`/`fn_scope_schema_url` constants absent from `src/generated/otlp.zig`. | None. |
| 7 | #27 | OTLP-COMPRESSION: gzip enum declared but never applied | Not Implemented | `src/sdk/config.zig:52` defines `compression: enum { none, gzip }`, `src/exporters/otlp_grpc.zig:296` hardcodes `out[0] = 0` and HTTP exporter never reads `cfg.*.otlp.compression`. | None. |
| 8 | #29 | PERIODIC-METRIC-READER missing | Not Implemented | `grep -rn "PeriodicExportingMetricReader\|periodic_metric"` -> 0 hits anywhere in repo. | None. |
| 9 | #30 | OBSERVABLE instruments API absent | Not Implemented | `src/api/metrics.zig:19` lists `observable_counter` enum value and SDK aggregator handles it (`src/sdk/metrics.zig:244,289`), but `grep` shows no `createObservable*` API on the Meter — callbacks unregistrable. | None. |
| 10 | #32 | gRPC-STATUS-PROPAGATION: server back-pressure dropped | Partial | `src/exporters/otlp_grpc.zig:206` defines `GrpcStatus` enum & `:148,196` map to `error.PartialSuccess`/retry but no parsing of `grpc-status` trailer for codes 4/8/13/14 with `Retry-After`. | Indirect via `test/remote_otlp.zig`. |

## Already-implemented but tracker-stale (recommend close after scanner verify)

| IID | Gap | Evidence the work is done |
|----:|-----|---------------------------|
| #1  | INSTRUMENTATION-SCOPE-PROPAGATION | `src/sdk/trace.zig:289-296` (reused & fresh paths both pass `scope`); test `test/trace.zig:57,83-87` directly asserts `scope.name == "demo"`/`"lib-a"` and `version`/`schema_url` via in-memory recorder. The bug at `:240` referenced in the issue title no longer exists. |
| #3  | OTLP-WIRE-INSTRUMENTATION-SCOPE | Sibling of #1; `src/exporters/otlp_http.zig:1057-1058` writes `fn_scope_name`/`fn_scope_version` from the now-correct `instrumentation_scope`. Wire-level golden test (`test/otlp_wire_parity.zig`) exists; only missing assertion is non-empty scope round-trip. |
| #7  | OTLP-METRIC-EXPORT (orientation says closed; CSV row stale) | `src/exporters/otlp_http.zig:84,356-360,425` (`/v1/metrics` + `encodeMetricsProto`) and `src/exporters/otlp_grpc.zig:99,176` (`MetricsService/Export`). |
| #31 | REDACT-NOT-WIRED | `src/exporters/otlp_http.zig:644,873,1108,1386` and `src/exporters/prometheus.zig:201` invoke `redact.maskString(kv.key, s)` on string attribute values; `src/internal/json_codec.zig:173` does same in JSON path. |

## New / surprising findings (not in catalog)

1. **`tracer()` ctx wiring conflicts with `disabled` mode** — `src/sdk/trace.zig:251-252` returns an empty Tracer when `comptime build_options.otel_disabled` OR `cfg.disabled` is true, but the empty Tracer has `startSpanFn = null`, so any caller hitting `.startSpan` on a disabled provider null-derefs. No catalog entry for this.
2. **Two `unreachable`-style placeholders in metrics encoder** — `src/exporters/otlp_http.zig:523,559` use empty `{}` blocks for unreachable instrument shapes. Defensive but undocumented; no panic if reached.
3. **Build target aliasing intentional but undertested** — `build.zig:399,402` keeps `test-integration` and `test-stress` as aliases (#79). The aliasing is documented but no separate CI matrix exists, so the integration-suite gap is real and untracked separately for the stress side.
4. **`src/exporters/otlp_grpc.zig:113,114,169,170` returns `UnsupportedTransport` when `build_options.use_devnw_grpc` is false** — production callers without that build flag will silently fail without diagnostic; not flagged in any current quality issue.

## Blockers

- None preventing the scan. `zig build check` passed exit 0. `glab` API healthy. No auth issues.
- Cannot run full `zig build test` matrix (CI-only Windows + zig-fuzz disabled per #99/#100), but unit tests are runnable locally and would not change the scan classification of the top-10 gaps (all confirmed via static evidence).

## Artifacts written

- `/data/home/benji/src/devnw/zig/otel/docs/audit/gap-scanner/SCAN_RESULTS.md` — this file
