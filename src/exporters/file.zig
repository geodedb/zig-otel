// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// File JSONL exporter — appends one JSON record per line to a file
// inside a caller-supplied `std.Io.Dir`. Useful for sidecar/Fluent Bit
// pipelines.
//
// GAP-SEC-H-3: the open() entry point requires an explicit base
// directory and rejects empty / absolute / `..`-bearing sub-paths. This
// blocks the file exporter from being used to clobber arbitrary files
// outside the intended log directory (or to follow a symlink the
// attacker planted).

const std = @import("std");
const exp = @import("../sdk/export.zig");
const json_codec = @import("../internal/json_codec.zig");

pub const FileJsonl = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,

    /// Open (creating if needed) a JSONL file *inside* `base`.
    ///
    /// The `sub_path` must be a relative path with no `..` components.
    /// Absolute paths and parent-traversal segments are refused with
    /// `error.InvalidPath` to prevent the file exporter from being used
    /// to clobber arbitrary files on disk (GAP-SEC-H-3).
    ///
    /// The file is opened with `truncate = false` so existing data is
    /// preserved across restarts.
    pub fn open(allocator: std.mem.Allocator, io: std.Io, base: std.Io.Dir, sub_path: []const u8) !FileJsonl {
        try validateSubPath(sub_path);
        const file = try base.createFile(io, sub_path, .{ .truncate = false, .read = false });
        return .{ .allocator = allocator, .io = io, .file = file };
    }

    pub fn close(self: *FileJsonl) void {
        self.file.close(self.io);
    }

    pub fn spanExporter(self: *FileJsonl) exp.SpanExporter {
        return .{ .ctx = self, .exportFn = expSpans, .shutdownFn = doShutdown, .forceFlushFn = doFlush };
    }

    pub fn logExporter(self: *FileJsonl) exp.LogExporter {
        return .{ .ctx = self, .exportFn = expLogs, .shutdownFn = doShutdown, .forceFlushFn = doFlush };
    }
};

/// Reject `sub_path` if empty, absolute, or containing any `..` segment.
/// The check is component-wise so `foo/..bar/baz.txt` (a real filename
/// component starting with `..`) is allowed, but `../escape.txt` and
/// `nested/../etc/passwd` are not.
fn validateSubPath(sub_path: []const u8) !void {
    if (sub_path.len == 0) return error.InvalidPath;
    if (std.fs.path.isAbsolute(sub_path)) return error.InvalidPath;
    var it = std.mem.splitAny(u8, sub_path, "/\\");
    while (it.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return error.InvalidPath;
    }
}

fn doShutdown(ctx: ?*anyopaque) void {
    const self: *FileJsonl = @ptrCast(@alignCast(ctx.?));
    self.file.sync(self.io) catch {};
}

fn doFlush(ctx: ?*anyopaque, _: u64) anyerror!void {
    const self: *FileJsonl = @ptrCast(@alignCast(ctx.?));
    try self.file.sync(self.io);
}

fn writeLine(self: *FileJsonl, payload: []const u8) !void {
    try self.file.writeStreamingAll(self.io, payload);
    try self.file.writeStreamingAll(self.io, "\n");
}

fn expSpans(ctx: ?*anyopaque, items: []const exp.SpanData) anyerror!exp.SpanExportResult {
    const self: *FileJsonl = @ptrCast(@alignCast(ctx.?));
    for (items) |span| {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const json = try json_codec.spanToJson(arena.allocator(), span);
        try writeLine(self, json);
    }
    return .success;
}

fn expLogs(ctx: ?*anyopaque, items: []const exp.LogData) anyerror!exp.SpanExportResult {
    const self: *FileJsonl = @ptrCast(@alignCast(ctx.?));
    for (items) |l| {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const json = try json_codec.logToJson(arena.allocator(), l);
        try writeLine(self, json);
    }
    return .success;
}

test "validateSubPath rejects parent traversal" {
    try std.testing.expectError(error.InvalidPath, validateSubPath("../escape.txt"));
    try std.testing.expectError(error.InvalidPath, validateSubPath("a/b/../c"));
    try std.testing.expectError(error.InvalidPath, validateSubPath(".."));
}

test "validateSubPath rejects absolute paths" {
    try std.testing.expectError(error.InvalidPath, validateSubPath("/etc/cron.d/x"));
}

test "validateSubPath rejects empty" {
    try std.testing.expectError(error.InvalidPath, validateSubPath(""));
}

test "validateSubPath accepts relative paths" {
    try validateSubPath("spans.jsonl");
    try validateSubPath("logs/spans.jsonl");
    try validateSubPath("foo/..bar/baz.txt"); // real filename component starting with ..
}
