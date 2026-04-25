// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Thin CLI wrapper. Production users embed the library directly; the
// binary exists so `zig build run -- <args>` provides a smoke test.

const std = @import("std");
const otel = @import("otel");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const out = &stdout_writer.interface;

    try out.print("otel {s}\n", .{otel.version});
    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 1) {
        try out.writeAll("Available subcommands run via `zig build golden -- <name>`:\n");
        try out.writeAll("  - trace-context\n  - signals\n  - invalid-traceparent\n  - redaction\n");
    } else {
        try out.writeAll("No-op CLI. Use `zig build golden -- <subcommand>` for the acceptance harness.\n");
    }
    try out.flush();
}
