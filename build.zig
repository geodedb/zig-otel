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
    opts.addOption([]const u8, "version", "0.1.26");
    opts.addOption([]const u8, "package_name", "otel");
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
        // Keep the complete pinned source tree, including transport and new
        // transitive imports, so the adapter inherits upstream repairs.
        _ = wf.addCopyDirectory(grpc_src_root, ".", .{ .include_extensions = &.{".zig"} });

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
        var imports = upstream_server.import_table.iterator();
        while (imports.next()) |entry| {
            grpc_all.addImport(entry.key_ptr.*, entry.value_ptr.*);
        }
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

    // NEW-H-1 / GAP-SEC-M-2: shared manifest engine module.
    //
    // Both the proto/semconv generators and the regression test
    // (`test/manifest_provenance.zig`) consume `tools/manifest.zig`
    // through this module so the `requireSpecPayload` / `compute`
    // invariants stay test-anchored. Declared early so the test loop
    // below can wire it as an import.
    const manifest_module = b.createModule(.{
        .root_source_file = b.path("tools/manifest.zig"),
        .target = target,
        .optimize = optimize,
    });

    // External test suites under test/.
    const test_files = [_][]const u8{
        "test/context.zig",
        "test/baggage.zig",
        "test/trace.zig",
        "test/metrics.zig",
        "test/metrics_concurrency.zig",
        "test/logs.zig",
        "test/otlp.zig",
        "test/otlp_metrics.zig",
        // PR-9 (#143): pins the OTLP/gRPC endpoint-cache invariant
        // (parsed once at init, reads dispatch from the cache).
        "test/otlp_grpc_endpoint_cache.zig",
        "test/config.zig",
        "test/security.zig",
        "test/instrumentation_slog.zig",
        "test/otlp_wire_parity.zig",
        "test/otlp_spans_multi_scope.zig",
        // GAP-OTLP-WIRE-SCHEMA-URL (#26): pins Resource.schema_url
        // emission at ResourceSpans field 3 / ResourceMetrics field 3.
        "test/otlp_resource_schema_url.zig",
        // GAP-OTLP-WIRE-EVENTS-LINKS (#9): pins Span.events emission at
        // field 11 and Span.links emission at field 13, plus DevNW
        // protobuf parity for both. Trace.proto:242,295 in the vendored
        // OTLP 1.10.0 tree.
        "test/otlp_span_events_links.zig",
        // GAP-OTLP-LOG-EXPORT (#8): pins ExportLogsServiceRequest wire
        // shape, /v1/logs HTTP path, end-to-end Logger -> exporter, and
        // DevNW protobuf parity. logs.proto:48-226 in the vendored OTLP
        // 1.10.0 tree.
        "test/otlp_logs_wire.zig",
        "test/tls_loopback.zig",
        "test/batch_async.zig",
        // BSP concurrent-producer race (geode shard-worker pool) — pins
        // that with N threads × M spans each, forceFlush observes every
        // span exactly once on the synchronous-drain code path.
        "test/batch_concurrent.zig",
        "test/comptime_disabled.zig",
        // NEW-M-2 (#140, CONFIDENTIAL): regression test for CWE-59
        // symlink following in `src/exporters/file.zig`. See the file
        // header for the Zig 0.16 stdlib evidence.
        "test/file_exporter_symlink.zig",
        // Pluggable TextMapPropagator + Composite contract — pins the
        // factory the SDK uses to construct a propagator from
        // OTEL_PROPAGATORS at provider-build time. Carries the B3 /
        // Jaeger end-to-end coverage once those propagators land.
        "test/propagator.zig",
        // GAP-PROPAGATOR-B3 (#23): B3 single + multi header coverage.
        "test/propagator_b3.zig",
        // GAP-PROPAGATOR-JAEGER (#24): uber-trace-id + uberctx baggage.
        "test/propagator_jaeger.zig",
        // GAP-EXPORTER-FACTORY (#4): OTEL_*_EXPORTER env vars → typed
        // exporter dispatch, plus *Provider.initFromConfig helpers and
        // factory lifecycle (deinit frees backing allocations).
        "test/exporter_factory.zig",
        // GAP-OBSERVABLE-INSTRUMENTS (#30): asynchronous Counter /
        // UpDownCounter / Gauge — callback registration, multi-callback
        // ordering, idempotent unregister, cumulative semantics.
        "test/observable_instruments.zig",
        // GAP-PERIODIC-METRIC-READER (#29): timer-driven reader pinning
        // interval cadence, force-flush, prompt shutdown (<100ms target
        // even at 60s interval), and observable-instrument integration.
        "test/periodic_metric_reader.zig",
        // GAP-OTLP-COMPRESSION (#27): gzip body for OTLP/HTTP and
        // framing-flag byte for OTLP/gRPC. Pins Content-Encoding header,
        // gzip magic, gzip<->raw round-trip on representative payloads
        // (including >= 64 KiB), and the [1, len_be, gzipped] gRPC
        // framing shape via the `frame()` / `frameGzip()` helpers.
        "test/otlp_compression.zig",
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

    // NEW-H-1 / GAP-SEC-M-2: manifest provenance regression tests. The
    // test imports `tools/manifest.zig` directly (separate root from the
    // library) so it gets its own module entry rather than riding along
    // the `otel`-import test loop above.
    {
        const manifest_test_module = b.createModule(.{
            .root_source_file = b.path("test/manifest_provenance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "manifest", .module = manifest_module },
            },
        });
        const t = b.addTest(.{ .root_module = manifest_test_module });
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
    // NEW-H-1 / GAP-SEC-M-2: deterministic generators + verifiers for
    // `src/generated/` provenance. The shared `manifest_module` is
    // declared earlier so the regression test can consume the same
    // module identity.
    //
    // Each generator is exposed twice:
    //   * `zig build gen-*`       — emits the manifest to stdout
    //                               (regenerate recipe in the header).
    //   * `zig build verify-*-manifest`
    //                              — re-computes against the on-disk
    //                                manifest and exits 2 on drift.
    //
    // The shared engine (`tools/manifest.zig`) refuses to emit a
    // "successful" manifest when the upstream tree contains only
    // LICENSE — closing the NEW-H-1 (CWE-345) supply-chain forgery
    // primitive that the previous LICENSE-only manifest left open.
    // ------------------------------------------------------------------
    const gen_otlp_module = b.createModule(.{
        .root_source_file = b.path("tools/gen_otlp.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "manifest", .module = manifest_module },
        },
    });
    const gen_otlp_exe = b.addExecutable(.{
        .name = "gen-otlp",
        .root_module = gen_otlp_module,
    });
    const run_gen_otlp = b.addRunArtifact(gen_otlp_exe);
    if (b.args) |args| run_gen_otlp.addArgs(args);
    run_gen_otlp.stdio = .inherit;
    // The generators consult the working tree directly, so they must
    // never see a stale cache result. Mark each invocation as having
    // side effects so the build runner re-runs the artifact on every
    // request (otherwise CI would compare the manifest against a cached
    // last-good run rather than against the live vendored tree).
    run_gen_otlp.has_side_effects = true;
    const gen_otlp_step = b.step("gen-otlp", "Emit a SHA-256 manifest of third_party/opentelemetry-proto-v1.10.0/");
    gen_otlp_step.dependOn(&run_gen_otlp.step);

    const verify_proto_run = b.addRunArtifact(gen_otlp_exe);
    verify_proto_run.addArg("--verify");
    verify_proto_run.has_side_effects = true;
    verify_proto_run.stdio = .inherit;
    const verify_proto_step = b.step("verify-proto-manifest", "Verify docs/proto-manifest.txt matches third_party/opentelemetry-proto-v1.10.0/ (NEW-H-1)");
    verify_proto_step.dependOn(&verify_proto_run.step);

    const gen_semconv_module = b.createModule(.{
        .root_source_file = b.path("tools/gen_semconv.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "manifest", .module = manifest_module },
        },
    });
    const gen_semconv_exe = b.addExecutable(.{
        .name = "gen-semconv",
        .root_module = gen_semconv_module,
    });
    const run_gen_semconv = b.addRunArtifact(gen_semconv_exe);
    if (b.args) |args| run_gen_semconv.addArgs(args);
    run_gen_semconv.stdio = .inherit;
    run_gen_semconv.has_side_effects = true;
    const gen_semconv_step = b.step("gen-semconv", "Emit a SHA-256 manifest of third_party/semantic-conventions-v1.40.0/");
    gen_semconv_step.dependOn(&run_gen_semconv.step);

    const verify_semconv_run = b.addRunArtifact(gen_semconv_exe);
    verify_semconv_run.addArg("--verify");
    verify_semconv_run.has_side_effects = true;
    verify_semconv_run.stdio = .inherit;
    const verify_semconv_step = b.step("verify-semconv-manifest", "Verify docs/semconv-manifest.txt matches third_party/semantic-conventions-v1.40.0/ (NEW-H-1)");
    verify_semconv_step.dependOn(&verify_semconv_run.step);

    // Convenience aggregator — the CI gate runs both at once.
    const verify_manifests_step = b.step("verify-manifests", "Verify both proto + semconv manifests against the vendored upstream trees");
    verify_manifests_step.dependOn(verify_proto_step);
    verify_manifests_step.dependOn(verify_semconv_step);

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

    // ------------------------------------------------------------------
    // Benchmark artifact graph (zero-overhead-when-disabled bench
    // system). The framework.zig module is std-only and shared across
    // every bench artifact. Each artifact takes its own .root_source_file
    // and imports the otel module + framework module + build_options.
    //
    // CI catalog compatibility:
    //   - `bench` is preserved as an alias for `bench-ci`
    //   - `scale-bench` is preserved as an alias for `bench-ci`
    //   - `bench-micro` and `compare-bench` are real steps now (no
    //     longer fmt_check pass-throughs)
    // ------------------------------------------------------------------
    const framework_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/framework.zig"),
        .target = target,
        .optimize = optimize,
    });

    const BenchArtifact = struct {
        name: []const u8,
        root: []const u8,
        needs_otel: bool = true,
    };
    const bench_artifacts = [_]BenchArtifact{
        .{ .name = "bench-micro-exe", .root = "benchmarks/micro/main.zig" },
        .{ .name = "bench-integration-exe", .root = "benchmarks/integration/main.zig" },
        .{ .name = "bench-ab-exe", .root = "benchmarks/compare_bench.zig" },
        .{ .name = "bench-smoke-exe", .root = "benchmarks/smoke.zig" },
        .{ .name = "bench-compare-exe", .root = "benchmarks/compare.zig", .needs_otel = false },
        .{ .name = "bench-hard-criteria-exe", .root = "benchmarks/check_hard_criteria.zig", .needs_otel = false },
    };

    var bench_runs: [bench_artifacts.len]*std.Build.Step.Run = undefined;
    for (bench_artifacts, 0..) |a, idx| {
        var imports: std.ArrayList(std.Build.Module.Import) = .empty;
        imports.append(b.allocator, .{ .name = "framework", .module = framework_module }) catch @panic("OOM");
        if (a.needs_otel) {
            imports.append(b.allocator, .{ .name = "otel", .module = otel_module }) catch @panic("OOM");
            imports.append(b.allocator, .{ .name = "build_options", .module = build_options_module }) catch @panic("OOM");
        }
        const m = b.createModule(.{
            .root_source_file = b.path(a.root),
            .target = target,
            .optimize = optimize,
            .imports = imports.items,
        });
        const exe = b.addExecutable(.{ .name = a.name, .root_module = m });
        const run = b.addRunArtifact(exe);
        if (b.args) |args| run.addArgs(args);
        bench_runs[idx] = run;
    }

    const bench_micro_step = b.step("bench-micro", "Run the micro-benchmark suite");
    bench_micro_step.dependOn(&bench_runs[0].step);

    const bench_integration_step = b.step("bench-integration", "Run the integration-benchmark suite");
    bench_integration_step.dependOn(&bench_runs[1].step);

    const bench_ab_step = b.step("bench-ab", "Run the comparison-layer A/B harness (use -Dotel_disabled=true|false)");
    bench_ab_step.dependOn(&bench_runs[2].step);

    const bench_smoke_step = b.step("bench-smoke", "Run a one-round smoke check across all bench artifacts");
    bench_smoke_step.dependOn(&bench_runs[3].step);

    const compare_bench_step = b.step("compare-bench", "Compare two ResultDocument JSON files for regressions");
    compare_bench_step.dependOn(&bench_runs[4].step);

    const hard_criterion_step = b.step("hard-criterion-check", "Verify comptime-disabled and level-1 hard pass criteria from two ref JSON files");
    hard_criterion_step.dependOn(&bench_runs[5].step);

    const bench_ci_step = b.step("bench-ci", "Run the full bench suite (micro + integration) for CI");
    bench_ci_step.dependOn(bench_micro_step);
    bench_ci_step.dependOn(bench_integration_step);

    // Preserve historical step names as aliases. The shared GitLab CI
    // catalog dispatches on these names; renaming would break the
    // matrix. `bench` and `scale-bench` both fold into bench-ci.
    const bench_step = b.step("bench", "Alias for bench-ci");
    bench_step.dependOn(bench_ci_step);
    const scale_bench_step = b.step("scale-bench", "Alias for bench-ci (CI catalog compat)");
    scale_bench_step.dependOn(bench_ci_step);

    // Tests for the bench framework itself (universal-schema envelope,
    // zero-alloc assertion, --ops override). The framework is a
    // standalone std-only module; testing it does not require any otel
    // imports, so the build step stays lightweight.
    const framework_test = b.addTest(.{ .root_module = framework_module });
    if (tsan) framework_test.root_module.sanitize_thread = true;
    const framework_test_step = b.step("bench-framework-test", "Run benchmark framework unit tests");
    framework_test_step.dependOn(&b.addRunArtifact(framework_test).step);

    // Tests for the multi-shot loopback HTTP discard server used by
    // the level-6 integration bench. Std-only — no otel imports
    // needed, since the server's contract is independent of the SDK.
    const loopback_test_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/integration/loopback_server.zig"),
        .target = target,
        .optimize = optimize,
    });
    const loopback_test = b.addTest(.{ .root_module = loopback_test_module });
    if (tsan) loopback_test.root_module.sanitize_thread = true;
    const loopback_test_step = b.step("bench-loopback-test", "Run loopback HTTP discard server tests");
    loopback_test_step.dependOn(&b.addRunArtifact(loopback_test).step);
}
