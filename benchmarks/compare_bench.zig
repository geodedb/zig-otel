// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

//! Comparison-layer A/B harness. Built twice (once per
//! `-Dotel_disabled` value) and run by `scripts/bench_ab_runner.sh`.
//! All 13 comparison scenarios land in Phase 6; this stub keeps the
//! `bench-ab` build step compiling against the real artifact graph.

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
        .help_only => try framework.printHelp(stderr, "bench-ab"),
        .list_only => try framework.printScenarios(stderr, scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, scenarios, opts),
    }
}
