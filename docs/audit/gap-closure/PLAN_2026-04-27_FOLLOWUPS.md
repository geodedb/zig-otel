# Gap Closure Plan — Deferred Follow-Ups (2026-04-27)

**Author:** <benji@codepros.org>
**Branch:** `main` (clean)
**Source audit:** `docs/audit/AUDIT_SUMMARY_2026-04-27.md` §"Operator-Pending Follow-Ups"
**Predecessor plan:** `docs/audit/gap-closure/PLAN_2026-04-27.md`
(7 commits already pushed today closing PR-1, PR-2, PR-3, OTEL-Q-001, OTEL-Q-NEW-A, NEW-H-1)

This plan covers the **5 deferred follow-ups** that were explicitly out of
the morning's 5-PR closure run. Each item carries an SLA, an owner, and a
recommended terminal status; not all of them are coding work.

---

## 1. Baseline (captured 2026-04-27, before any follow-up work)

| Action | Command | Result |
|--------|---------|--------|
| Format | `zig fmt --check src/ tools/ test/ build.zig build.zig.zon` | EXIT 0 (clean) |
| Build  | `zig build check` | EXIT 0 (clean) |
| Test   | `zig build test --summary all` | **40/40 steps; 109/130 pass / 21 skip / 0 fail** |

This matches the morning verifier verdict (`109/21/0` default), so the
five deferred items are starting from a known-green baseline.

DevNW-codecs run was previously recorded at 114/16/0; not re-run for this
plan because none of the 5 follow-ups touches the DevNW JSON encoder
hot-path.

---

## 2. Gap Files Surveyed

| File | Domain | Open | Partial | Closed | Won't Do |
|------|--------|-----:|--------:|-------:|---------:|
| `docs/GAP_ANALYSIS.md` | General | 33 | 0 | 0 | 0 |
| `docs/PERF_GAP_ANALYSIS.md` | Performance | 27 | 1 | 10 | 0 |
| `docs/QUALITY_GAP_ANALYSIS.md` | Quality | 16 | 0 | 4 | 0 |
| `docs/SECURITY_GAP_ANALYSIS.md` | Security | 1 (H-7 op-pending) | 0 | 20 | 4 |
| `docs/GAP_ANALYSIS_RESOLVED.md` | History | — | — | — | — |

In-scope subset for this plan = the 5 items called out by the audit
summary as **Operator-Pending Follow-Ups**. No other open gap is being
re-opened in this run.

The 4 `zig-pkg/thread_pool-*/docs/` `*GAP_ANALYSIS.md` files are vendored
DevNW dependency artifacts and out-of-scope.

---

## 3. Real-State Findings (per item)

### 3.1 H-7 #80 — CI token rotation (deadline 2026-05-03)

| Check | Result |
|-------|--------|
| `scripts/audit_ci_logs.sh` exists | YES (`-rwxrwxr-x`, 3.8 kB) |
| Script is executable | YES |
| Runbook `docs/runbooks/h7-token-rotation.md` exists | YES (4.2 kB, dated 2026-04-27) |
| Runbook references audit script | YES (line 41-43) |
| Runbook deadline accurate | YES (2026-05-03 explicit) |

**Note:** the audit-summary-mentioned `docs/runbooks/baseline-bootstrap.md`
does **not** exist (only `h7-token-rotation.md` is in `docs/runbooks/`).
Ignore — that file belongs to a different work item, not this rotation.

The script has an unfortunate local-test gotcha: it requires `glab` CLI
authenticated against `gitlab.com/devnw/zig/otel`. Implementer should
shell out to `glab auth status` before claiming "verified executable".

### 3.2 NEW-M-2 #140 (CONFIDENTIAL) — Zig 0.16 createFile + symlinks

**Verified directly against** `/data/home/benji/.local/share/mise/installs/zig/0.16.0/lib/std/Io/Dir.zig`:

| Evidence | Line | Outcome |
|----------|-----:|---------|
| `pub const CreateFileOptions = struct {` | 586 | No `follow_symlinks` field at all |
| `pub fn createFile(...flags: CreateFileOptions)` | 638 | Flags struct lacks the toggle |
| `pub const OpenFileOptions = struct {` | 498 | Has `follow_symlinks: bool = true` (line 551) |
| Backend conditional (every Io variant) | `Threaded.zig:8211`, `Uring.zig:2720`, `Dispatch.zig:2352`, etc. | `if (!options.follow_symlinks) AT.SYMLINK_NOFOLLOW else 0` — gated on a field that **doesn't exist on `CreateFileOptions`** |

**Conclusion:** `Dir.createFile` follows symlinks unconditionally on Zig
0.16. `src/exporters/file.zig:34` is therefore vulnerable to a symlink
swap inside the trusted `base` dir (e.g., a hostile sidecar replaces
`spans.jsonl` with a symlink to `/etc/cron.d/x`).

**This means:** NEW-M-2 is **NOT** an info-close. It needs a real patch.

Three viable patches:

1. After `createFile`, `fstat` the result and reject if `S_ISLNK`. Race-prone (TOCTOU between create and stat) — reject.
2. `openFile(.{ .follow_symlinks = false, .mode = .read_write })` first, fall back to `createFile` only on `error.FileNotFound`. Cleanest; matches OWASP guidance for trusted-dir log writers.
3. `O_NOFOLLOW | O_CREAT` via raw `posix.openat`. Bypasses Zig's `Io.Dir`; portability cost.

Recommendation: **option 2** plus a regression test that plants a symlink
under a tmp `base` and asserts the open path returns `error.IsSymLink`
(or `AccessDenied` per platform).

### 3.3 M-3 #84 — DevNW Sigstore/cosign signing

The local `build.zig.zon` SHA-pins DevNW deps; verification works. But
**the signing infrastructure has to live in DevNW shared CI** (the org
that produces `json` and `thread_pool`), not in this consumer repo.
There is no actionable code change in `devnw/zig/otel` for this item.

`SECURITY_GAP_ANALYSIS.md:103` already records "Partially Closed
(consumer side); DevNW-side Sigstore/cosign signing infra remains OOB."

**Recommendation:** **Won't Do (this repo)**. Move the closure marker to
`GAP_ANALYSIS_RESOLVED.md` with a pointer to where the upstream tracker
should land (DevNW-meta repo).

### 3.4 BENCH-BASELINES-MISSING #166

Surveyed `benchmarks/` and `docs/performance/`:

| Have baselines (before/after JSON) | Missing baselines |
|------------------------------------|-------------------|
| P0-1 attribute-set | P0-3 setName arena-only |
| P0-2 spanstate-pool | P0-5 attributeKey scratch (folded P0-4) |
| P0-4 pointFor | P0-7 Histogram bucket binsearch |
| zero-overhead-when-disabled (ref-a/ref-b) | P0-8 BSP queue contention |
| (PR-2 implicitly via micro_encode_spans_proto_{64,512,4096}) | P-N3..P-N7, P1-1..P1-13 |

A clean baseline requires a hand-written micro/integration scenario per
gap (the `framework.Scenario` shape). For closed/folded items
(P0-5/P1-4/P1-12) the baseline would be retrospective. For the
14 not-yet-closed items (P0-3/P0-7/P0-8/P-N3..N7/P1-1..3/P1-6..13)
authoring proper A/B harnesses is **clearly more than one session of
work** — each scenario needs domain modeling.

**Recommendation:** **Partial** — this session captures baselines only
for items that already have a probe shape:

- PR-2 micro_encode_spans_proto_{64,512,4096} (already in `bench-micro`,
  just needs a results dump committed under
  `docs/performance/2026-04-27-pr-2-nested-encode/`)
- PR-1 metrics scenarios — need fresh micro scenario; defer
- zero-overhead probe is already current; pin its current numbers as the
  PERF-SLO floor (see 3.5)

The remaining 14 items are reissued as scoped tracker work in #166's
description (each gets its own `docs/performance/<date>-<id>/` dir).

### 3.5 PERF-SLO-DEFINE #167

Documentation + policy task. Tractable in one session. Inputs available:

- `benchmarks/check_hard_criteria.zig` already enforces two criteria
  (comptime-disabled ≤ baseline+2 ns; level-1-tracer-noop ≤ baseline+5 ns)
- Current ref-a baseline-no-call is 5320 ns/10 000 ops = **0.532 ns/op**
- 18 micro scenarios with stable p50/p95/p99 in
  `benchmarks/micro/main.zig:32-56`

Proposed SLO numbers (to be ratified in implementer phase against fresh
data, not these stale ref-a numbers):

| Metric | Floor | Source |
|--------|------:|--------|
| comptime-disabled overhead | ≤ baseline+2 ns | already enforced |
| level-1 tracer-noop overhead | ≤ baseline+5 ns | already enforced |
| span record steady-state p99 | TBD via fresh `bench-micro` | new |
| metric counter add (4-attr hit) p99 | TBD via fresh `bench-micro` | new |
| OTLP encode 512-span batch p99 | TBD via fresh `bench-micro` | new |
| zero-alloc scenarios alloc/op | == 0 | already enforced for level-1 |

Implementer phase will:

1. Run `zig build bench-micro` and `zig build bench-integration`, capture JSON.
2. Author `docs/performance/SLO.md` with each scenario's measured p99 + chosen tolerance.
3. Extend `benchmarks/check_hard_criteria.zig` with the new rule set.
4. Wire into `make ci` so SLO regression breaks the build.

Steps 1-3 are squarely one session of work. Step 4 ties into the
already-scoped CI dark-spot work (audit-summary blocker §4).

**Recommendation:** **Closed** with the SLO.md file + extended
hard-criterion checker as evidence.

---

## 4. Implementation Order

| # | Item | Est. effort | Status target | Why this slot |
|--:|------|------------:|---------------|---------------|
| 1 | M-3 #84 (Won't Do) | 5 min | Won't Do | Doc-only re-class; clears the queue and removes a distractor |
| 2 | NEW-M-2 #140 (patch) | 45 min | Closed | Real bug found in 3.2; security fix should land before SLO/baselines |
| 3 | H-7 #80 (verify + checklist) | 20 min | Blocked (operator-pending) | Tractable verification; deadline 2026-05-03 makes this urgent regardless |
| 4 | PERF-SLO-DEFINE #167 | 60 min | Closed | Need SLO numbers before BENCH-BASELINES partial-close uses them |
| 5 | BENCH-BASELINES-MISSING #166 | 30 min (partial) | Partial | Partial close depends on SLO numbers; reissue tracker for the 14 untractable rows |

**Total session estimate:** ~2.5 hours.

The order matches the user's proposal exactly.

---

## 5. Per-Item Acceptance / Closure Criteria

### 5.1 M-3 #84 → Won't Do

- `docs/GAP_ANALYSIS_RESOLVED.md` gains a "Won't Do (deferred upstream)"
  row for M-3 with explicit pointer to DevNW-meta tracker location.
- `docs/SECURITY_GAP_ANALYSIS.md:103` updated from "Partially Closed
  (consumer side)" to "Won't Do (upstream)" with rationale.
- GitLab issue #84 commented + closed as `wontfix`.

### 5.2 NEW-M-2 #140 → Closed

- `src/exporters/file.zig:34` no longer races on symlinks. Concretely:
  `open()` either uses an `openFile(.{ .follow_symlinks = false, ... })`
  prelude before `createFile`, or post-`createFile` `fstat`+reject if
  `S_ISLNK` (option 2 preferred).
- New regression test under `test/file_exporter_symlink.zig` (or inline
  in `src/exporters/file.zig`):
  - `tmp_dir/spans.jsonl -> /tmp/evil` symlink planted before `open()`
  - Assert `error.IsSymLink` or platform-equivalent
- All existing `validateSubPath` tests still pass.
- `zig build test --summary all` still 0 fail.
- Doc: `SECURITY_GAP_ANALYSIS.md` Section 6.2 NEW-M-2 row → Closed with commit hash.

### 5.3 H-7 #80 → Blocked (operator-pending)

- `scripts/audit_ci_logs.sh --help` runs cleanly; verified executable bit.
- `glab auth status` documented in runbook as a pre-flight (verify
  current text already covers it; if not, patch).
- Issue #80 gets a comment with a 5-step operator checklist:
  1. `glab auth status` returns OK on `gitlab.com/devnw/zig/otel`
  2. Run `scripts/audit_ci_logs.sh --days 90 --job otlp-integration-live`
  3. Generate replacement token; update GitLab CI/CD variable
  4. Trigger `otlp-integration-live` job; confirm `[masked]` redaction
  5. Revoke old token; update `SECURITY_GAP_ANALYSIS.md` quarterly cron
- Status remains **Open / Blocked (operator)** in the tracker. **No code
  closure.** Deadline 2026-05-03.

### 5.4 PERF-SLO-DEFINE #167 → Closed

- New file `docs/performance/SLO.md` with measured p99 numbers + chosen
  tolerances per scenario.
- `benchmarks/check_hard_criteria.zig` extended with at least 2 new
  rules drawn from SLO.md (e.g., span-record steady-state, OTLP-512 encode).
- `make ci` (or `zig build hard-criterion-check`) gates SLO regressions.
- `docs/PERF_GAP_ANALYSIS.md` row 100 (PERF-SLO-DEFINE) → Closed with commit hash.

### 5.5 BENCH-BASELINES-MISSING #166 → Partial

- `docs/performance/2026-04-27-pr-2-nested-encode/results/{before,after}.json`
  populated with the existing PR-2 commit's pre/post numbers.
- (Optional, if cheap) re-baseline zero-overhead probe and pin the
  numbers as the SLO floor in #167.
- Issue #166 description rewritten to itemize the 14 not-yet-baselined
  perf gaps as separate scoped follow-ups (each will need its own
  `docs/performance/<date>-<id>/plan.json` and is sized as 30-90 min/each).
- `docs/PERF_GAP_ANALYSIS.md` row 99 (BENCH-BASELINES-MISSING) → Partial
  with a link to the per-gap follow-ups list.

---

## 6. Dependencies

- **#167 → #166 (partial):** SLO numbers feed the baseline-pin choice,
  so PERF-SLO-DEFINE closes before the BENCH-BASELINES partial close.
- No other inter-item deps. M-3 and NEW-M-2 are independent of the rest.

---

## 7. Risks / Blockers

| Risk | Likelihood | Mitigation |
|------|-----------:|------------|
| `glab` not installed locally → can't smoke-test the audit script | Med | Run `--help` only; the live `glab ci list` path is operator-side anyway. Document the dependency. |
| NEW-M-2 fix breaks existing `test/file_exporter_*.zig` (if any) | Low | Re-run full test suite; expected fall-out is minimal because nothing legitimate currently writes through symlinks. |
| Hard-criterion changes destabilize CI | Med | Add new criteria as `allow_failure: true` for one cycle; flip after a known-clean run lands. Aligns with audit summary §"CI dark spots". |
| BENCH-BASELINES "partial" leaves #166 misleadingly open | Med | Issue description rewrite is part of acceptance; reviewer must confirm the 14-item scoped list landed before merge. |
| ScheduleMissed on H-7 deadline | Low (6 days remaining) | This plan publishes a 5-step checklist; operator owns the SLA. |

No hard blockers. Implementer phase can proceed.

---

## 8. Out-of-Scope Notes (informational)

These items from the audit summary §"Operator-Pending Follow-Ups" are
**not** addressed in this plan and remain on the long-term backlog:

- **#6** — re-enable zig-fuzz + Windows tests after upstream Zig 0.16 fix.
- **#6** — flip benchmark-regression `allow_failure: false` after baselines.
- **#7** — tracker drift on #7 + #101 (resolved-doc, tracked-open).

These belong to the next audit cycle, not this 5-item closure window.
