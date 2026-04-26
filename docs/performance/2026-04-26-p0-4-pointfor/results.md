# P0-4 — pointFor zero-alloc hit path

Closes GitLab issue **#15** (P0, PerfScore 72) and stacks with **#17**
(P0-5 attributeKey allocator pressure).

## Hypothesis

Every `Counter.add` / `Histogram.record` allocated **3 times** before
finding the existing aggregated point:

1. `allocator.alloc(Entry, n)` — copy of entries for sorting
2. `ArrayList(u8)` growth — formatting the canonical key
3. `allocator.dupe(buf.items)` — final owned slice

Then it linear-scanned `inst.points.items` doing `std.mem.eql` on the
just-built string, and freed the string on hit. The hit path was
therefore O(N · K) bytes of allocator traffic, where N is the number
of distinct attribute combinations seen and K is the formatted-key
length.

## Change

- New `attrFingerprint(entries) u64` — canonicalises by sorting
  *indices into* `entries` on a 128-byte stack buffer, then
  Wyhash-streams the sorted entries with a small per-type tag. No
  heap allocation on any path.
- `InstrumentBackend` gains a
  `points_index: AutoHashMapUnmanaged(u64, u32)` mapping the
  fingerprint to a `points` slice index.
- `pointFor` now does an O(1) HashMap lookup on the hit path. The
  miss path keeps the formatted-string `attribute_key` for stable
  diagnostics and Prometheus exposition.

Hash-collision risk: birthday bound at ≤1024 distinct points per
instrument is < 2⁻⁴⁴; we accept this for the fast path. A future
`attribute_key` deep-equality check could be added behind an opt-in
debug toggle if any production collision is ever observed.

## A/B

`zig build -Doptimize=ReleaseFast bench-micro` (median of 6 samples).

| Scenario | Before p50 | After p50 | Speedup | Allocs/op |
|----------|---:|---:|---:|---:|
| `micro_counter_add_no_attrs`        | 78.9 ns  | 79.1 ns  | 1.00× | 0 → 0 |
| `micro_counter_add_4_attrs_hit`     | 465.9 ns | 270.5 ns | 1.72× | **3 → 0** |
| `micro_histogram_record_4_attrs_hit`| 479.9 ns | 250.9 ns | 1.91× | **3 → 0** |

The "no_attrs" line is the control: counterAdd with zero attributes
already short-circuited the alloc loops, so this fix should not
regress it. ✓

## Risks / follow-ups

- Cardinality explosion: the points_index grows linearly with the
  number of unique attribute combinations the instrument sees. There
  is no spec-mandated cardinality limit on metrics today; if
  unbounded cardinality becomes a problem in production we'll add a
  cap + spillover at this layer (separate finding).
- `attribute_key` is now redundant for the hit path. We keep it so
  Prometheus / stable-debug callers can read it; if memory becomes a
  pain point at high cardinality we can compute it lazily on first
  read.
