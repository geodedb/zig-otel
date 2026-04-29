// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Zero-arg synchronization primitives for the no-`thread_pool` build.
//
// Zig 0.16 removed `std.Thread.Mutex`; `std.Io.Mutex` is the supported
// path forward but every `lock`/`unlock` requires an `Io` instance to
// be threaded through. Plumbing `Io` through every internal SDK
// surface (BSP queue, span pool, BSP shutdown wakeup) is a bigger
// refactor than this module wants to absorb — and the DevNW
// `thread_pool` dependency already wraps `std.Io.Mutex` with a
// zero-arg shape via `std.Io.Threaded.global_single_threaded`.
//
// This file replicates that shape locally so the no-pool build (which
// does not import `thread_pool`) can still get a real, blocking,
// zero-arg mutex. The futex vtable on `Threaded` ignores its
// `userdata` for the `*Uncancelable` paths, so this is safe to call
// from any thread regardless of whether the caller is registered with
// a `Threaded` runtime.
//
// The shape matches `tp.sync.Mutex` so call sites can alias either
// behind a single `if (build_options.use_devnw_pool)` switch without
// further wrapping.

const std = @import("std");

inline fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(io());
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(io());
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }
};
