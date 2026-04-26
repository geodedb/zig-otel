// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW

//! Integration-benchmark entry point. End-to-end pipeline scenarios
//! (level-3 through level-6 per the architecture document) land in
//! Phase 5; this stub keeps the build graph green in the meantime.

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
        .help_only => try framework.printHelp(stderr, "bench-integration"),
        .list_only => try framework.printScenarios(stderr, scenarios),
        .run => |opts| try framework.runScenarios(allocator, init.io, scenarios, opts),
    }
}
