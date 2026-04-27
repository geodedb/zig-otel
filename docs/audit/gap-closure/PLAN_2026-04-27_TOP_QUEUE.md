# Gap Closure Plan — 2026-04-27 Top Queue (22-Item Critical+High Sweep)

**Author:** codepros gap-close planner
**Branch baseline:** `main` @ `7c0ac5e`
**Repo:** `gitlab.com/devnw/zig/otel` (Zig 0.16.0)
**Scope inbound:** 22 items (4 Critical + 12 High Gap + 6 High Perf)
**Scope outbound (Day-1):** **8** items (≤ session capacity, all reviewable, one commit per gap)
**Status:** Phase-1 plan only — no code changes in this commit

---

## 0. Baseline (clean tree)

| Action | Command | Result |
|--------|---------|--------|
| Format | `zig fmt --check src examples benchmarks build.zig` | **PASS** (exit 0) |
| Compile | `zig build check` | **PASS** (exit 0) |
| Tests (default) | `zig build test --summary all` | **PASS** (exit 0) — 0 failures, skips honored |
| SLO gate | `make slo-check` | **PASS** — Rule 3 `attr_put_update p99=28.967 ns/op ≤ 50` · Rule 4 `counter_add allocs/op=0.00150 ≤ 0.005` |

Baseline matches the morning's stated state (112/21/0 default, 117/16/0 DevNW). No pre-existing failures.

---

## 1. Tracker label verification (glab)

All 12 candidate "High Gap" issues confirmed as `priority::high` on tracker:

| Item | Issue | priority::high? | Type | Notes |
|------|------:|:----------------|------|-------|
| #4 GAP-EXPORTER-FACTORY | `priority::critical` (not high) | n/a (Critical, not High) | feature | gates per-signal env vars |
| #7 GAP-OTLP-METRIC-EXPORT | `priority::critical` | n/a | feature | **TRACKER DRIFT** — code shipped `ac68bff` |
| #8 GAP-OTLP-LOG-EXPORT | `priority::critical` | n/a | feature | full log path needed |
| #9 GAP-OTLP-WIRE-EVENTS-LINKS | `priority::critical` | n/a | feature | events/links never written to wire |
| #23, #24, #25, #26, #27, #29, #30, #32, #33, #35 | all `priority::high` | yes | feature/bug | confirmed |
| #138, #139, #141, #143, #144, #146 | all `priority::high`+`perf::p1` | yes | enhancement | confirmed |

**Per-signal env-var family (#60/#63/#64/#66) NOT in scope:** verified via `glab issue list` — these are NOT `priority::high`. They are `priority::medium`. Excluded from Day-1 per the audit instruction.

---

## 2. Status / availability findings

### #25 — OTLP Profiles (`priority::high`)

- Upstream `pprofile/profiles.proto` is still under `/v1development/` in `third_party/opentelemetry-proto-v1.10.0/` — **not stable**.
- Tracker issue body explicitly allows acceptance via "downgrade `docs/SPEC_COMPLIANCE.md` and have the API surface return a clearer 'not yet supported' error."
- API surface: `src/api/profiles.zig:53-66` — `noopEmit` returns `error.UnsupportedTransport`.
- **Decision: Won't-Do (downgrade docs path).** Land a one-paragraph SPEC_COMPLIANCE.md edit + replace `error.UnsupportedTransport` with a typed `error.ProfilesNotYetSupported` and a precise comment naming `/v1development/`. Keeps the door open for full implementation post-stabilization. **Day-1.**

### #27 — gzip compression (`priority::high`)

- **Available:** `std.compress.flate.Compress` with `Container.gzip` ships in Zig 0.16.0 stdlib at `lib/std/compress/flate.zig` (lines 31, 70, 88-127). Full encoder + decoder.
- HTTP path: gzip frame the proto/json body, set `Content-Encoding: gzip`, configurable via `OtlpConfig.compression` (already declared `.none|.gzip` enum at `src/sdk/config.zig:52`).
- gRPC path: per-message `compressed-flag` byte (frame byte 0) + zlib (or gzip — gRPC spec allows either). Existing 5-byte gRPC prefix lives in the otlp_grpc unaryExport path — needs the flag byte and length adjusted.
- **Day-1 risk:** moderate. HTTP side is straight-line. gRPC side needs careful frame-byte handling and flips a bit other implementations watch closely. Per the user's "be aggressive about cutting" directive, **HTTP-only first; gRPC compression deferred to Day-2.**

### #32 — gRPC status propagation (`priority::high`)

- `src/exporters/otlp_grpc.zig:274-275` (verbatim): "grpc-zig's client surfaces neither the trailers nor the `grpc-status` value — `call()` either returns the response bytes…"
- `zig-pkg/grpc_zig-…/src/client.zig:59-63`: `call()` returns only `response_bytes`. Trailer access is **not** in the public API.
- **Status: Blocked-upstream.** Mark on tracker; do not attempt this session. Closing requires upstream `grpc_zig` API change to expose trailers.

### Zig 0.16 stdlib status

- `std.compress.flate` is stable, with both encoder (`Compress.zig`) and decoder (`Decompress.zig`).
- `Container = enum { raw, gzip, zlib }` — Day-1 viable.

### Tracker drift items (no code, close on tracker)

- **#7** — code landed `ac68bff`; verified live: `src/exporters/otlp_http/metrics.zig:39 const metric_path = "/v1/metrics"`, `src/exporters/otlp_grpc.zig:99 metrics_export_method = "MetricsService/Export"`. Comment + label flip only. **Day-1.**

---

## 3. Final Day-1 list (8 items, ordered, ≤ 1 session)

Each line item gives **gap-id**, severity, complexity (XS/S/M/L), file:line target, and a one-sentence acceptance sketch. **One commit per gap.** Trivial perf wins are NOT bundled (per policy). Order is: tracker drift first (free), then trivial perf wins (low risk — keep tests green), then small env parsers, then the encoder addition (largest), then docs-downgrade.

| # | Gap-ID (issue) | Severity | Complexity | File:Line target | Acceptance criteria sketch |
|---|---------------|----------|-----------|-------------------|----------------------------|
| 1 | **#7 GAP-OTLP-METRIC-EXPORT** | Critical (drift) | XS | tracker comment + `docs/GAP_ANALYSIS.md` | Tracker comment cites commit `ac68bff` + 2 file:line proofs; flatfile moves row to RESOLVED. **No code.** |
| 2 | **#141 PR-8** double `clock.now` per metric record | High (perf P1) | XS | `src/sdk/metrics.zig` lines 517/527 (counter), 550/560 (udc), 574/595 (hist), 609/619 (gauge) | Single `clock.now()` per record path, used both for `pointIndexFor(.., now)` and `pt.last_unix_nano = now`. Tests pass; no SLO regression. |
| 3 | **#143 PR-9** endpoint reparse on every export | High (perf P1) | S | `src/exporters/otlp_grpc.zig:65,129,177` (3 `parseGrpcEndpoint` call sites) | Cache parsed endpoint on `OtlpGrpcExporter` at `init` (non-Owned `host`/`port`/`scheme_secure`). Exporter `expSpans`/`expMetrics` read from the cache. Re-parse error becomes `init`-time error. |
| 4 | **#144 PR-10** redundant `arena.dupe(buf.items)` | High (perf P1) | XS | `src/internal/json_codec.zig:50, 75, 100` | Replace `try arena.dupe(u8, buf.items)` + `defer buf.deinit(arena)` with `try buf.toOwnedSlice(arena)` (drop the dupe + drop the deinit). |
| 5 | **#33 GAP-ENV-BSP** | High (gap) | S | `src/sdk/config.zig` `applyEnv` (~line 375) — add 4 envs | Parse `OTEL_BSP_SCHEDULE_DELAY` (ms), `OTEL_BSP_EXPORT_TIMEOUT` (ms), `OTEL_BSP_MAX_QUEUE_SIZE`, `OTEL_BSP_MAX_EXPORT_BATCH_SIZE` into `Config.bsp`-style fields (or pipe to `BatchSpanProcessorOptions`). Test in `test/config.zig`. |
| 6 | **#35 GAP-ENV-METRIC-INTERVAL** | High (gap) | S | `src/sdk/config.zig` `applyEnv` — add 2 envs | Parse `OTEL_METRIC_EXPORT_INTERVAL` and `OTEL_METRIC_EXPORT_TIMEOUT` (ms). Test that values round-trip through Config. |
| 7 | **#26 GAP-OTLP-WIRE-SCHEMA-URL** | High (gap) | S | `src/exporters/otlp_http/encode_proto.zig` — `ResourceSpans.schema_url` field 3 + DevNW path mirror | Add `try w.writeString(otlp.fn_resource_spans_schema_url, resource.schema_url)` at the end of the `rs_start` block (before `commitSubMessage`). Verify field number — proto3 `ResourceSpans.schema_url` is field **3**. Mirror in `encode_proto_devnw.zig`. Add a wire-parity test asserting the schema_url byte for a non-empty resource. |
| 8 | **#9 GAP-OTLP-WIRE-EVENTS-LINKS** | Critical (gap) | M | `src/exporters/otlp_http/encode_proto.zig` `writeSpan` — emit `fn_span_events`/`fn_span_links` (fields 11/13) + DevNW path | Encode `span.events` (field 11) using `fn_event_*` field constants already defined at `src/generated/otlp.zig:334-337`; encode `span.links` (field 13) using `fn_link_*` (lines 339-343). Add tests in `test/otlp_spans_multi_scope.zig` (or new `test/otlp_spans_events_links.zig`) — assert byte presence + parity vs DevNW path for spans with 1+ events and 1+ links. |

**Day-1 commit policy reminders:**

- Each commit message: `<type>(<scope>): close <ID> (#<issue>) — <one-line>` plus closing the GitLab issue with its evidence comment.
- Do **not** bundle items 2/4 (both XS perf) into one commit even though they touch unrelated files; policy is one-commit-per-gap.
- Run `make ci` after each commit (= `clean + check + test-all + slo-check`).

**Day-1 risk budget:**

- Items 1–6 are very-low risk (tracker, env parsing, single-line refactors).
- Item 7 (schema_url) needs the field number verified vs upstream `trace.proto` — quick `grep` of `third_party/opentelemetry-proto-v1.10.0/`.
- Item 8 (events/links) is the biggest single-commit footprint of the day. If items 1–7 take longer than expected, **drop item 8 to Day-2** and substitute item-9 below from the Day-2 list (#25 docs downgrade) which is XS.

---

## 4. Day-2 (deferred, with one-line justification)

| Item | Reason |
|------|--------|
| **#4 GAP-EXPORTER-FACTORY** (Critical) | Substantial — wires `OTEL_*_EXPORTER` to actual exporter construction across all signals; touches config + sdk/trace + sdk/metrics + sdk/logs. Single commit but must NOT bundle. |
| **#8 GAP-OTLP-LOG-EXPORT** (Critical) | Largest single item — needs encoder, exporter, gRPC route, processor, tests, and pairs naturally with #98 (env BLRP). Half-day minimum. |
| **#23 GAP-PROPAGATOR-B3** (High) | Moderate — needs new `src/propagation/b3.zig` (single + multi header variants), composite-propagator dispatch, test parity vs trace_context. |
| **#24 GAP-PROPAGATOR-JAEGER** (High) | Moderate — `uber-trace-id` parser/emitter; pair with #23 in same Day-2 session if shared dispatch refactor. |
| **#27 (gRPC half) gzip compression** | gRPC frame-byte handling deferred behind HTTP-only Day-1 ship. |
| **#29 GAP-PERIODIC-METRIC-READER** (High) | Moderate — periodic reader thread with shutdown semantics; depends on env interval (#35) which lands Day-1. |
| **#30 GAP-OBSERVABLE-INSTRUMENTS** (High) | Large — callback-based metric API surface (Counter/UpDownCounter/Gauge variants). Multi-day naturally. |
| **#138 PR-5 groupByScope hash-keyed** (High perf) | Small but pairs naturally with #9 events/links since both touch the encoder. Defer one day to keep #9 reviewable on its own. |
| **#139 PR-6 Baggage.put dedup-before-dupe** (High perf) | Has a known fix shape (P0-1 anti-pattern) but needs care — the FailingAllocator path on the `BaggageFull` branch must keep behaving (already-rejected over-cap inserts must not leave half-duped slices). |
| **#146 PR-7 Prometheus per-bucket re-sort** (High perf) | **Re-investigate before fix.** Current `src/exporters/prometheus.zig:150-175` does NOT visibly sort per bucket — iterates `a.entries.items` directly. The "score 82" finding may already be addressed by P0-1 (AttributeSet canonicalization). Don't burn Day-1 time on a no-op patch. |

---

## 5. Won't-Do (close on tracker with justification)

| Gap-ID | Severity | Reason |
|--------|----------|--------|
| **#25 GAP-OTLP-PROFILES-EXPORT** | High | Profiles still `/v1development/` upstream; tracker body explicitly allows docs-downgrade closure path. **Day-1 close** via SPEC_COMPLIANCE.md edit + typed error. |
| **#7 GAP-OTLP-METRIC-EXPORT** | Critical (drift) | Code shipped `ac68bff`; tracker not updated. **Day-1 close** via tracker comment, no code. |

---

## 6. Blocked

| Gap-ID | Severity | Reason |
|--------|----------|--------|
| **#32 GAP-GRPC-STATUS-PROPAGATION** | High | Upstream `grpc_zig` `client.call()` returns only `response_bytes` — trailers not exposed. Source: `zig-pkg/grpc_zig-…/src/client.zig:59-63` and the verbatim comment at `src/exporters/otlp_grpc.zig:274-275`. Closing requires upstream API change. **Day-1: comment on tracker, label `status::blocked-upstream`, do not attempt code change.** |

---

## 7. Risks / blockers

1. **Day-1 item count is 8 but realistic capacity is 6–7 in a single session.** If items 7 (schema_url field-number verification) or 8 (events/links encoder) hit a snag, drop item 8 first and add #25 (docs downgrade, XS) as a swap-in. Items 1–6 must all land for the day to be a "win".
2. **PR-7 (#146) discrepancy** — the current Prometheus code does not match the issue body's cited line range. Whoever picks up #146 in Day-2 must first reconcile what changed since the issue was filed (likely P0-1 already obviated the re-sort). **Don't burn Day-1 time on this.**
3. **Schema URL field-number assumption** — Day-1 item 7 assumes `ResourceSpans.schema_url = field 3` (proto3). Must `grep schema_url third_party/opentelemetry-proto-v1.10.0/opentelemetry/proto/trace/v1/trace.proto` BEFORE coding to confirm. Also, `ResourceMetrics.schema_url` and `ResourceLogs.schema_url` are NOT in scope of #26 — only ResourceSpans is in the issue title; widen if convenient and the proto agrees.
4. **Events/links sub-message size budget** — `Writer` already uses deferred-compaction (`commitSubMessage` is O(1) post-PR-2); high event/link counts will stress the same path. No expected SLO regression but worth eyeballing the `micro_encode_spans_proto_*` rows after the commit.
5. **The user's note "many of these are large enough that one session cannot finish all 22"** is correct. This plan ships 8 (≈36% of the queue). The remaining 14 split as: 8 Day-2 (#4, #8, #23, #24, #27-grpc, #29, #30, #138, #139, #146 = 10 — three of which are higher-effort), 2 Won't-Do (#7, #25), 1 Blocked (#32), and the 3 deferred perf items (PR-5/PR-6/PR-7 = #138/#139/#146). Expected calendar: **2 more sessions** at this complexity, plus 1 session for #4 + #8 (the two Critical mega-items).

---

## 8. Plan artifact

This document: `/data/home/benji/src/devnw/zig/otel/docs/audit/gap-closure/PLAN_2026-04-27_TOP_QUEUE.md`

Sibling planning artifacts (prior runs, for context):

- `docs/audit/gap-closure/PLAN_2026-04-27.md` — morning's 5-PR plan (closed)
- `docs/audit/gap-closure/PLAN_2026-04-27_FOLLOWUPS.md` — morning's follow-ups (closed)
- `docs/audit/gap-closure/COMPLETION_REPORT_2026-04-27.md` and `..._FOLLOWUPS.md` — closure evidence
