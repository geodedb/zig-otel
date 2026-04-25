// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// File JSONL exporter — appends one JSON record per line to the
// configured file path. Useful for sidecar/Fluent Bit pipelines.

const std = @import("std");
const exp = @import("../sdk/export.zig");
const json_codec = @import("../internal/json_codec.zig");

pub const FileJsonl = struct {
    allocator: std.mem.Allocator,
    file: std.fs.File,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !FileJsonl {
        const file = try std.fs.cwd().createFile(path, .{ .truncate = false, .read = false });
        try file.seekFromEnd(0);
        return .{ .allocator = allocator, .file = file };
    }

    pub fn close(self: *FileJsonl) void {
        self.file.close();
    }

    pub fn spanExporter(self: *FileJsonl) exp.SpanExporter {
        return .{ .ctx = self, .exportFn = expSpans, .shutdownFn = doShutdown, .forceFlushFn = doFlush };
    }

    pub fn logExporter(self: *FileJsonl) exp.LogExporter {
        return .{ .ctx = self, .exportFn = expLogs, .shutdownFn = doShutdown, .forceFlushFn = doFlush };
    }
};

fn doShutdown(ctx: ?*anyopaque) void {
    const self: *FileJsonl = @ptrCast(@alignCast(ctx.?));
    self.file.sync() catch {};
}

fn doFlush(ctx: ?*anyopaque, _: u64) anyerror!void {
    const self: *FileJsonl = @ptrCast(@alignCast(ctx.?));
    try self.file.sync();
}

fn writeLine(self: *FileJsonl, payload: []const u8) !void {
    try self.file.writeAll(payload);
    try self.file.writeAll("\n");
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
