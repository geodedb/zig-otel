# P0-1 — AttributeSet O(1) put / get

Closes GitLab issue **#5** (P0, PerfScore 72) and stacks with **#75** (P1-12 cold-path get) and **#45** (P1-7 arena pollution on overwrite).

## Hypothesis

`AttributeSet.put` ran a linear scan over `entries` *after* duplicating
the incoming key into the arena. Two pathologies fell out:

1. **O(n²) put** — each insert paid an O(N) scan, so a span filling
   the 128-attr cap saw quadratic cost.
2. **Arena pollution on overwrite** — every `put` for a duplicate key
   still arena-duplicated the key bytes; the duplicate sat in the
   arena until span end. Long-lived spans with hot, frequently-rewritten
   keys (counters, retry-attempt counters, etc.) leaked into the arena.

## Change

- Added a `std.StringHashMapUnmanaged(u32)` index keyed by the
  arena-owned key bytes (no extra duplication; index keys alias entry
  keys).
- Reordered `put` to look up first, then either replace the value in
  place (no key dup) or — only on insert — dup the key + value and
  append.
- `getString` now goes through the index for O(1) lookup.

## A/B

`zig build -Doptimize=ReleaseFast bench-micro -- --filter micro_attr_put`

| Scenario | Baseline median | After median | Speedup | Throughput delta |
|----------|---:|---:|---:|---:|
| `micro_attr_put_new` (1 put on fresh set) | 48,199 ns | 43,795 ns | 1.10× | +10.06% |
| `micro_attr_put_update` (10 000 overwrites of one key) | 775,738 ns | 298,622 ns | 2.60× | +159.77% |
| `micro_attr_put_near_limit` (5 000 puts after 120-entry prefill) | 2,110,360 ns | 189,093 ns | **11.16×** | **+1016.04%** |

Compare-bench output:

```text
micro_attr_put_new:        throughput  +10.06%  wall_p50   -9.14%
micro_attr_put_update:     throughput +159.77%  wall_p50  -61.50%
micro_attr_put_near_limit: throughput +1016.04% wall_p50  -91.04%
```

The `near_limit` win is what closes the P0 ledger: a span that fills
to ~120 attributes used to pay 16k key-comparisons; it now pays 1.

## Risks / follow-ups

- The index doubles `entries.deinit()`'s peak memory by the size of
  the StringHashMap buckets (worst case ~256 buckets × 16 B = 4 KiB
  per AttributeSet). For 128-entry sets this is ≪ the entries
  themselves and fine.
- Iteration order is unchanged (`entries: ArrayList` still source of
  truth); ordering tests pass.
- Cascade: P1-12 (#75) and P1-7 (#45) are now also resolved by the
  same change; close in the same commit.
