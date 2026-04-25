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

    const opts = b.addOptions();
    opts.addOption(bool, "otel_profiles", otel_profiles);
    opts.addOption(bool, "deprecated_span_events", deprecated_span_events);
    opts.addOption(bool, "use_devnw_slog", use_devnw_slog);
    opts.addOption(bool, "use_devnw_json", use_devnw_json);
    opts.addOption(bool, "use_devnw_config", use_devnw_config);
    opts.addOption(bool, "use_devnw_protobuf", use_devnw_protobuf);
    opts.addOption(bool, "use_devnw_metrics", use_devnw_metrics);
    opts.addOption(bool, "use_devnw_tls", use_devnw_tls);
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
}
