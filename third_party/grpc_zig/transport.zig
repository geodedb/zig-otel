const std = @import("std");
const net = std.Io.net;
const http2 = struct {
    pub const connection = @import("http2/connection.zig");
    pub const frame = @import("http2/frame.zig");
    pub const stream = @import("http2/stream.zig");
};

pub const TransportError = error{
    ConnectionClosed,
    InvalidHeader,
    PayloadTooLarge,
    CompressionNotSupported,
    Http2Error,
};

/// HPACK dynamic table entry for tracking :path values across requests.
const HpackDynEntry = struct {
    is_path: bool = false,
    path: [128]u8 = .{0} ** 128,
    path_len: usize = 0,
};

const HPACK_DYN_MAX = 128;

/// I/O abstraction for TLS-wrapped connections.
/// The caller provides opaque context and function pointers for read/write/close.
pub const TlsIo = struct {
    ctx: *anyopaque,
    read_fn: *const fn (*anyopaque, []u8) anyerror!usize,
    write_fn: *const fn (*anyopaque, []const u8) anyerror!usize,
    close_fn: *const fn (*anyopaque) void,
};

pub const Transport = struct {
    stream: net.Stream,
    io: std.Io,
    tls_io: ?TlsIo = null,
    read_buf: []u8,
    write_buf: []u8,
    allocator: std.mem.Allocator,
    http2_conn: ?http2.connection.Connection,
    /// Track the stream ID from the client's HEADERS frame for responses
    last_stream_id: u31,
    /// The gRPC method path extracted from the last HEADERS frame (e.g. "/geode.GeodeService/Handshake")
    last_method: [256]u8 = .{0} ** 256,
    last_method_len: usize = 0,
    /// HPACK dynamic table (ring buffer, newest entry at hpack_dyn_head)
    hpack_dyn: [HPACK_DYN_MAX]HpackDynEntry = [_]HpackDynEntry{.{}} ** HPACK_DYN_MAX,
    hpack_dyn_count: usize = 0,
    hpack_dyn_head: usize = 0,

    pub fn initClient(allocator: std.mem.Allocator, io: std.Io, stream_: net.Stream) !Transport {
        const read_buf = try allocator.alloc(u8, 1024 * 64);
        errdefer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, 1024 * 64);
        errdefer allocator.free(write_buf);

        var trans = Transport{
            .stream = stream_,
            .io = io,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .allocator = allocator,
            .http2_conn = null,
            .last_stream_id = 1,
            .last_method = .{0} ** 256,
            .last_method_len = 0,
        };

        // Initialize HTTP/2 connection
        trans.http2_conn = try http2.connection.Connection.init(allocator);
        errdefer trans.http2_conn.?.deinit();
        try trans.setupHttp2Client();

        return trans;
    }

    pub fn initServer(allocator: std.mem.Allocator, io: std.Io, stream_: net.Stream) !Transport {
        const read_buf = try allocator.alloc(u8, 1024 * 64);
        errdefer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, 1024 * 64);
        errdefer allocator.free(write_buf);

        var trans = Transport{
            .stream = stream_,
            .io = io,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .allocator = allocator,
            .http2_conn = null,
            .last_stream_id = 1,
            .last_method = .{0} ** 256,
            .last_method_len = 0,
        };

        // Initialize HTTP/2 connection
        trans.http2_conn = try http2.connection.Connection.init(allocator);
        errdefer trans.http2_conn.?.deinit();
        try trans.setupHttp2Server();

        return trans;
    }

    pub fn initServerTls(allocator: std.mem.Allocator, io: std.Io, stream_: net.Stream, tls_io_: TlsIo) !Transport {
        const read_buf = try allocator.alloc(u8, 1024 * 64);
        errdefer allocator.free(read_buf);
        const write_buf = try allocator.alloc(u8, 1024 * 64);
        errdefer allocator.free(write_buf);

        var trans = Transport{
            .stream = stream_,
            .io = io,
            .tls_io = tls_io_,
            .read_buf = read_buf,
            .write_buf = write_buf,
            .allocator = allocator,
            .http2_conn = null,
            .last_stream_id = 1,
            .last_method = .{0} ** 256,
            .last_method_len = 0,
        };
        // If setup fails, close the TLS connection to avoid leaking the
        // SSL object and SslConn allocation.
        errdefer tls_io_.close_fn(tls_io_.ctx);

        // Initialize HTTP/2 connection
        trans.http2_conn = try http2.connection.Connection.init(allocator);
        errdefer trans.http2_conn.?.deinit();
        try trans.setupHttp2Server();

        return trans;
    }

    fn ioRead(self: *Transport, buf: []u8) !usize {
        if (self.tls_io) |tio| return tio.read_fn(tio.ctx, buf);
        var bufs = [_][]u8{buf};
        return self.io.vtable.netRead(self.io.userdata, self.stream.socket.handle, &bufs);
    }

    fn ioWrite(self: *Transport, data: []const u8) !usize {
        if (self.tls_io) |tio| return tio.write_fn(tio.ctx, data);
        // Patched for the otel umbrella: upstream passes `&.{}` as the
        // iovec slice, which makes `netWritePosix` underflow when it
        // computes `data[data.len - 1]` (the stdlib API expects at
        // least one element so it can identify the trailing splat
        // pattern). Pass the payload as a single-element iovec with an
        // empty header and splat=0; that writes exactly `data` once
        // and matches the stdlib contract. See
        // `third_party/grpc_zig/all.zig` for why this file is
        // duplicated rather than referenced upstream.
        const iov = [_][]const u8{data};
        return self.io.vtable.netWrite(self.io.userdata, self.stream.socket.handle, "", &iov, 0);
    }

    fn ioClose(self: *Transport) void {
        if (self.tls_io) |tio| tio.close_fn(tio.ctx);
        self.stream.close(self.io);
    }

    pub fn deinit(self: *Transport) void {
        if (self.http2_conn) |*conn| {
            conn.deinit();
        }
        self.allocator.free(self.read_buf);
        self.allocator.free(self.write_buf);
        self.ioClose();
    }

    fn setupHttp2Client(self: *Transport) !void {
        // Client sends HTTP/2 connection preface
        _ = try self.ioWrite(http2.connection.Connection.PREFACE);

        // Send initial SETTINGS frame
        const settings_header: [9]u8 = .{
            0, 0, 0, // length: 0 (no settings parameters)
            @intFromEnum(http2.frame.FrameType.SETTINGS),
            0, // flags: none
            0, 0, 0, 0, // stream_id: 0
        };
        _ = try self.ioWrite(&settings_header);
    }

    /// Read exactly `buf.len` bytes from the stream, handling partial reads.
    fn readExact(self: *Transport, buf: []u8) !void {
        var total: usize = 0;
        while (total < buf.len) {
            const n = try self.ioRead(buf[total..]);
            if (n == 0) return TransportError.ConnectionClosed;
            total += n;
        }
    }

    /// Read a single HTTP/2 frame header and payload.
    /// Returns frame_type, flags, stream_id, and allocated payload.
    fn readFrame(self: *Transport) !struct { frame_type: u8, flags: u8, stream_id: u31, payload: []u8 } {
        var header: [9]u8 = undefined;
        try self.readExact(&header);

        const length: u24 = (@as(u24, header[0]) << 16) | (@as(u24, header[1]) << 8) | @as(u24, header[2]);
        const frame_type = header[3];
        const flags = header[4];
        const stream_id: u31 = @intCast(
            (@as(u32, header[5] & 0x7F) << 24) |
                (@as(u32, header[6]) << 16) |
                (@as(u32, header[7]) << 8) |
                @as(u32, header[8]),
        );

        const payload = try self.allocator.alloc(u8, length);
        errdefer self.allocator.free(payload);

        if (length > 0) {
            try self.readExact(payload);
        }

        return .{ .frame_type = frame_type, .flags = flags, .stream_id = stream_id, .payload = payload };
    }

    /// Write an HTTP/2 frame with the given type, flags, stream ID, and payload.
    fn writeFrame(self: *Transport, frame_type: http2.frame.FrameType, flags: u8, stream_id: u31, payload: []const u8) !void {
        const length: u24 = @intCast(payload.len);
        var header: [9]u8 = undefined;
        header[0] = @intCast((length >> 16) & 0xFF);
        header[1] = @intCast((length >> 8) & 0xFF);
        header[2] = @intCast(length & 0xFF);
        header[3] = @intFromEnum(frame_type);
        header[4] = flags;
        header[5] = @intCast((@as(u32, stream_id) >> 24) & 0x7F);
        header[6] = @intCast((@as(u32, stream_id) >> 16) & 0xFF);
        header[7] = @intCast((@as(u32, stream_id) >> 8) & 0xFF);
        header[8] = @intCast(@as(u32, stream_id) & 0xFF);

        _ = try self.ioWrite(&header);
        if (payload.len > 0) {
            _ = try self.ioWrite(payload);
        }
    }

    fn setupHttp2Server(self: *Transport) !void {
        // Server receives and validates HTTP/2 connection preface
        var preface_buf: [24]u8 = undefined;
        try self.readExact(&preface_buf);

        // Validate preface
        if (!std.mem.eql(u8, &preface_buf, http2.connection.Connection.PREFACE)) {
            return TransportError.Http2Error;
        }

        // Read client's initial SETTINGS frame
        const frame = try self.readFrame();
        defer self.allocator.free(frame.payload);

        if (frame.frame_type != @intFromEnum(http2.frame.FrameType.SETTINGS)) {
            return TransportError.Http2Error;
        }

        // Send server's SETTINGS frame (empty = use defaults)
        try self.writeFrame(.SETTINGS, 0, 0, &.{});

        // Send SETTINGS ACK for client's settings
        try self.writeFrame(.SETTINGS, 0x1, 0, &.{});
    }

    /// Read the next gRPC message from the connection.
    /// Handles standard gRPC framing: skips HEADERS, SETTINGS, WINDOW_UPDATE,
    /// PING frames, and extracts the protobuf payload from DATA frames by
    /// stripping the 5-byte gRPC length-prefixed message header.
    pub fn readMessage(self: *Transport) ![]const u8 {
        while (true) {
            const frame = try self.readFrame();
            const frame_type = frame.frame_type;
            const payload = frame.payload;

            switch (frame_type) {
                @intFromEnum(http2.frame.FrameType.DATA) => {
                    // gRPC DATA frame: [1 byte compressed flag][4 bytes msg length][protobuf...]
                    if (payload.len >= 5) {
                        // Strip 5-byte gRPC header, return just the protobuf message
                        const msg_len = (@as(u32, payload[1]) << 24) |
                            (@as(u32, payload[2]) << 16) |
                            (@as(u32, payload[3]) << 8) |
                            @as(u32, payload[4]);

                        if (payload.len >= 5 + msg_len) {
                            const result = self.allocator.alloc(u8, msg_len) catch {
                                self.allocator.free(payload);
                                return error.OutOfMemory;
                            };
                            @memcpy(result, payload[5 .. 5 + msg_len]);
                            self.allocator.free(payload);
                            return result;
                        }
                    }

                    // Fallback: if no gRPC header or too short, return payload as-is
                    // (for backward compat with custom clients)
                    return payload;
                },
                @intFromEnum(http2.frame.FrameType.HEADERS) => {
                    // Standard gRPC sends HEADERS before DATA. Remember the
                    // stream ID so we can respond on the same stream.
                    self.last_stream_id = frame.stream_id;
                    // Extract :path from HPACK-encoded headers
                    self.extractPathFromHpack(payload);
                    self.allocator.free(payload);
                    // Continue reading to get the DATA frame
                    continue;
                },
                @intFromEnum(http2.frame.FrameType.SETTINGS) => {
                    // Could be client's SETTINGS ACK or new SETTINGS
                    const is_ack = (frame.flags & 0x1) != 0;
                    if (!is_ack) {
                        // ACK the client's settings -- free payload before try
                        // to avoid leak if writeFrame fails
                        self.allocator.free(payload);
                        try self.writeFrame(.SETTINGS, 0x1, 0, &.{});
                    } else {
                        self.allocator.free(payload);
                    }
                    continue;
                },
                @intFromEnum(http2.frame.FrameType.WINDOW_UPDATE) => {
                    // Flow control — acknowledge and continue
                    self.allocator.free(payload);
                    continue;
                },
                @intFromEnum(http2.frame.FrameType.PING) => {
                    // Respond with PONG (PING with ACK flag)
                    // Copy payload data before freeing, since writeFrame
                    // needs the data and payload must be freed to avoid leaks
                    const is_ack = (frame.flags & 0x1) != 0;
                    if (!is_ack) {
                        var ping_data: [8]u8 = .{0} ** 8;
                        const copy_len = @min(payload.len, 8);
                        @memcpy(ping_data[0..copy_len], payload[0..copy_len]);
                        self.allocator.free(payload);
                        try self.writeFrame(.PING, 0x1, 0, ping_data[0..copy_len]);
                    } else {
                        self.allocator.free(payload);
                    }
                    continue;
                },
                @intFromEnum(http2.frame.FrameType.RST_STREAM) => {
                    self.allocator.free(payload);
                    return TransportError.ConnectionClosed;
                },
                @intFromEnum(http2.frame.FrameType.GOAWAY) => {
                    self.allocator.free(payload);
                    return TransportError.ConnectionClosed;
                },
                else => {
                    // Unknown frame type — skip
                    self.allocator.free(payload);
                    continue;
                },
            }
        }
    }

    /// Return the gRPC method path extracted from the last HEADERS frame.
    pub fn lastMethod(self: *Transport) []const u8 {
        return self.last_method[0..self.last_method_len];
    }

    /// Push a new entry to the front of the HPACK dynamic table.
    fn hpackDynPush(self: *Transport, is_path: bool) void {
        // Move head backward (ring buffer)
        if (self.hpack_dyn_count == 0) {
            self.hpack_dyn_head = 0;
        } else {
            self.hpack_dyn_head = if (self.hpack_dyn_head == 0) HPACK_DYN_MAX - 1 else self.hpack_dyn_head - 1;
        }
        self.hpack_dyn[self.hpack_dyn_head] = .{};
        if (is_path) {
            const len = @min(self.last_method_len, 128);
            @memcpy(self.hpack_dyn[self.hpack_dyn_head].path[0..len], self.last_method[0..len]);
            self.hpack_dyn[self.hpack_dyn_head].path_len = len;
            self.hpack_dyn[self.hpack_dyn_head].is_path = true;
        }
        if (self.hpack_dyn_count < HPACK_DYN_MAX) {
            self.hpack_dyn_count += 1;
        }
    }

    /// Look up a dynamic table entry by index (0 = newest).
    fn hpackDynGet(self: *Transport, dyn_idx: usize) ?*const HpackDynEntry {
        if (dyn_idx >= self.hpack_dyn_count) return null;
        const actual = (self.hpack_dyn_head + dyn_idx) % HPACK_DYN_MAX;
        return &self.hpack_dyn[actual];
    }

    /// Look up an HPACK indexed reference and set last_method if it's a :path entry.
    fn hpackLookupIndex(self: *Transport, index: usize) void {
        if (index <= 61) return; // Static table — :path entries 4,5 are "/" and "/index.html"
        const dyn_idx = index - 62;
        if (self.hpackDynGet(dyn_idx)) |entry| {
            if (entry.is_path) {
                const len = @min(entry.path_len, self.last_method.len);
                @memcpy(self.last_method[0..len], entry.path[0..len]);
                self.last_method_len = len;
            }
        }
    }

    // RFC 7541 Appendix B Huffman decode table, organized by code bit-length.
    // Each group: codes [first_code .. first_code+syms.len) map to syms[] in order.
    // Symbols are sorted by value within each group (canonical Huffman assignment).
    const HuffGroup = struct { bits: u8, first_code: u32, syms: []const u8 };
    const huff_groups = [_]HuffGroup{
        .{ .bits = 5, .first_code = 0x00, .syms = &[_]u8{ '0', '1', '2', 'a', 'c', 'e', 'i', 'o', 's', 't' } },
        .{ .bits = 6, .first_code = 0x14, .syms = &[_]u8{ ' ', '%', '-', '.', '/', '3', '4', '5', '6', '7', '8', '9', '=', 'A', '_', 'b', 'd', 'f', 'g', 'h', 'l', 'm', 'n', 'p', 'r', 'u' } },
        .{ .bits = 7, .first_code = 0x5c, .syms = &[_]u8{ ':', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'Y', 'j', 'k', 'q', 'v', 'w', 'x', 'y', 'z' } },
        .{ .bits = 8, .first_code = 0xf8, .syms = &[_]u8{ '&', '*', ',', ';', 'X', 'Z' } },
        .{ .bits = 10, .first_code = 0x3f8, .syms = &[_]u8{ '!', '"', '(', ')', '?' } },
        .{ .bits = 11, .first_code = 0x7fa, .syms = &[_]u8{ '\'', '+', '|' } },
        .{ .bits = 12, .first_code = 0xffa, .syms = &[_]u8{ '#', '>' } },
        .{ .bits = 13, .first_code = 0x1ff8, .syms = &[_]u8{ 0, '$', '@', '[', ']', '~' } },
        .{ .bits = 14, .first_code = 0x3ffc, .syms = &[_]u8{ '^', '}' } },
        .{ .bits = 15, .first_code = 0x7ffc, .syms = &[_]u8{ '<', '`' } },
        .{ .bits = 19, .first_code = 0x7fff0, .syms = &[_]u8{ '\\', '{' } },
    };

    /// Decode an RFC 7541 HPACK Huffman-encoded byte string into plaintext.
    /// Returns the number of decoded bytes written to `out`.
    fn huffmanDecode(encoded: []const u8, out: []u8) usize {
        var out_pos: usize = 0;
        var acc: u32 = 0; // bit accumulator
        var acc_bits: u8 = 0; // number of valid bits in acc

        for (encoded) |byte| {
            // Process each bit from MSB to LSB
            var b: u8 = byte;
            var bit_i: u4 = 0;
            while (bit_i < 8) : (bit_i += 1) {
                acc = (acc << 1) | ((b >> 7) & 1);
                acc_bits += 1;
                b <<= 1;

                // Try to match accumulated bits against each group
                for (huff_groups) |grp| {
                    if (acc_bits == grp.bits) {
                        if (acc >= grp.first_code and acc < grp.first_code + grp.syms.len) {
                            if (out_pos < out.len) {
                                out[out_pos] = grp.syms[acc - grp.first_code];
                                out_pos += 1;
                            }
                            acc = 0;
                            acc_bits = 0;
                            break;
                        }
                    }
                }

                // If we've accumulated too many bits without a match, stop
                // (would only happen for control chars / high bytes not in table)
                if (acc_bits > 19) return out_pos;
            }
        }
        return out_pos;
    }

    /// Decode an HPACK integer with the given prefix size.
    /// Returns the decoded value and the number of bytes consumed.
    fn hpackDecodeInt(data: []const u8, comptime prefix_bits: u4) struct { value: usize, consumed: usize } {
        if (data.len == 0) return .{ .value = 0, .consumed = 0 };
        const mask: u8 = (@as(u8, 1) << @as(u3, @intCast(prefix_bits))) - 1;
        var value: usize = data[0] & mask;
        if (value < mask) return .{ .value = value, .consumed = 1 };
        // Multi-byte integer
        var pos: usize = 1;
        var m: std.math.Log2Int(usize) = 0;
        while (pos < data.len) {
            const b = data[pos];
            value += @as(usize, b & 0x7F) << m;
            pos += 1;
            if (b & 0x80 == 0) break;
            m += 7;
        }
        return .{ .value = value, .consumed = pos };
    }

    /// Skip an HPACK string (returns bytes consumed).
    fn hpackSkipString(data: []const u8) usize {
        if (data.len == 0) return 0;
        const int_result = hpackDecodeInt(data, 7);
        return int_result.consumed + int_result.value;
    }

    /// Check if an HPACK string (plain-text, not Huffman) matches `expected`.
    fn hpackStringIs(data: []const u8, expected: []const u8) bool {
        if (data.len == 0) return false;
        const is_huffman = (data[0] & 0x80) != 0;
        if (is_huffman) return false; // only match plain-text names
        const r = hpackDecodeInt(data, 7);
        if (r.value != expected.len) return false;
        if (r.consumed + r.value > data.len) return false;
        return std.mem.eql(u8, data[r.consumed .. r.consumed + r.value], expected);
    }

    /// Extract the :path header from HPACK-encoded payload.
    /// Stores the result in last_method/last_method_len.
    /// Tracks the HPACK dynamic table so indexed references to :path work.
    fn extractPathFromHpack(self: *Transport, payload: []const u8) void {
        var pos: usize = 0;
        var found_path = false;
        while (pos < payload.len) {
            const byte = payload[pos];

            if (byte & 0x80 != 0) {
                // Indexed header field (1xxxxxxx) — look up in dynamic table
                const r = hpackDecodeInt(payload[pos..], 7);
                pos += r.consumed;
                if (!found_path) {
                    self.hpackLookupIndex(r.value);
                    if (r.value > 61) {
                        // Check if we found a :path entry
                        const dyn_idx = r.value - 62;
                        if (self.hpackDynGet(dyn_idx)) |entry| {
                            if (entry.is_path) found_path = true;
                        }
                    }
                }
            } else if (byte & 0xC0 == 0x40) {
                // Literal with incremental indexing (01xxxxxx) — adds to dynamic table
                const r = hpackDecodeInt(payload[pos..], 6);
                pos += r.consumed;
                const name_idx = r.value;
                var is_path_header = (name_idx == 4 or name_idx == 5);
                if (name_idx == 0) {
                    // Literal name — check if it's ":path" before skipping
                    if (!is_path_header) {
                        is_path_header = hpackStringIs(payload[pos..], ":path");
                    }
                    pos += hpackSkipString(payload[pos..]);
                }
                // Read value
                if (pos >= payload.len) {
                    // Still add a non-path entry to keep table in sync
                    self.hpackDynPush(false);
                    break;
                }
                if (is_path_header) {
                    // This is :path — decode and add to dynamic table
                    self.setPathFromHpackString(payload[pos..]);
                    pos += hpackSkipString(payload[pos..]);
                    self.hpackDynPush(true);
                    found_path = true;
                } else {
                    pos += hpackSkipString(payload[pos..]);
                    self.hpackDynPush(false);
                }
            } else if (byte & 0xF0 == 0x00 or byte & 0xF0 == 0x10) {
                // Literal without indexing (0000xxxx) or never indexed (0001xxxx)
                // Does NOT add to dynamic table
                const r = hpackDecodeInt(payload[pos..], 4);
                pos += r.consumed;
                const name_idx = r.value;
                var is_path_hdr = (name_idx == 4 or name_idx == 5);
                if (name_idx == 0) {
                    if (!is_path_hdr) {
                        is_path_hdr = hpackStringIs(payload[pos..], ":path");
                    }
                    pos += hpackSkipString(payload[pos..]);
                }
                if (pos >= payload.len) break;
                if (is_path_hdr) {
                    self.setPathFromHpackString(payload[pos..]);
                    found_path = true;
                }
                pos += hpackSkipString(payload[pos..]);
            } else if (byte & 0xE0 == 0x20) {
                // Dynamic table size update (001xxxxx) — skip
                const r = hpackDecodeInt(payload[pos..], 5);
                pos += r.consumed;
            } else {
                pos += 1; // unknown — skip byte
            }
        }
    }

    /// Read an HPACK string at position and set last_method from it.
    /// Handles both Huffman and non-Huffman encoded strings.
    fn setPathFromHpackString(self: *Transport, data: []const u8) void {
        if (data.len == 0) return;
        const is_huffman = (data[0] & 0x80) != 0;
        const r = hpackDecodeInt(data, 7);
        const str_start = r.consumed;
        const str_len = r.value;
        if (str_start + str_len > data.len) return;
        const str_bytes = data[str_start .. str_start + str_len];

        if (!is_huffman) {
            // Plain text — copy directly
            const copy_len = @min(str_len, self.last_method.len);
            @memcpy(self.last_method[0..copy_len], str_bytes[0..copy_len]);
            self.last_method_len = copy_len;
        } else {
            // Huffman encoded — decode using RFC 7541 table
            self.last_method_len = huffmanDecode(str_bytes, &self.last_method);
        }
    }

    /// Write a single gRPC response message in a server stream.
    /// Sends HEADERS (if first message) + DATA, but no TRAILERS — the stream stays open.
    pub fn writeStreamMessage(self: *Transport, message: []const u8, is_first: bool) !void {
        const sid = self.last_stream_id;

        if (is_first) {
            // Send HEADERS on first message
            const response_headers = [_]u8{
                0x88, // :status: 200
                0x40 | 31, 16, 'a', 'p', 'p', 'l', 'i', 'c', 'a', 't', 'i', 'o', 'n', '/', 'g', 'r', 'p', 'c',
            };
            try self.writeFrame(.HEADERS, http2.frame.FrameFlags.END_HEADERS, sid, &response_headers);
        }

        // Send DATA frame (no END_STREAM)
        const grpc_msg_len: u32 = @intCast(message.len);
        const grpc_frame = try self.allocator.alloc(u8, 5 + message.len);
        defer self.allocator.free(grpc_frame);
        grpc_frame[0] = 0;
        grpc_frame[1] = @intCast((grpc_msg_len >> 24) & 0xFF);
        grpc_frame[2] = @intCast((grpc_msg_len >> 16) & 0xFF);
        grpc_frame[3] = @intCast((grpc_msg_len >> 8) & 0xFF);
        grpc_frame[4] = @intCast(grpc_msg_len & 0xFF);
        @memcpy(grpc_frame[5..], message);
        try self.writeFrame(.DATA, 0, sid, grpc_frame);
    }

    /// End a gRPC server stream by sending TRAILERS with grpc-status: 0.
    pub fn endStream(self: *Transport) !void {
        const sid = self.last_stream_id;
        const trailers = [_]u8{
            0x40, 11, 'g', 'r', 'p', 'c', '-', 's', 't', 'a', 't', 'u', 's', 1, '0',
        };
        try self.writeFrame(.HEADERS, http2.frame.FrameFlags.END_STREAM | http2.frame.FrameFlags.END_HEADERS, sid, &trailers);
    }

    /// Write a gRPC response message.
    /// Sends proper gRPC framing: HEADERS frame, then DATA frame with
    /// 5-byte gRPC prefix, then TRAILERS with grpc-status: 0.
    pub fn writeMessage(self: *Transport, message: []const u8) !void {
        const sid = self.last_stream_id;

        // 1. Send HEADERS frame with gRPC response headers
        //    Minimal HPACK-encoded headers for gRPC:
        //    :status: 200, content-type: application/grpc
        const response_headers = [_]u8{
            // :status: 200 (indexed header field, index 8)
            0x88,
            // content-type: application/grpc (literal header with incremental indexing)
            // name index 31 = content-type, value = "application/grpc"
            0x40 | 31, // incremental indexing, name index 31
            16, // value length = 16
            'a', 'p', 'p', 'l', 'i', 'c', 'a', 't', 'i', 'o', 'n', '/', 'g', 'r', 'p', 'c',
        };
        try self.writeFrame(.HEADERS, http2.frame.FrameFlags.END_HEADERS, sid, &response_headers);

        // 2. Send DATA frame with gRPC-framed message
        //    [1 byte: not compressed][4 bytes: message length BE][protobuf message]
        const grpc_msg_len: u32 = @intCast(message.len);
        const grpc_frame = try self.allocator.alloc(u8, 5 + message.len);
        defer self.allocator.free(grpc_frame);
        grpc_frame[0] = 0; // not compressed
        grpc_frame[1] = @intCast((grpc_msg_len >> 24) & 0xFF);
        grpc_frame[2] = @intCast((grpc_msg_len >> 16) & 0xFF);
        grpc_frame[3] = @intCast((grpc_msg_len >> 8) & 0xFF);
        grpc_frame[4] = @intCast(grpc_msg_len & 0xFF);
        @memcpy(grpc_frame[5..], message);

        try self.writeFrame(.DATA, 0, sid, grpc_frame);

        // 3. Send TRAILERS frame with grpc-status: 0 (OK)
        //    HPACK: literal header, name "grpc-status", value "0"
        const trailers = [_]u8{
            0x40, // literal header with incremental indexing, new name
            11, // name length = 11
            'g', 'r', 'p', 'c', '-', 's', 't', 'a', 't', 'u', 's',
            1, // value length = 1
            '0', // status = OK
        };
        try self.writeFrame(.HEADERS, http2.frame.FrameFlags.END_STREAM | http2.frame.FrameFlags.END_HEADERS, sid, &trailers);
    }
};
