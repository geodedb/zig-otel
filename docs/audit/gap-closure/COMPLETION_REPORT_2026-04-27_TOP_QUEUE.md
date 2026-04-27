# Gap Closure Completion Report — 2026-04-27 Top Queue (Day-1 Batch)

**Run:** Day-1 of the 22-item Critical+High top-queue sweep
**Plan:** `docs/audit/gap-closure/PLAN_2026-04-27_TOP_QUEUE.md`
**Branch baseline:** `main` @ `7c0ac5e` (verifier captured at HEAD `9eaeec2`)
**Verifier verdict:** ALL PASS — `zig build test --summary all` → 132/25/0 default, 141/16/0 DevNW. Zero regressions.
**Operator:** codepros gap-closure agent + `<benji@codepros.org>`

---

## 1. GAP_ANALYSIS Status

| File | Closed (this run) | Blocked | Won't Do | Remaining Open | Total |
|------|------------------:|--------:|---------:|---------------:|------:|
| `docs/GAP_ANALYSIS.md` | 4 (#9, #26, #33, #35) | 1 (#32) | 0 | 27 | 32 open |
| `docs/PERF_GAP_ANALYSIS.md` | 3 (#141, #143, #144) | 0 | 0 | 14 (P1) + others | 27 open (post-batch) |
| `docs/GAP_ANALYSIS_RESOLVED.md` | 1 Won't Do moved (#25) + 1 reaffirmed (#7) | n/a | n/a | n/a | n/a |
| `docs/QUALITY_GAP_ANALYSIS.md` | 0 | 0 | 0 | unchanged | unchanged |
| `docs/SECURITY_GAP_ANALYSIS.md` | 0 | 0 | 0 | unchanged | unchanged |

**Overall this run:** 7 closed (Closed status), 1 closed Won't Do (#25), 1 commented + kept open (#32 Blocked-upstream). Plus 2 tracker-drift closures (#7, #101) that were already closed before this run started; carried into the report for traceability.

---

## 2. Closed Items

### Tracker-only (no code, already closed via glab — carried for traceability)

| Gap-ID | Issue | File | Title | Evidence |
|--------|------:|------|-------|----------|
| GAP-OTLP-METRIC-EXPORT | #7 | `docs/GAP_ANALYSIS_RESOLVED.md` § 2026-04-27 | OTLP metric export shipped earlier; tracker drift | `ac68bff`; `src/exporters/otlp_http/metrics.zig:39` `const metric_path = "/v1/metrics"`; `src/exporters/otlp_grpc.zig:99` `metrics_export_method = "MetricsService/Export"` |
| GAP-DEPRECATED-SPAN-EVENTS-FLAG | #101 | `docs/GAP_ANALYSIS_RESOLVED.md` § note-only | Docs-only note for `-Ddeprecated_span_events` build gate | `src/api/trace.zig:215-218`; Phase 3 GAP_DETECTION classification |

### Code commits (this batch, 7 closed + 1 Won't Do)

| Gap-ID | Issue | Commit | File | Title | Evidence (file:line + tests) |
|--------|------:|--------|------|-------|------------------------------|
| PR-8 | #141 | `b934ac3` | `docs/PERF_GAP_ANALYSIS.md` row 8 | Single `clock.now()` per metric record | `src/sdk/metrics.zig:517,531,554,565,579,601,615,626`; SLO gate clean (Rule 3 p99=28.97 ns/op; Rule 4 allocs/op=0.00150) |
| PR-9 | #143 | `0f9de4f` | `docs/PERF_GAP_ANALYSIS.md` row 9 | Cache parsed gRPC endpoint at init | `src/exporters/otlp_grpc.zig` (`parsed_endpoint` cached at init; 3 reparse sites collapsed); `test/otlp_grpc_endpoint_cache.zig` (5 tests, incl. post-init mutation safety) |
| PR-10 | #144 | `8bc8a09` | `docs/PERF_GAP_ANALYSIS.md` row 10 | `toOwnedSlice` replaces redundant `arena.dupe` | `src/internal/json_codec.zig:50,75,100`; wire-parity tests byte-identical; SLO gate clean |
| GAP-ENV-BSP | #33 | `9539b8b` | `docs/GAP_ANALYSIS.md` row | Parse `OTEL_BSP_*` env vars | `src/sdk/config.zig:193-198,415-422`; `src/sdk/export.zig:146-149`; `src/sdk/trace.zig:121-124,212`; 4 new `test/config.zig` cases (defaults, parse, invalid-fallback, BSP options surface) |
| GAP-ENV-METRIC-INTERVAL | #35 | `636d9e9` | `docs/GAP_ANALYSIS.md` row | Parse `OTEL_METRIC_EXPORT_INTERVAL/_TIMEOUT` | `src/sdk/config.zig:209-212,231,445-446`; 3 new `test/config.zig` cases. Reader runtime wiring deferred to #29 |
| GAP-OTLP-WIRE-SCHEMA-URL | #26 | `d1d3bd7` | `docs/GAP_ANALYSIS.md` row | Emit `Resource.schema_url` on the wire | `src/exporters/otlp_http/encode_proto.zig:333-342` (ResourceSpans field 3) + `:106-113` (ResourceMetrics field 3); `src/exporters/otlp_http/encode_proto_devnw.zig:160-172,201-205`; `test/otlp_resource_schema_url.zig` (5 tests). Logs path deferred to #8 |
| GAP-OTLP-WIRE-EVENTS-LINKS | #9 | `87875d1` | `docs/GAP_ANALYSIS.md` row | Emit `Span.events` (field 11) and `Span.links` (field 13) | `src/exporters/otlp_http/encode_proto.zig:281-291` (events/dropped + links/dropped fields), `:310-323` `writeEvent`, `:332-344` `writeLink`; `src/exporters/otlp_http/encode_proto_devnw.zig:124-156,173-191,312-340`; `test/otlp_span_events_links.zig` (7 tests: events/links/byte-identical-empty + 3 DevNW parity) |

---

## 3. Won't Do Items

| Gap-ID | Issue | Commit | File | Title | Reason |
|--------|------:|--------|------|-------|--------|
| GAP-OTLP-PROFILES-EXPORT | #25 | `c116d3e` | `docs/GAP_ANALYSIS_RESOLVED.md` § Won't Do (2026-04-27) | OTLP profiles export | Upstream `opentelemetry-proto v1.10.0` still has `pprofile/profiles.proto` under `/v1development/` — not stable. Tracker issue body explicitly permits docs-downgrade closure. README + SPEC_COMPLIANCE updated to mark Profiles NOT IMPLEMENTED; the inert `error.UnsupportedTransport` stub at `src/api/profiles.zig` is preserved as forward-compat insurance. **Re-open trigger:** when upstream promotes the package to `opentelemetry.proto.profiles.v1`. |

---

## 4. Blocked Items

| Gap-ID | Issue | Commit | File | Title | Blocker | Unblock Steps |
|--------|------:|--------|------|-------|---------|---------------|
| GAP-GRPC-STATUS-PROPAGATION | #32 | `9eaeec2` (docs flip only) | `docs/GAP_ANALYSIS.md` § Blocked-upstream callouts; `docs/runbooks/upstream-asks.md` § ASK-GRPC-ZIG-TRAILERS | gRPC status trailers invisible to OTLP retry loop | Pinned `gitlab.com/devnw/zig/grpc-zig` `client.call(...) ![]u8` returns only response bytes; HTTP/2 trailers (`grpc-status`, `grpc-message`, `Retry-After`) are not in the public API. Source: `zig-pkg/grpc_zig-…/src/client.zig:43-64`; consumer-side documented at `src/exporters/otlp_grpc.zig:291-295`. | **6 steps** (in `docs/runbooks/upstream-asks.md`): 1. File upstream issue on `devnw/zig/grpc-zig` requesting trailer access; 2. Land upstream change (e.g. `callWithTrailers(...) !{ body, trailers: StringHashMap }`); 3. Bump pin in `build.zig.zon`; 4. Wire trailer consumption in `unaryExport`; 5. Add regression test pair (success + RESOURCE_EXHAUSTED + Retry-After); 6. Close #32 with evidence and flip `GAP_ANALYSIS.md` row to Closed. |

---

## 5. Tests Executed

| Command | Result |
|---------|--------|
| `zig fmt --check src examples benchmarks build.zig` | PASS (exit 0) |
| `zig build check` | PASS (exit 0) |
| `zig build test --summary all` (default flags) | **PASS — 132/25/0** (132 pass / 25 skip / 0 fail) |
| `zig build test --summary all -Dotel_use_devnw_json -Dotel_use_devnw_protobuf` | **PASS — 141/16/0** (141 pass / 16 skip / 0 fail) |
| `make slo-check` | **PASS** — Rule 3 `attr_put_update` p99=28.97 ns/op (≤ 50, 1.6× headroom) · Rule 4 `counter_add` allocs/op=0.00150 (≤ 0.005, 3.3× headroom). Re-verified after each of the 9 commits. |
| `make ci` (= clean + check + test-all + slo-check) | PASS — across all 9 commits |

Baseline at start of run: 112/21/0 default, 117/16/0 DevNW. Net delta: **+20 default tests / +24 DevNW tests** added (config, endpoint cache, schema_url, events/links). Zero regressions.

---

## 6. Security Notes

- **No new attack surface this run.** Nine commits touched encoder + config + grpc client memoization paths only; security review on each:
  - PR-8/PR-9/PR-10: pure refactor + caching; no input handling, no I/O surface change. Lifetime of `parsed_endpoint` (PR-9) verified — exporter init is the single owner; subsequent mutation of `config.endpoint` post-init has a regression test pinning that dispatch is unaffected (defense against TOCTOU on the endpoint string).
  - GAP-ENV-BSP / GAP-ENV-METRIC-INTERVAL: env-var parsing falls back to spec defaults on invalid/empty values rather than failing config load; this is the safer-fail-open posture per OTel spec but means malformed operator input cannot DoS the SDK.
  - GAP-OTLP-WIRE-SCHEMA-URL / GAP-OTLP-WIRE-EVENTS-LINKS: encoder paths emit data the SDK already collects; no new untrusted-data ingress. Empty events/links arrays and empty schema_url stay byte-identical to pre-fix wire shape (proto3 default-omit), preserving wire-parity invariants.
- **Tracker-drift closures (#7, #101):** no code changed; documentation reconciliation only.
- **Won't Do (#25):** retains the inert `error.UnsupportedTransport` stub; no new code surface.
- **Blocked (#32):** docs-only flip; production behaviour of `unaryExport` unchanged from prior to this run. The retry classifier still falls back to HTTP-status-only (transport.retryClassifyHttp) when trailers are unavailable — defensive, not exploitable.
- **No secrets handled, no new I/O paths, no new env-var families processing untrusted bytes.**

---

## 7. Remaining Blockers

1. **GAP-GRPC-STATUS-PROPAGATION (#32) — upstream-grpc_zig.** Issue stays OPEN with the 6-step unblock checklist in `docs/runbooks/upstream-asks.md` § ASK-GRPC-ZIG-TRAILERS. **Next action:** operator files the upstream issue on `gitlab.com/devnw/zig/grpc-zig`. Owner: <benji@codepros.org>.

No other blockers from this run.

---

## 8. Platform Issues Updated

| Gap-ID | Issue | Action |
|--------|------:|--------|
| GAP-OTLP-METRIC-EXPORT | #7 | already closed (carried; tracker drift) |
| GAP-OTLP-WIRE-EVENTS-LINKS | #9 | closed (commit `87875d1`) |
| GAP-OTLP-PROFILES-EXPORT | #25 | closed Won't Do (commit `c116d3e`) |
| GAP-OTLP-WIRE-SCHEMA-URL | #26 | closed (commit `d1d3bd7`) |
| GAP-GRPC-STATUS-PROPAGATION | #32 | commented (Blocked — upstream-grpc_zig); kept OPEN |
| GAP-ENV-BSP | #33 | closed (commit `9539b8b`) |
| GAP-ENV-METRIC-INTERVAL | #35 | closed (commit `636d9e9`) |
| GAP-DEPRECATED-SPAN-EVENTS-FLAG | #101 | already closed (carried; docs-only by design) |
| PR-8 | #141 | closed (commit `b934ac3`) |
| PR-9 | #143 | closed (commit `0f9de4f`) |
| PR-10 | #144 | closed (commit `8bc8a09`) |

**Summary:** 9 closed (#7 + #101 carried; #9, #25, #26, #33, #35, #141, #143, #144 closed this run); 1 commented + open (#32). Closure-evidence comment posted on every issue with the matching commit SHA, file:line evidence, regression test names, and verification numbers (132/25/0 + 141/16/0; SLO gate clean).

---

## 9. Definition of Done — Verified

- [x] 7 issues closed (Closed status): #9, #26, #33, #35, #141, #143, #144 + 2 carried (#7, #101) = **9 total Closed**
- [x] 1 issue closed Won't Do: #25
- [x] 1 issue commented but kept open: #32 (Blocked-upstream)
- [x] All affected tracking docs reflect Closed/Won't-Do/Blocked status: `docs/GAP_ANALYSIS.md`, `docs/GAP_ANALYSIS_RESOLVED.md`, `docs/PERF_GAP_ANALYSIS.md`, `CHANGELOG.md`
- [x] `CHANGELOG.md` `[Unreleased]` has 9 distinct entries (one per code commit) — verified across Performance, Added, Fixed, Notes sections
- [x] `git status` clean post close-out commit
- [x] Completion report exists with 6-section format (this file extends to 9 sections for traceability)
- [x] Verifier verdict: ALL PASS (132/25/0 + 141/16/0; zero regressions)

---

## 10. Artifacts

- **Plan:** `docs/audit/gap-closure/PLAN_2026-04-27_TOP_QUEUE.md`
- **This report:** `docs/audit/gap-closure/COMPLETION_REPORT_2026-04-27_TOP_QUEUE.md`
- **Audit summary update:** `docs/audit/AUDIT_SUMMARY_2026-04-27.md` § "Top-Queue Day-1 Closures — 2026-04-27"
- **Commit range:** `b934ac3..9eaeec2` (9 commits on `main`, not yet pushed at hand-off)
- **Tracking files:** `docs/GAP_ANALYSIS.md`, `docs/GAP_ANALYSIS_RESOLVED.md`, `docs/PERF_GAP_ANALYSIS.md`, `CHANGELOG.md`
- **Upstream-ask runbook:** `docs/runbooks/upstream-asks.md` § ASK-GRPC-ZIG-TRAILERS
- **Sibling reports (same-day prior runs):** `docs/audit/gap-closure/COMPLETION_REPORT_2026-04-27.md` (5-PR run) and `..._FOLLOWUPS.md` (5 follow-ups)
