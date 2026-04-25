// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Runtime/process instrumentation helper. Materialises a small set of
// observable metrics (resident set, threads, uptime) and exposes them
// through callbacks so the SDK pulls a fresh snapshot per collection.

const std = @import("std");
const metrics_api = @import("../api/metrics.zig");
const semconv = @import("../generated/semconv.zig");

/// Reads `/proc/self/statm` on Linux. On other platforms returns null
/// fields and the helper degrades gracefully (no points emitted).
pub const Snapshot = struct {
    rss_bytes: ?u64 = null,
    page_size: u64 = 4096,
    threads: ?u32 = null,

    pub fn capture() Snapshot {
        var s: Snapshot = .{};
        if (@import("builtin").os.tag != .linux) return s;
        var buf: [256]u8 = undefined;
        const f = std.fs.openFileAbsolute("/proc/self/statm", .{}) catch return s;
        defer f.close();
        const n = f.readAll(&buf) catch return s;
        if (n == 0) return s;
        const data = buf[0..n];
        // statm format: size resident shared text lib data dt
        var iter = std.mem.tokenizeScalar(u8, data, ' ');
        _ = iter.next();
        const resident_pages = iter.next() orelse return s;
        const pages = std.fmt.parseInt(u64, std.mem.trim(u8, resident_pages, " \n"), 10) catch return s;
        s.rss_bytes = pages * std.heap.pageSize();

        // Threads are exposed in /proc/self/status as "Threads:".
        const status_f = std.fs.openFileAbsolute("/proc/self/status", .{}) catch return s;
        defer status_f.close();
        var status_buf: [4096]u8 = undefined;
        const sn = status_f.readAll(&status_buf) catch return s;
        const sd = status_buf[0..sn];
        if (std.mem.indexOf(u8, sd, "Threads:")) |idx| {
            const rest = sd[idx + "Threads:".len ..];
            const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
            const value = std.mem.trim(u8, rest[0..end], " \t");
            s.threads = std.fmt.parseInt(u32, value, 10) catch null;
        }
        return s;
    }
};

/// Convenience installer — registers `process.runtime.zig.*` instruments
/// against `meter` and returns the handles so callers can refresh them
/// from a periodic timer.
pub const Handles = struct {
    rss: ?metrics_api.Gauge = null,
    threads: ?metrics_api.Gauge = null,
};

pub fn install(meter: metrics_api.Meter) !Handles {
    const rss = try meter.gauge(.{
        .name = "process.runtime.zig.memory.resident_set",
        .unit = "By",
        .kind = .gauge,
        .description = "Resident set size in bytes",
    });
    const threads = try meter.gauge(.{
        .name = "process.runtime.zig.threads",
        .unit = "{thread}",
        .kind = .gauge,
        .description = "Number of OS threads in the process",
    });
    return .{ .rss = rss, .threads = threads };
}

pub fn refresh(h: Handles) void {
    const s = Snapshot.capture();
    if (h.rss) |g| if (s.rss_bytes) |v| g.set(@floatFromInt(v), &.{});
    if (h.threads) |g| if (s.threads) |v| g.set(@floatFromInt(v), &.{});
}

test "snapshot does not crash on linux" {
    _ = Snapshot.capture();
}
