// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Single-module umbrella over `grpc-zig` exposing both the client and
// server APIs. Required because `grpc-zig`'s upstream `build.zig`
// publishes `grpc-client` and `grpc-server` as TWO distinct modules
// whose roots transitively import the same shared files
// (`proto/service.zig`, `transport.zig`, `features/*.zig`,
// `http2/*.zig`). Zig 0.16 forbids the same source file belonging to
// two distinct modules in one compilation, so any consumer that needs
// BOTH sides (the otel module here, which uses the client for export
// and the server for the loopback test harness) must collapse them
// into a single module.
//
// This file is the new module's root. The `build.zig` in `otel`
// synthesizes a directory under `addWriteFiles` containing this file
// alongside a verbatim copy of every upstream `src/*.zig` file, then
// builds one module rooted here. Sibling `@import`s below resolve
// inside the synthesized directory, so `client.zig`, `server.zig`,
// and their transitive imports all belong to the SAME module
// (`grpc_zig`) and the file-collision rule is satisfied.

pub const client = @import("client.zig");
pub const server = @import("server.zig");

// Re-export the most commonly used symbols at the umbrella root for
// ergonomic access from the consumer side.
pub const GrpcClient = client.GrpcClient;
pub const GrpcServer = server.GrpcServer;
pub const Transport = server.Transport;
pub const Handler = server.Handler;
