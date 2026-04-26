# Zero-Overhead-When-Disabled Bench Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the bench scenario catalog described by `docs/performance/2026-04-26-zero-overhead-when-disabled/plan.json` and add a `-Dotel_disabled=true` build option that compiles the OTel SDK out, so the user can prove the disabled path is zero-cost and quantify the cost of each enabled telemetry level.

**Architecture:** Two-axis bench system on top of the existing `benchmarks/framework.zig` harness. Axis A measures the existing runtime-noop vtable path. Axis B introduces a new `comptime build_options.otel_disabled` short-circuit at every API call site (`Tracer.startSpan`, `Counter.add`, `Histogram.record`, `Gauge.set`, `UpDownCounter.add`, `Logger.emit`). When the flag is `true`, those methods become `comptime`-known no-ops that the optimizer can fully dead-code-eliminate. Provider `tracer()` / `meter()` / `logger()` methods also short-circuit to API-layer noop handles when the flag is on. The bench harness compares: (i) baseline-no-call vs runtime-noop (≤ 5 ns Δ, 0 allocs), (ii) comptime-disabled vs baseline-no-call (≤ 2 ns Δ, 0 allocs), (iii) ascending levels 3–6 with no upper bound (these become the "cost per telemetry level" report).

**Tech Stack:** Zig 0.16.0, std.Io clock-based timing, `framework.zig` `TrackingAllocator` for zero-alloc probes, in-process `std.net.Server` loopback for level-6 OTLP/HTTP, Bash 5+ A/B runner script, repo-native `zig build` step graph.

**Reference inputs (load both before each phase):**

- `docs/performance/2026-04-26-zero-overhead-when-disabled/architecture.md` — prose architecture (605 lines)
- `docs/performance/2026-04-26-zero-overhead-when-disabled/plan.json` — machine-readable scenario catalog (838 lines, 30 scenarios)

---

## Phase 1: Add `-Dotel_disabled` build option + comptime elision in API + SDK providers

**Files:**

- Modify: `build.zig:10-43` — add `otel_disabled` option, thread into `build_options` module
- Modify: `src/api/trace.zig` — `Tracer.startSpan` early-returns `.noop` when `comptime build_options.otel_disabled`
- Modify: `src/api/metrics.zig` — `Counter.add`, `UpDownCounter.add`, `Histogram.record`, `Gauge.set`, `Observer.observeInt`, `Observer.observeDouble` early-return when disabled
- Modify: `src/api/logs.zig` — `Logger.emit` early-returns when disabled
- Modify: `src/sdk/trace.zig:210-217` — `TracerProvider.tracer()` returns API-layer noop tracer (no SDK vtable wiring) when disabled
- Modify: `src/sdk/metrics.zig` — `MeterProvider.meter()` similarly
- Modify: `src/sdk/logs.zig:109-116` — `LoggerProvider.logger()` similarly
- Test: `test/comptime_disabled.zig` — new file; verifies the disabled path returns noop handles and existing tests still pass

**Acceptance criteria:**

- `zig build test -Dotel_disabled=false` → all 22 existing test files pass (status quo)
- `zig build test -Dotel_disabled=true` → all existing tests pass; comptime branches collapse the SDK paths
- Existing tests that explicitly assert SDK-level behavior (e.g. "alwaysOff sampler returns a non-recording span" in `src/sdk/trace.zig:282-294`) must still pass when the option is OFF; when the option is ON, they may be skipped if they require live SDK behavior — but only via a `if (build_options.otel_disabled) return error.SkipZigTest;` guard at the test top, **not** by removing or weakening the assertion.
- `zig build check -Dotel_disabled=true` succeeds.
- No existing public API is renamed, removed, or has its signature changed.

**TDD ordering:**

- [ ] **Step 1.1** Write `test/comptime_disabled.zig` — failing test asserting that with `build_options.otel_disabled == true`, calling `tracer.startSpan()` returns `Span.noop`, calling `counter.add()` is a no-op (verify by running it 1000× under `std.testing.allocator` and asserting zero allocations), calling `logger.emit()` does nothing.
- [ ] **Step 1.2** Add the build option:

  ```zig
  const otel_disabled = b.option(bool, "otel_disabled",
      "Compile out the OTel SDK; providers and API methods become trivial noop stubs."
  ) orelse false;
  ```

  And in the `b.addOptions()` block:

  ```zig
  opts.addOption(bool, "otel_disabled", otel_disabled);
  ```

  Wire `build_options_module` into the new `test/comptime_disabled.zig` test (add to `test_files` list).

- [ ] **Step 1.3** Add comptime branch in `src/api/trace.zig` `Tracer.startSpan`:

  ```zig
  pub fn startSpan(self: Tracer, ctx: Context, name: []const u8, opts: SpanOptions) !Span {
      if (comptime build_options.otel_disabled) return Span.noop;
      return try self.startSpanFn(self.ctx, ctx, name, opts);
  }
  ```

- [ ] **Step 1.4** Add the same `if (comptime build_options.otel_disabled) return ...;` early-return guards to:
  - `src/api/metrics.zig` `Counter.add`, `UpDownCounter.add`, `Histogram.record`, `Gauge.set`, `Observer.observeInt`, `Observer.observeDouble`, `Meter.counter/upDownCounter/histogram/gauge` (the latter four return zero-vtable handles)
  - `src/api/logs.zig` `Logger.emit`
  - Each file must `const build_options = @import("build_options");` at top if not already present.
- [ ] **Step 1.5** In SDK provider `tracer()` / `meter()` / `logger()` methods, add the same comptime branch returning a default-constructed API-layer handle (zero vtable, calls collapse to noop):

  ```zig
  pub fn tracer(self: *TracerProvider, scope: trace_api.InstrumentationScope) trace_api.Tracer {
      if (comptime build_options.otel_disabled) return .{ .scope = scope };
      return .{ .ctx = self, .scope = scope, .startSpanFn = startSpan };
  }
  ```

  Same pattern for `MeterProvider.meter` and `LoggerProvider.logger`.

- [ ] **Step 1.6** Run `zig build check -Dotel_disabled=true` — must compile with zero errors.
- [ ] **Step 1.7** Run `zig build test -Dotel_disabled=false` — all 22 existing test files must pass.
- [ ] **Step 1.8** Run `zig build test -Dotel_disabled=true` — must pass. Tests that require live SDK behavior add `if (@import("build_options").otel_disabled) return error.SkipZigTest;` at the top.
- [ ] **Step 1.9** Verify `test/comptime_disabled.zig` passes under both flag values (using `std.testing.allocator` to assert zero allocations on the disabled path).
- [ ] **Step 1.10** Commit: `feat(api): add -Dotel_disabled comptime elision (zero-overhead-when-disabled phase 1)`.

---

## Phase 2: Bench framework universal-schema additions

**Files:**

- Modify: `benchmarks/framework.zig` — extend `ResultRow` with universal-schema envelope fields, expose `TrackingAllocator` allocations as `alloc_assertion` outcome, add `--ops N` CLI override
- Modify: `benchmarks/compare.zig` — accept the new envelope fields without breaking the existing baseline format
- Test: `benchmarks/framework_test.zig` (new) — schema round-trip + zero-alloc assertion behavior

**Acceptance criteria:**

- `ResultRow` JSON includes the universal envelope (`scenario_id`, `layer`, `language`, `variant`, `git_sha`, `command`, `timestamp`, `os`, `arch`, `runtime_version`, `warmups`, `rounds`, `metrics`, `samples`, `counters`) **alongside** the existing fields. Existing fields stay so `compare.zig` keeps working with old baselines.
- `Scenario` gains `layer: []const u8`, `variant: []const u8 = "A"`, `zero_alloc_expected: bool = false`, `alloc_threshold_bytes: u64 = 0`. When `zero_alloc_expected == true` and `alloc_count > 0`, the runner exits non-zero with a clear diagnostic — but only after writing the JSON so the failure is observable in CI artifacts.
- `--ops N` CLI override sets `ops_per_iteration` for all selected scenarios.

**TDD ordering:**

- [ ] **Step 2.1** Write `benchmarks/framework_test.zig` — assert that `ResultRow` JSON includes envelope fields, assert that a `Scenario` with `zero_alloc_expected: true` and a body that allocates fails the run.
- [ ] **Step 2.2** Extend `Scenario` with `layer`, `variant`, `zero_alloc_expected`, `alloc_threshold_bytes`.
- [ ] **Step 2.3** Extend `ResultRow` with the universal envelope. Keep existing fields so `compare.zig` continues to work; the new fields are additive.
- [ ] **Step 2.4** In `runScenarios`, after a scenario completes: if `zero_alloc_expected` and `alloc_count > 0` (and `alloc_count > alloc_threshold_bytes` when threshold is meaningful for bytes — for count we want exactly 0), record `counters.alloc_assertion = "fail"` and accumulate a `had_failure` flag; otherwise `"pass"`. Return non-zero from the runner if any assertion failed (after JSON write).
- [ ] **Step 2.5** Add `--ops N` CLI flag to `parseArgs` that overrides `ops_per_iteration` per selected scenario.
- [ ] **Step 2.6** Run `zig build test` — framework_test passes.
- [ ] **Step 2.7** Commit: `feat(bench): extend framework schema with universal envelope + zero-alloc assertions`.

---

## Phase 3: build.zig — replace bench stubs with real artifacts

**Files:**

- Modify: `build.zig:425-442` — replace stub `bench`, `bench-micro`, `scale-bench`, `compare-bench` with real `addRunArtifact` graph
- Add new steps: `bench-integration`, `bench-ab-default`, `bench-ab-disabled`, `bench-smoke`, `bench-ci`
- Create stubs for the artifact source files so the build graph compiles even before the scenarios are written:
  - Create empty stub: `benchmarks/micro/main.zig` (empty `main` that calls framework with zero scenarios)
  - Create empty stub: `benchmarks/integration/main.zig`
  - Create empty stub: `benchmarks/smoke.zig`
  - Create stub: `benchmarks/check_hard_criteria.zig` (reads ref-a.json + ref-b.json, exits 0 if missing files for now)

**Acceptance criteria:**

- `zig build bench-micro` — runs (zero scenarios, exits 0)
- `zig build bench-integration` — runs (zero scenarios, exits 0)
- `zig build bench-smoke` — runs (zero scenarios, exits 0)
- `zig build bench-compare -- --baseline /tmp/a.json --current /tmp/b.json --floor 3.0` — same behavior as the existing `compare.zig` after stub replacement
- `zig build bench-ab-default -Dotel_disabled=false -- --output /tmp/a.json` — runs the comparison-layer harness binary built with `otel_disabled=false`
- `zig build bench-ab-disabled -Dotel_disabled=true -- --output /tmp/b.json` — same harness binary, built with `otel_disabled=true`
- `zig build bench-ci` — depends on all four core suites + hard_criterion_check
- `scale-bench` becomes an alias for `bench-ci` (CI catalog compatibility per plan.json `V1_stub_replacement_note`)
- The existing `bench` step name is preserved as an alias for `bench-ci`

**TDD ordering:**

- [ ] **Step 3.1** Create the four stub source files. Each has a `main` that calls `framework.runScenarios` with an empty `[_]Scenario{}` array and returns successfully.
- [ ] **Step 3.2** In `build.zig`, after the existing test wiring, add a `framework_module` (`benchmarks/framework.zig` as a module) imported by every bench artifact. It needs `otel` as an import dep so the bench bodies can reach the API.
- [ ] **Step 3.3** Replace stubs (lines 432-442) with `addExecutable` + `addRunArtifact` for each artifact (`bench_micro_exe`, `bench_integration_exe`, `bench_ab_exe`, `bench_smoke_exe`, `compare_bench_exe`, `check_hard_criteria_exe`). Each executable depends on `otel_module`, `framework_module`, `build_options_module`. Forward `b.args` after `--`.
- [ ] **Step 3.4** Run `zig build bench-micro -- --list` — must print "Registered scenarios:" with no entries.
- [ ] **Step 3.5** Run `zig build bench-ab-disabled -- --list` — same.
- [ ] **Step 3.6** Run `zig build bench-ci` — must succeed; no scenario regressions because there are no scenarios yet.
- [ ] **Step 3.7** Commit: `feat(build): wire bench artifact graph (replace fmt-check stubs)`.

---

## Phase 4: Micro layer — 11 scenarios

**File:** `benchmarks/micro/main.zig`

**Scenarios (per plan.json):** `micro_attr_put_new`, `micro_attr_put_update`, `micro_attr_put_near_limit`, `micro_next_trace_id`, `micro_next_span_id`, `micro_clock_unix_nano`, `micro_redact_is_sensitive_miss`, `micro_redact_is_sensitive_hit`, `micro_json_write_attrs_4`, `micro_json_write_attrs_32`, `micro_noop_vtable_dispatch`.

**Acceptance criteria:**

- `zig build bench-micro -- --list` prints all 11.
- `zig build bench-micro -Doptimize=ReleaseFast` runs all 11 to completion under 60 s total on a typical Linux runner.
- Scenarios with `zero_alloc_expected: true` (per plan.json: `micro_next_trace_id`, `micro_next_span_id`, `micro_clock_unix_nano`, `micro_redact_*`, `micro_noop_vtable_dispatch`) pass the zero-alloc assertion.
- Each scenario's body has a `std.mem.doNotOptimizeAway` sink to prevent the compiler folding the work away.

**Implementation pattern per scenario:**

```zig
fn benchAttrPutNew(ctx: *framework.Context) anyerror!void {
    var set = otel.internal.attributes.AttributeSet.init(ctx.allocator);
    defer set.deinit();
    var i: u64 = 0;
    while (i < ctx.scenario.ops_per_iteration) : (i += 1) {
        // Synthesize a unique key per put so we exercise the new-key path.
        var key_buf: [16]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "k{d}", .{i}) catch unreachable;
        try set.put(key, .{ .int = @intCast(i) });
    }
    std.mem.doNotOptimizeAway(set.entries.items.len);
}
```

(Other scenarios follow the same shape — see plan.json for setup specifics, e.g., `micro_attr_put_update` puts the same key 10× to exercise the linear scan; `micro_attr_put_near_limit` fills to `attrs.max_attributes - 1` then puts.)

**TDD ordering:** one commit per ~3 scenarios, in the order listed in plan.json.

- [ ] **Step 4.1** Implement `micro_attr_put_new`, `micro_attr_put_update`, `micro_attr_put_near_limit`. Run `zig build bench-micro -- --filter micro_attr_put`. Commit.
- [ ] **Step 4.2** Implement `micro_next_trace_id`, `micro_next_span_id`, `micro_clock_unix_nano` with zero-alloc probes. Commit.
- [ ] **Step 4.3** Implement `micro_redact_is_sensitive_miss`, `micro_redact_is_sensitive_hit`, `micro_noop_vtable_dispatch` with zero-alloc probes. Commit.
- [ ] **Step 4.4** Implement `micro_json_write_attrs_4`, `micro_json_write_attrs_32`. Commit.
- [ ] **Step 4.5** Run full `zig build bench-micro -Doptimize=ReleaseFast --` end-to-end. Verify all zero-alloc probes pass. Commit smoke output as a comment in the run dir's `architecture.md` if needed.

---

## Phase 5: Integration layer — 6 scenarios + loopback discard server

**Files:**

- `benchmarks/integration/main.zig`
- `benchmarks/integration/loopback_server.zig` — in-process `std.net.Server` discard server (D-3 default)

**Scenarios:** `integ_level3_sync_1span`, `integ_level3_sync_100spans`, `integ_level3_sync_10kspans`, `integ_level4_sync_100spans`, `integ_level5_sync_100spans`, `integ_level6_otlp_loopback_100spans`.

**Acceptance criteria:**

- All 6 scenarios run to completion.
- The loopback server starts and stops cleanly per scenario; thread join times don't contaminate the measured loop (server is hoisted outside the timed region).
- Level-3 sync (in-memory exporter) shows non-zero allocations as expected.
- Level-6 OTLP loopback shows clear allocation overhead vs level-5.

**TDD ordering:**

- [ ] **Step 5.1** Implement `loopback_server.zig` with `start()` returning a struct exposing `addr: std.net.Address` and `stop()` that joins the thread. The server reads bytes and discards them. Test in isolation by sending a small payload and confirming the server consumed it.
- [ ] **Step 5.2** Implement levels 3–5 (in-memory exporter scenarios). Commit.
- [ ] **Step 5.3** Implement level-6 (OTLP/HTTP loopback). Commit.
- [ ] **Step 5.4** Run full `zig build bench-integration -Doptimize=ReleaseFast --`.

---

## Phase 6: Comparison layer — 13 scenarios

**File:** `benchmarks/compare_bench.zig` — the bench-AB harness binary (distinct from the existing `benchmarks/compare.zig` regression-comparison tool)

**Scenarios:** `baseline-no-call`, `noop-tracer-startend`, `runtime-disabled-alwaysOff`, `fully-enabled-alwaysOn-inmemory`, `comptime-disabled`, `runtime-disabled-noop`, `level-0-disabled`, `level-1-tracer-noop`, `level-2-tracer-alwaysoff`, `level-3-tracing-only`, `level-4-tracing-metrics`, `level-5-tracing-metrics-logs`, `level-6-full-otlp-http-loopback`.

**Note on overlap:** `level-1` ≈ `noop-tracer-startend`, `level-3` ≈ `fully-enabled-alwaysOn-inmemory`, `level-6` ≈ `integ_level6_otlp_loopback_100spans`. We register them as distinct scenario IDs so the comparison-layer A/B output is self-contained and the level-ladder report can pull all numbers from one JSON file.

**Acceptance criteria:**

- The same binary built with `-Dotel_disabled=true` and `-Dotel_disabled=false` produces all 13 scenarios. Scenarios that depend on `otel_disabled=true` (`comptime-disabled`, `level-0-disabled`) skip themselves under the wrong flag (`return error.SkipZigTest`); the others run in both modes.
- Built with `-Dotel_disabled=true`, the `comptime-disabled` scenario's `ns_per_op` is within ±2ns of `baseline-no-call`.
- Built with `-Dotel_disabled=false`, the `level-1-tracer-noop` scenario's `ns_per_op` is within ±5ns of `baseline-no-call`.
- The output JSON variant field reflects the build-time `otel_disabled` value: `"variant": "comptime_disabled"` or `"variant": "default"`.

**TDD ordering:** group commits by 3–4 scenarios.

- [ ] **Step 6.1** Implement `baseline-no-call`, `noop-tracer-startend`, `runtime-disabled-alwaysOff`, `fully-enabled-alwaysOn-inmemory`. Commit.
- [ ] **Step 6.2** Implement `comptime-disabled`, `runtime-disabled-noop`, `level-0-disabled`. Commit.
- [ ] **Step 6.3** Implement `level-1-tracer-noop`, `level-2-tracer-alwaysoff`, `level-3-tracing-only`. Commit.
- [ ] **Step 6.4** Implement `level-4-tracing-metrics`, `level-5-tracing-metrics-logs`, `level-6-full-otlp-http-loopback`. Commit.
- [ ] **Step 6.5** Run both `zig build bench-ab-default --` and `zig build bench-ab-disabled --`. Verify the hard criterion (`comptime-disabled` ≤ 2 ns Δ vs `baseline-no-call`) on this host. If it fails, dump the disassembly via `zig build bench-ab-disabled -- --filter comptime --no-track`, eyeball whether the optimizer collapsed the path, and adjust phase 1 if needed.

---

## Phase 7: A/B runner script + hard criterion check + bench-validator

**Files:**

- Create: `scripts/bench_ab_runner.sh` (Bash 5+, stdlib only)
- Implement: `benchmarks/check_hard_criteria.zig` — reads `ref-a.json` and `ref-b.json`, applies the comptime-disabled hard criterion + level-1 hard criterion. Exit non-zero on failure.
- Update: `.gitlab-ci.yml` — only if needed; the existing performance stage already references `bench-micro`, `scale-bench`, `compare-bench`. Confirm the stub replacement keeps the same names.

**Acceptance criteria:**

- `bash scripts/bench_ab_runner.sh --ref-a 4de1b11 --ref-b HEAD` runs end-to-end and writes `docs/performance/2026-04-26-zero-overhead-when-disabled/raw/round_NN_{A,B}.json`.
- The script aborts loudly if refs resolve to the same SHA, if either worktree is dirty, or if any round errors out.
- `zig build bench-ci` runs micro + integration + ab + compare + hard_criterion_check sequentially and prints the stable summary line:

  `BENCH 2026-04-26 4de1b11 micro=11pass integ=6pass compare=13pass/13total hard_criterion=PASS`

- `bench-validator` agent run reports zero violations.

**TDD ordering:**

- [ ] **Step 7.1** Implement `check_hard_criteria.zig`. Test with synthetic ref-a/ref-b JSON pairs.
- [ ] **Step 7.2** Implement `scripts/bench_ab_runner.sh`. Test with two synthetic worktree refs.
- [ ] **Step 7.3** Run the bench-validator agent. Address any violations.
- [ ] **Step 7.4** Final commit: `feat(bench): A/B runner + hard criterion gate (zero-overhead-when-disabled bench system complete)`.

---

## Self-review checklist

- All 30 scenarios from `plan.json` mapped to a phase: micro 11 (Phase 4), integration 6 (Phase 5), comparison 13 (Phase 6).
- All 4 architect decisions (D-1, D-2, D-3, D-4) honored as documented defaults.
- All 4 audit violations addressed: V-1 stub replacement (Phase 3), V-2 left as `F-2` follow-up (out of scope), V-3 evidence dir already created (Design phase), V-4 deferred to async-drain follow-up `F-3` (Phase 5 documents this).
- All hard rules from `references/hard-rules.md` honored: stdlib-only timing, no third-party bench libs, A/B disable control (the `-Dotel_disabled` flag itself is the control), no weakening of correctness suites (Phase 1 acceptance criterion: existing 22 tests must still pass in both modes).
