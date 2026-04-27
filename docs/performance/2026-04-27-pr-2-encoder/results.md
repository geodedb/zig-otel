# PR-2 — OTLP nested-encode (`commitSubMessage` deferred compaction)

Captures the post-fix steady-state baseline for the OTLP/protobuf
nested-message encoder, closing the captured-subset of
**BENCH-BASELINES-MISSING** ([#166](https://gitlab.com/devnw/zig/otel/-/work_items/166))
for the **PR-2** ([#36](https://gitlab.com/devnw/zig/otel/-/work_items/36))
encoder rewrite.

## Subject

The three `micro_encode_spans_proto_*` scenarios in `benchmarks/micro/main.zig`
exercise `src/generated/otlp.zig` (`writeRepeatedMessage` →
`commitSubMessage` → `Writer.toOwnedSlice`) at three batch sizes that
sit just inside the working-set thresholds tracked by `make slo-check`:

| Scenario | Batch size | What it stresses |
|----------|----------:|------------------|
| `micro_encode_spans_proto_64` | 64 spans | L1/L2 in-cache encode |
| `micro_encode_spans_proto_512` | 512 spans | L3-resident encode |
| `micro_encode_spans_proto_4096` | 4 096 spans | RSS-bound encode (~146 MiB peak) |

PR-2 swapped the prior O(N) `copyForwards` length-prefix backfill for a
deferred-compaction pass in `Writer.toOwnedSlice`. The defect was
super-linear at large batch sizes; the fix targets a flat per-span cost
profile across the three sizes.

## Build flags

```text
zig build bench-micro -Doptimize=ReleaseFast -- --output benchmarks/results/micro-latest.json
```

(invoked via `make slo-check`, which is the canonical capture path per
`docs/performance/SLO.md` §"Build-mode contract".)

| Field | Value |
|-------|-------|
| Zig version | `0.16.0` |
| Target | `linux-x86_64-broadwell` |
| Optimize | `ReleaseFast` |
| Warmups | 1 |
| Samples / scenario | 6 |
| Captured at | 2026-04-27 (Unix `1777307628`) |
| Git SHA | `e82205da9da1c748839e34cd0c93ae1b2eb0b13c` |

## Numbers

| Scenario | p50 wall (ns) | p95 wall (ns) | p99 wall (ns) | spans/s | allocs / iter | peak live bytes |
|----------|-------------:|-------------:|-------------:|--------:|-------------:|---------------:|
| `micro_encode_spans_proto_64`   |       182 162 |       185 894 |       185 894 | 351 336 |           33 |          72 774 |
| `micro_encode_spans_proto_512`  |     1 421 556 |     1 442 239 |     1 442 239 | 360 169 |           43 |         559 120 |
| `micro_encode_spans_proto_4096` |    11 956 254 |    12 229 131 |    12 229 131 | 342 582 |           54 |       4 896 486 |

Per-span median cost is approximately:

| Scenario | ns/span | allocs/span |
|----------|-------:|-----------:|
| 64-batch  | 2 846 | 0.516 |
| 512-batch | 2 776 | 0.084 |
| 4096-batch | 2 919 | 0.013 |

The PR-2 acceptance criterion was a **flat** per-span cost across the
three batch sizes; observed: 2 776 ns/span at 512 vs 2 919 ns/span at
4 096 (≤ 6 % spread). Acceptance met.

## Files

| File | Purpose |
|------|---------|
| `results/baseline.json` | Frozen snapshot captured at SHA `e82205d` — the floor against which future runs compare. |
| `results/latest.json`   | Most recent capture; identical to `baseline.json` on first commit. Replaced on every fresh `make slo-check` if the operator chooses to re-pin. |
| `results.md`            | This document. |

## Pointer back

- Source PR / change: PR-2 ([#36](https://gitlab.com/devnw/zig/otel/-/work_items/36)) — `src/generated/otlp.zig` `commitSubMessage` deferred-compaction.
- Bench probe authored in: `benchmarks/micro/main.zig:53-55` (`micro_encode_spans_proto_{64,512,4096}`) plus helpers `benchEncodeSpansProto64/512/4096`.
- SLO floor for these scenarios: `docs/performance/SLO.md` §"OTLP encode latency floor".
- Tracking: BENCH-BASELINES-MISSING ([#166](https://gitlab.com/devnw/zig/otel/-/work_items/166)) — captured-subset of the partial close.

## Risks / follow-ups

- The `4096` row's RSS peak (~146 MiB) is genuinely the hot working-set
  this encoder is allowed to touch; if a future change starts reusing
  arenas across batches the alloc-count column will drop and a re-pin
  is required.
- The `64` row's allocs/span (0.516) reflects per-batch fixed-cost
  amortisation. Re-pinning is expected on any change that moves the
  per-batch overhead (e.g., scope-grouping changes from PR-3 / PR-5).
