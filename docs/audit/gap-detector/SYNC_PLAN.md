# Gap-Detector Sync Plan — Phase 4 input

> Generated: 2026-04-27
> Source: `docs/audit/gap-detector/REGISTRY.md`
> Target: GitLab `gitlab.com/devnw/zig/otel`
> Mode: registry only — Phase 4 (gap-sync) will execute these as `glab` calls.

## Mutations to apply

### CREATE (1)

| Title | Labels | Body source |
|-------|--------|-------------|
| `GAP-DISABLED-TRACER-DOC: disabled-mode tracer no-op contract undocumented and untested` | `gap; quality; priority::medium; type::enhancement; category::docs; category::tests` | REGISTRY.md §"GAP-DISABLED-TRACER-DOC" |

### CLOSE (3)

| IID | Closure note (one-paragraph) | Evidence |
|----:|------------------------------|----------|
| #1  | Tracer scope flow now passes through both fresh and reused span paths; verified by `test/trace.zig` lines 57 and 83–87 asserting scope.name, version, schema_url. The line reference in the issue title (`src/sdk/trace.zig:240`) is stale; current path is `src/sdk/trace.zig:289-296`. | `src/sdk/trace.zig:289-296`, `test/trace.zig:57,83-87` |
| #3  | OTLP wire output emits `fn_scope_name`/`fn_scope_version` correctly now that #1 root-cause is fixed. Sibling closure of #1. | `src/exporters/otlp_http.zig:1057-1058`, `test/otlp_wire_parity.zig` |
| #31 | redact.maskString is invoked in every export path: HTTP exporter (`src/exporters/otlp_http.zig:644,873,1108,1386`), Prometheus (`src/exporters/prometheus.zig:201`), JSON codec (`src/internal/json_codec.zig:173`). Coalesced with security-side closure of GAP-SEC-H-6 (commit `0cb9a79`). | listed file:line set above |

### NO-OP (verified open, evidence current)

The remaining 32 `gap`-labelled open issues retain their current state and labels. No relabel needed; severities in REGISTRY.md match the existing `priority::*` labels 1:1.

## Quality / perf / security items NOT touched by gap-sync

The catalog includes 71 non-`gap`-labelled open items (quality + perf + bench security). Phase 3 reviewed them and confirmed:

- 17 quality items map onto already-tracked gap obligations (e.g. C2/C3/H1) — no relabel.
- 28 perf items are tracked under `performance` and `perf::p*`; not converted to `gap`.
- 6 bench-area items (Q32–Q38, P-N3..P-N7, S-N1..S-N4) are correctly scoped as `area::bench` and are out of the gap-detector remit.

## Operator confirmations required before Phase 4 executes

- Confirm closure of #1, #3, #31 against the cited file:line evidence (single PR review or local `zig build test` run).
- Confirm the create body for `GAP-DISABLED-TRACER-DOC` matches the wording in REGISTRY.md.

## Roll-back plan

If any close is contested, gap-sync will re-open the issue with a `status::triage` label and a comment quoting the contested evidence. The new GAP-DISABLED-TRACER-DOC issue can be deleted in one `glab issue delete` if rejected.
