// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Thin re-export shim for the gRPC loopback test harness.
//
// The actual harness lives at
// `src/exporters/otlp_grpc_test_server.zig` and is exposed publicly
// from the `otel` module as `otel.exporters.otlp_grpc_test_server`.
// Hosting it inside the library source tree (rather than purely under
// `test/`) is a Zig-0.16 build constraint, not a design choice: the
// `grpc-zig` package exposes its `grpc-client` and `grpc-server`
// modules with overlapping transitive imports (`proto/service.zig`,
// `transport.zig`), and the compiler errors out when the same source
// file belongs to two distinct modules in one compilation unit. By
// having both grpc imports live inside the otel module's own import
// graph, the loopback test stays a pure consumer of `otel.*` and we
// avoid wiring a second module that would re-pull the grpc-zig
// sources.
//
// This file exists because the dispatch plan calls for
// `test/grpc_test_helpers.zig` by name; it forwards every symbol to
// the real harness so the test reads like the plan template.

const otel = @import("otel");

pub const Server = otel.exporters.otlp_grpc_test_server.Server;
pub const startLoopbackGrpc = otel.exporters.otlp_grpc_test_server.startLoopbackGrpc;
