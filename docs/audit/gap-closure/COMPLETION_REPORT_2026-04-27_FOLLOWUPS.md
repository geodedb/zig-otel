# Gap Closure Completion Report — Deferred Follow-Ups (2026-04-27)

**Author:** <benji@codepros.org>
**Branch:** `main` (5 commits landed, not yet pushed)
**Scope:** 5 operator-pending follow-ups deferred from the 2026-04-27 morning closure run
**Plan:** [`docs/audit/gap-closure/PLAN_2026-04-27_FOLLOWUPS.md`](PLAN_2026-04-27_FOLLOWUPS.md)
**Predecessor report:** [`docs/audit/gap-closure/COMPLETION_REPORT_2026-04-27.md`](COMPLETION_REPORT_2026-04-27.md) (5 PRs landed earlier the same day)
**Audit summary:** [`docs/audit/AUDIT_SUMMARY_2026-04-27.md`](../AUDIT_SUMMARY_2026-04-27.md) §"Follow-ups Closed — 2026-04-27"

---

## GAP_ANALYSIS Status

Documentation update applied to in-scope tracking files only. Out-of-scope files (`docs/GAP_ANALYSIS.md`, `docs/QUALITY_GAP_ANALYSIS.md`, vendored `zig-pkg/thread_pool-*/docs/`) untouched.

| File | Closed (this run) | Blocked | Won't Do | Partial | Remaining Open | Total Items Touched |
|------|------------------:|--------:|---------:|--------:|---------------:|--------------------:|
| `docs/SECURITY_GAP_ANALYSIS.md` | 1 (NEW-M-2) | 1 (H-7 operator) | 1 (M-3) | 0 | — | 3 |
| `docs/PERF_GAP_ANALYSIS.md` | 1 (PERF-SLO-DEFINE) | 0 | 0 | 1 (BENCH-BASELINES-MISSING) | — | 2 |
| `docs/GAP_ANALYSIS_RESOLVED.md` | (M-3 moved Partial → Won't Do; pre-existing rows preserved) | — | 1 row updated | — | — | 1 |
| `docs/audit/AUDIT_SUMMARY_2026-04-27.md` | "Follow-ups Closed — 2026-04-27" section appended | — | — | — | — | — |
| `CHANGELOG.md` | 5 distinct `[Unreleased]` entries | — | — | — | — | — |

**Overall:** 3 fully closed (M-3 Won't-Do, NEW-M-2 Closed, PERF-SLO-DEFINE Closed), 1 blocked operator-pending (H-7), 1 partial (BENCH-BASELINES-MISSING) out of 5 in-scope follow-ups. 2 issues remain open on the GitLab tracker by design (H-7 awaiting operator action; #166 reduced to remaining-probe scope).

---

## Closed Items

| Gap-ID | File | Title | Commit | Evidence |
|--------|------|-------|--------|----------|
| NEW-M-2 (#140 CONFIDENTIAL) | `docs/SECURITY_GAP_ANALYSIS.md` §6.2 | File JSONL exporter follows symlinks (CWE-59 / OWASP A01:2021) | `d8dd8a5` | `src/exporters/file.zig:50-69` — `Dir.openFile(.{ .follow_symlinks = false, .mode = .write_only })` first; on `error.FileNotFound` falls through to `Dir.createFile(.{ .exclusive = true })` (`O_NOFOLLOW` + atomic `O_CREAT \| O_EXCL`). Regression coverage: `test/file_exporter_symlink.zig` (3 tests — symlink-refusal with sentinel-bytes-preserved assertion, fresh-create branch, existing-regular-file restart branch). Zig 0.16.0 stdlib citation: `lib/std/Io/Dir.zig:586` `CreateFileOptions` has no `follow_symlinks` field (compare `OpenFileOptions:551`). |
| PERF-SLO-DEFINE (#167) | `docs/PERF_GAP_ANALYSIS.md` row "PERF-SLO-DEFINE" | Service-level performance SLO + runtime hard-criterion gate | `e82205d` | `docs/performance/SLO.md` (~290 lines, 9 sections) anchors per-op latency + alloc ceilings to the verified 2026-04-26 P0-1 / P0-4 baselines. `benchmarks/check_hard_criteria.zig` Rule 3 caps `micro_attr_put_update` p99 at **50 ns/op** (1.6× headroom over the 31.92 ns/op floor); Rule 4 caps `micro_counter_add_4_attrs_hit` at **0.005 allocs/op** (3.3× headroom over the 0.0015 allocs/op floor). `make slo-check` drives `bench-micro -Doptimize=ReleaseFast` + the gate; `make ci` includes `slo-check`. Verified PASS on fresh ReleaseFast bench-micro output (28.24 ns/op p99 attr-update; 0.0015 allocs/op counter-add hit). |

---

## Won't Do Items

| Gap-ID | File | Title | Commit | Reason |
|--------|------|-------|--------|--------|
| M-3 (#84) | `docs/SECURITY_GAP_ANALYSIS.md` row 13 + `docs/GAP_ANALYSIS_RESOLVED.md` Won't-Do section | DevNW deps SHA-pinned but unsigned; no upstream Sigstore/cosign signing | `914579e` | Sigstore/cosign signing of DevNW packages (`slog`, `json`, `yaml`, `config`, `protobuf`, `metrics`, `tls`, `grpc-zig`, `thread-pool`, `dotenv`, `runtime`, `prometheus`) requires changes to **DevNW shared CI infrastructure**, not this consumer repo. No actionable code change in `devnw/zig/otel`. **Alternative controls in place (consumer side, commit `f82e186` 2026-04-26):** SHA pinning of every DevNW dep in `build.zig.zon` (`.hash` entries) + `osv-scanner` CI gate on MR / main / scheduled pipelines covers CVE surface in the meantime. Upstream signing tracked OOB on the DevNW-meta tracker (to be filed at `gitlab.com/devnw/meta`). Reclassified from "Partially Closed (consumer side)" → **"Won't Do (this repo)"** 2026-04-27. |

---

## Blocked Items

| Gap-ID | File | Title | Commit | Blocker | Unblock Steps | Deadline |
|--------|------|-------|--------|---------|---------------|----------|
| H-7 (#80 CONFIDENTIAL) | `docs/SECURITY_GAP_ANALYSIS.md` §2.1 + row 4 of Top-5 | Live integration test response-body printer — token rotation pending | `b3301e7` | Operator-side action only — code side already closed in `43330db` (2026-04-26). Local `glab` cached token is rejected by gitlab.com (`! Invalid token provided in configuration file.`); only the operator can authenticate against the project to run the pre-rotation audit and replace the CI/CD variable. | **Five-step checklist (verbatim from `docs/runbooks/h7-token-rotation.md` and `SECURITY_GAP_ANALYSIS.md` §2.1):** (1) `glab auth login` to refresh PAT; (2) run `bash scripts/audit_ci_logs.sh --days 90 --job otlp-integration-live` **BEFORE** rotation (rotating invalidates the bearer the script needs); save output; PASS → continue, any hit → fork to incident-response; (3) GitLab UI → Project → Settings → CI/CD → Variables → replace `OTEL_INTEGRATION_AUTH_HEADER` (Masked YES, Protected YES, Expanded NO); (4) trigger one `otlp-integration-live` pipeline and confirm `OTLP integration test PASS` + `[masked]` token; (5) revoke old ingest token in GitLab Observability + update issue #80 with `Rotated YYYY-MM-DD; next rotation YYYY-MM-DD; CI log audit clean`. | **2026-05-03** (6 days from 2026-04-27). Owner: `<benji@codepros.org>`. |

---

## Partial Items

| Gap-ID | File | Title | Commit | Captured This Session | Remaining Scope | Reissued As |
|--------|------|-------|--------|------------------------|------------------|-------------|
| BENCH-BASELINES-MISSING (#166) | `docs/PERF_GAP_ANALYSIS.md` rows for #166 + §"Deferred bench probes" | Bench A/B baselines for closed and pending perf gaps | `94866d2` | PR-2 nested-encode (`micro_encode_spans_proto_{64,512,4096}`) frozen ReleaseFast snapshot at `docs/performance/2026-04-27-pr-2-encoder/results/{baseline.json,latest.json}` + `results.md` (subject, build flags, capture date, source PR pointer, numbers table). Per-span cost flat ≤6% spread across the 64×–4096× batch range, confirming PR-2 fix. **Combined with the 2026-04-26 P0-1 / P0-2 / P0-4 + `zero-overhead-when-disabled` dirs, every micro-scenario currently in `benchmarks/micro/main.zig` has a captured ReleaseFast snapshot.** | 18 deferred probes (P0-3, P0-5 folded, P0-7, P0-8, P-N3..P-N7, P1-1 alias, P1-2, P1-3, P1-6, P1-7, P1-8, P1-10, P1-11, P1-13) + 2 Won't-Do rows (P1-4 subsumed by P0-2, P1-12 auto-fixed by P0-1). Each row in the §"Deferred bench probes" table carries subject, target probe layer (micro / integration), and a 5-step unblock recipe (author probe → `make ci` → `make slo-check` → extract rows → write `results.md`). | Issue #166 stays OPEN with reduced scope; a comment on the tracker enumerates the captured set, the deferred set, and the unblock recipe. |

---

## Tests Executed

Verifier ran the full suite under both default and DevNW-codec build flags. Verdict: ALL PASS, zero regressions.

| Command | Result |
|---------|--------|
| `zig fmt --check src/ tools/ test/ build.zig build.zig.zon` | PASS (exit 0) |
| `zig build check` | PASS (exit 0) |
| `zig build test --summary all` (default) | PASS (**112 / 133 ; 21 skip ; 0 fail**) |
| `zig build test -Dotel_use_devnw_protobuf=true -Dotel_use_devnw_json=true --summary all` | PASS (**117 / 133 ; 16 skip ; 0 fail**) |
| `bash scripts/audit_ci_logs.sh --help` | PASS (exit 0) |
| `bash scripts/audit_ci_logs.sh --unknown-flag` | PASS (exit 2 — usage-error contract) |
| `bash -n scripts/audit_ci_logs.sh` | PASS (exit 0 — syntax clean) |
| `glab auth status` | host present, token rejected — operator must `glab auth login` before live audit run (documented in runbook §1) |
| `make slo-check` (Rule 3 / Rule 4) | PASS (28.24 ns/op p99 attr-update; 0.0015 allocs/op counter-add hit) |
| Pre-fix `test/file_exporter_symlink.zig` (NEW-M-2) | FAIL with `error.ExporterFollowedSymlink` |
| Post-fix `test/file_exporter_symlink.zig` (NEW-M-2) | PASS (3/3 tests) |

Baseline comparison (morning closure run → this run): **109/21/0 → 112/21/0** default (3 new symlink tests added), **114/16/0 → 117/16/0** DevNW codecs (same 3 tests). No tests regressed.

---

## Security Notes

- **NEW-M-2 (CWE-59 / OWASP A01:2021) is a real fix, not an info-close.** Plan §3.2 verified directly against `lib/std/Io/Dir.zig` in the active Zig 0.16.0 install: `CreateFileOptions` (line 586) has no `follow_symlinks` field at all — backends gate `AT.SYMLINK_NOFOLLOW` on a flag that does not exist on the `createFile` codepath, so `Dir.createFile` follows symlinks unconditionally. The `validateSubPath` defence from H-3 only covers string-level traversal (`..`, absolute paths) and cannot defeat a symlink already planted at the resolved path. The fix uses `O_NOFOLLOW` on the `openFile` prelude and `O_CREAT | O_EXCL` on the `createFile` fallback — the create is atomic against any entry that may have appeared between the existence check and the create call (including a symlink), so the TOCTOU window is closed at the kernel level. Sentinel-bytes-preserved assertion on the regression test confirms the planted target was not touched.
- **H-7 confidentiality preserved.** Issue #80 closure comment is deliberately brief (operator checklist + audit-script smoke result + deadline reminder) — no exploit detail, no PoC strings, consistent with the project confidentiality policy in `SECURITY_GAP_ANALYSIS.md` §7.
- **NEW-M-2 confidentiality preserved.** Closing comment on #140 cites only commit SHA + file:line + test names + Zig stdlib citation — no exploit path or attacker model details.
- **M-3 reclassification documented.** Both `SECURITY_GAP_ANALYSIS.md` row 13 and `GAP_ANALYSIS_RESOLVED.md` Won't-Do section now name DevNW shared CI as the responsible owner and point to the `gitlab.com/devnw/meta` tracker location for the upstream work item; consumer-side controls are explicitly enumerated as the alternative.
- **No new exposures.** `make verify-manifests` (proto + semconv provenance gates from NEW-H-1 morning closure) still passes; `gitleaks` not re-run this session because no new secret-prone surface was introduced (3 doc files + 1 src file + 1 test file modified across the 5 commits).

---

## Remaining Blockers

- **H-7 #80 — operator-side rotation** is the only remaining blocker against a fully-closed security ledger. Code side is fully closed. The five-step unblock checklist is the only path forward; deadline 2026-05-03; owner `<benji@codepros.org>`. Issue stays OPEN until the operator updates it with `Rotated YYYY-MM-DD; next rotation YYYY-MM-DD; CI log audit clean.`
- **#166 reduced scope** carries no blocker — the 18 deferred probes are scheduled work, each with a documented 5-step unblock recipe and a target probe layer. Each probe authoring is sized at 30–90 min/each per the recipe. Tracking-only.

No other blockers.

---

## Platform Issues Updated

GitLab project `devnw/zig/otel` (`gitlab.com/devnw/zig/otel`).

| Gap-ID | Issue | Confidential | Action | Closing Note (substance) |
|--------|------:|--------------|--------|--------------------------|
| M-3 | [#84](https://gitlab.com/devnw/zig/otel/-/work_items/84) | No | Closed (Won't Do) | Cites consumer-side mitigations (SHA pinning + osv-scanner CI gate from `f82e186`) and points to the DevNW-meta upstream tracker. Reclassification commit: `914579e`. |
| NEW-M-2 | [#140](https://gitlab.com/devnw/zig/otel/-/work_items/140) | **Yes** | Closed | Cites commit `d8dd8a5` + `src/exporters/file.zig:50-69` + 3 regression tests in `test/file_exporter_symlink.zig`. Brief technical detail only, no exploit path. |
| H-7 | [#80](https://gitlab.com/devnw/zig/otel/-/work_items/80) | **Yes** | Commented (kept OPEN) | Posts the 5-step operator unblock checklist + audit-script smoke evidence pointer (`docs/audit/h7-audit-evidence-2026-04-27.txt`) + deadline reminder 2026-05-03. Issue stays OPEN. |
| PERF-SLO-DEFINE | [#167](https://gitlab.com/devnw/zig/otel/-/work_items/167) | No | Closed | Cites commit `e82205d` + `docs/performance/SLO.md` + the 4 hard-criterion rules now active (Rule 1 comptime-disabled ≤ baseline+2 ns; Rule 2 level-1 tracer-noop ≤ baseline+5 ns; Rule 3 attr-update p99 ≤ 50 ns/op; Rule 4 counter-add allocs/op ≤ 0.005). |
| BENCH-BASELINES-MISSING | [#166](https://gitlab.com/devnw/zig/otel/-/work_items/166) | No | Commented (kept OPEN, reduced scope) | Posts commit `94866d2` + the captured set (PR-2 nested-encode snapshot under `docs/performance/2026-04-27-pr-2-encoder/`) + the 18 deferred probes + the 5-step unblock recipe. Issue scope formally reduced; remains OPEN until each deferred probe lands. |

**Closures:** 3 (#84, #140, #167). **Comments without close:** 2 (#80, #166).

---

## Definition of Done

- [x] M-3, NEW-M-2, PERF-SLO-DEFINE issues closed with evidence on tracker
- [x] H-7 + BENCH-BASELINES-MISSING issues updated (NOT closed) with appropriate status comments
- [x] All affected tracking docs reflect Closed / Blocked / Won't-Do / Partial status
- [x] CHANGELOG.md `[Unreleased]` has 5 distinct entries (one per gap)
- [x] git status clean after the close-out commit
- [x] Completion report (this file) exists with the 6-section format

---

## Artefact Index

- Plan — `docs/audit/gap-closure/PLAN_2026-04-27_FOLLOWUPS.md`
- Audit summary (with §"Follow-ups Closed — 2026-04-27") — `docs/audit/AUDIT_SUMMARY_2026-04-27.md`
- This report — `docs/audit/gap-closure/COMPLETION_REPORT_2026-04-27_FOLLOWUPS.md`
- Tracking — `docs/SECURITY_GAP_ANALYSIS.md`, `docs/PERF_GAP_ANALYSIS.md`, `docs/GAP_ANALYSIS_RESOLVED.md`, `CHANGELOG.md`
- H-7 audit-script smoke evidence — `docs/audit/h7-audit-evidence-2026-04-27.txt`
- H-7 runbook (operator-facing) — `docs/runbooks/h7-token-rotation.md`
- PERF-SLO-DEFINE policy — `docs/performance/SLO.md`
- BENCH-BASELINES-MISSING captured snapshot — `docs/performance/2026-04-27-pr-2-encoder/`
- NEW-M-2 fix — `src/exporters/file.zig` + `test/file_exporter_symlink.zig`
- Predecessor (morning) report — `docs/audit/gap-closure/COMPLETION_REPORT_2026-04-27.md`

**Commit range (this session):** `914579e..94866d2` (5 commits) — `main`, not yet pushed.
