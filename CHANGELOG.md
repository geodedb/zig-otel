# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Security

- H-7 (#80) blocked operator-pending; rotation deadline 2026-05-03.
  Code side already closed (`43330db`); the audit script
  (`scripts/audit_ci_logs.sh`) was smoke-checked 2026-04-27 (evidence:
  `docs/audit/h7-audit-evidence-2026-04-27.txt`) and the runbook
  (`docs/runbooks/h7-token-rotation.md`) hardened with a prominent
  "run audit before rotating" warning. Five-step operator unblock
  checklist tracked in `docs/SECURITY_GAP_ANALYSIS.md` §2.1.
- **File JSONL exporter no longer follows symlinks (NEW-M-2, gitlab
  #140, CONFIDENTIAL).** `src/exporters/file.zig::FileJsonl.open` was
  delegating to `std.Io.Dir.createFile`, which on Zig 0.16.0 follows
  symlinks unconditionally — `lib/std/Io/Dir.zig:586`
  `CreateFileOptions` has no `follow_symlinks` field at all (compare
  `OpenFileOptions:551` which does expose the toggle). An attacker with
  write access to the exporter's trusted base dir could plant
  `spans.jsonl -> /etc/cron.d/x` and have the exporter clobber the
  target. CWE-59 / OWASP A01:2021. Fix: `open()` now first attempts
  `Dir.openFile(.{ .follow_symlinks = false, .mode = .write_only })`;
  on `error.SymLinkLoop` (POSIX `ELOOP` from `O_NOFOLLOW`) the open is
  refused. On `error.FileNotFound` the call falls through to
  `Dir.createFile(.{ .exclusive = true })`, so even a TOCTOU symlink
  plant between the existence check and the create call is rejected
  atomically (`O_CREAT | O_EXCL` returns `error.PathAlreadyExists`
  against any existing entry, including a symlink). Three regression
  tests in `test/file_exporter_symlink.zig` cover the symlink refusal
  (with sentinel-bytes-preserved assertion), the fresh-create path,
  and the existing-regular-file restart path.
- M-3 (#84) recorded Won't Do — DevNW upstream signing tracked OOB.
- **Proto + semconv manifest provenance gate now anchors the actual
  upstream sources (NEW-H-1, gitlab #134, CONFIDENTIAL).** The previous
  state of `docs/proto-manifest.txt` and `docs/semconv-manifest.txt`
  hashed only the `LICENSE` file in each `third_party/<pin>/`
  directory — a structural facade that did not anchor any of the
  `.proto` / YAML model bytes the hand-rolled `src/generated/otlp.zig`
  encoder and `src/generated/semconv.zig` constants were derived from.
  CWE-345 (Insufficient Verification of Authenticity).
  Path A taken (vendor real upstream sources): the relevant subset of
  `opentelemetry-proto v1.10.0` (16 files: 10 `.proto` + 3
  `_http.yaml` Google-API HTTP gateway annotations + 1 README + 1
  LICENSE + 1 collector README) and the entire `model/` directory of
  `semantic-conventions v1.40.0` (244 model files + LICENSE) are now
  vendored in-tree. The shared manifest engine
  (`tools/manifest.zig`) walks every regular file, sorts by POSIX
  path, and emits a SHA-256 line per file; the new
  `requireSpecPayload` invariant fails loud (exit 2 with a clear
  diagnostic) if the upstream tree contains nothing but LICENSE.
  Generators expose `--emit` (default) and `--verify` modes; the
  build wires `zig build verify-proto-manifest`,
  `zig build verify-semconv-manifest`, and the `verify-manifests`
  aggregator. `make verify-manifests` is the CI hook (now part of
  `make ci`). Five new regression tests in
  `test/manifest_provenance.zig` pin the structural assertion that a
  LICENSE-only state must fail and that the vendored canonical files
  (e.g. `opentelemetry/proto/trace/v1/trace.proto`,
  `model/version.properties`) are present.

### Refactor

- **OTLP/HTTP exporter split into a module tree.** `src/exporters/otlp_http.zig`
  was a 1407-LOC single file mixing transport dispatch, retry
  classifier, header validation, and three encoder families (proto,
  JSON-stdlib, JSON-DevNW) per signal. It is now a thin facade
  re-exporting from `src/exporters/otlp_http/`:
  `exporter.zig`, `transport.zig`, `headers.zig`, `encode_proto.zig`,
  `encode_proto_devnw.zig`, `encode_json.zig`, `spans.zig`,
  `metrics.zig`. Largest module is 582 LOC; facade is 85 LOC.
  Wire-parity, multi-scope grouping, and security tests are
  unchanged. The duplicated retry/dispatch loops in `expSpans` and
  `expMetrics` collapsed into a shared `OtlpHttpExporter.exportSignal`
  helper, and the magic 1024-byte response stash is now
  `transport.last_response_body_capacity`. The HTTP retry rules live
  in `transport.retryClassifyHttp` (success / partial / retryable /
  fatal) so OTEL-Q-NEW-C (#164, 408/425) can land at one site.
  (OTEL-Q-001, gitlab #149)
- **`Transport` is now a tagged union.** Pre-refactor the export loop
  routed between the in-house transport and test-injected fakes by
  comparing function pointers (`self.transport == httpTransport`) at
  `otlp_http.zig:303-306, 372-375`. LTO/inlining or wrapping the fn
  in a closure would have silently broken the production path. The
  field is now `Transport = union(enum) { stdlib_io, custom: CustomFn }`
  and dispatch is an exhaustive `switch (self.transport)`. Tests
  inject fakes as `.{ .custom = fakeTransport }`. (OTEL-Q-NEW-A,
  gitlab #163)

### Performance

- **OTLP/gRPC endpoint parsed once at `init` (PR-9, gitlab #143).**
  `OtlpGrpcExporter.checkExportPreconditions`, `expSpans`, and
  `expMetrics` were each calling `parseGrpcEndpoint(self.config.endpoint)`
  on every export — three reparses per call before the gRPC client
  even sees a byte. The endpoint is immutable for the exporter's
  lifetime; it is now parsed once at `init` and cached on
  `OtlpGrpcExporter.parsed_endpoint`. Side effect: malformed
  endpoints fail at construction time instead of at first export
  (callers see `error.InvalidEndpoint` from
  `OtlpGrpcExporter.init`). Pinned by 5 regression tests in
  `test/otlp_grpc_endpoint_cache.zig` including a "post-init mutation
  of `config.endpoint` does not affect dispatch" assertion.

- **Single `clock.now()` per metric record (PR-8, gitlab #141).**
  `counterAdd` / `udcAdd` / `histRecord` / `gaugeSet` in
  `src/sdk/metrics.zig` were calling `provider.clock.now()` twice per
  record — once before the lock to feed `pointIndexFor`, then again
  to stamp `pt.last_unix_nano`. The second call is now elided; the
  pre-lock timestamp is reused for both purposes. SLO gate clean
  (Rule 3 attr_put_update p99=28.97 ns/op; Rule 4 counter_add
  allocs/op=0.00150).

- **OTLP encoder is now O(N) on nested submessages.**
  `Writer.commitSubMessage` (`src/generated/otlp.zig`) used to
  `copyForwards`-shift the payload tail on every commit so the varint
  length header could occupy fewer than its 10 reserved bytes. With
  five-deep OTLP nesting (ResourceSpans → ScopeSpans → Span →
  Event/Status/Link → KeyValue → AnyValue) every byte added at the
  inner level got shifted up the stack five times, giving O(N²) wall
  clock on body bytes. The encoder now records each commit and defers
  all length-header rewrites to a single linear compaction sweep
  inside `toOwnedSlice`. New `bench-micro` scenarios
  `micro_encode_spans_proto_{64,512,4096}` measure flat ~50 K spans/s
  throughput across the 64×–4096× batch range; the existing OTLP
  wire-parity tests pass byte-identical against the DevNW protobuf
  encoder. (PR-2, gitlab #36)

- **Bench baselines: PR-2 nested-encode captured.** Frozen
  `ReleaseFast` baseline for `micro_encode_spans_proto_{64,512,4096}`
  committed at `docs/performance/2026-04-27-pr-2-encoder/results/{baseline,latest}.json`
  with results.md (subject, build flags, capture date, source PR
  pointer, numbers table). Combined with the 2026-04-26 P0-1/P0-2/P0-4
  dirs, every micro-scenario in `benchmarks/micro/main.zig` now has a
  captured snapshot. **Partial close** of BENCH-BASELINES-MISSING — the
  remaining 18 perf gaps still need a bench probe authored before a
  baseline can be captured (plus 2 won't-do rows P1-4 / P1-12);
  reissued in `docs/PERF_GAP_ANALYSIS.md`
  §"Deferred bench probes". (BENCH-BASELINES-MISSING #166, partial)

### Changed

- **BREAKING:** `TracerProvider`'s `default_exporter` now wraps the
  supplied exporter in a `BatchSpanProcessor` (one async worker,
  5 s `schedule_delay_ms`) instead of a `SimpleSpanProcessor`.
  Aligns with every other OTel SDK; lifts blocking export off the
  producer thread. Migration: callers that need synchronous post-
  `end` visibility (most tests) should construct a
  `SimpleSpanProcessor` explicitly and pass it via the `processors`
  field, or call `tp.forceFlush(timeout_ms)` before reading the
  exporter. See `docs/adr/0003-default-bsp.md`. (P0-10)
- `BatchSpanProcessor` now honours `schedule_delay_ms` via a
  dedicated timer thread (gated on `-Dotel_use_devnw_pool=true`
  and `async_workers > 0`). Spans below `max_export_batch_size`
  no longer sit in the queue until the next forceFlush. (P0-9)
- `SpanState` is now reused via a mutex-guarded pool with arena
  retain-capacity semantics. Steady-state span recording is ~1.97×
  faster and uses 55% less allocator traffic. (P0-2)
- `AttributeSet.put` now uses an O(1) hash index. Per-span
  attribute ingestion at 120-attr prefill is **~11× faster**.
  (P0-1)
- `MeterProvider.pointFor` is now zero-alloc on the hit path via a
  fingerprint index. `Counter.add` / `Histogram.record` go from 3
  allocs/op to 0. (P0-4)

### Added

- **Service-level performance SLOs + runtime hard-criterion gate
  (PERF-SLO-DEFINE, gitlab #167).** New `docs/performance/SLO.md`
  (~290 lines) defines per-op latency and allocation ceilings
  anchored to the verified 2026-04-26 P0-1 / P0-4 baselines under
  `docs/performance/2026-04-26-p0-*/results/after.json`.
  `benchmarks/check_hard_criteria.zig` is extended with two new
  runtime rules: Rule 3 caps `micro_attr_put_update` p99 at 50 ns/op
  (1.6x headroom over the 31.92 ns/op floor); Rule 4 caps
  `micro_counter_add_4_attrs_hit` allocations at 0.005 allocs/op
  (3.3x headroom over the post-PR-1 / post-P0-4 0.0015 allocs/op
  floor). The checker accepts an optional `--micro <path>` JSON in
  addition to the pre-existing `--ref-a` / `--ref-b` comparison
  inputs; missing inputs skip cleanly so the step is safe to wire
  before every baseline is captured. New `make slo-check` target
  drives a fresh `bench-micro -Doptimize=ReleaseFast` + checker pass;
  `make ci` now includes `slo-check`. Verified against fresh
  ReleaseFast bench-micro output (28.24 ns/op p99 attr-update;
  0.0015 allocs/op counter-add hit) — both new rules PASS.
  Deferred drain-side / OTLP-encode SLO rows tracked under
  BENCH-BASELINES-MISSING (#166).
- **OTLP metric export path.** `OtlpHttpExporter.metricExporter()`
  posts `ExportMetricsServiceRequest` to `/v1/metrics`;
  `OtlpGrpcExporter.metricExporter()` routes through
  `MetricsService/Export`. The new
  `encodeMetricsProto` emits OTLP 1.10.0 wire shape for
  Sum (counter / up-down-counter), Gauge, and Histogram
  (with packed `bucket_counts` and `explicit_bounds`). The JSON
  variant routes through `../json` (DevNW `streamingEncoder`) when
  `-Dotel_use_devnw_json=true`. (GAP-OTLP-METRIC-EXPORT, gitlab #7)
- Runtime kill-switch on `Tracer`/`Meter`/`Logger` providers via
  `config.disabled` (mirrors the `OTEL_SDK_DISABLED` env var). (F-2)
- Real-loopback HTTP integration bench at level 6. (F-5)
- Per-call retry backoff sleep in OTLP/HTTP and OTLP/gRPC
  exporters; CPU no longer pegs on persistent failures. (P-N1, P-N2)
- Linux comptime guard around `LoopbackServer.wake()` raw syscalls
  for clean cross-OS bench compile errors. (Q35)

### Fixed

- **Trace OTLP encoder now groups spans by `instrumentation_scope`.**
  `encodeSpansProto` (and the parallel `encodeSpansProtoDevnw` path)
  in `src/exporters/otlp_http.zig` previously took
  `items[0].instrumentation_scope` for the entire batch and emitted
  one `ScopeSpans` block. When a batch contained spans from multiple
  tracers (different `(name, version, schema_url)`) every span past
  index 0 was mislabelled as belonging to the first tracer's scope —
  a wire-correctness defect that downstream OTLP backends could not
  recover from. The encoder now passes the batch through a new
  `groupSpansByScope` helper (mirroring the metrics-side
  `groupByScope` pattern but keyed on the full
  `(name, version, schema_url)` tuple) and emits one `ScopeSpans`
  per distinct scope. `ScopeSpans.schema_url` (proto field 3) is
  wired through both encoder paths. Single-scope batches stay
  byte-identical to the pre-fix wire shape (proto3 default-omit
  on the empty `schema_url`), so the common case takes no perf
  hit. New regression tests in `test/otlp_spans_multi_scope.zig`
  (5 tests: multi-scope by name/version/schema_url, single-scope
  byte-parity fast path, DevNW↔in-repo wire parity) FAIL on `main`
  pre-fix and PASS post-fix. PR-5 (#138) replaces the linear scan
  inside `groupSpansByScope` with a hash-keyed bucket table next.
  (PR-3, #136)
- **`MeterProvider.pointFor` race fix.** Concurrent
  `Counter.add` / `Histogram.record` / `Gauge.set` calls — and a
  concurrent `collect()` — now run under a per-instrument
  `InstrumentMutex`. The old code mutated `inst.points`
  (ArrayList grow) and `inst.points_index` (HashMap put) without
  synchronisation, so two threads racing on a fingerprint miss
  would tear the slice header, dangle a `&items[idx]` pointer
  across a re-grow, or trip a HashMap pointer-stability assert.
  `pointIndexFor` now returns indices instead of pointers and the
  record-paths hold the lock from index resolution through the
  value mutation; `collect()` deep-copies attribute sets and
  histogram buffers under the lock so the snapshot fully detaches
  from `inst.points`. New helper `freeSnapshot(allocator, snap)`
  tears down the cloned storage. Coverage in
  `test/metrics_concurrency.zig` (single-threaded shape stability,
  2-thread record stress, writer-vs-collector stress); the
  pre-fix run reliably crashes with `panic: reached unreachable
  code` inside `std.HashMap.getOrPutContextAdapted` when the two
  writers hit the same fingerprint window. Hot-path perf within
  ±5% of pre-fix (`micro_counter_add_4_attrs_hit` -2.6%,
  `micro_histogram_record_4_attrs_hit` -0.4%). (PR-1, #135)
- `InstrumentationScope` now propagates from the `Tracer` value to
  the recorded `SpanState` instead of being clobbered with an empty
  scope. OTLP wire output groups spans correctly under their
  originating `ScopeSpans`. (GAP #1, #3)

## [0.1.0] - YYYY-MM-DD

### Added

- Initial release
- Basic functionality
- Documentation and examples

[Unreleased]: https://gitlab.com/devnw/zig/otel/-/compare/v0.1.0...HEAD
[0.1.0]: https://gitlab.com/devnw/zig/otel/-/releases/v0.1.0
