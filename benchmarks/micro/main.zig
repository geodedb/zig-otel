// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

//! Micro-benchmark entry point. Isolated hot paths with deterministic
//! inputs and zero-alloc assertions where applicable. Real scenarios
//! land in Phase 4 of the zero-overhead-when-disabled plan; this stub
//! exists so the build graph is wired and `zig build bench-micro` runs
//! cleanly today.
//!
//! See docs/performance/2026-04-26-zero-overhead-when-disabled/plan.json
//! for the scenario catalog.

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
        .help_only => try framework.printHelp(stderr, "bench-micro"),
        .list_only => try framework.printScenarios(stderr, scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, scenarios, opts),
    }
}
