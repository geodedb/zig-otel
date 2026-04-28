# otel Integration Recipe (per consumer repo)

## Invariants

- Build flag `-Dwith_otel=<bool>` defaults to `false`. When `false`, the otel
  dependency is never resolved, no otel symbols are imported, and the
  produced artifact contains no `otel` or `observability` linked symbols
  (verified by `otel/scripts/verify-consumer-noop.sh`).
- Telemetry is non-fatal: every emit at the seam is wrapped `catch {}` (or
  the equivalent for the call shape) so a failed export, dropped span, or
  exporter timeout cannot propagate into caller code.
- Sampling default is `parentbased_traceidratio` @ 0.05 (5%). Consumers
  override via `OTEL_TRACES_SAMPLER` / `OTEL_TRACES_SAMPLER_ARG`.
- Resource attribute `service.name` defaults to the value the consumer
  passes as `service_name_default` to `Otel.init` — typically the `.name`
  field from `build.zig.zon` resolved at build time. Consumers override at
  runtime via `OTEL_SERVICE_NAME` (env wins; YAML, then the
  `service_name_default` parameter, fall in behind it).
- Exporter default is `otlp` over `http/protobuf` to
  `http://localhost:4318`. Override via `OTEL_EXPORTER_OTLP_*`.
- Secret redaction is on by default (otel ships with the redaction list:
  `password`, `secret`, `token`, `api.key`, `authorization`, `credential`).
  Consumers do not duplicate the list — they only ensure attributes named
  in spec language pass through unmodified.
- Profiles signal stays disabled (`-Dotel_profiles=false`); upstream proto
  is unstable (otel issue #25).

## Placeholders

The templates use the following angle-bracket placeholders. Replace each
one (project-wide find-and-replace) before committing the consumer repo:

- `<PIN_SHA>` — the otel commit SHA from `docs/plan/otel-rollout.md`'s
  Task 0.3 (`otel.dependency.git.commit`).
- `<PIN_HASH>` — the `zig fetch --save` output hash for that SHA.
- `<root_module_var>` — the `build.zig` local variable name for the
  consumer's root module (commonly `lib_mod` or `mod`).
- `<consumer>` — the consumer's `@import` module name, matching the
  `build.zig.zon` `.name` field (e.g. `http3`, `quic`, `tls`).

## The 8-step recipe

1. **Pull latest** the consumer repo on its default branch.
2. **Add the build option** `with_otel: bool = false` to `build.zig`.
3. **Add the gated dependency** to `build.zig.zon` using the pinned URL +
   hash from `otel/docs/integration/templates/build.zig.zon.fragment.zon.template`.
4. **Wire the conditional import** in `build.zig` exactly as
   `templates/build.zig.fragment.zig.template` shows.
5. **Drop in `observability.zig`** at the public root of the consumer's
   library module, copied from `templates/instrumentation.zig.template` and
   adapted at every `// TODO[REPO]:` marker.
6. **Drop in `observability_init.zig`** copied from
   `templates/otel_init.zig.template`; only compiled when `with_otel=true`.
   The consumer's `main()` (or equivalent process-entry) must hold the
   returned `Otel` value at a stable address (a `var` parked in `main`'s
   stack frame for the process lifetime, or a heap allocation) and call
   `installGlobals()` against `&that_value`. The two-phase split is
   deliberate — `init` returns by value, so publishing the global pointer
   from inside `init` would dangle.
7. **Wire the seam into the consumer's hot path** at every public
   request/operation entry point. Every emit is `catch {}`-discarded.
8. **Add two tests**: one disabled-no-op (copy of
   `templates/test_disabled_noop.zig.template`) verifying the no-op
   invariant, one enabled-smoke (copy of
   `templates/test_enabled_smoke.zig.template`) verifying a span lands in
   an in-memory recorder.

## Verification gate

After steps 1–8, run:

```bash
zig build test                                 # default flag = false
zig build test -Dwith_otel=true                # flag on
otel/scripts/verify-consumer-noop.sh <repo>    # symbol-leak check
```

All three must pass before commit.
