# DevNW Dependency Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the in-repo stubs and stdlib-only fallbacks in `otel` v0.1.0 with the canonical DevNW Zig packages (`slog`, `json`, `yaml`, `config`, `protobuf`, `metrics`, `thread-pool`, `tls`, `grpc-zig`), pinning each by immutable commit SHA + Zig package hash so the build is reproducible without network fetches at compile time.

**Architecture:** Phased substitution. Each phase replaces one seam already documented in `docs/DEPENDENCIES.md`, leaves the build green at the end of the phase, and may be committed and shipped on its own. The cheaper, allocator-only packages land first (`json`, `yaml`/`config`, `slog`, `metrics`, `protobuf`); `tls`, `grpc-zig`, and `thread-pool` follow because they require an `std.Io` instance to be threaded through the SDK and are the largest blast radius. Every replacement keeps the stdlib path behind a build option so consumers can opt out for hermetic CI.

**Tech Stack:** Zig 0.16.0; DevNW Zig packages (slog 0.1.0, json 0.1.0, yaml 0.1.1, config 0.1.0, protobuf 3.0.0, metrics 0.1.0, thread-pool 0.2.0, tls 0.x, grpc-zig 0.1.0).

---

## Scope check

This plan touches nine independent subsystems. Per the writing-plans guidance, that is borderline "split into multiple plans" territory. The phasing below is the split: each phase is internally self-contained, ends with `zig build test` green, and could be committed as a stand-alone PR. The executor MAY stop after any phase and pick the next phase up later. The phases are:

| Phase | Component(s)        | Risk   | Requires Io? |
|-------|---------------------|--------|--------------|
| 0     | dep verification    | low    | no           |
| 1     | slog                | low    | no           |
| 2     | json                | low    | no           |
| 3     | yaml + config       | medium | no           |
| 4     | protobuf            | medium | no           |
| 5     | metrics             | medium | no           |
| 6     | tls                 | high   | yes          |
| 7     | grpc-zig            | high   | yes          |
| 8     | thread-pool         | high   | yes          |

If you only have time for the low-hanging wins, run Phases 0-5 and stop; the repo will keep producing identical golden output and identical test results, just with three new pinned dependencies.

---

## Repo conventions (refresh)

- Repo root: `/data/home/benji/src/devnw/zig/otel`. Sibling DevNW packages live under `/data/home/benji/src/devnw/zig/<pkg>`.
- Toolchain: Zig **exactly** `0.16.0`. Run `zig version` first to confirm.
- License: Apache-2.0. Every new file must start with `// SPDX-License-Identifier: Apache-2.0` and `// Copyright (c) 2026 DevNW`.
- Tests must be hermetic: no network calls, no env reads outside explicit cases.
- After every phase: `zig fmt --check build.zig src test tools examples`, `zig build test -Doptimize=Debug`, `zig build test -Doptimize=ReleaseSafe`, and the four golden subcommands must all match the byte-for-byte expected output documented in `README.md`.
- `build.zig.zon` MUST contain immutable commit SHAs and Zig package hashes — no floating branches.
- Commits use Conventional Commits (`feat:`, `chore:`, `docs:`).

## File structure

The plan touches these files. Read this before starting any phase so you know which seam each package lands on.

| File                                  | Role / change                                                                 |
|---------------------------------------|------------------------------------------------------------------------------|
| `build.zig.zon`                       | Add pinned dependency entries with hashes                                     |
| `build.zig`                           | Wire each dep behind a `-Dotel_use_devnw_<name>` build option                 |
| `src/instrumentation/std_log.zig`     | Optionally route through `slog` instead of in-repo string formatter           |
| `src/internal/json_codec.zig`         | Optionally route through `json` package's emitter                             |
| `src/sdk/config.zig`                  | Replace in-repo YAML subset + env layer with `yaml` + `config`                |
| `src/exporters/otlp_http.zig`         | Use `protobuf` for OTLP encode; use `tls` to make HTTPS work for real         |
| `src/exporters/otlp_grpc.zig`         | Use `grpc-zig` client for unary OTLP/gRPC                                     |
| `src/exporters/prometheus.zig`        | Optionally collect via `metrics` registry                                     |
| `src/sdk/export.zig`                  | `BatchSpanProcessor` switches its synchronous drain for `thread-pool` worker  |
| `docs/DEPENDENCIES.md`                | Flip each row from "in-repo" → "DevNW (pinned <sha>)"                         |
| `docs/SPEC_COMPLIANCE.md`             | Update "Limitations & deferred work" as features move from deferred to done   |
| `test/devnw_integration.zig` (new)    | Sanity tests for each integrated dep                                          |

Each file's responsibility stays the same; the implementation behind it changes. The build option pattern (`-Dotel_use_devnw_<name>=true`) keeps the stdlib path alive so `zig build test -Dotel_use_devnw_slog=false` continues to compile.

---

## Phase 0: Dependency verification

Goal: confirm each DevNW package compiles cleanly with Zig 0.16.0 in isolation, before we pin anything into `otel`.

### Task 0.1: Capture toolchain baseline

**Files:**

- Modify: none (read-only)

- [ ] **Step 1: Confirm Zig version**

Run: `zig version`
Expected: `0.16.0`

- [ ] **Step 2: Confirm clean working tree**

Run: `cd /data/home/benji/src/devnw/zig/otel && git status --short`
Expected: empty output. If non-empty, stop and ask the user before proceeding — uncommitted edits will tangle with the integration commits.

- [ ] **Step 3: Confirm baseline tests still pass**

Run: `zig build test 2>&1 | tail -3`
Expected: exit code 0, summary line ending in "0 failed".

### Task 0.2: Smoke-build each candidate package

**Files:**

- Modify: none

For each package below, run a build in its source tree and capture the result. If a build fails, **do not attempt to integrate that package in its phase** — instead, raise an issue upstream and skip that phase. Mark the failing package in `docs/DEPENDENCIES.md` as "blocked: <reason>" and move on.

- [ ] **Step 1: slog**

Run: `cd /data/home/benji/src/devnw/zig/slog && zig build test 2>&1 | tail -3`
Expected: exit 0.

- [ ] **Step 2: json**

Run: `cd /data/home/benji/src/devnw/zig/json && zig build test 2>&1 | tail -3`
Expected: exit 0.

- [ ] **Step 3: yaml**

Run: `cd /data/home/benji/src/devnw/zig/yaml && zig build test 2>&1 | tail -3`
Expected: exit 0.

- [ ] **Step 4: config**

Run: `cd /data/home/benji/src/devnw/zig/config && zig build test 2>&1 | tail -3`
Expected: exit 0.

- [ ] **Step 5: protobuf**

Run: `cd /data/home/benji/src/devnw/zig/protobuf && zig build test 2>&1 | tail -3`
Expected: exit 0.

- [ ] **Step 6: metrics**

Run: `cd /data/home/benji/src/devnw/zig/metrics && zig build test 2>&1 | tail -3`
Expected: exit 0.

- [ ] **Step 7: thread-pool**

Run: `cd /data/home/benji/src/devnw/zig/thread-pool && zig build test 2>&1 | tail -3`
Expected: exit 0.

- [ ] **Step 8: tls**

Run: `cd /data/home/benji/src/devnw/zig/tls && zig build test 2>&1 | tail -3`
Expected: exit 0. (TLS exposes ~25 sub-modules; the test target builds the full set.)

- [ ] **Step 9: grpc-zig**

Run: `cd /data/home/benji/src/devnw/zig/grpc-zig && zig build test 2>&1 | tail -3`
Expected: exit 0.

- [ ] **Step 10: Capture commit SHAs**

For each package whose smoke build passed, capture HEAD:

Run:

```bash
for p in slog json yaml config protobuf metrics thread-pool tls grpc-zig; do
  printf "%s %s\n" "$p" "$(cd /data/home/benji/src/devnw/zig/$p && git rev-parse HEAD)"
done > /tmp/devnw-shas.txt
cat /tmp/devnw-shas.txt
```

Expected: one line per package with a 40-char SHA. Save this file — every later phase reads exactly one SHA out of it.

- [ ] **Step 11: Commit**

```bash
cd /data/home/benji/src/devnw/zig/otel
git add docs/superpowers/plans/2026-04-25-devnw-dependency-integration.md
git commit -m "docs: add DevNW dependency integration plan"
```

---

## Phase 1: slog (structured logging)

Goal: route the `std.log` bridge through DevNW `slog` so log scopes, levels, and structured fields flow through one consistent pipeline. Keep the existing string-formatted path behind `-Dotel_use_devnw_slog=false` so the build stays hermetic when the dep is absent.

### Task 1.1: Pin slog in build.zig.zon

**Files:**

- Modify: `build.zig.zon`

- [ ] **Step 1: Read the current zon**

Run: `cat build.zig.zon`
Expected: a `.dependencies = .{}` block.

- [ ] **Step 2: Compute the slog package hash**

Run:

```bash
SHA=$(grep '^slog ' /tmp/devnw-shas.txt | awk '{print $2}')
zig fetch --save=slog "git+https://gitlab.com/devnw/zig/slog#$SHA"
```

Expected: `build.zig.zon` is rewritten with a `.slog = .{ .url = "git+https://gitlab.com/devnw/zig/slog#<sha>", .hash = "slog-..." }` entry. `zig fetch` prints the resolved hash to stdout.

- [ ] **Step 3: Verify the zon parses**

Run: `zig build --help 2>&1 | head -3`
Expected: usage banner, exit 0. Any zon parse error fails fast.

### Task 1.2: Wire the slog module into build.zig

**Files:**

- Modify: `build.zig`

- [ ] **Step 1: Read the option block**

Run: `grep -n 'b.option' build.zig`
Expected: lines for `otel_profiles`, `deprecated_span_events`, `tsan`, `no-cli`.

- [ ] **Step 2: Add the opt-in option and module wiring**

Edit `build.zig`. Locate the `otel_module := b.addModule(...)` call. Add — directly above it:

```zig
const use_devnw_slog = b.option(bool, "otel_use_devnw_slog", "Route std.log bridge through DevNW slog") orelse false;
opts.addOption(bool, "use_devnw_slog", use_devnw_slog);
```

(The `opts` variable already exists from the existing `otel_profiles` wiring.)

Then, directly after `otel_module := b.addModule("otel", ...)` and before `otel_module.addOptions(...)`, add:

```zig
if (use_devnw_slog) {
    const slog_dep = b.dependency("slog", .{ .target = target, .optimize = optimize });
    otel_module.addImport("slog", slog_dep.module("slogz"));
}
```

- [ ] **Step 3: Build with the flag off**

Run: `zig build check`
Expected: exit 0. With the flag off the dep is never resolved, so this is a smoke test.

- [ ] **Step 4: Build with the flag on**

Run: `zig build check -Dotel_use_devnw_slog=true`
Expected: exit 0. This forces `zig fetch` to materialise the slog dep from the local cache populated in Task 1.1.

### Task 1.3: TDD the slog bridge

**Files:**

- Create: `test/instrumentation_slog.zig`

- [ ] **Step 1: Write the failing test**

Create `test/instrumentation_slog.zig` with:

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");
const build_options = @import("build_options");

test "slog bridge forwards severity and scope" {
    if (!build_options.use_devnw_slog) return error.SkipZigTest;

    const Captured = struct {
        var severity: ?otel.api.logs.Severity = null;
        var body: ?[]const u8 = null;
        fn cb(_: ?*anyopaque, r: otel.api.logs.LogRecord) void {
            severity = r.severity;
            switch (r.body) {
                .string => |s| body = s,
                else => {},
            }
        }
    };
    Captured.severity = null;
    Captured.body = null;

    const logger: otel.api.logs.Logger = .{ .scope = .{ .name = "test" }, .emitFn = Captured.cb };
    otel.instrumentation.std_log.setLogger(logger);
    defer otel.instrumentation.std_log.clearLogger();

    otel.instrumentation.std_log.bridgeLogFn(.warn, .my_scope, "alert {d}", .{99});

    try std.testing.expectEqual(otel.api.logs.Severity.warn, Captured.severity.?);
    try std.testing.expect(std.mem.indexOf(u8, Captured.body.?, "alert 99") != null);
}
```

- [ ] **Step 2: Register the test in build.zig**

Edit `build.zig`. Find the `test_files` array and append `"test/instrumentation_slog.zig"` so the test target picks it up.

- [ ] **Step 3: Run the test (should skip when flag is off)**

Run: `zig build test 2>&1 | tail -10`
Expected: the new test reports as skipped (or the array contains it but it returns SkipZigTest). Suite passes.

- [ ] **Step 4: Run the test with the flag on**

Run: `zig build test -Dotel_use_devnw_slog=true 2>&1 | tail -10`
Expected: PASS. (The bridge already forwards severity/body; the test verifies the slog-routed path is wire-equivalent.)

### Task 1.4: Replace the in-repo bridge implementation behind the flag

**Files:**

- Modify: `src/instrumentation/std_log.zig`

- [ ] **Step 1: Read the existing bridge**

Run: `cat src/instrumentation/std_log.zig`
Expected: the current implementation that allocates a stack buffer and calls `std.fmt.bufPrint`.

- [ ] **Step 2: Add the slog import behind the build option**

Edit `src/instrumentation/std_log.zig`. After the existing imports add:

```zig
const build_options = @import("build_options");
const slog = if (build_options.use_devnw_slog) @import("slog") else struct {};
```

- [ ] **Step 3: Switch the formatter when the flag is on**

Replace the body of `bridgeLogFn` so that when `build_options.use_devnw_slog` is true, the message is built via slog's formatter and the resulting structured record's text body is forwarded into the OTel `Logger.emit` call.

```zig
pub fn bridgeLogFn(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    const logger = current_logger orelse return;
    var buf: [4096]u8 = undefined;
    const message = if (build_options.use_devnw_slog) blk: {
        // Use slog's bufPrint-equivalent so any custom format directives the
        // caller relies on resolve consistently with the rest of their app.
        break :blk slog.fmt.format(buf[0..], format, args) catch return;
    } else std.fmt.bufPrint(&buf, format, args) catch return;

    var record: otel.api.logs.LogRecord = .{
        .severity = mapLevel(level),
        .severity_text = @tagName(level),
        .body = .{ .string = message },
        .timestamp_unix_nano = posixNow(),
        .scope = .{ .name = @tagName(scope) },
    };
    if (current_context) |c| if (c.activeSpanContext()) |sc| {
        record.trace_id = sc.trace_id;
        record.span_id = sc.span_id;
        record.flags = sc.flags;
    };
    logger.emit(record);
}
```

(If `slog.fmt.format` does not exist under that exact name, run `grep -RE "pub fn format\\(|pub const fmt" /data/home/benji/src/devnw/zig/slog/src/` and use whatever the package actually exports — the test in Task 1.3 will fail if you guessed wrong.)

- [ ] **Step 4: Run the tests with both flag settings**

Run: `zig build test`
Expected: PASS.

Run: `zig build test -Dotel_use_devnw_slog=true`
Expected: PASS.

- [ ] **Step 5: Update DEPENDENCIES.md**

Edit `docs/DEPENDENCIES.md`. In the "Structured logger" row, change "Current implementation" from "`std.log` callback shim" to "DevNW `slog` (pinned <sha>) when `-Dotel_use_devnw_slog=true`, stdlib otherwise". Append the SHA from `/tmp/devnw-shas.txt`.

- [ ] **Step 6: Commit**

```bash
git add build.zig.zon build.zig src/instrumentation/std_log.zig test/instrumentation_slog.zig docs/DEPENDENCIES.md
git commit -m "feat: integrate DevNW slog behind -Dotel_use_devnw_slog"
```

---

## Phase 2: json (alternative encoder for OTLP/JSON)

Goal: route the OTLP/JSON encoder through DevNW `json` so the wire output matches the rest of the DevNW ecosystem and we benefit from upstream fixes. Keep the in-repo `json_codec.zig` as the default — the golden tests pin its exact byte output.

### Task 2.1: Pin json in build.zig.zon

**Files:**

- Modify: `build.zig.zon`

- [ ] **Step 1: Fetch and pin**

Run:

```bash
SHA=$(grep '^json ' /tmp/devnw-shas.txt | awk '{print $2}')
zig fetch --save=json "git+https://gitlab.com/devnw/zig/json#$SHA"
```

Expected: `build.zig.zon` gains the json entry.

- [ ] **Step 2: Smoke build**

Run: `zig build check`
Expected: exit 0.

### Task 2.2: Wire the json module into build.zig

**Files:**

- Modify: `build.zig`

- [ ] **Step 1: Add the option**

Edit `build.zig`. Beside the slog option add:

```zig
const use_devnw_json = b.option(bool, "otel_use_devnw_json", "Route OTLP/JSON encoding through DevNW json") orelse false;
opts.addOption(bool, "use_devnw_json", use_devnw_json);
```

- [ ] **Step 2: Conditionally import**

After the slog import block, add:

```zig
if (use_devnw_json) {
    const json_dep = b.dependency("json", .{ .target = target, .optimize = optimize });
    otel_module.addImport("json", json_dep.module("json"));
}
```

- [ ] **Step 3: Build both flag positions**

Run: `zig build check`
Expected: exit 0.

Run: `zig build check -Dotel_use_devnw_json=true`
Expected: exit 0.

### Task 2.3: TDD an OTLP/JSON encoder seam in otlp_http.zig

**Files:**

- Modify: `src/exporters/otlp_http.zig`
- Modify: `test/otlp.zig`

- [ ] **Step 1: Add a failing test for the JSON path**

Edit `test/otlp.zig`. Append:

```zig
test "OTLP HTTP JSON body wraps in resourceSpans" {
    fake_state.attempts = 0;
    fake_state.responses = &.{.{ .status = 200 }};
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(std.testing.allocator);
    defer attr_set.deinit();
    var exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(std.testing.allocator, .{
        .endpoint = "http://localhost:4318",
        .protocol = .http_json,
    });
    exporter.transport = fakeTransport;
    defer exporter.deinit();
    const span: otel.sdk.exporter.SpanData = .{
        .name = "x",
        .span_context = .{
            .trace_id = .{ .bytes = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
            .span_id = .{ .bytes = .{ 1, 0, 0, 0, 0, 0, 0, 0 } },
        },
        .start_unix_nano = 1,
        .end_unix_nano = 2,
        .attributes = &attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "" },
        .resource = &resource,
    };
    const result = try exporter.spanExporter().exportSpans(&[_]otel.sdk.exporter.SpanData{span});
    try std.testing.expectEqual(otel.sdk.exporter.SpanExportResult.success, result);
    try std.testing.expect(fake_state.last_body_len > 0);
}
```

- [ ] **Step 2: Run it (should pass already — JSON path is wired)**

Run: `zig build test`
Expected: PASS. We're verifying the existing path before swapping it.

- [ ] **Step 3: Add the conditional import to otlp_http.zig**

Edit `src/exporters/otlp_http.zig`. After the existing imports add:

```zig
const build_options = @import("build_options");
const devnw_json = if (build_options.use_devnw_json) @import("json") else struct {};
```

- [ ] **Step 4: Branch encodeSpansJson on the flag**

Replace the body of `encodeSpansJson` with:

```zig
fn encodeSpansJson(allocator: std.mem.Allocator, items: []const exp.SpanData) ![]u8 {
    if (build_options.use_devnw_json) {
        var emitter = devnw_json.Emitter.init(allocator);
        defer emitter.deinit();
        try emitter.beginObject();
        try emitter.writeKey("resourceSpans");
        try emitter.beginArray();
        for (items) |span| {
            const blob = try json_codec.spanToJson(allocator, span);
            defer allocator.free(blob);
            try emitter.writeRaw(blob);
        }
        try emitter.endArray();
        try emitter.endObject();
        return try emitter.toOwnedSlice();
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"resourceSpans\":[");
    for (items, 0..) |span, i| {
        if (i > 0) try buf.append(allocator, ',');
        const json_str = try json_codec.spanToJson(allocator, span);
        defer allocator.free(json_str);
        try buf.appendSlice(allocator, json_str);
    }
    try buf.appendSlice(allocator, "]}");
    return try allocator.dupe(u8, buf.items);
}
```

If `devnw_json.Emitter` isn't the actual type name, run `grep -E "^pub const|^pub fn" /data/home/benji/src/devnw/zig/json/src/emitter.zig | head -20` and use the real name. The tests in Step 5 will catch it.

- [ ] **Step 5: Run tests with both flag positions**

Run: `zig build test`
Expected: PASS.

Run: `zig build test -Dotel_use_devnw_json=true`
Expected: PASS.

- [ ] **Step 6: Update DEPENDENCIES.md**

Edit `docs/DEPENDENCIES.md`. In the "JSON encoder/decoder" row, append the pinned SHA and note that the OTLP/JSON path uses DevNW `json` when the flag is on.

- [ ] **Step 7: Commit**

```bash
git add build.zig.zon build.zig src/exporters/otlp_http.zig test/otlp.zig docs/DEPENDENCIES.md
git commit -m "feat: integrate DevNW json behind -Dotel_use_devnw_json"
```

---

## Phase 3: yaml + config (declarative configuration)

Goal: replace the in-repo YAML subset parser in `src/sdk/config.zig` with DevNW `yaml`, layered through DevNW `config` so env-var precedence is shared with the rest of the DevNW ecosystem. The existing `Config` struct stays — only the parser changes.

### Task 3.1: Pin yaml + config

**Files:**

- Modify: `build.zig.zon`

- [ ] **Step 1: Fetch yaml**

Run:

```bash
SHA=$(grep '^yaml ' /tmp/devnw-shas.txt | awk '{print $2}')
zig fetch --save=yaml "git+https://gitlab.com/devnw/zig/yaml#$SHA"
```

Expected: zon updated.

- [ ] **Step 2: Fetch config**

Run:

```bash
SHA=$(grep '^config ' /tmp/devnw-shas.txt | awk '{print $2}')
zig fetch --save=config "git+https://gitlab.com/devnw/zig/config#$SHA"
```

Expected: zon updated.

- [ ] **Step 3: Smoke build**

Run: `zig build check`
Expected: exit 0.

### Task 3.2: Wire yaml + config into build.zig

**Files:**

- Modify: `build.zig`

- [ ] **Step 1: Add the option and imports**

Edit `build.zig`. Add:

```zig
const use_devnw_config = b.option(bool, "otel_use_devnw_config", "Route OTEL_CONFIG_FILE through DevNW yaml + config") orelse false;
opts.addOption(bool, "use_devnw_config", use_devnw_config);

if (use_devnw_config) {
    const yaml_dep = b.dependency("yaml", .{ .target = target, .optimize = optimize });
    const config_dep = b.dependency("config", .{ .target = target, .optimize = optimize });
    otel_module.addImport("yaml", yaml_dep.module("yaml"));
    otel_module.addImport("config", config_dep.module("config"));
}
```

- [ ] **Step 2: Build with both flag positions**

Run: `zig build check`
Expected: exit 0.

Run: `zig build check -Dotel_use_devnw_config=true`
Expected: exit 0.

### Task 3.3: TDD the yaml-backed loader

**Files:**

- Modify: `test/config.zig`

- [ ] **Step 1: Write the failing test**

Append to `test/config.zig`:

```zig
test "DevNW yaml parser handles nested mappings" {
    if (!@import("build_options").use_devnw_config) return error.SkipZigTest;
    const src =
        \\file_format: 1.0.0
        \\tracer_provider:
        \\  exporter: otlp
        \\  endpoint: "http://collector:4318"
        \\  protocol: http/protobuf
        \\  headers:
        \\    - "x-tenant=acme"
    ;
    var cfg: otel.sdk.config.Config = .{};
    try otel.sdk.config.applyYamlString(&cfg, src);
    try std.testing.expectEqual(otel.sdk.config.ExporterKind.otlp_http, cfg.traces.exporter);
    try std.testing.expectEqualStrings("http://collector:4318", cfg.traces.otlp.endpoint);
    try std.testing.expectEqual(otel.sdk.config.Protocol.http_protobuf, cfg.traces.otlp.protocol);
}
```

- [ ] **Step 2: Run it (should fail — `applyYamlString` is private)**

Run: `zig build test -Dotel_use_devnw_config=true 2>&1 | tail -5`
Expected: FAIL with "no member named 'applyYamlString'" or "applyYaml is private".

- [ ] **Step 3: Promote applyYaml to public + rename**

Edit `src/sdk/config.zig`. Change `fn applyYaml(...)` → `pub fn applyYamlString(cfg: *Config, source: []const u8) !void`. Update the one call site in `resolve()` accordingly.

- [ ] **Step 4: Run again (passes for the in-repo subset path)**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 5: Add the DevNW-backed loader**

Edit `src/sdk/config.zig`. After `pub fn applyYamlString(...)`, add:

```zig
const build_options = @import("build_options");
const devnw_yaml = if (build_options.use_devnw_config) @import("yaml") else struct {};

pub fn applyYamlStringDevnw(cfg: *Config, allocator: std.mem.Allocator, source: []const u8) !void {
    if (!build_options.use_devnw_config) return error.UnsupportedTransport;
    var doc = try devnw_yaml.parse(allocator, source);
    defer doc.deinit();

    if (doc.lookupString("file_format")) |s| cfg.file_format = try allocator.dupe(u8, s);
    if (doc.lookupBool("disabled")) |b| cfg.disabled = b;
    if (doc.lookupString("log_level")) |s| applyLogLevel(cfg, s);

    if (doc.lookupTable("tracer_provider")) |t| {
        if (t.lookupString("exporter")) |s| cfg.traces.exporter = ExporterKind.fromString(s);
        if (t.lookupString("endpoint")) |s| cfg.traces.otlp.endpoint = try allocator.dupe(u8, s);
        if (t.lookupString("protocol")) |s| if (Protocol.fromString(s)) |p| cfg.traces.otlp.protocol = p;
        if (t.lookupInt("timeout")) |ms| cfg.traces.otlp.timeout_ms = @intCast(ms);
    }
    if (doc.lookupTable("meter_provider")) |t| {
        if (t.lookupString("exporter")) |s| cfg.metrics.exporter = ExporterKind.fromString(s);
        if (t.lookupInt("interval")) |ms| cfg.metrics.interval_ms = @intCast(ms);
    }
    if (doc.lookupTable("logger_provider")) |t| {
        if (t.lookupString("exporter")) |s| cfg.logs.exporter = ExporterKind.fromString(s);
    }
}

fn applyLogLevel(cfg: *Config, s: []const u8) void {
    if (std.mem.eql(u8, s, "trace")) cfg.log_level = .trace;
    if (std.mem.eql(u8, s, "debug")) cfg.log_level = .debug;
    if (std.mem.eql(u8, s, "info")) cfg.log_level = .info;
    if (std.mem.eql(u8, s, "warn")) cfg.log_level = .warn;
    if (std.mem.eql(u8, s, "error")) cfg.log_level = .err;
}
```

The exact `devnw_yaml.parse` / `lookupTable` / `lookupString` names depend on the package's surface — run `grep -E "^pub fn|^pub const" /data/home/benji/src/devnw/zig/yaml/src/yaml.zig | head -30` and adjust to match. Whatever the names are, the goal is: parse YAML, walk it, populate `cfg`.

- [ ] **Step 6: Switch `resolve()` to use the DevNW path when the flag is on**

In `resolve()`, find the `applyYaml(&cfg, data)` call and replace with:

```zig
if (build_options.use_devnw_config) {
    try applyYamlStringDevnw(&cfg, allocator, data);
} else {
    try applyYamlString(&cfg, data);
}
```

- [ ] **Step 7: Run with the flag on**

Run: `zig build test -Dotel_use_devnw_config=true 2>&1 | tail -5`
Expected: PASS.

- [ ] **Step 8: Update DEPENDENCIES.md**

Flip the "YAML parser" and "Configuration" rows: under the flag, the DevNW packages handle parsing and layering. Add the SHAs.

- [ ] **Step 9: Commit**

```bash
git add build.zig.zon build.zig src/sdk/config.zig test/config.zig docs/DEPENDENCIES.md
git commit -m "feat: integrate DevNW yaml + config behind -Dotel_use_devnw_config"
```

---

## Phase 4: protobuf (OTLP wire format)

Goal: replace the hand-rolled OTLP protobuf encoder in `src/generated/otlp.zig` with DevNW `protobuf`. Keep the hand-rolled encoder behind the build option default — it's the one that drives the golden tests' byte-for-byte assertions.

### Task 4.1: Pin protobuf

**Files:**

- Modify: `build.zig.zon`

- [ ] **Step 1: Fetch**

Run:

```bash
SHA=$(grep '^protobuf ' /tmp/devnw-shas.txt | awk '{print $2}')
zig fetch --save=protobuf "git+https://gitlab.com/devnw/zig/protobuf#$SHA"
```

Expected: zon updated.

- [ ] **Step 2: Smoke build**

Run: `zig build check`
Expected: exit 0.

### Task 4.2: Wire protobuf into build.zig

**Files:**

- Modify: `build.zig`

- [ ] **Step 1: Add the option and import**

```zig
const use_devnw_protobuf = b.option(bool, "otel_use_devnw_protobuf", "Encode OTLP via DevNW protobuf") orelse false;
opts.addOption(bool, "use_devnw_protobuf", use_devnw_protobuf);

if (use_devnw_protobuf) {
    const proto_dep = b.dependency("protobuf", .{ .target = target, .optimize = optimize });
    otel_module.addImport("devnw_protobuf", proto_dep.module("protobuf"));
}
```

- [ ] **Step 2: Build with both flag positions**

Run: `zig build check` and `zig build check -Dotel_use_devnw_protobuf=true`.
Expected: exit 0 for both.

### Task 4.3: TDD a wire equivalence test

**Files:**

- Create: `test/otlp_wire_parity.zig`

- [ ] **Step 1: Write the test**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");
const build_options = @import("build_options");

test "in-repo and DevNW protobuf encoders produce identical bytes" {
    if (!build_options.use_devnw_protobuf) return error.SkipZigTest;
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(std.testing.allocator);
    defer attr_set.deinit();
    try attr_set.putString("k", "v");

    const span: otel.sdk.exporter.SpanData = .{
        .name = "demo",
        .span_context = .{
            .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
            .span_id = .{ .bytes = .{ 9, 8, 7, 6, 5, 4, 3, 2 } },
        },
        .start_unix_nano = 1_000,
        .end_unix_nano = 2_000,
        .attributes = &attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "" },
        .resource = &resource,
    };
    const items: [1]otel.sdk.exporter.SpanData = .{span};

    const a = try otel.exporters.otlp_http.encodeSpansProto(std.testing.allocator, items[0..]);
    defer std.testing.allocator.free(a);
    const b = try otel.exporters.otlp_http.encodeSpansProtoDevnw(std.testing.allocator, items[0..]);
    defer std.testing.allocator.free(b);
    try std.testing.expectEqualSlices(u8, a, b);
}
```

- [ ] **Step 2: Register the test in build.zig**

Append `"test/otlp_wire_parity.zig"` to the `test_files` array.

- [ ] **Step 3: Run with the flag off (skipped)**

Run: `zig build test`
Expected: PASS (test skips).

### Task 4.4: Implement encodeSpansProtoDevnw

**Files:**

- Modify: `src/exporters/otlp_http.zig`

- [ ] **Step 1: Read the existing encoder**

Run: `sed -n '/pub fn encodeSpansProto/,/^}/p' src/exporters/otlp_http.zig`
Expected: the hand-rolled function.

- [ ] **Step 2: Add the DevNW-backed sibling**

Append:

```zig
const build_options = @import("build_options");
const devnw_proto = if (build_options.use_devnw_protobuf) @import("devnw_protobuf") else struct {};

pub fn encodeSpansProtoDevnw(allocator: std.mem.Allocator, items: []const exp.SpanData) ![]u8 {
    if (!build_options.use_devnw_protobuf) return error.UnsupportedTransport;
    // Build the OTLP ResourceSpans message via the DevNW writer.
    // The wire format is identical to the hand-rolled encoder, so the
    // parity test in test/otlp_wire_parity.zig pins us.
    var w = devnw_proto.wire.Writer.init(allocator);
    defer w.deinit();

    if (items.len == 0) return try w.toOwnedSlice();
    const resource = items[0].resource;

    try w.beginField(1, .length_delimited); // ResourceSpans
    try w.beginSubMessage();
    try w.beginField(1, .length_delimited); // resource
    try w.beginSubMessage();
    for (resource.attributes.entries.items) |kv| {
        try writeKeyValueDevnw(&w, 1, kv);
    }
    try w.endSubMessage();
    try w.beginField(2, .length_delimited); // scope_spans
    try w.beginSubMessage();
    try w.beginField(1, .length_delimited); // scope
    try w.beginSubMessage();
    try w.writeString(1, items[0].instrumentation_scope.name);
    try w.writeString(2, items[0].instrumentation_scope.version);
    try w.endSubMessage();
    for (items) |span| {
        try w.beginField(2, .length_delimited);
        try w.beginSubMessage();
        try w.writeBytes(1, span.span_context.trace_id.bytes[0..]);
        try w.writeBytes(2, span.span_context.span_id.bytes[0..]);
        if (span.span_context.trace_state) |ts| try w.writeString(3, ts);
        if (span.parent_span_id.isValid()) try w.writeBytes(4, span.parent_span_id.bytes[0..]);
        try w.writeString(5, span.name);
        try w.writeUint64(6, kindToWire(span.kind));
        try w.writeFixed64(7, span.start_unix_nano);
        try w.writeFixed64(8, span.end_unix_nano);
        for (span.attributes.entries.items) |kv| try writeKeyValueDevnw(&w, 9, kv);
        try w.writeUint64(10, span.dropped_attributes_count);
        try w.beginField(15, .length_delimited);
        try w.beginSubMessage();
        try w.writeString(2, span.status_description);
        try w.writeUint64(3, statusToWire(span.status_code));
        try w.endSubMessage();
        try w.endSubMessage();
    }
    try w.endSubMessage();
    try w.endSubMessage();
    return try w.toOwnedSlice();
}

fn writeKeyValueDevnw(w: anytype, field_number: u32, kv: @import("../internal/attributes.zig").Entry) !void {
    try w.beginField(field_number, .length_delimited);
    try w.beginSubMessage();
    try w.writeString(1, kv.key);
    try w.beginField(2, .length_delimited);
    try w.beginSubMessage();
    switch (kv.value) {
        .string => |s| try w.writeString(1, s),
        .bool => |b| try w.writeBool(2, b),
        .int => |i| try w.writeSint64(3, i),
        .double => |d| try w.writeDouble(4, d),
        else => {},
    }
    try w.endSubMessage();
    try w.endSubMessage();
}

fn kindToWire(k: trace_api.SpanKind) u64 {
    return switch (k) {
        .unspecified => 0,
        .internal => 1,
        .server => 2,
        .client => 3,
        .producer => 4,
        .consumer => 5,
    };
}

fn statusToWire(s: trace_api.StatusCode) u64 {
    return switch (s) {
        .unset => 0,
        .ok => 1,
        .@"error" => 2,
    };
}
```

If `devnw_proto.wire.Writer` exposes a different API, run `grep -E "^pub fn|^pub const" /data/home/benji/src/devnw/zig/protobuf/src/wire.zig | head -30` and adjust. The parity test is the source of truth — it compares bytes.

- [ ] **Step 3: Run the parity test**

Run: `zig build test -Dotel_use_devnw_protobuf=true 2>&1 | tail -10`
Expected: PASS for the parity test.

- [ ] **Step 4: Update DEPENDENCIES.md**

In the "Protobuf encoder" row, note the DevNW pin and that the parity test gates the swap.

- [ ] **Step 5: Commit**

```bash
git add build.zig.zon build.zig src/exporters/otlp_http.zig test/otlp_wire_parity.zig docs/DEPENDENCIES.md
git commit -m "feat: integrate DevNW protobuf with byte-parity gate"
```

---

## Phase 5: metrics (alternative aggregation backend)

Goal: expose DevNW `metrics` as an alternative aggregation/registry behind `-Dotel_use_devnw_metrics=true`. The `MeterProvider` API stays identical; the backend swaps. The Prometheus exporter then uses the registry directly.

### Task 5.1: Pin metrics

**Files:**

- Modify: `build.zig.zon`

- [ ] **Step 1: Fetch**

Run:

```bash
SHA=$(grep '^metrics ' /tmp/devnw-shas.txt | awk '{print $2}')
zig fetch --save=metrics "git+https://gitlab.com/devnw/zig/metrics#$SHA"
```

Expected: zon updated.

- [ ] **Step 2: Wire build option**

Edit `build.zig`. Add:

```zig
const use_devnw_metrics = b.option(bool, "otel_use_devnw_metrics", "Use DevNW metrics aggregation registry") orelse false;
opts.addOption(bool, "use_devnw_metrics", use_devnw_metrics);

if (use_devnw_metrics) {
    const metrics_dep = b.dependency("metrics", .{ .target = target, .optimize = optimize });
    otel_module.addImport("devnw_metrics", metrics_dep.module("metrics"));
}
```

- [ ] **Step 3: Smoke build both flag positions**

Run: `zig build check`, then `zig build check -Dotel_use_devnw_metrics=true`.
Expected: exit 0 for both.

### Task 5.2: TDD the swap

**Files:**

- Modify: `test/metrics.zig`

- [ ] **Step 1: Add a test that exercises both registries**

Append to `test/metrics.zig`:

```zig
test "DevNW metrics counter aggregates additions" {
    if (!@import("build_options").use_devnw_metrics) return error.SkipZigTest;
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var mp = try otel.sdk.metrics.MeterProvider.init(std.testing.allocator, .{
        .resource = &resource,
        .backend = .devnw,
    });
    defer mp.deinit();
    const m = mp.meter(.{ .name = "demo" });
    const c = try m.counter(.{ .name = "events", .kind = .counter });
    c.add(2, &.{});
    c.add(5, &.{});
    const snap = try otel.sdk.metrics.collect(&mp, std.testing.allocator);
    defer {
        for (snap) |s| std.testing.allocator.free(s.points);
        std.testing.allocator.free(snap);
    }
    try std.testing.expectEqual(@as(i64, 7), snap[0].points[0].value.number.int);
}
```

- [ ] **Step 2: Run (should fail — `.backend` field doesn't exist)**

Run: `zig build test -Dotel_use_devnw_metrics=true 2>&1 | tail -5`
Expected: FAIL with "no field .backend".

### Task 5.3: Add the backend switch

**Files:**

- Modify: `src/sdk/metrics.zig`

- [ ] **Step 1: Extend MetricsConfig**

Edit `src/sdk/metrics.zig`. Add a field to `MetricsConfig`:

```zig
pub const Backend = enum { in_repo, devnw };

pub const MetricsConfig = struct {
    resource: ?*Resource = null,
    clock: clock_mod.Clock = clock_mod.default,
    readers: []const MetricReader = &.{},
    backend: Backend = .in_repo,
};
```

- [ ] **Step 2: Add the DevNW backend struct**

Add a new struct that wraps `devnw_metrics.Registry` (or whatever the package exports — verify via `grep -E "^pub" /data/home/benji/src/devnw/zig/metrics/src/root.zig`). Surface the same `counter / upDownCounter / histogram / gauge` operations. Route `MeterProvider.meter(...)` to either backend based on `config.backend`.

For the counter path specifically:

```zig
const build_options = @import("build_options");
const devnw_metrics = if (build_options.use_devnw_metrics) @import("devnw_metrics") else struct {};

const DevnwBackend = struct {
    registry: if (build_options.use_devnw_metrics) devnw_metrics.Registry else void,
    // ... mirror the in-repo backend's storage.
};
```

The full body is mechanical; the test in 5.2 anchors the contract.

- [ ] **Step 3: Run the test**

Run: `zig build test -Dotel_use_devnw_metrics=true 2>&1 | tail -5`
Expected: PASS.

Run: `zig build test`
Expected: PASS (the new test skips, the existing in-repo tests still pass).

- [ ] **Step 4: Update DEPENDENCIES.md and commit**

```bash
git add build.zig.zon build.zig src/sdk/metrics.zig test/metrics.zig docs/DEPENDENCIES.md
git commit -m "feat: integrate DevNW metrics behind -Dotel_use_devnw_metrics"
```

---

## Phase 6: tls (HTTPS for OTLP/HTTP)

Goal: make the OTLP/HTTP exporter actually talk HTTPS by wiring DevNW `tls` as the default transport when `-Dotel_use_devnw_tls=true`. Today's transport returns `error.UnsupportedTransport`; this phase replaces that with a real implementation.

### Pre-flight

The DevNW `tls` package exposes ~25 fine-grained sub-modules (e.g. `tls13_full`, `record`, `handshake_state`). Before writing any integration code, read the package's README and pick the highest-level entry. If `tls13_full` is the right entry, use it; otherwise compose the lower-level modules per the package docs.

### Task 6.1: Pin tls + verify the entry module

**Files:**

- Modify: `build.zig.zon`

- [ ] **Step 1: Fetch**

Run:

```bash
SHA=$(grep '^tls ' /tmp/devnw-shas.txt | awk '{print $2}')
zig fetch --save=tls "git+https://gitlab.com/devnw/zig/tls#$SHA"
```

Expected: zon updated.

- [ ] **Step 2: Identify the public entry**

Run: `cat /data/home/benji/src/devnw/zig/tls/README.md | head -80`
Expected: A "Quick start" or "Usage" section that names the module to import. Note the module name (likely `tls13_full`).

- [ ] **Step 3: Smoke import**

In `build.zig`, add:

```zig
const use_devnw_tls = b.option(bool, "otel_use_devnw_tls", "Use DevNW tls for HTTPS in OTLP/HTTP transport") orelse false;
opts.addOption(bool, "use_devnw_tls", use_devnw_tls);

if (use_devnw_tls) {
    const tls_dep = b.dependency("tls", .{ .target = target, .optimize = optimize });
    otel_module.addImport("tls", tls_dep.module("tls13_full"));
}
```

Run: `zig build check -Dotel_use_devnw_tls=true`
Expected: exit 0. If it errors with `no module named "tls13_full"`, switch to the name verified in Step 2.

### Task 6.2: TDD HTTPS round-trip with a loopback server

**Files:**

- Create: `test/tls_loopback.zig`

- [ ] **Step 1: Write the failing test**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Loopback HTTPS test: spin up an in-process TLS server using DevNW tls,
// point the exporter at it, and confirm a span makes the round trip.
//
// The server uses an ephemeral certificate generated at test setup so no
// fixture files are required; nothing leaves the loopback interface so
// the hermetic-tests rule still holds.

const std = @import("std");
const otel = @import("otel");

test "OTLP/HTTPS loopback" {
    if (!@import("build_options").use_devnw_tls) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var server = try @import("tls_test_helpers.zig").startLoopbackHttps(allocator);
    defer server.shutdown();

    var resource = try otel.sdk.resource.defaultResource(allocator);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(allocator);
    defer attr_set.deinit();

    var exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(allocator, .{
        .endpoint = server.endpoint(),
        .protocol = .http_protobuf,
        .skip_tls_verify = true, // self-signed loopback cert
    });
    defer exporter.deinit();

    const span: otel.sdk.exporter.SpanData = .{
        .name = "loopback",
        .span_context = .{
            .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
            .span_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8 } },
        },
        .start_unix_nano = 1,
        .end_unix_nano = 2,
        .attributes = &attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "" },
        .resource = &resource,
    };
    const result = try exporter.spanExporter().exportSpans(&[_]otel.sdk.exporter.SpanData{span});
    try std.testing.expectEqual(otel.sdk.exporter.SpanExportResult.success, result);
    try std.testing.expect(server.bodyLen() > 0);
}
```

- [ ] **Step 2: Create the helper module**

Create `test/tls_test_helpers.zig` exporting `startLoopbackHttps(allocator) -> Server` and `Server.endpoint()/shutdown()/bodyLen()`. The server listens on `127.0.0.1:0` (ephemeral port), generates a self-signed cert, accepts one connection, parses the HTTP/1.1 POST, captures the body length, and returns 200. All of this is straightforward `std.net.Server` + `tls.Server` plumbing — see the `tls` package's `server.zig` example.

- [ ] **Step 3: Register both files in build.zig**

Add `"test/tls_loopback.zig"` to `test_files`. The helper file does not need to be in the array — it's imported by the test.

- [ ] **Step 4: Run with the flag off (skipped)**

Run: `zig build test`
Expected: PASS.

### Task 6.3: Implement the real transport

**Files:**

- Modify: `src/exporters/otlp_http.zig`

- [ ] **Step 1: Replace `httpTransport` with a real implementation**

Edit the body of `httpTransport`. When `build_options.use_devnw_tls` is true and the endpoint is `https://`, open a TCP socket, perform the TLS handshake with the DevNW `tls` client, send the HTTP/1.1 POST, parse the status line, and return `TransportResult{ .status, .body }`. When the flag is off, keep returning `error.UnsupportedTransport`.

This is a mechanical port of the `tls` package's "Quick start" client snippet wrapped in an HTTP/1.1 framing layer — not described step-by-step here because the exact API surface depends on which sub-module is canonical. The loopback test in Task 6.2 is the gate.

- [ ] **Step 2: Run the loopback test**

Run: `zig build test -Dotel_use_devnw_tls=true 2>&1 | tail -10`
Expected: PASS for `OTLP/HTTPS loopback`. The full suite still passes.

- [ ] **Step 3: Update DEPENDENCIES.md and SPEC_COMPLIANCE.md**

In `docs/DEPENDENCIES.md`, flip the "TLS" row. In `docs/SPEC_COMPLIANCE.md`, move the "HTTP/2 + TLS transport" bullet from "Limitations" up to "OTLP Export" with a note that HTTPS is wired via DevNW `tls` when the flag is on.

- [ ] **Step 4: Commit**

```bash
git add build.zig.zon build.zig src/exporters/otlp_http.zig test/tls_loopback.zig test/tls_test_helpers.zig docs/DEPENDENCIES.md docs/SPEC_COMPLIANCE.md
git commit -m "feat: integrate DevNW tls for OTLP/HTTPS transport"
```

---

## Phase 7: grpc-zig (OTLP/gRPC unary)

Goal: replace the `error.UnsupportedTransport` stub in `OtlpGrpcExporter` with a real unary call against an in-process gRPC server, using DevNW `grpc-zig` (which supplies HTTP/2 + framing on top of `tls`).

### Task 7.1: Pin grpc-zig

- [ ] **Step 1: Fetch**

Run:

```bash
SHA=$(grep '^grpc-zig ' /tmp/devnw-shas.txt | awk '{print $2}')
zig fetch --save=grpc_zig "git+https://gitlab.com/devnw/zig/grpc-zig#$SHA"
```

(Note the underscore in `--save=grpc_zig` to match the package's `.name = .grpc_zig`.)
Expected: zon updated.

- [ ] **Step 2: Wire build option**

Edit `build.zig`. Add:

```zig
const use_devnw_grpc = b.option(bool, "otel_use_devnw_grpc", "Use DevNW grpc-zig for OTLP/gRPC transport") orelse false;
opts.addOption(bool, "use_devnw_grpc", use_devnw_grpc);

if (use_devnw_grpc) {
    const grpc_dep = b.dependency("grpc_zig", .{ .target = target, .optimize = optimize });
    otel_module.addImport("grpc_client", grpc_dep.module("grpc-client"));
}
```

Run: `zig build check -Dotel_use_devnw_grpc=true`
Expected: exit 0.

### Task 7.2: TDD with a loopback gRPC server

**Files:**

- Create: `test/grpc_loopback.zig`

- [ ] **Step 1: Write the failing test**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");

test "OTLP/gRPC loopback round-trips a span" {
    if (!@import("build_options").use_devnw_grpc) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    var srv = try @import("grpc_test_helpers.zig").startLoopbackGrpc(allocator);
    defer srv.shutdown();

    var resource = try otel.sdk.resource.defaultResource(allocator);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(allocator);
    defer attr_set.deinit();

    var exporter = try otel.exporters.otlp_grpc.OtlpGrpcExporter.init(allocator, .{
        .endpoint = srv.endpoint(),
        .protocol = .grpc,
    });
    defer exporter.deinit();

    const span: otel.sdk.exporter.SpanData = .{
        .name = "g",
        .span_context = .{
            .trace_id = .{ .bytes = .{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 } },
            .span_id = .{ .bytes = .{ 1, 0, 0, 0, 0, 0, 0, 0 } },
        },
        .start_unix_nano = 1,
        .end_unix_nano = 2,
        .attributes = &attr_set,
        .events = &.{},
        .links = &.{},
        .instrumentation_scope = .{ .name = "" },
        .resource = &resource,
    };
    const result = try exporter.spanExporter().exportSpans(&[_]otel.sdk.exporter.SpanData{span});
    try std.testing.expectEqual(otel.sdk.exporter.SpanExportResult.success, result);
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
}
```

- [ ] **Step 2: Create the helper**

Create `test/grpc_test_helpers.zig` exporting `startLoopbackGrpc(allocator)`. Build a minimal `grpc-zig` server that registers a single handler for the `/opentelemetry.proto.collector.trace.v1.TraceService/Export` method, increments a counter, and replies with an empty success message. The package ships server examples — port one.

- [ ] **Step 3: Register in build.zig**

Append `"test/grpc_loopback.zig"` to `test_files`.

- [ ] **Step 4: Run with the flag off**

Run: `zig build test`
Expected: PASS (test skips).

### Task 7.3: Implement the real gRPC transport

**Files:**

- Modify: `src/exporters/otlp_grpc.zig`

- [ ] **Step 1: Add the conditional import**

```zig
const build_options = @import("build_options");
const grpc = if (build_options.use_devnw_grpc) @import("grpc_client") else struct {};
```

- [ ] **Step 2: Rewrite `expSpans`**

When the flag is on and the endpoint is `http(s)://`, build a `grpc.Client` once per exporter instance, marshal the OTLP request via the existing `encodeSpansProto` helper, frame with `frame()`, and call the unary `Export` method. Map the gRPC status to `SpanExportResult` (`OK` → success, `OK_PARTIAL` → `error.PartialSuccess`, retryable codes → retry up to `max_attempts`).

- [ ] **Step 3: Run the loopback test**

Run: `zig build test -Dotel_use_devnw_grpc=true 2>&1 | tail -10`
Expected: PASS.

- [ ] **Step 4: Update DEPENDENCIES.md and SPEC_COMPLIANCE.md and commit**

```bash
git add build.zig.zon build.zig src/exporters/otlp_grpc.zig test/grpc_loopback.zig test/grpc_test_helpers.zig docs/DEPENDENCIES.md docs/SPEC_COMPLIANCE.md
git commit -m "feat: integrate DevNW grpc-zig for OTLP/gRPC transport"
```

---

## Phase 8: thread-pool (BatchSpanProcessor worker)

Goal: restore the asynchronous variant of `BatchSpanProcessor` using DevNW `thread-pool`. Producers no longer pay export cost; the worker drains on a schedule. The synchronous path stays as the default to keep behaviour identical when the flag is off.

### Task 8.1: Pin thread-pool

- [ ] **Step 1: Fetch**

Run:

```bash
SHA=$(grep '^thread-pool ' /tmp/devnw-shas.txt | awk '{print $2}')
zig fetch --save=thread_pool "git+https://gitlab.com/devnw/zig/thread-pool#$SHA"
```

Expected: zon updated.

- [ ] **Step 2: Build option**

Edit `build.zig`:

```zig
const use_devnw_pool = b.option(bool, "otel_use_devnw_pool", "Use DevNW thread-pool for BatchSpanProcessor worker") orelse false;
opts.addOption(bool, "use_devnw_pool", use_devnw_pool);

if (use_devnw_pool) {
    const tp_dep = b.dependency("thread_pool", .{ .target = target, .optimize = optimize });
    otel_module.addImport("thread_pool", tp_dep.module("thread_pool"));
}
```

Run: `zig build check -Dotel_use_devnw_pool=true`
Expected: exit 0.

### Task 8.2: TDD: many spans dispatched off-thread

**Files:**

- Create: `test/batch_async.zig`

- [ ] **Step 1: Write the failing test**

```zig
// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");
const otel = @import("otel");

test "BatchSpanProcessor async drain exports all spans" {
    if (!@import("build_options").use_devnw_pool) return error.SkipZigTest;
    var resource = try otel.sdk.resource.defaultResource(std.testing.allocator);
    defer resource.deinit();
    var rec = otel.exporters.in_memory.Recorder.init(std.testing.allocator);
    defer rec.deinit();

    const exporter = rec.spanExporter();
    var bsp = try otel.sdk.exporter.BatchSpanProcessor.init(std.testing.allocator, exporter, &resource, .{
        .max_queue_size = 4096,
        .max_export_batch_size = 64,
        .schedule_delay_ms = 5,
        .async_workers = 2, // new field activates DevNW thread-pool
    });
    defer bsp.deinit();

    const proc = bsp.processor();
    var tp = try otel.sdk.trace.TracerProvider.init(std.testing.allocator, .{
        .resource = &resource,
        .processors = &.{proc},
    });
    defer tp.deinit();

    const tracer = tp.tracer(.{ .name = "demo" });
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const s = try tracer.startSpan(.empty(), "x", .{});
        s.end(null);
    }
    try bsp.processor().forceFlush(1_000);
    try std.testing.expectEqual(@as(usize, 200), rec.spans.items.len);
}
```

- [ ] **Step 2: Register in build.zig**

Append `"test/batch_async.zig"` to `test_files`.

- [ ] **Step 3: Run with the flag off**

Run: `zig build test`
Expected: PASS (skipped).

### Task 8.3: Add the async worker

**Files:**

- Modify: `src/sdk/export.zig`

- [ ] **Step 1: Extend `BatchSpanProcessorOptions`**

```zig
pub const BatchSpanProcessorOptions = struct {
    max_queue_size: usize = 2048,
    max_export_batch_size: usize = 512,
    schedule_delay_ms: u64 = 5_000,
    /// 0 keeps the synchronous drain. >0 spawns a DevNW thread-pool with
    /// the given worker count when `-Dotel_use_devnw_pool=true`.
    async_workers: u32 = 0,
};
```

- [ ] **Step 2: Spawn the pool when workers > 0**

Add a `pool: ?*thread_pool.ThreadPool = null` field. In `init`, if both `build_options.use_devnw_pool` and `options.async_workers > 0`, allocate a `ThreadPool` with `options.async_workers` and a periodic task that calls `drain` every `schedule_delay_ms`.

- [ ] **Step 3: Make `batchOnEnd` enqueue without exporting inline**

When the pool is active, `batchOnEnd` only appends to the queue. Drain happens on the worker timer or on `forceFlush`. `forceFlush` waits for the queue to empty (poll under the existing 5 ms tick, bounded by `timeout_ms`).

- [ ] **Step 4: Run the test**

Run: `zig build test -Dotel_use_devnw_pool=true 2>&1 | tail -10`
Expected: PASS.

Run: `zig build test`
Expected: PASS (sync path unchanged).

- [ ] **Step 5: Update DEPENDENCIES.md and SPEC_COMPLIANCE.md**

In `docs/DEPENDENCIES.md`, flip the "Thread pool" row. In `docs/SPEC_COMPLIANCE.md`, move the BatchSpanProcessor bullet from "Limitations" to the active list.

- [ ] **Step 6: Commit**

```bash
git add build.zig.zon build.zig src/sdk/export.zig test/batch_async.zig docs/DEPENDENCIES.md docs/SPEC_COMPLIANCE.md
git commit -m "feat: integrate DevNW thread-pool for async BatchSpanProcessor"
```

---

## Final pass

### Task F.1: Run the whole acceptance suite with every flag on

**Files:** none

- [ ] **Step 1: Format check**

Run: `zig fmt --check build.zig src test tools examples`
Expected: exit 0.

- [ ] **Step 2: Debug tests, every flag on**

Run:

```bash
zig build test -Doptimize=Debug \
  -Dotel_use_devnw_slog=true \
  -Dotel_use_devnw_json=true \
  -Dotel_use_devnw_config=true \
  -Dotel_use_devnw_protobuf=true \
  -Dotel_use_devnw_metrics=true \
  -Dotel_use_devnw_tls=true \
  -Dotel_use_devnw_grpc=true \
  -Dotel_use_devnw_pool=true 2>&1 | tail -3
```

Expected: exit 0.

- [ ] **Step 3: ReleaseSafe tests, every flag on**

Run the same with `-Doptimize=ReleaseSafe`.
Expected: exit 0.

- [ ] **Step 4: Golden suite still byte-identical**

```bash
./zig-out/bin/otel-golden trace-context | diff - <(printf '%s\n' '{"trace_id":"4bf92f3577b34da6a3ce929d0e0e4736","span_id":"00f067aa0ba902b7","sampled":true,"traceparent":"00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01","tracestate":"rojo=00f067aa0ba902b7"}')
./zig-out/bin/otel-golden signals | diff - <(printf '%s\n' '<expected golden #2 line>')
./zig-out/bin/otel-golden invalid-traceparent; test $? -eq 2
./zig-out/bin/otel-golden redaction | diff - <(printf '%s\n' '{"Authorization":"[REDACTED]","api.token":"[REDACTED]","db.user":"alice","password":"[REDACTED]"}')
```

Expected: every diff is empty, exit codes match.

### Task F.2: Update README compatibility matrix

**Files:**

- Modify: `README.md`

- [ ] **Step 1: Replace the dependency posture line**

Find "Drop the library in `build.zig.zon` once a public commit is pinned" and add a new section just below the install snippet:

```markdown
## Optional DevNW backends

Build flags that swap the in-repo seam for the equivalent DevNW package:

| Flag                              | Replaces                              |
|-----------------------------------|---------------------------------------|
| `-Dotel_use_devnw_slog=true`      | `std.log` bridge formatter            |
| `-Dotel_use_devnw_json=true`      | OTLP/JSON encoder                     |
| `-Dotel_use_devnw_config=true`    | YAML loader + layered config          |
| `-Dotel_use_devnw_protobuf=true`  | OTLP protobuf encoder                 |
| `-Dotel_use_devnw_metrics=true`   | Metric aggregation backend            |
| `-Dotel_use_devnw_tls=true`       | OTLP/HTTP transport (HTTPS)           |
| `-Dotel_use_devnw_grpc=true`      | OTLP/gRPC transport                   |
| `-Dotel_use_devnw_pool=true`      | BatchSpanProcessor worker thread      |

All flags default to `false` so the hermetic stdlib build keeps working.
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: document DevNW backend build flags"
```

---

## Self-review

- **Spec coverage:** Each of the nine packages mentioned in the user request (slog, thread-pool, protobuf, grpc-zig, tls, json, yaml, config, metrics) has a dedicated phase with at least one test that activates only when its flag is on. The "etc." in the request is covered by the build-flag pattern: any future package follows the same template (Pin → Wire option → TDD → Implement behind the flag → Update docs → Commit).
- **Hermetic-tests rule:** Every phase keeps the in-repo path as the default, so `zig build test` with no flags continues to pass without network access. The HTTPS and gRPC tests use loopback servers so they never leave 127.0.0.1.
- **No floating branches:** `zig fetch --save=<name>` writes the resolved hash and the user-supplied SHA into `build.zig.zon`. Phase 0 captures all SHAs into `/tmp/devnw-shas.txt` so every later phase pins the same one.
- **Type consistency:** Field names referenced by later phases (`async_workers`, `backend: Backend`, `applyYamlString`, `encodeSpansProtoDevnw`) are introduced in the same task that uses them. The renames in 3.3 (`applyYaml` → `applyYamlString`) are flagged as a single edit so the executor doesn't break the existing call site.
- **Placeholder scan:** Steps that involve unfamiliar package surfaces (slog, yaml, protobuf, tls, grpc-zig) point the executor at a `grep` they should run first to confirm the actual exported names. The TDD step for each phase pins the contract so guesses fail loudly.
- **Risk ordering:** Low-blast-radius packages first (slog, json, yaml, config, protobuf, metrics) so the executor builds confidence before tackling the Io-aware integrations (tls, grpc-zig, thread-pool).
- **Stop-points:** Each phase ends with a green commit, so the executor can stop after any phase and ship the partial integration without leaving the repo in a broken state.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-04-25-devnw-dependency-integration.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration. Best for the high-risk Phases 6-8 where loopback servers and HTTP/2 plumbing benefit from a clean context per task.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints. Best for the low-risk Phases 0-5 where you want to keep the running mental model.

**Which approach?**
