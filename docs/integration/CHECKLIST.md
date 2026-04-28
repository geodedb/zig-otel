# Per-repo otel Integration Checklist

- [ ] Repo has been `git pull --ff-only`'d on its default branch.
- [ ] Repo's GitLab visibility is "public" (confirm via list-public-siblings.sh).
- [ ] `with_otel` build option added, defaults to `false`.
- [ ] `build.zig.zon` has the gated `.otel` dependency entry with `lazy = true`.
- [ ] `build.zig` wires `b.lazyDependency("otel", ...)` only inside the
      `if (with_otel)` branch.
- [ ] `observability.zig` exists at the consumer's library root, with
      every public function returning a no-op when `enabled == false`.
- [ ] `observability_init.zig` exists and is only compiled when
      `with_otel = true`.
- [ ] Every public request/operation entry point calls `start*Span` /
      `end*Span` with `catch {}`-discard semantics.
- [ ] No telemetry path can return an error to caller code.
- [ ] `zig build test` passes.
- [ ] `zig build test -Dwith_otel=true` passes.
- [ ] `otel/scripts/verify-consumer-noop.sh <repo>` passes.
- [ ] README has an "Observability" section pointing at this guide.
