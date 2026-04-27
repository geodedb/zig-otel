# Gap-Collector Orientation — devnw/zig/otel

> Generated: 2026-04-27
> Platform: GitLab (`gitlab.com/devnw/zig/otel`)
> Auth: glab OK (logged in as `benjiv`)
> Scope: entire repo

## Project shape

- Zig 0.16 OpenTelemetry client library: trace + metric + log SDK, OTLP HTTP+gRPC exporters, propagation, baggage, semconv, signals, batching.
- Spec targets: OpenTelemetry 1.56.0 / OTLP 1.10.0 / SemConv 1.40.0 / Declarative 1.0.0.

## Issue tracker totals (authoritative)

Source: `glab api projects/devnw%2Fzig%2Fotel/issues_statistics`.

| State  | Count |
|--------|-------|
| Open   | 108   |
| Closed | 24    |
| **All**| **132** |

Page-fetch confirmed 132 issues across 2 pages of 100/page.

## Label coverage (all 132 issues)

| Bucket                | All | Open |
|-----------------------|----:|-----:|
| `gap`                 | 38  | 37   |
| `security`            | 27  | 6    |
| `performance`         | 30  | 28   |
| `quality`             | 37  | 37   |
| `type::feature`       | 19  | 19   |
| `type::bug`           | 28  | 27   |
| `type::enhancement`   | 52  | 50   |
| `type::security`      | 23  | 2    |
| `priority::critical`  | 9   | 6    |
| `priority::high`      | 18  | 12   |
| `priority::medium`    | 24  | 16   |
| `priority::low`       | 19  | 14   |

Closed issues are dominated by the recent security-closure run (21 of 24 closed carry `type::security`) plus P0 perf landings and OTLP metric export.

## Doc-side requirement sources (all mirror the tracker)

| Doc | Lines | Purpose | Tracker linkage |
|-----|------:|---------|-----------------|
| `docs/GAP_ANALYSIS.md` | 112 | Open functional gaps index (35 entries) | every row links to GitLab issue ID |
| `docs/GAP_ANALYSIS_RESOLVED.md` | 112 | Closed gaps ledger | every row links to GitLab work_items/IID |
| `docs/SPEC_COMPLIANCE.md` | 155 | MUST/REQUIRED clauses → file+test | references gap IDs for deferred work |
| `docs/PERF_GAP_ANALYSIS.md` | 208 | Perf P0/P1/P2/P3 ranked plan | each row has GitLab issue link |
| `docs/QUALITY_GAP_ANALYSIS.md` | 206 | Quality findings by tier | each tier row links GitLab issue |
| `docs/SECURITY_GAP_ANALYSIS.md` | 222 | Security findings (C/H/M/L) | each row links GitLab work_items |
| `CHANGELOG.md` | 70 | Released change log | -- |
| `README.md` | 201 | User-facing surface | links to docs/SPEC_COMPLIANCE.md |
| `docs/audit/*` | -- | Phase audits feeding the gap docs | -- |

**No doc-only requirements were found that lack a GitLab issue.** Every requirement, gap, security finding, perf item and quality item in the docs explicitly cross-references a GitLab issue ID. The catalog is fully reconciled.

## Label taxonomy status

All required labels exist on the project (50 labels total). Verified via `glab label list`:

| Required label            | Status |
|---------------------------|--------|
| `priority::critical`      | exists |
| `priority::high`          | exists |
| `priority::medium`        | exists |
| `priority::low`           | exists |
| `type::feature`           | exists |
| `type::bug`               | exists |
| `type::enhancement`       | exists |
| `type::security`          | exists |
| `gap`                     | exists |

Plus extended taxonomy already in use: `severity::*`, `security::*`, `perf::p0..p3`, `category::*`, `area::*`, `confidence::*`, `dev::*`, `status::triage`, `sec::vuln`, `sec::remediation`. Nothing to create.

## Blockers

None. Auth is healthy (despite a misleading "Invalid token provided" warning from glab — API calls succeeded against `issues_statistics`, `issue list`, and `label list`). All 132 issues paginated cleanly.

## Recently closed (gap-closure work since previous run)

Per `git log` and `docs/GAP_ANALYSIS_RESOLVED.md`:

- Security closure run `d19b65b..cd9f906` — 20 fully closed, 2 partial.
- `GAP-BENCH-NOT-WIRED` (#78) closed in PM re-audit.
- `GAP-OTLP-METRIC-EXPORT` (#7) closed 2026-04-27 (HTTP `/v1/metrics` + gRPC `MetricsService/Export`).
- Recent commits land P0-1, P0-2, P0-4, P0-9, P0-10, P-N1, P-N2 perf items and the BSP-default ADR.

## Artifacts written

| Path | Purpose |
|------|---------|
| `docs/audit/gap-collector/ORIENTATION.md` | this summary |
| `docs/audit/gap-collector/catalog.json` | machine-readable totals + label histograms |
| `docs/audit/gap-collector/catalog.csv` | full 132-row catalog (iid, state, title, labels, url) |

## Gap-scanner next-step pointers

- **Open gap queue:** filter `gap` + `state==opened` (37 items) — see `catalog.csv`.
- **Critical open:** 6 issues (`priority::critical` + opened). Top of queue: #1, #3 (sibling pair, one-line fix), #4 (exporter factory — gates per-signal env-var family), #8 (OTLP log export), #9 (OTLP wire events/links).
- **Reconciliation:** all 38 `gap`-labelled issues have a corresponding row in `docs/GAP_ANALYSIS.md` or `docs/GAP_ANALYSIS_RESOLVED.md`.
- **Conflicts found:** none.
