// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// GAP-OTLP-LOG-EXPORT (gitlab #8) — golden + behavioural tests for the
// OTLP/HTTP and OTLP/gRPC log export paths.
//
// The tests pin:
//   1. `logExporter()` posts to `/v1/logs` (not `/v1/traces`).
//   2. The proto encoder pins the canonical OTLP 1.10.0 wire shape:
//      - ExportLogsServiceRequest.resource_logs = 1
//      - ResourceLogs.resource = 1, scope_logs = 2, schema_url = 3
//      - ScopeLogs.scope = 1, log_records = 2, schema_url = 3
//      - LogRecord field numbers per
//        `third_party/opentelemetry-proto-v1.10.0/opentelemetry/proto/logs/v1/logs.proto`:
//        time_unix_nano = 1 (fixed64), severity_number = 2 (varint),
//        severity_text = 3, body = 5 (AnyValue), attributes = 6,
//        dropped_attributes_count = 7, flags = 8 (fixed32),
//        trace_id = 9 (bytes), span_id = 10 (bytes),
//        observed_time_unix_nano = 11 (fixed64), event_name = 12.
//   3. Multi-scope batches collapse into one `ScopeLogs` per scope.
//   4. Logger -> SimpleLogProcessor -> OTLP/HTTP via in-memory transport
//      end-to-end: `Logger.emit` produces a wire-encoded request that the
//      transport seam captures.
//   5. (When `-Dotel_use_devnw_protobuf=true`) DevNW protobuf parity:
//      `encodeLogsProtoDevnw` produces byte-identical output to
//      `encodeLogsProto` for canonical inputs.

const std = @import("std");
const otel = @import("otel");
const build_options = @import("build_options");

// ---------------- minimal protobuf reader (mirrors otlp_spans_multi_scope) ----

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn eof(self: *const Reader) bool {
        return self.pos >= self.buf.len;
    }

    fn readVarint(self: *Reader) !u64 {
        var v: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (self.pos >= self.buf.len) return error.Truncated;
            const b = self.buf[self.pos];
            self.pos += 1;
            v |= (@as(u64, b & 0x7f)) << shift;
            if (b & 0x80 == 0) return v;
            shift += 7;
            if (shift >= 64) return error.VarintOverflow;
        }
    }

    fn readTag(self: *Reader) !struct { field: u32, wire: u3 } {
        const tag = try self.readVarint();
        return .{
            .field = @intCast(tag >> 3),
            .wire = @intCast(tag & 0x7),
        };
    }

    fn readBytes(self: *Reader) ![]const u8 {
        const n = try self.readVarint();
        if (self.pos + n > self.buf.len) return error.Truncated;
        const out = self.buf[self.pos .. self.pos + @as(usize, @intCast(n))];
        self.pos += @intCast(n);
        return out;
    }

    fn readFixed64(self: *Reader) !u64 {
        if (self.pos + 8 > self.buf.len) return error.Truncated;
        const v = std.mem.readInt(u64, self.buf[self.pos..][0..8], .little);
        self.pos += 8;
        return v;
    }

    fn readFixed32(self: *Reader) !u32 {
        if (self.pos + 4 > self.buf.len) return error.Truncated;
        const v = std.mem.readInt(u32, self.buf[self.pos..][0..4], .little);
        self.pos += 4;
        return v;
    }

    fn skip(self: *Reader, wire: u3) !void {
        switch (wire) {
            0 => _ = try self.readVarint(),
            1 => {
                if (self.pos + 8 > self.buf.len) return error.Truncated;
                self.pos += 8;
            },
            2 => _ = try self.readBytes(),
            5 => {
                if (self.pos + 4 > self.buf.len) return error.Truncated;
                self.pos += 4;
            },
            else => return error.UnsupportedWireType,
        }
    }
};

// Decoded fields we care about for the assertions.
const DecodedRecord = struct {
    time_unix_nano: u64 = 0,
    observed_time_unix_nano: u64 = 0,
    severity_number: u64 = 0,
    severity_text: []const u8 = "",
    body_string: []const u8 = "",
    body_int: ?i64 = null,
    body_double: ?f64 = null,
    flags: u32 = 0,
    trace_id: []const u8 = "",
    span_id: []const u8 = "",
    event_name: []const u8 = "",
};

const ScopeBlock = struct {
    name: []const u8,
    version: []const u8,
    schema_url: []const u8,
    records: std.ArrayList(DecodedRecord),
};

fn decodeBody(record: *DecodedRecord, body_bytes: []const u8) !void {
    var r: Reader = .{ .buf = body_bytes };
    while (!r.eof()) {
        const t = try r.readTag();
        switch (t.field) {
            1 => record.body_string = try r.readBytes(), // string_value
            3 => {
                // int_value (sint64 zigzag)
                const z = try r.readVarint();
                const signed: i64 = @bitCast((z >> 1) ^ (~(z & 1) +% 1));
                record.body_int = signed;
            },
            4 => {
                const bits = try r.readFixed64();
                record.body_double = @bitCast(bits);
            },
            else => try r.skip(t.wire),
        }
    }
}

fn decodeLogRecord(arena: std.mem.Allocator, lr_bytes: []const u8) !DecodedRecord {
    _ = arena;
    var record: DecodedRecord = .{};
    var r: Reader = .{ .buf = lr_bytes };
    while (!r.eof()) {
        const t = try r.readTag();
        switch (t.field) {
            1 => record.time_unix_nano = try r.readFixed64(),
            2 => record.severity_number = try r.readVarint(),
            3 => record.severity_text = try r.readBytes(),
            5 => {
                const body_bytes = try r.readBytes();
                try decodeBody(&record, body_bytes);
            },
            8 => record.flags = try r.readFixed32(),
            9 => record.trace_id = try r.readBytes(),
            10 => record.span_id = try r.readBytes(),
            11 => record.observed_time_unix_nano = try r.readFixed64(),
            12 => record.event_name = try r.readBytes(),
            else => try r.skip(t.wire),
        }
    }
    return record;
}

fn decodeScopeBlocks(arena: std.mem.Allocator, payload: []const u8) ![]ScopeBlock {
    var blocks: std.ArrayList(ScopeBlock) = .empty;

    var top: Reader = .{ .buf = payload };
    while (!top.eof()) {
        const tag = try top.readTag();
        if (tag.field == 1 and tag.wire == 2) { // ResourceLogs
            const rl_bytes = try top.readBytes();
            var rl: Reader = .{ .buf = rl_bytes };
            while (!rl.eof()) {
                const rt = try rl.readTag();
                if (rt.field == 2 and rt.wire == 2) { // ScopeLogs
                    const sl_bytes = try rl.readBytes();
                    var sl: Reader = .{ .buf = sl_bytes };
                    var block: ScopeBlock = .{
                        .name = "",
                        .version = "",
                        .schema_url = "",
                        .records = .empty,
                    };
                    while (!sl.eof()) {
                        const st = try sl.readTag();
                        if (st.field == 1 and st.wire == 2) { // scope
                            const sc_bytes = try sl.readBytes();
                            var sc: Reader = .{ .buf = sc_bytes };
                            while (!sc.eof()) {
                                const sct = try sc.readTag();
                                if (sct.field == 1 and sct.wire == 2) {
                                    block.name = try sc.readBytes();
                                } else if (sct.field == 2 and sct.wire == 2) {
                                    block.version = try sc.readBytes();
                                } else {
                                    try sc.skip(sct.wire);
                                }
                            }
                        } else if (st.field == 2 and st.wire == 2) { // log_records
                            const lr_bytes = try sl.readBytes();
                            const dr = try decodeLogRecord(arena, lr_bytes);
                            try block.records.append(arena, dr);
                        } else if (st.field == 3 and st.wire == 2) { // schema_url
                            block.schema_url = try sl.readBytes();
                        } else {
                            try sl.skip(st.wire);
                        }
                    }
                    try blocks.append(arena, block);
                } else {
                    try rl.skip(rt.wire);
                }
            }
        } else {
            try top.skip(tag.wire);
        }
    }
    return blocks.toOwnedSlice(arena);
}

// ---------------- helpers ----------------

fn mkLogData(record: otel.api.logs.LogRecord, scope: otel.api.trace.InstrumentationScope, resource: *const otel.sdk.resource.Resource) otel.sdk.exporter.LogData {
    return .{
        .record = record,
        .instrumentation_scope = scope,
        .resource = resource,
    };
}

// ---------------- encoder unit tests ----------------

test "encodeLogsProto emits a single LogRecord with the expected fields" {
    const a = std.testing.allocator;
    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();
    try attr_set.putString("k", "v");

    const record: otel.api.logs.LogRecord = .{
        .timestamp_unix_nano = 1_700_000_000_000_000_000,
        .observed_unix_nano = 1_700_000_000_000_000_001,
        .severity = .info,
        .severity_text = "INFO",
        .body = .{ .string = "hello world" },
        .attributes = &attr_set,
        .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
        .span_id = .{ .bytes = .{ 17, 18, 19, 20, 21, 22, 23, 24 } },
        .flags = .{ .sampled = true },
    };
    const items = [_]otel.sdk.exporter.LogData{
        mkLogData(record, .{ .name = "scope", .version = "1.0" }, &resource),
    };
    const out = try otel.exporters.otlp_http.encodeLogsProto(a, &items);
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const blocks = try decodeScopeBlocks(arena.allocator(), out);

    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("scope", blocks[0].name);
    try std.testing.expectEqualStrings("1.0", blocks[0].version);
    try std.testing.expectEqual(@as(usize, 1), blocks[0].records.items.len);

    const dr = blocks[0].records.items[0];
    try std.testing.expectEqual(@as(u64, 1_700_000_000_000_000_000), dr.time_unix_nano);
    try std.testing.expectEqual(@as(u64, 1_700_000_000_000_000_001), dr.observed_time_unix_nano);
    try std.testing.expectEqual(@as(u64, @intFromEnum(otel.api.logs.Severity.info)), dr.severity_number);
    try std.testing.expectEqualStrings("INFO", dr.severity_text);
    try std.testing.expectEqualStrings("hello world", dr.body_string);
    try std.testing.expectEqual(@as(u32, 1), dr.flags); // sampled bit
    try std.testing.expectEqual(@as(usize, 16), dr.trace_id.len);
    try std.testing.expectEqual(@as(u8, 1), dr.trace_id[0]);
    try std.testing.expectEqual(@as(u8, 16), dr.trace_id[15]);
    try std.testing.expectEqual(@as(usize, 8), dr.span_id.len);
    try std.testing.expectEqual(@as(u8, 17), dr.span_id[0]);
    try std.testing.expectEqual(@as(u8, 24), dr.span_id[7]);
}

test "encodeLogsProto encodes int and double bodies via AnyValue oneof" {
    const a = std.testing.allocator;
    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();

    const record_int: otel.api.logs.LogRecord = .{
        .timestamp_unix_nano = 1,
        .observed_unix_nano = 2,
        .body = .{ .int = -42 },
    };
    const record_double: otel.api.logs.LogRecord = .{
        .timestamp_unix_nano = 3,
        .observed_unix_nano = 4,
        .body = .{ .double = 3.5 },
    };
    const scope: otel.api.trace.InstrumentationScope = .{ .name = "s" };
    const items = [_]otel.sdk.exporter.LogData{
        mkLogData(record_int, scope, &resource),
        mkLogData(record_double, scope, &resource),
    };
    const out = try otel.exporters.otlp_http.encodeLogsProto(a, &items);
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const blocks = try decodeScopeBlocks(arena.allocator(), out);
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqual(@as(usize, 2), blocks[0].records.items.len);

    try std.testing.expect(blocks[0].records.items[0].body_int != null);
    try std.testing.expectEqual(@as(i64, -42), blocks[0].records.items[0].body_int.?);
    try std.testing.expect(blocks[0].records.items[1].body_double != null);
    try std.testing.expectEqual(@as(f64, 3.5), blocks[0].records.items[1].body_double.?);
}

test "encodeLogsProto groups multi-scope batches into one ScopeLogs per scope" {
    const a = std.testing.allocator;
    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();

    const scope_a: otel.api.trace.InstrumentationScope = .{ .name = "logger-a", .version = "1.0", .schema_url = "https://schema/a" };
    const scope_b: otel.api.trace.InstrumentationScope = .{ .name = "logger-b", .version = "2.0" };
    const scope_c: otel.api.trace.InstrumentationScope = .{ .name = "logger-c", .version = "3.0" };

    var items: [15]otel.sdk.exporter.LogData = undefined;
    var i: usize = 0;
    while (i < 5) : (i += 1) {
        items[i] = mkLogData(.{
            .timestamp_unix_nano = 1000 + @as(u64, i),
            .observed_unix_nano = 2000 + @as(u64, i),
            .severity = .info,
            .body = .{ .string = "a" },
        }, scope_a, &resource);
    }
    while (i < 10) : (i += 1) {
        items[i] = mkLogData(.{
            .timestamp_unix_nano = 1000 + @as(u64, i),
            .observed_unix_nano = 2000 + @as(u64, i),
            .severity = .warn,
            .body = .{ .string = "b" },
        }, scope_b, &resource);
    }
    while (i < 15) : (i += 1) {
        items[i] = mkLogData(.{
            .timestamp_unix_nano = 1000 + @as(u64, i),
            .observed_unix_nano = 2000 + @as(u64, i),
            .severity = .err,
            .body = .{ .string = "c" },
        }, scope_c, &resource);
    }

    const out = try otel.exporters.otlp_http.encodeLogsProto(a, &items);
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const blocks = try decodeScopeBlocks(arena.allocator(), out);

    try std.testing.expectEqual(@as(usize, 3), blocks.len);
    try std.testing.expectEqualStrings("logger-a", blocks[0].name);
    try std.testing.expectEqualStrings("https://schema/a", blocks[0].schema_url);
    try std.testing.expectEqual(@as(usize, 5), blocks[0].records.items.len);
    try std.testing.expectEqualStrings("logger-b", blocks[1].name);
    try std.testing.expectEqual(@as(usize, 5), blocks[1].records.items.len);
    try std.testing.expectEqualStrings("logger-c", blocks[2].name);
    try std.testing.expectEqual(@as(usize, 5), blocks[2].records.items.len);
}

test "encodeLogsProto encodes a 2-scope batch with attributes via shared writeKeyValue" {
    // QN-NEW-3 guard: after sharing ScopeKey3 + writeKeyValue between the
    // span and log encoders, a 2-scope log batch with attributes must still
    // encode byte-correctly. Decodes the log-record attribute (field 6) to
    // prove the shared key/value writer survived the refactor.
    const a = std.testing.allocator;
    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();

    var attrs_a = otel.internal.attributes.AttributeSet.init(a);
    defer attrs_a.deinit();
    try attrs_a.putString("tenant", "acme");

    const scope_a: otel.api.trace.InstrumentationScope = .{ .name = "logger-a", .version = "1.0" };
    const scope_b: otel.api.trace.InstrumentationScope = .{ .name = "logger-b", .version = "2.0" };

    const items = [_]otel.sdk.exporter.LogData{
        mkLogData(.{
            .timestamp_unix_nano = 10,
            .observed_unix_nano = 11,
            .severity = .info,
            .body = .{ .string = "a" },
            .attributes = &attrs_a,
        }, scope_a, &resource),
        mkLogData(.{
            .timestamp_unix_nano = 20,
            .observed_unix_nano = 21,
            .severity = .warn,
            .body = .{ .string = "b" },
        }, scope_b, &resource),
    };

    const out = try otel.exporters.otlp_http.encodeLogsProto(a, &items);
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const blocks = try decodeScopeBlocks(arena.allocator(), out);

    try std.testing.expectEqual(@as(usize, 2), blocks.len);
    try std.testing.expectEqualStrings("logger-a", blocks[0].name);
    try std.testing.expectEqualStrings("logger-b", blocks[1].name);
    try std.testing.expectEqual(@as(usize, 1), blocks[0].records.items.len);
    try std.testing.expectEqual(@as(usize, 1), blocks[1].records.items.len);

    // Re-decode the first record to extract its attribute key/value.
    var found_key: []const u8 = "";
    var found_val: []const u8 = "";
    {
        // Walk the raw payload again, descending to the first log record's
        // attributes (field 6 -> KeyValue{ key=1, value=2 -> string=1 }).
        var top: Reader = .{ .buf = out };
        outer: while (!top.eof()) {
            const tag = try top.readTag();
            if (tag.field == 1 and tag.wire == 2) {
                var rl: Reader = .{ .buf = try top.readBytes() };
                while (!rl.eof()) {
                    const rt = try rl.readTag();
                    if (rt.field == 2 and rt.wire == 2) {
                        var sl: Reader = .{ .buf = try rl.readBytes() };
                        while (!sl.eof()) {
                            const st = try sl.readTag();
                            if (st.field == 2 and st.wire == 2) { // log_records
                                var lr: Reader = .{ .buf = try sl.readBytes() };
                                while (!lr.eof()) {
                                    const lt = try lr.readTag();
                                    if (lt.field == 6 and lt.wire == 2) { // attribute KeyValue
                                        var kv: Reader = .{ .buf = try lr.readBytes() };
                                        while (!kv.eof()) {
                                            const kt = try kv.readTag();
                                            if (kt.field == 1 and kt.wire == 2) {
                                                found_key = try kv.readBytes();
                                            } else if (kt.field == 2 and kt.wire == 2) {
                                                var av: Reader = .{ .buf = try kv.readBytes() };
                                                while (!av.eof()) {
                                                    const at = try av.readTag();
                                                    if (at.field == 1 and at.wire == 2) {
                                                        found_val = try av.readBytes();
                                                    } else try av.skip(at.wire);
                                                }
                                            } else try kv.skip(kt.wire);
                                        }
                                        break :outer;
                                    } else try lr.skip(lt.wire);
                                }
                            } else try sl.skip(st.wire);
                        }
                    } else try rl.skip(rt.wire);
                }
            } else try top.skip(tag.wire);
        }
    }
    try std.testing.expectEqualStrings("tenant", found_key);
    try std.testing.expectEqualStrings("acme", found_val);
}

test "encodeLogsProto skips invalid trace_id and span_id" {
    const a = std.testing.allocator;
    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();

    const record: otel.api.logs.LogRecord = .{
        .timestamp_unix_nano = 100,
        .observed_unix_nano = 200,
        .severity = .info,
        .body = .{ .string = "no trace" },
        // trace_id and span_id default to .invalid (all zeros).
    };
    const items = [_]otel.sdk.exporter.LogData{
        mkLogData(record, .{ .name = "s" }, &resource),
    };
    const out = try otel.exporters.otlp_http.encodeLogsProto(a, &items);
    defer a.free(out);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const blocks = try decodeScopeBlocks(arena.allocator(), out);
    try std.testing.expectEqual(@as(usize, 1), blocks[0].records.items.len);
    const dr = blocks[0].records.items[0];
    try std.testing.expectEqual(@as(usize, 0), dr.trace_id.len);
    try std.testing.expectEqual(@as(usize, 0), dr.span_id.len);
}

test "encodeLogsProto handles empty input" {
    const out = try otel.exporters.otlp_http.encodeLogsProto(std.testing.allocator, &.{});
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// ---------------- HTTP transport tests ----------------

const fake = struct {
    var attempts: u32 = 0;
    var last_path: [64]u8 = undefined;
    var last_path_len: usize = 0;
    var last_content_type: [64]u8 = undefined;
    var last_content_type_len: usize = 0;
    var last_body: [4096]u8 = undefined;
    var last_body_len: usize = 0;
};

fn fakeTransport(
    _: std.mem.Allocator,
    _: []const u8,
    path: []const u8,
    _: ?[]const u8,
    content_type: []const u8,
    body: []const u8,
    _: u64,
) anyerror!otel.exporters.otlp_http.TransportResult {
    fake.attempts += 1;
    fake.last_path_len = @min(path.len, fake.last_path.len);
    @memcpy(fake.last_path[0..fake.last_path_len], path[0..fake.last_path_len]);
    fake.last_content_type_len = @min(content_type.len, fake.last_content_type.len);
    @memcpy(fake.last_content_type[0..fake.last_content_type_len], content_type[0..fake.last_content_type_len]);
    fake.last_body_len = @min(body.len, fake.last_body.len);
    @memcpy(fake.last_body[0..fake.last_body_len], body[0..fake.last_body_len]);
    return .{ .status = 200, .body = "" };
}

fn resetFake() void {
    fake.attempts = 0;
    fake.last_path_len = 0;
    fake.last_content_type_len = 0;
    fake.last_body_len = 0;
}

test "OTLP/HTTP log exporter posts to /v1/logs with protobuf body" {
    if (build_options.otel_disabled) return error.SkipZigTest;
    resetFake();
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();

    var exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(a, .{
        .endpoint = "http://localhost:4318",
        .protocol = .http_protobuf,
        .timeout_ms = 100,
    });
    exporter.transport = .{ .custom = fakeTransport };
    defer exporter.deinit();

    const record: otel.api.logs.LogRecord = .{
        .timestamp_unix_nano = 1,
        .observed_unix_nano = 2,
        .severity = .info,
        .body = .{ .string = "via-http" },
    };
    const items = [_]otel.sdk.exporter.LogData{
        mkLogData(record, .{ .name = "s" }, &resource),
    };
    const result = try exporter.logExporter().exportLogs(&items);
    try std.testing.expectEqual(otel.sdk.exporter.SpanExportResult.success, result);

    try std.testing.expectEqualStrings("/v1/logs", fake.last_path[0..fake.last_path_len]);
    try std.testing.expectEqualStrings("application/x-protobuf", fake.last_content_type[0..fake.last_content_type_len]);
    try std.testing.expect(fake.last_body_len > 0);
}

test "OTLP/HTTP log exporter posts to /v1/logs with JSON body" {
    if (build_options.otel_disabled) return error.SkipZigTest;
    resetFake();
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();

    var exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(a, .{
        .endpoint = "http://localhost:4318",
        .protocol = .http_json,
        .timeout_ms = 100,
    });
    exporter.transport = .{ .custom = fakeTransport };
    defer exporter.deinit();

    const record: otel.api.logs.LogRecord = .{
        .timestamp_unix_nano = 1,
        .observed_unix_nano = 2,
        .severity = .info,
        .body = .{ .string = "json-body" },
    };
    const items = [_]otel.sdk.exporter.LogData{
        mkLogData(record, .{ .name = "s" }, &resource),
    };
    const result = try exporter.logExporter().exportLogs(&items);
    try std.testing.expectEqual(otel.sdk.exporter.SpanExportResult.success, result);

    try std.testing.expectEqualStrings("/v1/logs", fake.last_path[0..fake.last_path_len]);
    try std.testing.expectEqualStrings("application/json", fake.last_content_type[0..fake.last_content_type_len]);
    try std.testing.expect(fake.last_body_len > 0);
    // JSON envelope sanity check: must contain `resourceLogs` key.
    try std.testing.expect(std.mem.indexOf(u8, fake.last_body[0..fake.last_body_len], "resourceLogs") != null);
}

// ---------------- end-to-end Logger -> exporter test ----------------

test "Logger emits LogRecord that flows through SimpleLogProcessor to OTLP/HTTP" {
    if (build_options.otel_disabled) return error.SkipZigTest;
    resetFake();
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();

    var exporter = try otel.exporters.otlp_http.OtlpHttpExporter.init(a, .{
        .endpoint = "http://localhost:4318",
        .protocol = .http_protobuf,
        .timeout_ms = 100,
    });
    exporter.transport = .{ .custom = fakeTransport };
    defer exporter.deinit();

    var lp = try otel.sdk.logs.LoggerProvider.init(a, .{
        .resource = &resource,
        .default_exporter = exporter.logExporter(),
    });
    defer lp.deinit();

    const lg = lp.logger(.{ .name = "demo.logger", .version = "1.0" });
    lg.emit(.{
        .timestamp_unix_nano = 1_700_000_000_000_000_000,
        .observed_unix_nano = 1_700_000_000_000_000_001,
        .severity = .info,
        .body = .{ .string = "hello" },
    });

    try std.testing.expectEqual(@as(u32, 1), fake.attempts);
    try std.testing.expectEqualStrings("/v1/logs", fake.last_path[0..fake.last_path_len]);

    // Decode the captured wire bytes and assert the LogRecord content.
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const body = fake.last_body[0..fake.last_body_len];
    const blocks = try decodeScopeBlocks(arena.allocator(), body);
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("demo.logger", blocks[0].name);
    try std.testing.expectEqual(@as(usize, 1), blocks[0].records.items.len);
    try std.testing.expectEqualStrings("hello", blocks[0].records.items[0].body_string);
    try std.testing.expectEqual(@as(u64, 1_700_000_000_000_000_000), blocks[0].records.items[0].time_unix_nano);
    try std.testing.expectEqual(@as(u64, 1_700_000_000_000_000_001), blocks[0].records.items[0].observed_time_unix_nano);
}

// ---------------- DevNW protobuf parity ----------------

test "encodeLogsProtoDevnw matches in-repo encoder for a canonical input" {
    if (!build_options.use_devnw_protobuf) return error.SkipZigTest;
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();
    var attr_set = otel.internal.attributes.AttributeSet.init(a);
    defer attr_set.deinit();
    try attr_set.putString("k", "v");

    const record: otel.api.logs.LogRecord = .{
        .timestamp_unix_nano = 100,
        .observed_unix_nano = 200,
        .severity = .info,
        .severity_text = "INFO",
        .body = .{ .string = "parity" },
        .attributes = &attr_set,
        .trace_id = .{ .bytes = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 } },
        .span_id = .{ .bytes = .{ 9, 8, 7, 6, 5, 4, 3, 2 } },
        .flags = .{ .sampled = true },
    };
    const items = [_]otel.sdk.exporter.LogData{
        mkLogData(record, .{ .name = "scope", .version = "1.0" }, &resource),
    };

    const lhs = try otel.exporters.otlp_http.encodeLogsProto(a, &items);
    defer a.free(lhs);
    const rhs = try otel.exporters.otlp_http.encodeLogsProtoDevnw(a, &items);
    defer a.free(rhs);
    try std.testing.expectEqualSlices(u8, lhs, rhs);
}

test "encodeLogsProtoDevnw matches in-repo encoder for multi-scope batches" {
    if (!build_options.use_devnw_protobuf) return error.SkipZigTest;
    const a = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(a);
    defer resource.deinit();

    const scope_a: otel.api.trace.InstrumentationScope = .{ .name = "logger-a", .version = "1.0" };
    const scope_b: otel.api.trace.InstrumentationScope = .{ .name = "logger-b", .version = "2.0" };

    const items = [_]otel.sdk.exporter.LogData{
        mkLogData(.{ .timestamp_unix_nano = 1, .observed_unix_nano = 2, .body = .{ .string = "alpha" } }, scope_a, &resource),
        mkLogData(.{ .timestamp_unix_nano = 3, .observed_unix_nano = 4, .body = .{ .string = "beta" } }, scope_b, &resource),
        mkLogData(.{ .timestamp_unix_nano = 5, .observed_unix_nano = 6, .body = .{ .string = "gamma" } }, scope_a, &resource),
    };

    const lhs = try otel.exporters.otlp_http.encodeLogsProto(a, &items);
    defer a.free(lhs);
    const rhs = try otel.exporters.otlp_http.encodeLogsProtoDevnw(a, &items);
    defer a.free(rhs);
    try std.testing.expectEqualSlices(u8, lhs, rhs);
}
