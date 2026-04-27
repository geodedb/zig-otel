# Gap Closure Completion Report — 2026-04-27

**Repository:** `gitlab.com/devnw/zig/otel` (Zig 0.16 OpenTelemetry SDK)
**Branch:** `main` (clean post-run)
**Plan:** `docs/audit/gap-closure/PLAN_2026-04-27.md`
**Audit summary:** `docs/audit/AUDIT_SUMMARY_2026-04-27.md` (§"Gap Closures — 2026-04-27")
**Verifier verdict:** ALL PASS — 109 / 21 / 0 default; 114 / 16 / 0 with DevNW codecs. Zero regressions.

## GAP_ANALYSIS Status

| File | Closed (this run) | Blocked | Won't Do | Remaining Open | Total |
|------|------------------:|--------:|---------:|---------------:|------:|
| `docs/PERF_GAP_ANALYSIS.md` | 3 (PR-1, PR-2, PR-3) | 0 | 0 | 27 | 30+ |
| `docs/QUALITY_GAP_ANALYSIS.md` | 2 (OTEL-Q-001, OTEL-Q-NEW-A) | 0 | 0 | 16 (+ legacy) | 55 |
| `docs/SECURITY_GAP_ANALYSIS.md` | 1 (NEW-H-1) | 0 | 0 | 5 (NEW + operator-pending) | 25 |
| `docs/GAP_ANALYSIS.md` | 0 in this run (cross-references the above; tracker-stale closures #1/#3/#31 closed in earlier sync) | 0 | 0 | 33 | — |
| `docs/GAP_ANALYSIS_RESOLVED.md` | n/a (history ledger) | — | — | — | — |

**Overall (this run):** **6 closed, 0 blocked, 0 won't-do** out of 6 in-scope items.

Out-of-scope follow-ups (separate workflows): H-7 (#80, operator rotation, deadline 2026-05-03), NEW-M-2 (#140, Zig 0.16 createFile semantics check), BENCH-BASELINES-MISSING (#166), PERF-SLO-DEFINE (#167).

## Closed Items

| Gap-ID | File | Title | Commit | Evidence |
|--------|------|-------|--------|----------|
| PR-1 | `docs/PERF_GAP_ANALYSIS.md` | `MeterProvider.pointFor` concurrency race | `177708f` | `src/sdk/metrics.zig:90-95,305-360,644-790`; tests in `test/metrics_concurrency.zig` (3); bench: `micro_counter_add_4_attrs_hit` -2.6%, `micro_histogram_record_4_attrs_hit` -0.4% (within ±5%) |
| PR-2 | `docs/PERF_GAP_ANALYSIS.md` | Two-pass OTLP encoder; eliminate quadratic `copyForwards` | `a8cce5b` | `src/generated/otlp.zig` (deferred-compaction `Writer.toOwnedSlice`); 6 inline tests + `test/otlp_wire_parity.zig` (3); `bench-micro` `micro_encode_spans_proto_{64,512,4096}` flat ~50 K spans/s |
| PR-3 | `docs/PERF_GAP_ANALYSIS.md` | Trace encoder groups spans by `instrumentation_scope` | `a092ca4` | `src/exporters/otlp_http/encode_proto.zig:216` (`groupSpansByScope`); tests in `test/otlp_spans_multi_scope.zig` (5: name/version/schema_url + single-scope byte parity + DevNW↔in-repo wire parity) |
| OTEL-Q-001 | `docs/QUALITY_GAP_ANALYSIS.md` | Split `exporters/otlp_http.zig` (1407 LOC) into module tree | `6f11474` | `src/exporters/otlp_http/{exporter,transport,headers,encode_proto,encode_proto_devnw,encode_json,spans,metrics}.zig`; façade at `src/exporters/otlp_http.zig` (85 LOC); largest module 582 LOC; refactor-only — all existing suites pass with no test-file edits |
| OTEL-Q-NEW-A | `docs/QUALITY_GAP_ANALYSIS.md` | Tagged-union Transport (replace fn-ptr identity sentinel) | `6f11474` | `src/exporters/otlp_http/transport.zig:57` (`Transport = union(enum) { stdlib_io, custom: CustomFn }`); dispatch at `src/exporters/otlp_http/exporter.zig:163` (`switch (self.transport)`); `grep 'self.transport ==' src/exporters/` returns no hits |
| NEW-H-1 | `docs/SECURITY_GAP_ANALYSIS.md` | Proto/semconv manifest provenance gate (CONFIDENTIAL) | `1e01147` | `tools/manifest.zig` (shared engine + `requireSpecPayload` invariant); `docs/proto-manifest.txt` (19 lines), `docs/semconv-manifest.txt` (248 lines); `third_party/opentelemetry-proto-v1.10.0/` (16 files), `third_party/semantic-conventions-v1.40.0/` (244 + LICENSE); `make verify-manifests` CI hook; tests in `test/manifest_provenance.zig` (5) |

## Won't Do Items

None. NEW-H-1 had a possible "rename manifest, defer real provenance" escape hatch but project policy required the real fix for a confirmed High security finding (CWE-345); Path A (vendor real upstream sources) was taken.

## Blocked Items

None.

## Tests Executed

| Command | Result |
|---------|--------|
| `zig fmt --check src/ tools/ test/ build.zig build.zig.zon` | PASS (exit 0) |
| `zig build check` | PASS (exit 0) |
| `zig build test --summary all` (default) | PASS — 109 pass / 21 skip / 0 fail across 40/40 build steps |
| `zig build test --summary all` (`-Dotel_use_devnw_json=true -Dotel_use_devnw_protobuf=true -Dotel_use_devnw_metrics=true`) | PASS — 114 pass / 16 skip / 0 fail (DevNW codecs path) |
| `make ci` | green (per audit baseline + verifier confirmation) |
| `bench-micro` `micro_encode_spans_proto_{64,512,4096}` | flat ~50 K spans/s across 64×–4096× batch range (was super-linear pre-PR-2) |
| Hot-path delta `micro_counter_add_4_attrs_hit` / `micro_histogram_record_4_attrs_hit` (PR-1) | -2.6% / -0.4% — within ±5% gate |

The 21 default skips and 16 DevNW-path skips are intentional (platform / network / live-collector gates); zero failures on either configuration.

## Security Notes

- **NEW-H-1 (#134, CONFIDENTIAL).** Pre-fix, `docs/proto-manifest.txt` and `docs/semconv-manifest.txt` hashed only `LICENSE` files in each `third_party/<pin>/` directory, leaving the actual `.proto` and YAML model bytes (the bytes the in-tree `src/generated/otlp.zig` and `src/generated/semconv.zig` were derived from) un-anchored. CWE-345 (Insufficient Verification of Authenticity), OWASP A08:2021. Path A taken: vendor the real upstream subset (16 OTLP `.proto` + Google-API HTTP gateway annotations + READMEs + LICENSE; 244 semantic-convention model files + LICENSE). New shared engine (`tools/manifest.zig`) walks every regular file, sorts by POSIX path, emits SHA-256 per file, and a `requireSpecPayload` invariant fails loud (exit 2) on any LICENSE-only state. Generators added `--verify` mode wired through `zig build verify-manifests` and `make verify-manifests` (now part of `make ci`). Closure comment on #134 is intentionally brief per confidentiality policy and does not enumerate the pre-fix exploit path beyond what is in the public diff.
- **PR-1 (#135).** Concurrent record/collect races could tear the `inst.points` ArrayList header or dangle a `&items[idx]` pointer across a re-grow. Per-instrument mutex now wraps both record and collect; `pointIndexFor` returns indices instead of pointers; `collect()` deep-copies attribute sets and histogram buffers under the lock. No security boundary crossed in the defect, but the data-race UB on metric aggregation is a correctness defect that touched aggregation state inputs (downstream OTLP wire bytes); fix removes the UB.
- **PR-3 (#136).** Wire-correctness defect — multi-tracer batches mislabelled scope on every span past index 0. Fix groups by full `(name, version, schema_url)` tuple and emits one `ScopeSpans` per bucket. No exploitable path; misattribution risk to downstream backends only.
- **OTEL-Q-001 / OTEL-Q-NEW-A.** Refactor-only. The tagged-union Transport eliminates an LTO-fragile fn-pointer-identity sentinel. No public-API surface change.

## Remaining Blockers

None for this scope. Operator-pending follow-ups (separate workflows):

- **H-7 (#80, CONFIDENTIAL)** — operator rotation of `OTEL_INTEGRATION_AUTH_HEADER` GitLab CI/CD variable; deadline **2026-05-03 (6 days)**. Owner: `benji@codepros.org`. Code side closed in commit `43330db` (2026-04-26). Audit script at `scripts/audit_ci_logs.sh` should run **before** rotation invalidates the token.
- **NEW-M-2 (#140, CONFIDENTIAL)** — confirm Zig 0.16 `std.fs.Dir.createFile` default `O_NOFOLLOW` semantics; downgrade to Info / Won't-Do if already nofollow on POSIX, otherwise patch. SLA 90d.
- **M-3 (#84)** — DevNW upstream Sigstore/cosign signing for vendored source tarballs. Out of repo scope.
- **BENCH-BASELINES-MISSING (#166)** + **PERF-SLO-DEFINE (#167)** — perf infrastructure tracking issues; gate for validating remaining open perf items.

## Platform Issues Updated

| Gap-ID | Issue | Action | Note URL |
|--------|------:|--------|----------|
| PR-1 | [#135](https://gitlab.com/devnw/zig/otel/-/work_items/135) | closed (with closure-evidence comment) | `#note_3290373474` |
| PR-2 | [#36](https://gitlab.com/devnw/zig/otel/-/work_items/36) | closed (with closure-evidence comment) | `#note_3290374638` |
| PR-3 | [#136](https://gitlab.com/devnw/zig/otel/-/work_items/136) | closed (with closure-evidence comment) | `#note_3290375628` |
| OTEL-Q-001 | [#149](https://gitlab.com/devnw/zig/otel/-/work_items/149) | closed (with closure-evidence comment) | `#note_3290376822` |
| OTEL-Q-NEW-A | [#163](https://gitlab.com/devnw/zig/otel/-/work_items/163) | closed (with closure-evidence comment) | `#note_3290377570` |
| NEW-H-1 | [#134](https://gitlab.com/devnw/zig/otel/-/work_items/134) (CONFIDENTIAL) | closed (with closure-evidence comment, redacted per policy) | `#note_3290379084` |

All six closures verified with `glab issue view <n> -R devnw/zig/otel` returning `state: closed`.

## Definition of Done

- [x] All 6 GitLab issues closed with evidence comments (one per gap; #134 redacted per confidentiality policy).
- [x] All affected tracking docs reflect Closed status.
  - `docs/PERF_GAP_ANALYSIS.md` — PR-1 / PR-2 / PR-3 marked **closed 2026-04-27**.
  - `docs/QUALITY_GAP_ANALYSIS.md` — OTEL-Q-001 / OTEL-Q-NEW-A marked **Closed**.
  - `docs/SECURITY_GAP_ANALYSIS.md` — NEW-H-1 row marked **Closed (2026-04-27)**.
  - `CHANGELOG.md` `[Unreleased]` — six entries (Security: NEW-H-1; Refactor: OTEL-Q-001, OTEL-Q-NEW-A; Performance: PR-2; Fixed: PR-3, PR-1).
- [x] Verifier verdict ALL PASS; 109/21/0 default and 114/16/0 DevNW; zero regressions.
- [x] `git status` clean after the two follow-up `docs(audit)` commits.
- [x] This Completion Report file exists with the standard sections.
