# otel Rollout — Integration Template & Exemplar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish the canonical, opt-in otel integration template (build flag, build.zig.zon entry, instrumentation seam, init helper, env wiring, no-op-when-disabled invariant, hermetic test pattern) and prove it end-to-end by integrating it into one exemplar repo (`http3`). Capture the recipe in a versioned integration guide so per-repo rollout plans can apply it mechanically.

**Architecture:** Each consumer repo gains a single boolean build option `with_otel` (default `false`). When `false`, the otel dependency is never resolved, no symbols are imported, and the binary/library is byte-identical to today (verified by a `nm`-grep guard). When `true`, an `observability.zig` module is compiled in that wraps the consumer's public entry points with `otel.api.trace`/`otel.api.metrics` calls, an `init()` helper bootstraps `TracerProvider`/`MeterProvider`/`LoggerProvider` from `OTEL_*` env vars (sampler `parentbased_traceidratio` @ 0.05, OTLP/HTTP exporter, service.name from build.zig.zon `name`, resource attrs from env). Telemetry failures NEVER propagate to caller code: every span emit is wrapped in a `catch {}` discard at the seam. The pattern mirrors http3's existing `interop = if (build_options.with_devnw_quic_adapter)` precedent.

**Tech Stack:** Zig 0.16.0, otel package (`gitlab.com/devnw/zig/otel`, pinned to a public commit SHA), the consumer repo's existing test harness (`zig build test`). No new runtime deps for consumers when `with_otel=false`.

**Scope note (read this first):** This plan integrates otel into ONE repo (`http3`) and produces the reusable recipe + verification tools. Rolling out to all other GitLab open-source siblings (`advanced-types`, `ai`, `audit`, `auth`, `capture`, `cli`, `concurrency`, `config`, `cuda`, `dns`, `dpi`, `ds`, `ebnf`, `encrypted-fs`, `entropy`, `fle`, `gql`, `graph-storage`, `grpc-zig`, `hnsw`, `hsm`, `i18n`, `json`, `ldap`, `mcp`, `metrics`, `oauth`, `oidc`, `oui`, `protobuf`, `quic`, `raft`, `repl`, `rtree`, `slog`, `spice`, `strings`, `thread-pool`, `timeseries`, `tls`, `toml`, `uri`, `uuid`, `vulkan`, `wal`, `wireguard`, `yaml`, `zcap`, `zig-template`, `zign`, `zlint`, `zp4`, `zvm`) requires per-tier sub-plans. The "Sub-Plans Required" section at the end lists them. Do not pile every repo into this plan — each tier is independent, testable software and deserves its own plan.

---

## File Structure

This plan creates / modifies files in three locations:

1. **`otel/scripts/` (this repo, the source of the template):**
   - Create `otel/scripts/list-public-siblings.sh` — discovery script that determines which sibling repos under `gitlab.com/devnw/zig/*` are public.
   - Create `otel/scripts/pull-public-siblings.sh` — pulls latest `main`/`master` for each public sibling before any rollout work begins.
   - Create `otel/scripts/verify-consumer-noop.sh` — invariant checker: rebuilds a target repo with `-Dwith_otel=false` and asserts no `otel`/`observability` symbol is linked into the resulting artifacts.

2. **`otel/docs/integration/` (this repo, the recipe other plans cite):**
   - Create `otel/docs/integration/README.md` — overview, decision log, glossary.
   - Create `otel/docs/integration/RECIPE.md` — exact step-by-step recipe (build flag, build.zig.zon stanza, conditional import wiring, init helper, env precedence, redaction, fail-closed-but-non-fatal contract).
   - Create `otel/docs/integration/CHECKLIST.md` — single-page verification checklist a per-repo plan author will copy.
   - Create `otel/docs/integration/templates/build.zig.fragment.zig` — paste-able zig snippet.
   - Create `otel/docs/integration/templates/build.zig.zon.fragment.zon` — paste-able dependency stanza with `<PIN_SHA>` / `<PIN_HASH>` placeholders.
   - Create `otel/docs/integration/templates/instrumentation.zig.template` — paste-able instrumentation seam skeleton with `// TODO[REPO]:` markers.
   - Create `otel/docs/integration/templates/otel_init.zig.template` — paste-able `init()` / `deinit()` helper.
   - Create `otel/docs/integration/templates/test_disabled_noop.zig.template` — paste-able comptime test asserting no otel symbols leak when the flag is off.
   - Create `otel/docs/integration/templates/test_enabled_smoke.zig.template` — paste-able test asserting one span is emitted when the flag is on.

3. **`http3/` (the exemplar consumer repo, modified after `git pull`):**
   - Modify `http3/build.zig` — add `with_otel` option, conditional dependency wiring, conditional module import, register the two new test artifacts.
   - Modify `http3/build.zig.zon` — gated `.otel` dependency entry with `lazy = true`.
   - Create `http3/src/h3/observability.zig` — single-file instrumentation seam exposing `Span`, `startClientSpan`, `endClientSpan`, `startServerSpan`, `endServerSpan`. When `with_otel=false`, every function returns a `void`-typed no-op the optimizer eliminates.
   - Create `http3/src/h3/observability_init.zig` — `Otel.init(allocator, io, default_service_name)` / `Otel.deinit()`, only compiled when `with_otel=true`.
   - Modify `http3/src/h3.zig` — surface `pub const observability = @import("h3/observability.zig")` and gated `observability_init`.
   - Modify `http3/src/h3/client.zig` — call `observability.startClientSpan` on request issue, `observability.endClientSpan` on response (or error).
   - Modify `http3/src/h3/server.zig` — call `observability.startServerSpan` on request accept, `observability.endServerSpan` on response flush (or abort).
   - Create `http3/tests/observability_disabled_test.zig` — golden no-op test (zero export on a recorder when flag off; comptime assertion that emit is unreachable).
   - Create `http3/tests/observability_enabled_test.zig` — span golden test (one client span + one server span recorded against an in-memory recorder).
   - Modify `http3/.gitignore` — exclude `.observability/` baseline-snapshot directory.
   - Modify `http3/README.md` — add a short "Observability" section pointing at `otel/docs/integration/RECIPE.md`.

Each file has one responsibility. The instrumentation seam (`observability.zig`) is the only place client/server code knows about otel; everything else is wiring.

---

## Phase 0 — Pre-flight tooling (in the otel repo)

### Task 0.1: Discovery script — list public sibling repos

**Files:**

- Create: `otel/scripts/list-public-siblings.sh`
- Create: `otel/scripts/test-list-public-siblings.sh`

**Why this task exists:** The user told us "all other repos in this directory that are open-sourced on GitLab". The local clone has GitLab remotes for every sibling, but visibility (public vs internal/private) is determined by the GitLab project setting, not by what is on disk. A repo with an `git@gitlab.com:devnw/...` remote may still be private. We must query the GitLab API (unauthenticated) to confirm public visibility before we touch each repo. An unauthenticated request to `https://gitlab.com/api/v4/projects/devnw%2Fzig%2F<repo>` returns HTTP 200 + a JSON body with `"visibility":"public"` for public projects, and HTTP 404 for private/internal ones.

- [ ] **Step 1: Write the failing test**

```bash
cat > otel/scripts/test-list-public-siblings.sh <<'EOF'
#!/usr/bin/env bash
# Smoke test: the script must print otel itself (known public) and exit 0.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$("$HERE/list-public-siblings.sh")"
echo "$out" | grep -qx "otel" || { echo "FAIL: 'otel' not in output"; exit 1; }
echo "PASS"
EOF
chmod +x otel/scripts/test-list-public-siblings.sh
```

- [ ] **Step 2: Run test to confirm it fails**

Run: `otel/scripts/test-list-public-siblings.sh`
Expected: FAIL — `list-public-siblings.sh: No such file or directory`.

- [ ] **Step 3: Write minimal implementation**

```bash
cat > otel/scripts/list-public-siblings.sh <<'EOF'
#!/usr/bin/env bash
# Print one repo name per line for every sibling under gitlab.com/devnw/zig/*
# whose GitLab visibility is "public". Reads candidate names from the parent
# directory of $PWD (or $1 if given) by listing dirs that contain a .git dir.
# Requires: curl, jq.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
[ -d "$ROOT" ] || { echo "ROOT not found: $ROOT" >&2; exit 1; }

for d in "$ROOT"/*/; do
    name="$(basename "$d")"
    [ -d "$d/.git" ] || continue
    encoded="devnw%2Fzig%2F$name"
    body="$(curl -s "https://gitlab.com/api/v4/projects/$encoded?simple=true" || echo "")"
    [ -n "$body" ] || continue
    vis="$(printf '%s' "$body" | jq -r '.visibility // empty' 2>/dev/null || echo "")"
    [ "$vis" = "public" ] && printf '%s\n' "$name"
done
EOF
chmod +x otel/scripts/list-public-siblings.sh
```

- [ ] **Step 4: Run test to confirm it passes**

Run: `otel/scripts/test-list-public-siblings.sh`
Expected: PASS.

If the test fails because `curl` or `jq` is unavailable, install them first (`apt-get install curl jq`) — these are explicit prerequisites called out at the top of the script. Do not paper over with a fallback that assumes-public; that would silently leak otel into private repos, which is a confidentiality risk.

- [ ] **Step 5: Commit**

```bash
git -C otel add scripts/list-public-siblings.sh scripts/test-list-public-siblings.sh
git -C otel commit -m "chore(scripts): add public-sibling discovery script"
```

---

### Task 0.2: Pull-latest script for the discovered set

**Files:**

- Create: `otel/scripts/pull-public-siblings.sh`
- Create: `otel/scripts/test-pull-public-siblings.sh`

**Why this task exists:** The user said "Each repo will need to be pulled prior to making changes to ensure the latest version is pulled." We need a single script the rollout engineer (and follow-on plans) calls before touching anything.

- [ ] **Step 1: Write the failing test**

```bash
cat > otel/scripts/test-pull-public-siblings.sh <<'EOF'
#!/usr/bin/env bash
# Dry-run smoke: --dry-run must list at least one fetch line and exit 0.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$("$HERE/pull-public-siblings.sh" --dry-run 2>&1)"
echo "$out" | grep -q "would fetch" || { echo "FAIL: no 'would fetch' line"; exit 1; }
echo "PASS"
EOF
chmod +x otel/scripts/test-pull-public-siblings.sh
```

- [ ] **Step 2: Run test to confirm it fails**

Run: `otel/scripts/test-pull-public-siblings.sh`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Write minimal implementation**

```bash
cat > otel/scripts/pull-public-siblings.sh <<'EOF'
#!/usr/bin/env bash
# For every public sibling reported by list-public-siblings.sh:
#   1. git fetch origin --prune
#   2. detect default branch (main|master)
#   3. if working tree clean: git checkout <default> && git pull --ff-only
#      else: warn and skip
# Exit non-zero if any clean repo failed to fast-forward.
set -euo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

mapfile -t repos < <("$HERE/list-public-siblings.sh")
fail=0
for r in "${repos[@]}"; do
    dir="$ROOT/$r"
    [ -d "$dir/.git" ] || { echo "skip $r (no .git)" >&2; continue; }
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "would fetch $r"
        continue
    fi
    echo "==> $r"
    git -C "$dir" fetch origin --prune
    default="$(git -C "$dir" symbolic-ref refs/remotes/origin/HEAD --short 2>/dev/null \
                 | sed 's@^origin/@@')"
    default="${default:-main}"
    if [ -n "$(git -C "$dir" status --porcelain)" ]; then
        echo "  dirty working tree; skipping pull" >&2
        fail=1
        continue
    fi
    git -C "$dir" checkout "$default"
    git -C "$dir" pull --ff-only origin "$default" || { fail=1; continue; }
done
exit $fail
EOF
chmod +x otel/scripts/pull-public-siblings.sh
```

- [ ] **Step 4: Run test to confirm it passes**

Run: `otel/scripts/test-pull-public-siblings.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C otel add scripts/pull-public-siblings.sh scripts/test-pull-public-siblings.sh
git -C otel commit -m "chore(scripts): add pull-public-siblings rollout script"
```

---

### Task 0.3: Pin a public otel commit SHA

**Files:**

- (this task records pin values to `/tmp/otel.pin.sha` and `/tmp/otel.pin.hash`; consumed in Task 0.4 step 2 and Task 1.3 step 3)

**Why this task exists:** Every consumer plan will paste a pinned `git+https://gitlab.com/devnw/zig/otel#<sha>` URL into its `build.zig.zon`. The SHA must reference a commit on the public `main` branch (so consumer fetches succeed without auth) and must include the integration scaffolding from Phase 0. Capturing the SHA now decouples consumer plans from the otel dev branch.

- [ ] **Step 1: Confirm `main` is up to date with this branch's tip**

Run:

```bash
cd /data/home/benji/src/devnw/zig/otel
current_branch="$(git rev-parse --abbrev-ref HEAD)"
if [ "$current_branch" != "main" ]; then
    git checkout main
    git merge --ff-only "$current_branch"
fi
git push origin main
git rev-parse origin/main > /tmp/otel.pin.sha
echo "Pinned otel commit: $(cat /tmp/otel.pin.sha)"
```

Expected: a single 40-char SHA written to `/tmp/otel.pin.sha`.

- [ ] **Step 2: Compute the Zig package hash for that commit**

Run:

```bash
sha="$(cat /tmp/otel.pin.sha)"
cd /tmp
rm -rf .zig-cache otel-fetch-probe
mkdir otel-fetch-probe && cd otel-fetch-probe
zig fetch --save=false "git+https://gitlab.com/devnw/zig/otel#$sha" \
  | tee /tmp/otel.pin.hash
```

Expected: prints `otel-0.1.0-<base32...>` to stdout and to `/tmp/otel.pin.hash`. If `zig fetch` prints a multi-line manifest, extract the `hash` field with `grep -oE 'otel-[0-9.]+-[A-Za-z0-9_-]+' /tmp/otel.pin.hash | head -1 > /tmp/otel.pin.hash.tmp && mv /tmp/otel.pin.hash.tmp /tmp/otel.pin.hash`.

- [ ] **Step 3: Verify the pin values are sane**

Run:

```bash
sha="$(cat /tmp/otel.pin.sha)"
hash="$(cat /tmp/otel.pin.hash)"
[ "${#sha}" -eq 40 ] || { echo "FAIL: SHA wrong length"; exit 1; }
echo "$hash" | grep -qE '^otel-[0-9.]+-[A-Za-z0-9_-]+$' || { echo "FAIL: hash format"; exit 1; }
echo "url = git+https://gitlab.com/devnw/zig/otel#$sha"
echo "hash = $hash"
```

Expected: both lines print without `FAIL`.

- [ ] **Step 4: No commit needed for this task** — the values are consumed by Task 0.4 step 2.

---

### Task 0.4: Recipe — `RECIPE.md` and paste-able templates

**Files:**

- Create: `otel/docs/integration/README.md`
- Create: `otel/docs/integration/RECIPE.md`
- Create: `otel/docs/integration/CHECKLIST.md`
- Create: `otel/docs/integration/templates/build.zig.zon.fragment.zon`
- Create: `otel/docs/integration/templates/build.zig.fragment.zig`
- Create: `otel/docs/integration/templates/instrumentation.zig.template`
- Create: `otel/docs/integration/templates/otel_init.zig.template`
- Create: `otel/docs/integration/templates/test_disabled_noop.zig.template`
- Create: `otel/docs/integration/templates/test_enabled_smoke.zig.template`

**Why this task exists:** The recipe and templates are the durable artifact this plan produces. Every per-repo follow-on plan cites them. They must be concrete (paste-able, with explicit `<PLACEHOLDERS>`) and testable (the http3 exemplar in Phase 1 is the integration test for the templates themselves).

- [ ] **Step 1: Create `RECIPE.md` with the canonical recipe**

````bash
mkdir -p otel/docs/integration/templates
cat > otel/docs/integration/RECIPE.md <<'EOF'
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
- Resource attribute `service.name` defaults to the consumer's
  `build.zig.zon` `.name` field. Consumers override via `OTEL_SERVICE_NAME`.
- Exporter default is `otlp` over `http/protobuf` to
  `http://localhost:4318`. Override via `OTEL_EXPORTER_OTLP_*`.
- Secret redaction is on by default (otel ships with the redaction list:
  `password`, `secret`, `token`, `api.key`, `authorization`, `credential`).
  Consumers do not duplicate the list — they only ensure attributes named
  in spec language pass through unmodified.
- Profiles signal stays disabled (`-Dotel_profiles=false`); upstream proto
  is unstable (otel issue #25).

## The 8-step recipe

1. **Pull latest** the consumer repo on its default branch.
2. **Add the build option** `with_otel: bool = false` to `build.zig`.
3. **Add the gated dependency** to `build.zig.zon` using the pinned URL +
   hash from `otel/docs/integration/templates/build.zig.zon.fragment.zon`.
4. **Wire the conditional import** in `build.zig` exactly as
   `templates/build.zig.fragment.zig` shows.
5. **Drop in `observability.zig`** at the public root of the consumer's
   library module, copied from `templates/instrumentation.zig.template` and
   adapted at every `// TODO[REPO]:` marker.
6. **Drop in `observability_init.zig`** copied from
   `templates/otel_init.zig.template`; only compiled when `with_otel=true`.
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
EOF
````

- [ ] **Step 2: Create `templates/build.zig.zon.fragment.zon` using the pin from Task 0.3**

```bash
sha="$(cat /tmp/otel.pin.sha)"
hash="$(cat /tmp/otel.pin.hash)"
cat > otel/docs/integration/templates/build.zig.zon.fragment.zon <<EOF
// Paste this entry into your build.zig.zon under .dependencies = .{ ... }.
// Zig only fetches dependencies that are reached by a b.dependency(...) /
// b.lazyDependency(...) call at build time, so gating the dependency in
// build.zig (behind -Dwith_otel) automatically gates the fetch as well.
.otel = .{
    .url = "git+https://gitlab.com/devnw/zig/otel#$sha",
    .hash = "$hash",
    .lazy = true,
},
EOF
```

(`.lazy = true` is the Zig 0.16 idiom — the source is fetched only when `b.lazyDependency` is invoked. This is what makes "default off" actually mean "no fetch".)

- [ ] **Step 3: Create `templates/build.zig.fragment.zig`**

```bash
cat > otel/docs/integration/templates/build.zig.fragment.zig <<'EOF'
// Paste/merge into your build.zig. Replace <root_module_var> with the
// existing variable name for the consumer's primary module
// (e.g. `lib_module`, `client_module`, `h3_module`). Keep the option
// default = false.

const with_otel = b.option(
    bool,
    "with_otel",
    "Compile in otel instrumentation (off by default; zero overhead when off)",
) orelse false;

const build_options = b.addOptions();
build_options.addOption(bool, "with_otel", with_otel);
<root_module_var>.addOptions("build_options", build_options);

if (with_otel) {
    const otel_dep = b.lazyDependency("otel", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;
    <root_module_var>.addImport("otel", otel_dep.module("otel"));
}
EOF
```

- [ ] **Step 4: Create `templates/instrumentation.zig.template`**

```bash
cat > otel/docs/integration/templates/instrumentation.zig.template <<'EOF'
//! observability.zig — single-file otel seam.
//!
//! When build_options.with_otel == false, every public function in this file
//! collapses to a comptime-known no-op so the optimizer eliminates the call
//! site entirely. When true, calls forward to the appropriate
//! `otel.api.trace`/`otel.api.metrics` helper.
//!
//! INVARIANT: every emit is `catch {}`-discarded. A failing exporter never
//! reaches the caller.
//!
//! TODO[REPO]: rename Span and the start/end signatures to match the
//! consumer's request/response types if the duck-typed anytype shape below
//! does not fit.

const std = @import("std");
const build_options = @import("build_options");

pub const enabled: bool = build_options.with_otel;

const otel = if (enabled) @import("otel") else struct {};

/// Opaque handle for an in-flight operation. When disabled, this is a
/// zero-sized struct the optimizer drops entirely.
pub const Span = if (enabled) otel.api.trace.Span else struct {
    pub fn end(self: @This()) void {
        _ = self;
    }
};

/// Start a span for an outbound operation. The caller passes anything with
/// `method_string()` and `url_string()` accessors.
pub fn startClientSpan(req: anytype) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    const span = otel.instrumentation.http.startClientSpan(
        tracer.*,
        .empty(),
        .{
            .method = req.method_string(),
            .url = req.url_string(),
        },
    ) catch return Span{};
    return span;
}

pub fn endClientSpan(span: Span, status: u16) void {
    if (!enabled) return;
    otel.instrumentation.http.endClientSpan(span, .{ .status_code = status });
}

/// Start a span for an inbound operation.
pub fn startServerSpan(req: anytype) Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    const span = otel.instrumentation.http.startServerSpan(
        tracer.*,
        .empty(),
        .{
            .method = req.method_string(),
            .route = req.route_string(),
        },
    ) catch return Span{};
    return span;
}

pub fn endServerSpan(span: Span, status: u16) void {
    if (!enabled) return;
    otel.instrumentation.http.endServerSpan(span, status);
}

/// Set once at process start by `observability_init.Otel.init`. Only
/// referenced when enabled is true; otherwise the optimizer drops it.
pub const global = if (enabled) struct {
    pub var tracer: ?*otel.api.trace.Tracer = null;
    pub var meter: ?*otel.api.metrics.Meter = null;
} else struct {};
EOF
```

- [ ] **Step 5: Create `templates/otel_init.zig.template`**

```bash
cat > otel/docs/integration/templates/otel_init.zig.template <<'EOF'
//! observability_init.zig — bootstrap helper. Only compiled when
//! build_options.with_otel == true.
//!
//! Read OTEL_* env vars via otel.sdk.config; build a TracerProvider,
//! MeterProvider, and LoggerProvider with sane production defaults; expose
//! Tracer/Meter handles to observability.zig's `global`. On any
//! init failure, log to std.log.err and leave globals as null — the seam's
//! `catch return Span{}` paths then yield no-op behaviour.

const std = @import("std");
const otel = @import("otel");
const observability = @import("observability.zig");

pub const Otel = struct {
    tracer_provider: otel.sdk.trace.TracerProvider,
    meter_provider: otel.sdk.metrics.MeterProvider,
    logger_provider: otel.sdk.logs.LoggerProvider,
    resource: otel.sdk.resource.Resource,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        service_name_default: []const u8,
    ) !@This() {
        var resource = try otel.sdk.resource.defaultResource(allocator);
        errdefer resource.deinit();

        // service.name precedence: OTEL_SERVICE_NAME env > caller default.
        const service_name = std.process.getEnvVarOwned(
            allocator,
            "OTEL_SERVICE_NAME",
        ) catch service_name_default;
        try resource.attributes.putString(otel.semconv.service_name, service_name);

        // OTLP/HTTP exporter; sampler defaults from env. otel.sdk.config
        // applies the OTEL_* precedence rules (code > YAML > env > default).
        const cfg = try otel.sdk.config.fromEnv(allocator);

        var tp = try otel.sdk.trace.TracerProvider.init(allocator, .{
            .resource = &resource,
            .sampler = cfg.tracer_sampler orelse
                otel.sdk.trace.samplers.parentBased(
                    otel.sdk.trace.samplers.traceIdRatioBased(0.05),
                ),
            .default_exporter = try cfg.tracer_exporter(allocator, io),
        });
        errdefer tp.deinit();

        var mp = try otel.sdk.metrics.MeterProvider.init(allocator, .{
            .resource = &resource,
            .reader = try cfg.metric_reader(allocator, io),
        });
        errdefer mp.deinit();

        var lp = try otel.sdk.logs.LoggerProvider.init(allocator, .{
            .resource = &resource,
            .processor = try cfg.log_processor(allocator, io),
        });
        errdefer lp.deinit();

        var self = @This(){
            .tracer_provider = tp,
            .meter_provider = mp,
            .logger_provider = lp,
            .resource = resource,
        };
        observability.global.tracer = &self.tracer_provider.tracer(.{ .name = service_name });
        observability.global.meter = &self.meter_provider.meter(.{ .name = service_name });
        return self;
    }

    pub fn deinit(self: *@This()) void {
        observability.global.tracer = null;
        observability.global.meter = null;
        self.tracer_provider.forceFlush(2_000) catch {};
        self.meter_provider.forceFlush(2_000) catch {};
        self.logger_provider.forceFlush(2_000) catch {};
        self.tracer_provider.deinit();
        self.meter_provider.deinit();
        self.logger_provider.deinit();
        self.resource.deinit();
    }
};
EOF
```

- [ ] **Step 6: Create the two test templates**

```bash
cat > otel/docs/integration/templates/test_disabled_noop.zig.template <<'EOF'
//! Verifies the no-op invariant when -Dwith_otel=false (the default).
//! TODO[REPO]: replace `<consumer>` with the consumer's module name.

const std = @import("std");
const consumer = @import("<consumer>");

test "build_options.with_otel exists and defaults to false" {
    const build_options = @import("build_options");
    try std.testing.expect(@hasDecl(build_options, "with_otel"));
    try std.testing.expectEqual(false, build_options.with_otel);
}

test "observability.enabled tracks build_options.with_otel" {
    const build_options = @import("build_options");
    try std.testing.expectEqual(build_options.with_otel, consumer.observability.enabled);
}

test "no-op when otel disabled" {
    if (consumer.observability.enabled) return error.SkipZigTest;
    var span = consumer.observability.startClientSpan(.{
        .method_string = struct {
            fn s() []const u8 { return "GET"; }
        }.s,
        .url_string = struct {
            fn s() []const u8 { return "https://x"; }
        }.s,
    });
    consumer.observability.endClientSpan(span, 200);
    span.end();
}
EOF

cat > otel/docs/integration/templates/test_enabled_smoke.zig.template <<'EOF'
//! Verifies one client span lands in an in-memory recorder when
//! -Dwith_otel=true. TODO[REPO]: replace <consumer> + the request shim.

const std = @import("std");
const otel = @import("otel");
const consumer = @import("<consumer>");

test "one span recorded when otel enabled" {
    if (!consumer.observability.enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(allocator);
    defer resource.deinit();
    try resource.attributes.putString(otel.semconv.service_name, "<consumer>-test");

    var recorder = otel.exporters.in_memory.Recorder.init(allocator);
    var tp = try otel.sdk.trace.TracerProvider.init(allocator, .{
        .resource = &resource,
        .default_exporter = recorder.spanExporter(),
    });
    defer tp.deinit();

    var tracer = tp.tracer(.{ .name = "<consumer>-test" });
    consumer.observability.global.tracer = &tracer;
    defer consumer.observability.global.tracer = null;

    var span = consumer.observability.startClientSpan(.{
        .method_string = struct {
            fn s() []const u8 { return "GET"; }
        }.s,
        .url_string = struct {
            fn s() []const u8 { return "https://x"; }
        }.s,
    });
    consumer.observability.endClientSpan(span, 200);

    try tp.forceFlush(1_000);
    try std.testing.expectEqual(@as(usize, 1), recorder.spans.items.len);
}
EOF
```

- [ ] **Step 7: Create `README.md` and `CHECKLIST.md` cover pages**

```bash
cat > otel/docs/integration/README.md <<'EOF'
# otel Integration Guide

Use `RECIPE.md` for the step-by-step procedure, `CHECKLIST.md` for a
single-page verification list, and `templates/` for paste-able fragments.
The exemplar implementation in `gitlab.com/devnw/zig/http3` (post-rollout)
is the working reference — diff against it when in doubt.
EOF

cat > otel/docs/integration/CHECKLIST.md <<'EOF'
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
EOF
```

- [ ] **Step 8: Commit**

```bash
git -C otel add docs/integration
git -C otel commit -m "docs(integration): add otel integration recipe + paste-able templates"
```

---

### Task 0.5: `verify-consumer-noop.sh` symbol-leak guard

**Files:**

- Create: `otel/scripts/verify-consumer-noop.sh`
- Create: `otel/scripts/test-verify-consumer-noop.sh`

**Why this task exists:** Recipe Invariant #1 declares "When `false`, the produced artifact contains no `otel` or `observability` linked symbols." Without an automated check, drift will sneak in (unused imports, stray build-options additions, accidental link of otel symbols). This script enforces it.

The check works by rebuilding the consumer with `-Dwith_otel=false -Doptimize=ReleaseSafe` from a clean cache, then running `nm -D --defined-only` over every artifact in `zig-out/` and grepping for `\botel\b|\bobservability\b`. Any hit fails the build.

- [ ] **Step 1: Write the failing test**

```bash
cat > otel/scripts/test-verify-consumer-noop.sh <<'EOF'
#!/usr/bin/env bash
# Smoke: must reject 'otel' as a target (otel itself contains otel symbols
# by definition, so the script must guard against being run against it).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if "$HERE/verify-consumer-noop.sh" otel >/dev/null 2>&1; then
    echo "FAIL: must reject 'otel' as a target"; exit 1
fi
echo "PASS"
EOF
chmod +x otel/scripts/test-verify-consumer-noop.sh
```

- [ ] **Step 2: Run test to confirm it fails**

Run: `otel/scripts/test-verify-consumer-noop.sh`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Write minimal implementation**

```bash
cat > otel/scripts/verify-consumer-noop.sh <<'EOF'
#!/usr/bin/env bash
# verify-consumer-noop.sh <consumer-repo-name>
# Build the consumer with -Dwith_otel=false and grep for otel/observability
# symbols in the resulting object/exe set. If any appear, fail loudly.
set -euo pipefail

repo="${1:?usage: verify-consumer-noop.sh <consumer-repo>}"
[ "$repo" != "otel" ] || { echo "ERROR: 'otel' is not a consumer target" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
dir="$ROOT/$repo"
[ -d "$dir" ] || { echo "no such repo dir: $dir" >&2; exit 2; }

(
    cd "$dir"
    rm -rf zig-out .zig-cache
    zig build -Dwith_otel=false -Doptimize=ReleaseSafe
)

# Walk every build artifact and assert no otel symbols are present.
hits=0
while IFS= read -r f; do
    [ -f "$f" ] || continue
    if nm -D --defined-only "$f" 2>/dev/null | grep -E '\botel\b|\bobservability\b' >&2; then
        echo "FAIL: otel symbols leaked into $f" >&2
        hits=$((hits+1))
    fi
done < <(find "$dir/zig-out" -type f \( -executable -o -name '*.a' -o -name '*.so' \))

[ "$hits" -eq 0 ] || exit 1
echo "PASS: no otel symbols in disabled build of $repo"
EOF
chmod +x otel/scripts/verify-consumer-noop.sh
```

- [ ] **Step 4: Run test to confirm it passes**

Run: `otel/scripts/test-verify-consumer-noop.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C otel add scripts/verify-consumer-noop.sh scripts/test-verify-consumer-noop.sh
git -C otel commit -m "chore(scripts): add verify-consumer-noop symbol-leak guard"
```

---

## Phase 1 — Apply the template to the `http3` exemplar

### Task 1.1: Pull http3 latest and branch

**Files:**

- (none — repo state operation)

- [ ] **Step 1: Confirm http3 is in the public-sibling list**

Run: `otel/scripts/list-public-siblings.sh | grep -x http3`
Expected: prints `http3`. If not, abort and revisit Phase 0 — the discovery script must report http3 before we proceed.

- [ ] **Step 2: Pull latest**

Run:

```bash
cd /data/home/benji/src/devnw/zig/http3
[ -z "$(git status --porcelain)" ] || { echo "dirty tree, aborting"; exit 1; }
git fetch origin --prune
default="$(git symbolic-ref refs/remotes/origin/HEAD --short | sed 's@^origin/@@')"
git checkout "$default"
git pull --ff-only
```

Expected: clean fast-forward; HEAD now matches `origin/$default`.

- [ ] **Step 3: Capture baseline build for the byte-identity reference**

Run:

```bash
cd /data/home/benji/src/devnw/zig/http3
zig build -Doptimize=ReleaseSafe
mkdir -p .observability
cp -r zig-out .observability/baseline-zig-out
```

Expected: `.observability/baseline-zig-out/` mirrors current `zig-out/` (kept untracked; added to `.gitignore` in Task 1.7).

- [ ] **Step 4: Branch for the integration**

Run: `git -C http3 checkout -b feat/otel-integration`
Expected: now on a fresh branch.

---

### Task 1.2: Add `with_otel` build option (TDD: comptime no-op invariant first)

**Files:**

- Modify: `http3/build.zig`
- Create: `http3/tests/observability_disabled_test.zig`

- [ ] **Step 1: Write the failing test**

```bash
cat > http3/tests/observability_disabled_test.zig <<'EOF'
const std = @import("std");

test "build_options.with_otel exists and defaults to false" {
    const build_options = @import("build_options");
    try std.testing.expect(@hasDecl(build_options, "with_otel"));
    try std.testing.expectEqual(false, build_options.with_otel);
}
EOF
```

- [ ] **Step 2: Register the test in `http3/build.zig`** (under the existing test step)

Open `http3/build.zig` and locate the existing `b.step("test", ...)` wiring (the variable holding the resulting step is conventionally `test_step`). Add the new artifact next to it:

```zig
const observability_disabled_test = b.addTest(.{
    .root_source_file = b.path("tests/observability_disabled_test.zig"),
    .target = target,
    .optimize = optimize,
});
observability_disabled_test.root_module.addOptions("build_options", build_options);
test_step.dependOn(&b.addRunArtifact(observability_disabled_test).step);
```

(If `build_options` does not yet exist in this file, this step will FAIL at build time — that is expected; Step 4 fixes it.)

- [ ] **Step 3: Run the test to confirm it fails**

Run: `cd http3 && zig build test`
Expected: FAIL with `error: file not found: build_options` or `unknown identifier 'build_options'`.

- [ ] **Step 4: Add the option and the build-options module**

Open `http3/build.zig`. Near the top of `pub fn build`, after `optimize` is defined, paste:

```zig
const with_otel = b.option(
    bool,
    "with_otel",
    "Compile in otel instrumentation (off by default; zero overhead when off)",
) orelse false;

const build_options = b.addOptions();
build_options.addOption(bool, "with_otel", with_otel);
```

Then, on the existing http3 module (the one passed to `b.addModule("h3", ...)` — locate the variable name; in the current build.zig it is named `h3_module`):

```zig
h3_module.addOptions("build_options", build_options);
```

- [ ] **Step 5: Run the test to confirm it passes**

Run: `cd http3 && zig build test`
Expected: PASS — including the new `observability_disabled_test`.

- [ ] **Step 6: Commit**

```bash
git -C http3 add build.zig tests/observability_disabled_test.zig
git -C http3 commit -m "feat(build): add -Dwith_otel option (default false)"
```

---

### Task 1.3: Add the gated otel dependency

**Files:**

- Modify: `http3/build.zig.zon`
- Modify: `http3/build.zig`
- Modify: `http3/tests/observability_disabled_test.zig`

- [ ] **Step 1: Append the failing test**

```bash
cat >> http3/tests/observability_disabled_test.zig <<'EOF'

test "no otel-prefixed decls leak from h3 root when disabled" {
    const h3 = @import("h3");
    inline for (@typeInfo(h3).@"struct".decls) |d| {
        try std.testing.expect(!std.mem.startsWith(u8, d.name, "otel_"));
    }
}
EOF
```

- [ ] **Step 2: Run to confirm it builds & passes (no otel symbols today, by definition)**

Run: `cd http3 && zig build test`
Expected: PASS — establishes the invariant before we add the dep.

- [ ] **Step 3: Add the lazy `.otel` entry to `build.zig.zon`**

Read the pinned values from Task 0.3 (`/tmp/otel.pin.sha`, `/tmp/otel.pin.hash`). Open `http3/build.zig.zon` and inside `.dependencies = .{ ... }` append (substituting the literal SHA + hash strings inline):

```zon
.otel = .{
    .url = "git+https://gitlab.com/devnw/zig/otel#<PIN_SHA>",
    .hash = "<PIN_HASH>",
    .lazy = true,
},
```

- [ ] **Step 4: Wire the conditional dependency in `build.zig`**

In `http3/build.zig`, after the `build_options` block from Task 1.2, paste:

```zig
if (with_otel) {
    const otel_dep = b.lazyDependency("otel", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;
    h3_module.addImport("otel", otel_dep.module("otel"));
}
```

- [ ] **Step 5: Run to confirm flag-off path still passes**

Run: `cd http3 && zig build test`
Expected: PASS — flag is off, no fetch, no new symbols.

- [ ] **Step 6: Run to confirm flag-on path resolves the dep**

Run: `cd http3 && zig build test -Dwith_otel=true`
Expected: PASS — otel resolves and tests still build (`observability.zig` does not exist yet, so the import is unused — fine for now).

- [ ] **Step 7: Commit**

```bash
git -C http3 add build.zig build.zig.zon tests/observability_disabled_test.zig
git -C http3 commit -m "feat(build): gate otel dependency behind -Dwith_otel"
```

---

### Task 1.4: Drop in `observability.zig` (the comptime-eliding seam)

**Files:**

- Create: `http3/src/h3/observability.zig`
- Modify: `http3/src/h3.zig`
- Modify: `http3/tests/observability_disabled_test.zig`

- [ ] **Step 1: Append the failing test**

```bash
cat >> http3/tests/observability_disabled_test.zig <<'EOF'

test "observability.enabled tracks build_options.with_otel" {
    const observability = @import("h3").observability;
    const build_options = @import("build_options");
    try std.testing.expectEqual(build_options.with_otel, observability.enabled);
}

test "observability.startClientSpan returns a no-op span when disabled" {
    const observability = @import("h3").observability;
    if (observability.enabled) return error.SkipZigTest;

    var span = observability.startClientSpan(.{
        .method_string = struct {
            fn s() []const u8 { return "GET"; }
        }.s,
        .url_string = struct {
            fn s() []const u8 { return "https://example.test/"; }
        }.s,
    });
    observability.endClientSpan(span, 200);
    span.end();
}
EOF
```

- [ ] **Step 2: Run to confirm the test fails**

Run: `cd http3 && zig build test`
Expected: FAIL — `observability` is not a decl on `h3`.

- [ ] **Step 3: Copy the template into the http3 source tree**

```bash
cp otel/docs/integration/templates/instrumentation.zig.template \
   http3/src/h3/observability.zig
```

The template's duck-typed `anytype` shape (looking for `method_string()` and `url_string()` / `route_string()` accessors) does not match http3's existing `Request` type. Add small adapter accessor methods on `client.Request` and `server.Request`:

In `http3/src/h3/client.zig`, find `pub const Request = struct { ... }` and append (inside the struct body):

```zig
pub fn method_string(self: @This()) []const u8 {
    return @tagName(self.method);
}
pub fn url_string(self: @This()) []const u8 {
    return self.path;
}
```

In `http3/src/h3/server.zig`, find `pub const Request = struct { ... }` and append:

```zig
pub fn method_string(self: @This()) []const u8 {
    return @tagName(self.method);
}
pub fn route_string(self: @This()) []const u8 {
    return self.path;
}
```

(Field names — `method`, `path` — must match the existing struct. If they differ, adjust the bodies but keep the function signatures, since `observability.zig` calls them by name.)

- [ ] **Step 4: Surface `observability` from `h3.zig`**

Open `http3/src/h3.zig` and append (after the existing public type aliases, e.g. after the `pub const Error = error_codes.Error;` line):

```zig
pub const observability = @import("h3/observability.zig");
```

- [ ] **Step 5: Run to confirm the test passes**

Run: `cd http3 && zig build test`
Expected: PASS — disabled-mode tests all green; flag is off so the no-op branch is hot.

- [ ] **Step 6: Commit**

```bash
git -C http3 add src/h3/observability.zig src/h3.zig src/h3/client.zig src/h3/server.zig tests/observability_disabled_test.zig
git -C http3 commit -m "feat(observability): add otel seam (no-op when disabled)"
```

---

### Task 1.5: Wire the seam into `client.zig` and `server.zig`

**Files:**

- Modify: `http3/src/h3/client.zig`
- Modify: `http3/src/h3/server.zig`

- [ ] **Step 1: Locate the request-issue and response-receipt sites**

Run: `grep -n "fn send\|fn recv\|fn request\|fn write_request\|fn read_response\|fn handle\|fn serve\|fn dispatch" http3/src/h3/client.zig http3/src/h3/server.zig`
Expected: at least one match per file. Note the line numbers — these are the call-site anchors.

- [ ] **Step 2: Wrap the client request lifecycle**

In `http3/src/h3/client.zig`, at the request-issue site (e.g. `pub fn request(self: *Client, req: Request) !Response`), insert at the function entry (after parameter destructuring):

```zig
const observability = @import("observability.zig");
var __obs_span = observability.startClientSpan(req);
defer __obs_span.end();
errdefer observability.endClientSpan(__obs_span, 0);
```

At the success path (immediately before `return response;`), insert:

```zig
observability.endClientSpan(__obs_span, response.status_code);
```

(The double-underscore prefix is intentional — it visually marks instrumentation-only scratch and avoids any chance of colliding with the existing local namespace.)

- [ ] **Step 3: Wrap the server request lifecycle**

In `http3/src/h3/server.zig`, in the request-handler dispatch site, mirror the pattern:

```zig
const observability = @import("observability.zig");
var __obs_span = observability.startServerSpan(req);
defer __obs_span.end();
errdefer observability.endServerSpan(__obs_span, 500);
// ... handler body remains unchanged ...
observability.endServerSpan(__obs_span, response.status_code);
```

- [ ] **Step 4: Run the disabled-mode tests**

Run: `cd http3 && zig build test`
Expected: PASS — every wrapper resolves to the no-op `Span{}`, so the existing test surface is unchanged.

- [ ] **Step 5: Verify the no-symbol-leak invariant via the helper**

Run: `otel/scripts/verify-consumer-noop.sh http3`
Expected: PASS — no `otel` or `observability` symbols leak into the disabled build artifacts.

- [ ] **Step 6: Commit**

```bash
git -C http3 add src/h3/client.zig src/h3/server.zig
git -C http3 commit -m "feat(observability): wire seam into client + server request paths"
```

---

### Task 1.6: Add `observability_init.zig` and the enabled-mode smoke test

**Files:**

- Create: `http3/src/h3/observability_init.zig`
- Create: `http3/tests/observability_enabled_test.zig`
- Modify: `http3/src/h3.zig`
- Modify: `http3/build.zig`

- [ ] **Step 1: Copy the init template**

```bash
cp otel/docs/integration/templates/otel_init.zig.template \
   http3/src/h3/observability_init.zig
```

The template is already correct for http3 — no `// TODO[REPO]:` edits needed beyond verifying the file compiles when otel is imported.

- [ ] **Step 2: Gate the init module so it only compiles when `with_otel=true`**

In `http3/src/h3.zig`, add (immediately after `pub const observability = @import("h3/observability.zig");`):

```zig
pub const observability_init = if (@import("build_options").with_otel)
    @import("h3/observability_init.zig")
else
    struct {};
```

- [ ] **Step 3: Write the failing enabled-mode smoke test**

```bash
cp otel/docs/integration/templates/test_enabled_smoke.zig.template \
   http3/tests/observability_enabled_test.zig
```

Replace each `<consumer>` placeholder with `h3` (so the test imports `h3.observability` / `h3.observability_init`). The test ends with an assertion that `recorder.spans.items.len == 1`.

- [ ] **Step 4: Register the smoke test in `build.zig`**

In `http3/build.zig`, add (next to the `observability_disabled_test` block from Task 1.2):

```zig
const observability_enabled_test = b.addTest(.{
    .root_source_file = b.path("tests/observability_enabled_test.zig"),
    .target = target,
    .optimize = optimize,
});
observability_enabled_test.root_module.addImport("h3", h3_module);
observability_enabled_test.root_module.addOptions("build_options", build_options);
if (with_otel) {
    const otel_dep_for_test = b.lazyDependency("otel", .{
        .target = target,
        .optimize = optimize,
    }) orelse return;
    observability_enabled_test.root_module.addImport("otel", otel_dep_for_test.module("otel"));
}
test_step.dependOn(&b.addRunArtifact(observability_enabled_test).step);
```

- [ ] **Step 5: Run flag-off — enabled test reports `SKIP`**

Run: `cd http3 && zig build test`
Expected: PASS; smoke test reports `error.SkipZigTest`.

- [ ] **Step 6: Run flag-on — smoke test must record exactly one span**

Run: `cd http3 && zig build test -Dwith_otel=true`
Expected: PASS — `recorder.spans.items.len == 1`.

- [ ] **Step 7: Commit**

```bash
git -C http3 add src/h3/observability_init.zig src/h3.zig tests/observability_enabled_test.zig build.zig
git -C http3 commit -m "feat(observability): add init helper + enabled-mode span smoke test"
```

---

### Task 1.7: README + .gitignore + final checklist sweep

**Files:**

- Modify: `http3/README.md`
- Modify: `http3/.gitignore`

- [ ] **Step 1: Add `.observability/` to `.gitignore`**

```bash
grep -qx '.observability/' http3/.gitignore || \
    echo '.observability/' >> http3/.gitignore
```

- [ ] **Step 2: Add an Observability section to `README.md`**

Append at the bottom of `http3/README.md` (above any existing License footer):

```markdown
## Observability

Build with `-Dwith_otel=true` to compile in OpenTelemetry instrumentation
(spans for client and server request lifecycles). The flag defaults to
`false`; when off, no `otel` symbol is linked, no dependency is fetched,
and the produced artifact contains no `otel`/`observability` symbols
(verified by `otel/scripts/verify-consumer-noop.sh`).

When enabled, configure exporters and sampler via the standard `OTEL_*`
environment variables. See
[`otel/docs/integration/RECIPE.md`](https://gitlab.com/devnw/zig/otel/-/blob/main/docs/integration/RECIPE.md)
for the full recipe.
```

- [ ] **Step 3: Walk the integration checklist**

Open `otel/docs/integration/CHECKLIST.md` and tick every box manually. Any unticked box → return to the matching task before commit.

- [ ] **Step 4: Run all three verification gates**

Run:

```bash
cd http3
zig build test
zig build test -Dwith_otel=true
otel/scripts/verify-consumer-noop.sh http3
```

Expected: all three PASS.

- [ ] **Step 5: Commit**

```bash
git -C http3 add README.md .gitignore
git -C http3 commit -m "docs(observability): document -Dwith_otel and link to recipe"
```

- [ ] **Step 6: Push the integration branch**

Run: `git -C http3 push -u origin feat/otel-integration`
Expected: branch lands on GitLab; open an MR with title "feat: opt-in otel instrumentation (off by default)" and link this plan in the description.

---

## Self-Review

### 1. Spec coverage

| Spec requirement | Covered by |
|------------------|-----------|
| "add ./otel support for all other repos in this directory" | Phase 0 + Phase 1 (template + http3 exemplar). Full coverage of *all* siblings is explicitly deferred to the per-tier sub-plans listed below — this plan produces the reusable artifact those sub-plans will consume. |
| "open-sourced on Gitlab" | Task 0.1 (`list-public-siblings.sh`) gates rollout on GitLab API visibility = `public`. |
| "build flags for otel should be off by default" | Task 1.2 (`with_otel ... orelse false`); recipe Invariant #1; `verify-consumer-noop.sh` enforces the no-link guarantee. |
| "support safe traces" | Recipe Invariant #2 (every emit `catch {}`); init helper leaves globals null on failure → seam falls back to no-op rather than propagating. |
| "enough instrumentation to provide valuable data" | Seam wraps full request lifecycle on both directions of every networked entry point (client + server in http3); smoke test verifies a span actually records. Recipe extends to RPC/DB/etc. via the per-repo `// TODO[REPO]:` markers in the instrumentation template. |
| "documented in ./otel" | All recipe + templates + scripts live under `otel/docs/integration/` and `otel/scripts/`. |
| "Each repo will need to be pulled prior to making changes" | Task 0.2 (`pull-public-siblings.sh`); Task 1.1 (per-repo pull as the first action of any rollout). |

### 2. Placeholder scan

- `<PIN_SHA>` and `<PIN_HASH>`: intentional placeholders, resolved in Task 0.3 and substituted inline at Task 1.3 step 3. The values cannot be hardcoded today because the integration commits land *during* Phase 0.
- `<consumer>`: appears in `templates/test_*.zig.template` only; resolved during the per-repo apply (Task 1.6 step 3 walks through the substitution for http3 → `h3`).
- `<root_module_var>`: appears in `templates/build.zig.fragment.zig` only; resolved during the per-repo apply (Task 1.2 step 4 substitutes it as `h3_module` for http3).
- No `TBD`, `TODO: implement later`, "similar to Task N", or "add appropriate error handling" lines.

### 3. Type / signature consistency

- `Span` is defined identically in `instrumentation.zig.template` and the http3 instance: `if (enabled) otel.api.trace.Span else struct { pub fn end(self) void {} }`. The `.end()` method exists on both branches.
- `startClientSpan` / `endClientSpan` / `startServerSpan` / `endServerSpan` signatures are identical across template, http3 source, and both tests.
- `observability.global.tracer` is `?*otel.api.trace.Tracer` — same type written by `observability_init.Otel.init` and read by every `start*Span`.
- The duck-typed accessors `method_string()`, `url_string()`, `route_string()` are introduced on `client.Request` / `server.Request` in Task 1.4 step 3 *before* they are read by the seam in Task 1.5 — order matches.

---

## Sub-Plans Required

This plan integrates otel into ONE repo (`http3`). To complete the full rollout described in the user's request, write and execute the following sub-plans in order. Each sub-plan should be a thin per-tier copy of Phase 1, parameterised by the repo set in its title — they are *not* part of this plan because each tier is independently testable software and a single mega-plan would be unreviewable.

The recipe in `otel/docs/integration/RECIPE.md` plus the templates and the `verify-consumer-noop.sh` guard are the contract every sub-plan must respect.

| Sub-plan | Repos | Why this tier |
|---------|-------|---------------|
| `2026-XX-XX-otel-rollout-tier1-rpc.md` | `grpc-zig`, `dns`, `mcp`, `quic`, `wireguard` | Networking + RPC layers; otel.instrumentation.http maps directly. Highest telemetry value per LoC. |
| `2026-XX-XX-otel-rollout-tier2-auth.md` | `auth`, `oauth`, `oidc`, `ldap`, `hsm`, `zcap`, `fle` | Authn/authz/secrets handling; `OTEL_*` redaction list must be cross-checked against in-repo redaction so secrets never leak via attribute. |
| `2026-XX-XX-otel-rollout-tier3-storage.md` | `wal`, `timeseries`, `hnsw`, `rtree`, `graph-storage`, `encrypted-fs`, `audit`, `raft` | Data path + consensus; instrumentation focuses on durable-write latency, replication RPCs, and operation counters. |
| `2026-XX-XX-otel-rollout-tier4-libs.md` | `advanced-types`, `concurrency`, `config`, `ds`, `ebnf`, `entropy`, `gql`, `i18n`, `json`, `oui`, `protobuf`, `repl`, `slog`, `spice`, `strings`, `thread-pool`, `tls`, `toml`, `uri`, `uuid`, `yaml`, `zig-template`, `zlint` | Utility libraries; minimal seams (only public-API entry points worth measuring). Many repos may end up with a build flag wired but no instrumentation calls — that is acceptable as long as the recipe checklist passes. |
| `2026-XX-XX-otel-rollout-tier5-apps.md` | `ai`, `capture`, `cli`, `cuda`, `dpi`, `metrics`, `vulkan`, `zign`, `zp4`, `zvm` | Binaries + capture/AI tooling. These repos add `observability_init` at `main()` so the binary itself bootstraps providers when the flag is on. |

After every sub-plan lands, run `otel/scripts/list-public-siblings.sh` and confirm every entry has both a `with_otel` build option and a passing `verify-consumer-noop.sh`. That is the definition of done for the user's original request.

---

## Execution Handoff

Plan complete and saved to `otel/docs/superpowers/plans/2026-04-28-otel-rollout-template.md`. Two execution options:

**1. Subagent-Driven (recommended)** — Dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batched checkpoints for review.

Which approach?
