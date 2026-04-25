// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Fixed-capacity SPMC ring buffer used by the batch span/log processors.
// Push returns false when full; the caller increments the dropped counter
// and surfaces it once per flush cycle.

const std = @import("std");

pub fn RingBuffer(comptime T: type) type {
    return struct {
        const Self = @This();
        buf: []T,
        head: usize = 0,
        tail: usize = 0,
        len_: usize = 0,
        allocator: std.mem.Allocator,

        pub fn init(allocator: std.mem.Allocator, cap: usize) !Self {
            std.debug.assert(cap > 0);
            const buf = try allocator.alloc(T, cap);
            return .{ .buf = buf, .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buf);
        }

        pub fn capacity(self: *const Self) usize {
            return self.buf.len;
        }

        pub fn len(self: *const Self) usize {
            return self.len_;
        }

        pub fn isEmpty(self: *const Self) bool {
            return self.len_ == 0;
        }

        pub fn isFull(self: *const Self) bool {
            return self.len_ == self.buf.len;
        }

        pub fn push(self: *Self, item: T) bool {
            if (self.isFull()) return false;
            self.buf[self.tail] = item;
            self.tail = (self.tail + 1) % self.buf.len;
            self.len_ += 1;
            return true;
        }

        pub fn pop(self: *Self) ?T {
            if (self.isEmpty()) return null;
            const item = self.buf[self.head];
            self.head = (self.head + 1) % self.buf.len;
            self.len_ -= 1;
            return item;
        }

        /// Drains up to `out.len` items into `out`. Returns the number drained.
        pub fn drain(self: *Self, out: []T) usize {
            var i: usize = 0;
            while (i < out.len) : (i += 1) {
                const v = self.pop() orelse break;
                out[i] = v;
            }
            return i;
        }
    };
}

test "ring buffer fifo order" {
    var rb = try RingBuffer(u32).init(std.testing.allocator, 4);
    defer rb.deinit();
    try std.testing.expect(rb.push(1));
    try std.testing.expect(rb.push(2));
    try std.testing.expect(rb.push(3));
    try std.testing.expectEqual(@as(usize, 3), rb.len());
    try std.testing.expectEqual(@as(?u32, 1), rb.pop());
    try std.testing.expectEqual(@as(?u32, 2), rb.pop());
    try std.testing.expectEqual(@as(?u32, 3), rb.pop());
    try std.testing.expectEqual(@as(?u32, null), rb.pop());
}

test "ring buffer drops when full" {
    var rb = try RingBuffer(u8).init(std.testing.allocator, 2);
    defer rb.deinit();
    try std.testing.expect(rb.push(1));
    try std.testing.expect(rb.push(2));
    try std.testing.expect(!rb.push(3));
}

test "ring buffer wraps after pop" {
    var rb = try RingBuffer(u8).init(std.testing.allocator, 3);
    defer rb.deinit();
    _ = rb.push(1);
    _ = rb.push(2);
    _ = rb.pop();
    try std.testing.expect(rb.push(3));
    try std.testing.expect(rb.push(4));
    try std.testing.expect(!rb.push(5));
    var out: [4]u8 = undefined;
    const n = rb.drain(out[0..]);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualSlices(u8, &.{ 2, 3, 4 }, out[0..n]);
}
