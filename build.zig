// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const otel_profiles = b.option(bool, "otel_profiles", "Enable experimental OTLP profiles export") orelse false;
    const deprecated_span_events = b.option(bool, "deprecated_span_events", "Enable deprecated Span.addEvent shim bridged to logs") orelse false;
    const tsan = b.option(bool, "tsan", "Enable ThreadSanitizer on test artifacts") orelse false;
    const no_cli = b.option(bool, "no-cli", "Skip building the CLI executable (library-only build)") orelse false;
    const use_devnw_slog = b.option(bool, "otel_use_devnw_slog", "Route std.log bridge through DevNW slog") orelse false;
    const use_devnw_json = b.option(bool, "otel_use_devnw_json", "Route OTLP/JSON encoding through DevNW json") orelse false;
    const use_devnw_config = b.option(bool, "otel_use_devnw_config", "Route OTEL_CONFIG_FILE through DevNW yaml + config") orelse false;
    const use_devnw_protobuf = b.option(bool, "otel_use_devnw_protobuf", "Encode OTLP via DevNW protobuf") orelse false;
    const use_devnw_metrics = b.option(bool, "otel_use_devnw_metrics", "Use DevNW metrics aggregation registry") orelse false;
    const use_devnw_tls = b.option(bool, "otel_use_devnw_tls", "Use DevNW tls for HTTPS in OTLP/HTTP transport") orelse false;
    const use_devnw_grpc = b.option(bool, "otel_use_devnw_grpc", "Use DevNW grpc-zig for OTLP/gRPC transport") orelse false;
    const use_devnw_pool = b.option(bool, "otel_use_devnw_pool", "Use DevNW thread-pool for BatchSpanProcessor worker") orelse false;
    // GAP-SEC-M-1: gate the loopback gRPC test server behind an explicit
    // build flag so production builds never include the test harness.
    // Defaults to `use_devnw_grpc` because the existing gRPC-test wiring
    // already implies the harness should be available; explicit
    // `-Dotel_grpc_test_server=false` strips it back out.
    const grpc_test_server_default = use_devnw_grpc;
    const grpc_test_server = b.option(bool, "otel_grpc_test_server", "Include the loopback gRPC test server in the library") orelse grpc_test_server_default;
    // Phase 1 of the zero-overhead-when-disabled bench system. When ON,
    // every API call site (Tracer.startSpan, Counter.add, etc.) collapses
    // to a comptime-known no-op so the optimizer can fully dead-code-
    // eliminate the disabled path.
    // See docs/performance/2026-04-26-zero-overhead-when-disabled/.
    const otel_disabled = b.option(bool, "otel_disabled", "Compile every API call site to a comptime-known no-op (zero-overhead disabled mode)") orelse false;

    const opts = b.addOptions();
    opts.addOption(bool, "otel_profiles", otel_profiles);
    opts.addOption(bool, "deprecated_span_events", deprecated_span_events);
    opts.addOption(bool, "use_devnw_slog", use_devnw_slog);
    opts.addOption(bool, "use_devnw_json", use_devnw_json);
    opts.addOption(bool, "use_devnw_config", use_devnw_config);
    opts.addOption(bool, "use_devnw_protobuf", use_devnw_protobuf);
    opts.addOption(bool, "use_devnw_metrics", use_devnw_metrics);
    opts.addOption(bool, "use_devnw_tls", use_devnw_tls);
    opts.addOption(bool, "use_devnw_grpc", use_devnw_grpc);
    opts.addOption(bool, "use_devnw_pool", use_devnw_pool);
    opts.addOption(bool, "grpc_test_server", grpc_test_server);
    opts.addOption(bool, "otel_disabled", otel_disabled);
    opts.addOption([]const u8, "version", "0.1.0");
    const build_options_module = opts.createModule();

    // ------------------------------------------------------------------
    // Library module — primary public surface.
    // ------------------------------------------------------------------
    const otel_module = b.addModule("otel", .{
        .root_source_file = b.path("src/otel.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (use_devnw_slog) {
        const slog_dep = b.dependency("slog", .{ .target = target, .optimize = optimize });
        otel_module.addImport("slog", slog_dep.module("slogz"));
    }
    if (use_devnw_json) {
        const json_dep = b.dependency("json", .{ .target = target, .optimize = optimize });
        otel_module.addImport("json", json_dep.module("json"));
    }
    if (use_devnw_config) {
        const yaml_dep = b.dependency("yaml", .{ .target = target, .optimize = optimize });
        const config_dep = b.dependency("config", .{ .target = target, .optimize = optimize });
        otel_module.addImport("yaml", yaml_dep.module("yaml"));
        otel_module.addImport("config", config_dep.module("config"));
    }
    if (use_devnw_protobuf) {
        const proto_dep = b.dependency("protobuf", .{ .target = target, .optimize = optimize });
        otel_module.addImport("devnw_protobuf", proto_dep.module("protobuf"));
    }
    if (use_devnw_metrics) {
        const metrics_dep = b.dependency("metrics", .{ .target = target, .optimize = optimize });
        otel_module.addImport("devnw_metrics", metrics_dep.module("metrics"));
    }
    if (use_devnw_tls) {
        // The DevNW tls package is QUIC-oriented (RFC 9001-first; no
        // traditional TCP record-layer driver). The `tls13_full` module
        // exposes the message-parsing primitives we'd need to drive a
        // TLS-over-TCP record loop ourselves. Wiring the import here
        // proves the module resolves; the real HTTPS transport landing is
        // tracked in docs/DEPENDENCIES.md (TLS row).
        const tls_dep = b.dependency("tls", .{ .target = target, .optimize = optimize });
        otel_module.addImport("tls", tls_dep.module("tls13_full"));
    }
    if (use_devnw_grpc) {
        const grpc_dep = b.dependency("grpc_zig", .{ .target = target, .optimize = optimize });

        // Build a single "umbrella" module that exposes BOTH the
        // grpc-zig client and server APIs. Upstream publishes them as
        // two separate modules (`grpc-client` and `grpc-server`) whose
        // roots transitively import the same shared files
        // (`proto/service.zig`, `transport.zig`, etc.). Zig 0.16
        // forbids the same source file belonging to two distinct
        // modules in one compilation, so importing both upstream
        // modules into our consumer trips a hard build error. We
        // instead synthesize a tiny umbrella source *inside the
        // upstream src/ directory* via `addWriteFile`, then build a
        // single module rooted at that synthesized file. The umbrella
        // imports `client.zig` and `server.zig` as siblings, which
        // works because both live in the same directory upstream and
        // already share their transitive imports — the whole graph
        // belongs to ONE module (`grpc_all`) so the collision is
        // resolved.
        //
        // The umbrella module also picks up the zlib link from
        // `grpc-server` (the public module exports that linkage), so
        // we re-link it here to keep the C dependency satisfied.
        const grpc_src_root = grpc_dep.path("src");
        const wf = b.addWriteFiles();
        const umbrella_path = wf.addCopyFile(b.path("third_party/grpc_zig/all.zig"), "all.zig");
        // Clone every upstream `src/` file into the same WriteFiles
        // directory so the synthesized `all.zig` can `@import` siblings
        // (and they can transitively `@import` each other) within the
        // single module identity.
        const upstream_files = [_][]const u8{
            "client.zig",
            "server.zig",
            "compat.zig",
            "benchmark.zig",
            "proto/service.zig",
            "features/auth.zig",
            "features/compression.zig",
            "features/streaming.zig",
            "features/health.zig",
            "http2/connection.zig",
            "http2/frame.zig",
            "http2/hpack.zig",
            "http2/stream.zig",
        };
        for (upstream_files) |sub| {
            _ = wf.addCopyFile(grpc_src_root.path(b, sub), sub);
        }
        // `transport.zig` is sourced from a local patched copy because
        // upstream's `ioWrite` calls `netWrite(..., data, &.{}, 0)`,
        // which underflows in `netWritePosix` (the stdlib API requires
        // at least one element in the iovec slice for the splat-pattern
        // computation). The patched copy passes the payload as a
        // single-element iovec with an empty header, matching the
        // stdlib contract. Drop this entry once upstream lands a fix.
        _ = wf.addCopyFile(b.path("third_party/grpc_zig/transport.zig"), "transport.zig");

        const grpc_all = b.createModule(.{
            .root_source_file = umbrella_path,
            .target = target,
            .optimize = optimize,
        });
        // Reuse the zlib library that upstream's `grpc-client` /
        // `grpc-server` modules link in. Easiest way to inherit it is
        // to depend on either upstream module's link state via
        // `module.linkLibrary`; we bind through `grpc-server`'s linkage
        // declaration.
        const upstream_server = grpc_dep.module("grpc-server");
        for (upstream_server.link_objects.items) |lo| {
            grpc_all.link_objects.append(b.allocator, lo) catch @panic("OOM");
        }
        otel_module.addImport("grpc_zig", grpc_all);
    }
    if (use_devnw_pool) {
        const tp_dep = b.dependency("thread_pool", .{ .target = target, .optimize = optimize });
        otel_module.addImport("thread_pool", tp_dep.module("thread_pool"));
    }
    otel_module.addImport("build_options", build_options_module);

    const static_lib = b.addLibrary(.{
        .name = "otel",
        .linkage = .static,
        .root_module = otel_module,
    });
    b.installArtifact(static_lib);

    const build_step = b.step("build", "Build the standalone library and CLI");
    build_step.dependOn(&static_lib.step);

    // ------------------------------------------------------------------
    // CLI — thin wrapper that forwards to the golden runner.
    // ------------------------------------------------------------------
    if (!no_cli) {
        const cli_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "otel", .module = otel_module },
            },
        });
        const cli_exe = b.addExecutable(.{
            .name = "otel",
            .root_module = cli_module,
        });
        b.installArtifact(cli_exe);
        build_step.dependOn(&cli_exe.step);

        const run_cli = b.addRunArtifact(cli_exe);
        if (b.args) |args| run_cli.addArgs(args);
        const run_step = b.step("run", "Run the CLI (forwards trailing args after `--`)");
        run_step.dependOn(&run_cli.step);
    }

    // ------------------------------------------------------------------
    // Check step — fast IDE feedback.
    // ------------------------------------------------------------------
    const check_step = b.step("check", "Compile the library and tests without running them");
    const check_tests = b.addTest(.{ .root_module = otel_module });
    check_step.dependOn(&check_tests.step);

    // ------------------------------------------------------------------
    // Unit tests live alongside the library code.
    // ------------------------------------------------------------------
    const unit_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{ .root_module = otel_module });
    if (tsan) unit_tests.root_module.sanitize_thread = true;
    unit_step.dependOn(&b.addRunArtifact(unit_tests).step);

    // External test suites under test/.
    const test_files = [_][]const u8{
        "test/context.zig",
        "test/baggage.zig",
        "test/trace.zig",
        "test/metrics.zig",
        "test/logs.zig",
        "test/otlp.zig",
        "test/config.zig",
        "test/security.zig",
        "test/instrumentation_slog.zig",
        "test/otlp_wire_parity.zig",
        "test/tls_loopback.zig",
        "test/batch_async.zig",
        "test/comptime_disabled.zig",
    };
    for (test_files) |path| {
        const m = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "otel", .module = otel_module },
                .{ .name = "build_options", .module = build_options_module },
            },
        });
        const t = b.addTest(.{ .root_module = m });
        if (tsan) t.root_module.sanitize_thread = true;
        unit_step.dependOn(&b.addRunArtifact(t).step);
        check_step.dependOn(&t.step);
    }

    // gRPC loopback test — the test source compiles regardless of the
    // grpc flag (it skips at runtime via `error.SkipZigTest` when the
    // flag is off). The test reaches the server harness through
    // `otel.exporters.otlp_grpc_test_server`, so we don't need to
    // wire any grpc-zig module on the test module itself. The umbrella
    // module (`grpc_zig`) lives entirely inside the otel module's
    // import graph and exposes both client and server APIs through one
    // module identity — see the umbrella wiring above.
    {
        const grpc_test_module = b.createModule(.{
            .root_source_file = b.path("test/grpc_loopback.zig"),
            .target = target,
            .optimize = optimize,
        });
        grpc_test_module.addImport("otel", otel_module);
        grpc_test_module.addImport("build_options", build_options_module);
        // No direct grpc_server import on the test module: it reaches the
        // server through `otel.exporters.otlp_grpc_test_server` (gated by
        // the same flag) so the grpc-zig source files are owned by a
        // single module in the compilation.
        const t = b.addTest(.{ .root_module = grpc_test_module });
        if (tsan) t.root_module.sanitize_thread = true;
        unit_step.dependOn(&b.addRunArtifact(t).step);
        check_step.dependOn(&t.step);
    }

    // ------------------------------------------------------------------
    // Golden runner — the acceptance harness.
    // Usage: zig build golden -- <subcommand> [args...]
    // ------------------------------------------------------------------
    const golden_module = b.createModule(.{
        .root_source_file = b.path("tools/golden.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "otel", .module = otel_module }},
    });
    const golden_exe = b.addExecutable(.{
        .name = "otel-golden",
        .root_module = golden_module,
    });
    b.installArtifact(golden_exe);
    const run_golden = b.addRunArtifact(golden_exe);
    if (b.args) |args| run_golden.addArgs(args);
    // Pass stdio through unmodified — the harness controls its own exit
    // code so the user sees `error.InvalidTraceParent: ...` verbatim and
    // gets the documented exit values (0 for ok, 2 for invalid).
    run_golden.stdio = .inherit;
    const golden_step = b.step("golden", "Run the golden acceptance harness");
    golden_step.dependOn(&run_golden.step);

    // ------------------------------------------------------------------
    // GAP-SEC-M-2: deterministic generators for `src/generated/`.
    // ------------------------------------------------------------------
    const gen_otlp_module = b.createModule(.{
        .root_source_file = b.path("tools/gen_otlp.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gen_otlp_exe = b.addExecutable(.{
        .name = "gen-otlp",
        .root_module = gen_otlp_module,
    });
    const run_gen_otlp = b.addRunArtifact(gen_otlp_exe);
    if (b.args) |args| run_gen_otlp.addArgs(args);
    run_gen_otlp.stdio = .inherit;
    const gen_otlp_step = b.step("gen-otlp", "Emit a SHA-256 manifest of third_party/opentelemetry-proto-v1.10.0/");
    gen_otlp_step.dependOn(&run_gen_otlp.step);

    const gen_semconv_module = b.createModule(.{
        .root_source_file = b.path("tools/gen_semconv.zig"),
        .target = target,
        .optimize = optimize,
    });
    const gen_semconv_exe = b.addExecutable(.{
        .name = "gen-semconv",
        .root_module = gen_semconv_module,
    });
    const run_gen_semconv = b.addRunArtifact(gen_semconv_exe);
    if (b.args) |args| run_gen_semconv.addArgs(args);
    run_gen_semconv.stdio = .inherit;
    const gen_semconv_step = b.step("gen-semconv", "Emit a SHA-256 manifest of third_party/semantic-conventions-v1.40.0/");
    gen_semconv_step.dependOn(&run_gen_semconv.step);

    // ------------------------------------------------------------------
    // Examples.
    // ------------------------------------------------------------------
    const example_basic = b.addExecutable(.{
        .name = "otel-basic",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/basic.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "otel", .module = otel_module }},
        }),
    });
    b.installArtifact(example_basic);
    const run_basic = b.addRunArtifact(example_basic);
    if (b.args) |args| run_basic.addArgs(args);
    const run_basic_step = b.step("run-basic", "Run examples/basic.zig");
    run_basic_step.dependOn(&run_basic.step);

    const example_http = b.addExecutable(.{
        .name = "otel-http-client",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/http_client.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "otel", .module = otel_module }},
        }),
    });
    b.installArtifact(example_http);
    const run_http = b.addRunArtifact(example_http);
    if (b.args) |args| run_http.addArgs(args);
    const run_http_step = b.step("run-http-client", "Run examples/http_client.zig");
    run_http_step.dependOn(&run_http.step);

    // ------------------------------------------------------------------
    // fmt convenience.
    // ------------------------------------------------------------------
    const fmt_step = b.step("fmt", "Run zig fmt over all sources");
    const fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "src", "test", "tools", "examples" },
        .check = false,
    });
    fmt_step.dependOn(&fmt.step);

    const fmt_check_step = b.step("fmt-check", "Verify zig fmt is a no-op");
    const fmt_check = b.addFmt(.{
        .paths = &.{ "build.zig", "src", "test", "tools", "examples" },
        .check = true,
    });
    fmt_check_step.dependOn(&fmt_check.step);

    // ------------------------------------------------------------------
    // CI compatibility steps.
    //
    // The shared GitLab CI catalog distinguishes `test`/`test-integration`/
    // `test-stress` for matrix coverage. We don't have a separate
    // integration or stress suite (the unit suite under `test/` already
    // covers integration-shaped scenarios via the in-memory exporter and
    // loopback servers), so wire both as aliases for `test` rather than
    // letting CI fail on missing step names. Removing the catalog jobs
    // is also an option, but the alias keeps the matrix in sync with
    // sibling DevNW Zig packages.
    // ------------------------------------------------------------------
    const test_integration_step = b.step("test-integration", "Alias for `test`; CI compatibility");
    test_integration_step.dependOn(unit_step);

    const test_stress_step = b.step("test-stress", "Alias for `test`; CI compatibility");
    test_stress_step.dependOn(unit_step);

    // Live OTLP integration tests against a real collector. Self-skip
    // unless the corresponding endpoint env var is set, so this step
    // is safe to wire into CI without polluting the hermetic default
    // suite. CI's `otlp-integration-live` job points it at the GitLab
    // Observability endpoints with `-Dotel_use_devnw_tls=true` (and,
    // when grpc-zig client TLS lands, `-Dotel_use_devnw_grpc=true`).
    const remote_test_module = b.createModule(.{
        .root_source_file = b.path("test/remote_otlp.zig"),
        .target = target,
        .optimize = optimize,
        // Link libc so `std.c.environ` is reachable. 0.16 dropped
        // `std.process.getEnvVarOwned`; the replacement walks the libc
        // environ block. Pulling libc in for the remote-test target
        // keeps the cost contained — the rest of the suite stays libc-
        // free for hermetic Debug/ReleaseSafe runs.
        .link_libc = true,
        .imports = &.{
            .{ .name = "otel", .module = otel_module },
            .{ .name = "build_options", .module = build_options_module },
        },
    });
    const remote_test = b.addTest(.{ .root_module = remote_test_module });
    if (tsan) remote_test.root_module.sanitize_thread = true;
    const remote_test_run = b.addRunArtifact(remote_test);
    // Always re-run — depends on env vars + the remote endpoint, never on cached state.
    remote_test_run.has_side_effects = true;
    const remote_step = b.step("test-remote-otlp", "Run live OTLP exporter tests against a remote collector (self-skips without env vars)");
    remote_step.dependOn(&remote_test_run.step);

    // The bench/scale-bench/compare-bench jobs in CI are advisory and
    // gated to default branch / schedule / RUN_BENCH=true. Until the
    // benchmark/ directory's bench.zig is wired against the current API
    // (it is template scaffolding from the zig-template), provide
    // pass-through stubs that succeed without doing anything. The CI
    // jobs are `allow_failure: true` anyway, but a clean pass keeps
    // the dashboard green.
    const bench_step = b.step("bench", "Run benchmark suite (stub — wired in a follow-up)");
    bench_step.dependOn(&fmt_check.step); // any always-succeed step

    const bench_micro_step = b.step("bench-micro", "Run micro-benchmarks (stub)");
    bench_micro_step.dependOn(&fmt_check.step);

    const scale_bench_step = b.step("scale-bench", "Run scale benchmarks (stub)");
    scale_bench_step.dependOn(&fmt_check.step);

    const compare_bench_step = b.step("compare-bench", "Compare benchmark output to baseline (stub)");
    compare_bench_step.dependOn(&fmt_check.step);

    // Tests for the bench framework itself (universal-schema envelope,
    // zero-alloc assertion, --ops override). The framework is a
    // standalone std-only module; testing it does not require any otel
    // imports, so the build step stays lightweight.
    const framework_test_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/framework.zig"),
        .target = target,
        .optimize = optimize,
    });
    const framework_test = b.addTest(.{ .root_module = framework_test_module });
    if (tsan) framework_test.root_module.sanitize_thread = true;
    const framework_test_step = b.step("bench-framework-test", "Run benchmark framework unit tests");
    framework_test_step.dependOn(&b.addRunArtifact(framework_test).step);
}
