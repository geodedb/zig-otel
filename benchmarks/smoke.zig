// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

//! Smoke-bench entry point. Runs one warmup + one sample of each
//! cross-platform-safe scenario so CI catches "the build broke the
//! bench" regressions without paying the full bench cost. Level-6
//! (loopback OTLP) is excluded per Decision D-4. Implementation lands
//! after the scenario catalogs are populated in Phases 4-6.

const std = @import("std");
const Io = std.Io;
const framework = @import("framework");

pub fn main(init: std.process.Init) !void {
    var arena = std.heap.ArenaAllocator.init(init.gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = Io.File.stderr().writer(init.io, &stderr_buf);
    const stderr = &stderr_writer.interface;

    const scenarios: []const framework.Scenario = &.{};

    switch (try framework.parseArgs(allocator, init.minimal.args)) {
        .help_only => try framework.printHelp(stderr, "bench-smoke"),
        .list_only => try framework.printScenarios(stderr, scenarios),
        .run => |opts| {
            var smoke_opts = opts;
            // Smoke-mode caps: 1 warmup + 1 sample to keep CI fast.
            smoke_opts.warmup_override = 1;
            smoke_opts.samples_override = 1;
            try framework.runScenarios(allocator, init.io, scenarios, smoke_opts);
        },
    }
}
