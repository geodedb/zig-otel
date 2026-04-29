// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// SpanState pool — recycles drained `api.trace.SpanState` instances so
// the steady-state span recording hot path skips the per-span
// `allocator.create(SpanState)` round trip and pays no first-page
// arena fault. See `docs/adr/0001-spanstate-pool-concurrency.md` for
// the design call (mutex-guarded freelist, cap 128).

const std = @import("std");
const trace_api = @import("../api/trace.zig");
const build_options = @import("build_options");
const tp = if (build_options.use_devnw_pool) @import("thread_pool") else struct {};
const internal_sync = @import("../internal/sync.zig");

/// Real mutex on both build paths. The previous no-op-when-disabled
/// shape assumed a single producer thread, but real consumers (e.g.
/// geode's shard-worker pool) call `Tracer.startSpan` from many
/// threads concurrently — each call hits `tryAcquire`, and concurrent
/// `tryAcquire` / `tryRelease` on a plain `std.ArrayListUnmanaged`
/// freelist tears the underlying slice. Mirrors the `QueueMutex`
/// pattern in `sdk/export.zig`.
const PoolMutex = if (build_options.use_devnw_pool) tp.sync.Mutex else internal_sync.Mutex;

pub const default_max: u32 = 128;

pub const Pool = struct {
    free: std.ArrayListUnmanaged(*trace_api.SpanState) = .empty,
    max: u32 = default_max,
    mu: PoolMutex = .{},
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Pool {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Pool) void {
        // No lock needed: deinit runs after the provider has
        // shut down all processors so there are no concurrent
        // acquire/release callers.
        for (self.free.items) |state| {
            state.recycler = null;
            state.deinit();
        }
        self.free.deinit(self.allocator);
    }

    /// Pop a recycled SpanState if one is available. Caller takes
    /// ownership and must wire whatever transient state it needs.
    pub fn tryAcquire(self: *Pool) ?*trace_api.SpanState {
        self.mu.lock();
        defer self.mu.unlock();
        return self.free.pop();
    }

    /// Push a drained SpanState onto the pool. Returns false when
    /// the pool is at capacity; the caller must then fully deinit
    /// the SpanState.
    pub fn tryRelease(self: *Pool, state: *trace_api.SpanState) bool {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.free.items.len >= self.max) return false;
        self.free.append(self.allocator, state) catch return false;
        return true;
    }

    /// Trampoline matching the `SpanState.Recycler.returnFn` shape.
    pub fn returnFn(ctx: *anyopaque, state: *trace_api.SpanState) bool {
        const self: *Pool = @ptrCast(@alignCast(ctx));
        return self.tryRelease(state);
    }

    pub fn recycler(self: *Pool) trace_api.SpanState.Recycler {
        return .{ .ctx = self, .returnFn = returnFn };
    }
};

test "pool acquires and releases" {
    var p = Pool.init(std.testing.allocator);
    defer p.deinit();

    // Manual SpanState construction — pool only wires the recycler.
    const state = try trace_api.SpanState.init(std.testing.allocator, "n", .{}, .{ .name = "" }, 0);
    state.recycler = p.recycler();

    try std.testing.expect(p.tryAcquire() == null);
    try std.testing.expect(p.tryRelease(state));
    try std.testing.expectEqual(@as(usize, 1), p.free.items.len);
    try std.testing.expect(p.tryAcquire() == state);
    try std.testing.expect(p.tryAcquire() == null);

    // Put it back so deinit cleans it up.
    try std.testing.expect(p.tryRelease(state));
}

test "pool rejects past capacity" {
    var p = Pool.init(std.testing.allocator);
    p.max = 2;
    defer p.deinit();

    const a = try trace_api.SpanState.init(std.testing.allocator, "a", .{}, .{ .name = "" }, 0);
    const b = try trace_api.SpanState.init(std.testing.allocator, "b", .{}, .{ .name = "" }, 0);
    const c = try trace_api.SpanState.init(std.testing.allocator, "c", .{}, .{ .name = "" }, 0);
    a.recycler = p.recycler();
    b.recycler = p.recycler();
    c.recycler = p.recycler();
    try std.testing.expect(p.tryRelease(a));
    try std.testing.expect(p.tryRelease(b));
    try std.testing.expect(!p.tryRelease(c));
    // c stayed unclaimed; clean it up to satisfy testing allocator.
    c.recycler = null;
    c.deinit();
}
