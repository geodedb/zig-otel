// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Pluggable clock. The SDK never reads wall time directly; everything that
// needs a timestamp pulls from a Clock so tests get deterministic output.

const std = @import("std");

pub const Clock = struct {
    ctx: ?*anyopaque,
    nowFn: *const fn (?*anyopaque) u64,

    pub fn now(self: Clock) u64 {
        return self.nowFn(self.ctx);
    }
};

/// Cross-platform wall-clock helper. Returns 0 if the OS rejects the
/// query; downstream code treats 0 as "no timestamp available" and
/// keeps going.
pub fn unixNanoNow() u64 {
    const builtin = @import("builtin");
    switch (builtin.os.tag) {
        .linux => {
            var ts: std.os.linux.timespec = undefined;
            const rc = std.os.linux.clock_gettime(std.os.linux.CLOCK.REALTIME, &ts);
            if (rc != 0) return 0;
            if (ts.sec < 0) return 0;
            const sec_ns = std.math.mul(u64, @intCast(ts.sec), std.time.ns_per_s) catch return 0;
            const nsec = if (ts.nsec < 0) 0 else @as(u64, @intCast(ts.nsec));
            return sec_ns +| nsec;
        },
        .macos, .ios, .tvos, .watchos => {
            // Darwin libc binding.
            var ts: std.c.timespec = undefined;
            if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
            if (ts.sec < 0) return 0;
            const sec_ns = std.math.mul(u64, @intCast(ts.sec), std.time.ns_per_s) catch return 0;
            const nsec = if (ts.nsec < 0) 0 else @as(u64, @intCast(ts.nsec));
            return sec_ns +| nsec;
        },
        else => return 0,
    }
}

fn defaultNow(_: ?*anyopaque) u64 {
    return unixNanoNow();
}

pub const default: Clock = .{ .ctx = null, .nowFn = defaultNow };

/// Deterministic clock used by tests and the golden harness.
pub const Fixed = struct {
    value: u64,

    pub fn init(value: u64) Fixed {
        return .{ .value = value };
    }

    pub fn clock(self: *Fixed) Clock {
        return .{ .ctx = self, .nowFn = fixedNow };
    }

    pub fn advance(self: *Fixed, by: u64) void {
        self.value +%= by;
    }
};

fn fixedNow(ctx: ?*anyopaque) u64 {
    const self: *Fixed = @ptrCast(@alignCast(ctx.?));
    return self.value;
}

/// Monotonically increasing stepped clock — each call returns prev + step.
pub const Stepped = struct {
    next: u64,
    step: u64,

    pub fn init(start: u64, step: u64) Stepped {
        return .{ .next = start, .step = step };
    }

    pub fn clock(self: *Stepped) Clock {
        return .{ .ctx = self, .nowFn = steppedNow };
    }
};

fn steppedNow(ctx: ?*anyopaque) u64 {
    const self: *Stepped = @ptrCast(@alignCast(ctx.?));
    const v = self.next;
    self.next +%= self.step;
    return v;
}

test "fixed clock returns constant" {
    var f = Fixed.init(42);
    const c = f.clock();
    try std.testing.expectEqual(@as(u64, 42), c.now());
    try std.testing.expectEqual(@as(u64, 42), c.now());
}

test "stepped clock advances each call" {
    var s = Stepped.init(100, 10);
    const c = s.clock();
    try std.testing.expectEqual(@as(u64, 100), c.now());
    try std.testing.expectEqual(@as(u64, 110), c.now());
    try std.testing.expectEqual(@as(u64, 120), c.now());
}
