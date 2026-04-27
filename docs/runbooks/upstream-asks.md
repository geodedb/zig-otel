# Upstream Asks — Operator Todo Tracker

> Tracker for blocked-upstream gaps that require landing a change in a
> dependency repo before this consumer repo can close them. Each entry
> documents the dep, the exact API gap, the file:line evidence, the
> intended unblock path, and the consumer-side row(s) waiting on the
> fix.

| Status | Dep | Asked? | Tracker | Owner |
|--------|-----|--------|---------|-------|
| Open   | `gitlab.com/devnw/zig/grpc-zig` — expose HTTP/2 trailers in client response API | **Pending — operator action** | (file upstream issue) | <benji@codepros.org> |

---

## ASK-GRPC-ZIG-TRAILERS — expose HTTP/2 trailers in `GrpcClient.call` response

- **Upstream dep:** `gitlab.com/devnw/zig/grpc-zig` (consumer pin
  `fd5405b860f25e3dd9226b3d63b676ab58f183d4`, Zig package hash
  `grpc_zig-0.1.0-7FnvpLrAAQAMxd1Mf0GfWePI0Ijw1vX-ZsEc6RCsIsq6`).
- **Consumer issue blocked:** [GAP-GRPC-STATUS-PROPAGATION (#32)](https://gitlab.com/devnw/zig/otel/-/issues/32).
- **Severity in consumer:** High — without `grpc-status` (and
  `Retry-After` from `grpc-status-details-bin`) the OTLP/gRPC retry
  loop in `src/exporters/otlp_grpc.zig` cannot classify
  `RESOURCE_EXHAUSTED` / `UNAVAILABLE` / `DEADLINE_EXCEEDED` per the
  OTLP 1.10.0 retry contract. The exporter falls back to a coarse
  io-error retry, which means real collector back-pressure is dropped
  on the floor.

### Evidence (verified 2026-04-27)

The pinned client returns only the response bytes:

```zig
// zig-pkg/grpc_zig-0.1.0-7FnvpLrAAQAMxd1Mf0GfWePI0Ijw1vX-ZsEc6RCsIsq6/src/client.zig:43-64
pub fn call(self: *GrpcClient, _: []const u8, request: []const u8, compression_alg: compression.Compression.Algorithm) ![]u8 {
    // ...
    try self.transport.writeMessage(compressed);
    const response_bytes = try self.transport.readMessage();
    defer self.allocator.free(response_bytes);

    // Decompress response
    return self.compression.decompress(response_bytes, compression_alg);
}
```

There is no trailer surface in the public API. `transport.readMessage`
returns the framed message body only; it does not expose the
trailing HEADERS frame (HTTP/2 §8.1) that carries `grpc-status`,
`grpc-message`, and (optionally) `grpc-status-details-bin`.

The consumer-side stub-out is documented inline at
`src/exporters/otlp_grpc.zig:291-295`:

```text
// grpc-zig's client surfaces neither the trailers nor the
// `grpc-status` value — `call()` either returns the response bytes
// or errors. A clean return therefore implies status OK; partial
// success and retryable failures from the server come back through
// io errors and the retry loop above.
```

### Asked-for change (upstream)

Extend the client API to expose trailers. One backwards-compatible
shape:

```zig
pub const CallResponse = struct {
    body: []u8,
    trailers: std.StringHashMap([]const u8),
    // Or a typed accessor:
    pub fn grpcStatus(self: CallResponse) ?GrpcStatusCode { ... }
    pub fn grpcMessage(self: CallResponse) ?[]const u8 { ... }
    pub fn retryAfterMs(self: CallResponse) ?u32 { ... }
};

pub fn callTrailing(
    self: *GrpcClient,
    method: []const u8,
    request: []const u8,
    compression_alg: compression.Compression.Algorithm,
) !CallResponse;
```

The existing `call` can stay as a one-line wrapper that drops trailers,
preserving every other consumer of grpc-zig.

### Operator unblock checklist

1. **File the upstream issue** on `gitlab.com/devnw/zig/grpc-zig`:
   - Title: "expose HTTP/2 trailers in client response API
     (`grpc-status`, `grpc-message`, `Retry-After`)"
   - Body: link to OTLP 1.10.0 retry classifier requirement; cite
     `transport.readMessage` as the current floor.
   - Cross-link to `gitlab.com/devnw/zig/otel/-/issues/32`.
2. **Land the upstream change** (assign / review / merge).
3. **Bump the pin** in this repo (`build.zig.zon` `grpc_zig` URL +
   hash) to a version that includes the new API.
4. **Wire it on the consumer side**: modify
   `src/exporters/otlp_grpc.zig::unaryExport` to consume trailers and
   map `grpc-status` to the `GrpcStatus` enum (or to extend that enum
   with the spec codes). Replace the always-`.ok` return.
5. **Add regression tests** in `test/grpc_loopback.zig` asserting that
   `RESOURCE_EXHAUSTED` and `UNAVAILABLE` from the loopback server
   are surfaced and routed through `OtlpExportError.Throttled` /
   `OtlpExportError.Retryable`.
6. **Close `gitlab.com/devnw/zig/otel/-/issues/32`** with the consumer
   commit SHA and a 2-line evidence note.

### Cross-references

- Consumer flatfile row: `docs/GAP_ANALYSIS.md` —
  `GAP-GRPC-STATUS-PROPAGATION` (status `Blocked (upstream-grpc_zig)`).
- Consumer dependency note: `docs/DEPENDENCIES.md` (gRPC client row).
- Consumer code: `src/exporters/otlp_grpc.zig:270-297`
  (`unaryExport`).
- Upstream pin: `build.zig.zon::grpc_zig`.

### History

- 2026-04-27 — created when issue #32 was reclassified from "Partial"
  to "Blocked (upstream-grpc_zig)" after re-verification of the pinned
  client's public API.
