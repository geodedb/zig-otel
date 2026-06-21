# FIPS-140-3 Status — otel

**REQ-ID:** REQ-FIPS-EXEMPT-001 — non-security crypto/hash/RNG sites are
allow-listed (exempt) from the workspace FIPS-140-3 routing requirement per
`docs/superpowers/specs/2026-06-20-fips-pqc-design.md` §5.

**Mode:** This library performs only **non-security** hashing and random-number
operations: W3C trace/span ID generation, full-jitter retry backoff, and
attribute-set / instrumentation-scope hashmap keys during OTLP encoding. It is
**exempt** from the workspace FIPS-140-3 routing requirement (see `fips` package
spec `docs/superpowers/specs/2026-06-20-fips-pqc-design.md` §5). No site
produces, protects, or verifies a secret, key, credential, authentication tag,
or signature; therefore none is routed through the `crypto_backend` seam and
none links the OpenSSL FIPS provider. When a consumer builds with
`-Dfips=true`, this library is unaffected: it adds no `-Dfips` flag and changes
no behavior.

## Exempt call sites

| File:Line | Primitive | Use | Why non-security (exempt) |
|-----------|-----------|-----|---------------------------|
| `src/internal/id.zig:129,132,140` | `std.Random.DefaultPrng` | W3C trace/span ID generation (incl. CSPRNG-seeded variant for cross-provider uniqueness, GAP-SEC-H-5) | Correlation identifiers; not secrets or keys |
| `src/exporters/otlp_http/exporter.zig:49,91` | `std.Random.DefaultPrng` | Exporter-local ID / backoff-jitter PRNG | Not a secret |
| `src/exporters/otlp_grpc.zig:37,74` | `std.Random.DefaultPrng` | Exporter-local ID / backoff-jitter PRNG | Not a secret |
| `src/sdk/export.zig:658,684` | `std.Random.DefaultPrng` (params) | Full-jitter retry backoff randomness | Liveness/backoff; not a secret |
| `src/sdk/metrics.zig:478,489` | `std.hash.Wyhash` | Attribute-set hashmap key for metric aggregation | Lookup key; not a secret |
| `src/exporters/otlp_http/encode_proto.zig:64,80` | `std.hash.Wyhash` | OTLP instrumentation-scope hashmap key | Lookup key; not a secret |
| `src/exporters/otlp_http/encode_json.zig:54` | `std.hash.Wyhash` | OTLP instrumentation-scope hashmap key | Lookup key; not a secret |

Line numbers are pre-annotation approximations.

## Test-only PRNGs

`src/sdk/export.zig:695,703` are deterministic test PRNGs
(`std.Random.DefaultPrng.init(1)`) used in retry-backoff unit tests; they are
annotated as test-support.

## OS entropy helpers (not std.crypto/std.hash/std.Random)

`src/internal/id.zig` `csprngU64` / `fillCsprngBytes` obtain OS entropy via
`std.os.linux.getrandom` / `std.c.arc4random_buf` (with a non-security
nano-time + PID fallback). These are OS-level entropy calls, not
`std.crypto` / `std.hash` / `std.Random` call sites, and seed only the
non-security trace/span ID and backoff PRNGs; no annotation is required.

## Observability seam cross-reference

The existing `otel` observability seam (the one re-enabled by the FIPS
foundation plan's module-dedup fix) is independent of this exemption work; this
document covers only otel's own incidental non-security crypto.

## zlint allow-list

Every production site above carries an inline
`// fips-exempt: non-security — <reason>` annotation so the `zlint` FIPS rule
treats it as allow-listed rather than a violation. Adding a new `std.crypto` /
`std.hash` / `std.Random` use to this library REQUIRES adding both the inline
annotation and a row in the table above.
