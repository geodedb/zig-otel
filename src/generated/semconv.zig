// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 DevNW
//
// Semantic Conventions 1.40.0 — generated constants.
//
// This file is treated as generated source: prefer a real generator
// (e.g. `weaver`) wired through `tools/` for downstream regeneration. The
// constants below cover the stable areas required by the spec: resource,
// HTTP, network, process, host, OS, service, exception, log, runtime,
// event, and profile.

pub const schema_url: []const u8 = "https://opentelemetry.io/schemas/1.40.0";

// ----- Telemetry SDK -----------------------------------------------------
pub const telemetry_sdk_name: []const u8 = "telemetry.sdk.name";
pub const telemetry_sdk_language: []const u8 = "telemetry.sdk.language";
pub const telemetry_sdk_version: []const u8 = "telemetry.sdk.version";

// ----- Service -----------------------------------------------------------
pub const service_name: []const u8 = "service.name";
pub const service_namespace: []const u8 = "service.namespace";
pub const service_version: []const u8 = "service.version";
pub const service_instance_id: []const u8 = "service.instance.id";

// ----- Resource - Process -----------------------------------------------
pub const process_pid: []const u8 = "process.pid";
pub const process_executable_name: []const u8 = "process.executable.name";
pub const process_executable_path: []const u8 = "process.executable.path";
pub const process_command_line: []const u8 = "process.command_line";
pub const process_runtime_name: []const u8 = "process.runtime.name";
pub const process_runtime_version: []const u8 = "process.runtime.version";
pub const process_runtime_description: []const u8 = "process.runtime.description";

// ----- Resource - OS -----------------------------------------------------
pub const os_type: []const u8 = "os.type";
pub const os_description: []const u8 = "os.description";
pub const os_name: []const u8 = "os.name";
pub const os_version: []const u8 = "os.version";

// ----- Resource - Host ---------------------------------------------------
pub const host_id: []const u8 = "host.id";
pub const host_name: []const u8 = "host.name";
pub const host_type: []const u8 = "host.type";
pub const host_arch: []const u8 = "host.arch";

// ----- HTTP attributes ---------------------------------------------------
pub const http_request_method: []const u8 = "http.request.method";
pub const http_response_status_code: []const u8 = "http.response.status_code";
pub const http_route: []const u8 = "http.route";
pub const url_full: []const u8 = "url.full";
pub const url_path: []const u8 = "url.path";
pub const url_scheme: []const u8 = "url.scheme";
pub const user_agent_original: []const u8 = "user_agent.original";
pub const server_address: []const u8 = "server.address";
pub const server_port: []const u8 = "server.port";
pub const client_address: []const u8 = "client.address";
pub const client_port: []const u8 = "client.port";

// ----- Network attributes ------------------------------------------------
pub const network_protocol_name: []const u8 = "network.protocol.name";
pub const network_protocol_version: []const u8 = "network.protocol.version";
pub const network_peer_address: []const u8 = "network.peer.address";
pub const network_peer_port: []const u8 = "network.peer.port";
pub const network_transport: []const u8 = "network.transport";

// ----- Exception attributes ---------------------------------------------
pub const exception_type: []const u8 = "exception.type";
pub const exception_message: []const u8 = "exception.message";
pub const exception_stacktrace: []const u8 = "exception.stacktrace";
pub const exception_escaped: []const u8 = "exception.escaped";

// ----- Event attributes --------------------------------------------------
pub const event_name: []const u8 = "event.name";

// ----- Log attributes ----------------------------------------------------
pub const log_record_uid: []const u8 = "log.record.uid";
pub const log_iostream: []const u8 = "log.iostream";
pub const log_file_name: []const u8 = "log.file.name";
pub const log_file_path: []const u8 = "log.file.path";

// ----- Runtime / Zig -----------------------------------------------------
pub const zig_compiler_version: []const u8 = "zig.compiler.version";
pub const zig_runtime_threads: []const u8 = "zig.runtime.threads";

// ----- Profile attributes (experimental) --------------------------------
pub const profile_frame_type: []const u8 = "profile.frame.type";
pub const profile_sample_period_ns: []const u8 = "profile.sample.period_ns";
pub const profile_sample_count: []const u8 = "profile.sample.count";

// ----- HTTP request method values ---------------------------------------
pub const HttpRequestMethod = struct {
    pub const get: []const u8 = "GET";
    pub const post: []const u8 = "POST";
    pub const put: []const u8 = "PUT";
    pub const delete: []const u8 = "DELETE";
    pub const head: []const u8 = "HEAD";
    pub const options: []const u8 = "OPTIONS";
    pub const patch: []const u8 = "PATCH";
    pub const connect: []const u8 = "CONNECT";
    pub const trace: []const u8 = "TRACE";
    pub const other: []const u8 = "_OTHER";
};
