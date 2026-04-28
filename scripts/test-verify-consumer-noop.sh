#!/usr/bin/env bash
# Tests for verify-consumer-noop.sh.
#
# Test 1 (rejection guard): the script must refuse to run against the otel
# repo itself, since otel by definition contains otel symbols.
#
# Test 2 (regex regression / positive nm-grep path): a tiny static archive
# containing a defined `otel_test_marker` symbol is dropped into a synthesized
# `zig-out/` under a fixture sibling repo; we then invoke the script with
# `--skip-build` so it skips `zig build` and exercises only the find/nm/grep
# guard. We assert the script reports FAIL (exit 1) and emits the expected
# diagnostic on stderr. This exists because an earlier `\botel\b` regex
# silently passed every leak — `_` is a POSIX word character, so `\botel\b`
# never matched real symbol names like `otel_init`. This positive test would
# have caught that regression.
#
# Test 3 (worktree auto-detection): when the consumer repo's only build
# artifacts live under `.worktrees/<name>/zig-out/` (because the consumer's
# build happened inside a git worktree, not the main checkout), the script
# must auto-detect that worktree and walk its zig-out — without the operator
# having to copy artifacts back into the main checkout or pass any flag.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
target="$HERE/verify-consumer-noop.sh"
[ -x "$target" ] || { echo "FAIL: $target not found or not executable"; exit 1; }

# --- Test 1: rejection guard ----------------------------------------------
if "$target" otel >/dev/null 2>&1; then
    echo "FAIL: must reject 'otel' as a target"; exit 1
fi

# --- Test 2: regex regression / positive guard ----------------------------
# Synthesize a sibling fixture repo: its zig-out/ contains a static archive
# whose defined symbols include `otel_test_marker`. The script must detect
# this and exit non-zero with the leak diagnostic.
common_git="$(git -C "$HERE" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "$common_git" ] && [ -d "$common_git" ]; then
    otel_root="$(dirname "$common_git")"
    ROOT="$(dirname "$otel_root")"
else
    ROOT="$(cd "$HERE/../.." && pwd)"
fi

# Throwaway, unique-ish name to avoid colliding with any real sibling.
fixture_name="verify-consumer-noop-fixture-$$"
fixture_dir="$ROOT/$fixture_name"
scratch="$(mktemp -d -t verify-consumer-noop-fixture.XXXXXX)"

cleanup() {
    rm -rf "$fixture_dir" "$scratch"
}
trap cleanup EXIT

mkdir -p "$fixture_dir/zig-out/lib"

# Build a tiny `.o` containing a defined `otel_test_marker` symbol, then
# wrap it in a static archive. `nm` should list `otel_test_marker` as `T`.
echo 'int otel_test_marker(void){return 0;}' \
    | gcc -c -x c -o "$scratch/leaked.o" -
ar rcs "$fixture_dir/zig-out/lib/leaked.a" "$scratch/leaked.o"

# Confirm the symbol is actually defined (defensive — if this fails the
# fixture itself is broken, not the script under test).
if ! nm --defined-only "$fixture_dir/zig-out/lib/leaked.a" 2>/dev/null \
        | grep -q 'otel_test_marker'; then
    echo "FAIL: fixture archive does not contain otel_test_marker"; exit 1
fi

# Run the guard with --skip-build so we only exercise the find/nm/grep path.
# Capture stderr; assert non-zero exit AND the expected diagnostic.
out_file="$scratch/out.txt"
set +e
"$target" --skip-build "$fixture_name" >/dev/null 2>"$out_file"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
    echo "FAIL: script must exit non-zero when otel symbols leak; got rc=0"
    echo "--- stderr ---"
    cat "$out_file"
    exit 1
fi
if ! grep -q 'FAIL: otel symbols leaked' "$out_file"; then
    echo "FAIL: missing expected diagnostic on stderr (rc=$rc)"
    echo "--- stderr ---"
    cat "$out_file"
    exit 1
fi

# --- Test 3: worktree auto-detection --------------------------------------
# Synthesize a sibling fixture whose ONLY zig-out lives under
# `.worktrees/probe-fixture/zig-out/`. The script (with no --worktree flag)
# must auto-detect that worktree and walk its zig-out, finding the leak.
wt_fixture_name="verify-consumer-noop-wt-fixture-$$"
wt_fixture_dir="$ROOT/$wt_fixture_name"
wt_scratch="$(mktemp -d -t verify-consumer-noop-wt-fixture.XXXXXX)"

wt_cleanup() {
    rm -rf "$fixture_dir" "$scratch" "$wt_fixture_dir" "$wt_scratch"
}
trap wt_cleanup EXIT

# Note: NO zig-out at the top level of the fixture. The leak ONLY exists
# under the worktree path, so a non-worktree-aware script would see "no
# artifacts" and falsely PASS.
mkdir -p "$wt_fixture_dir/.worktrees/probe-fixture/zig-out/lib"

echo 'int otel_test_marker(void){return 0;}' \
    | gcc -c -x c -o "$wt_scratch/leaked.o" -
ar rcs "$wt_fixture_dir/.worktrees/probe-fixture/zig-out/lib/leaked.a" \
    "$wt_scratch/leaked.o"

wt_out_file="$wt_scratch/out.txt"
set +e
"$target" --skip-build "$wt_fixture_name" >/dev/null 2>"$wt_out_file"
wt_rc=$?
set -e

if [ "$wt_rc" -eq 0 ]; then
    echo "FAIL: script must auto-detect worktree zig-out and report leak; got rc=0"
    echo "--- stderr ---"
    cat "$wt_out_file"
    exit 1
fi
if ! grep -q 'FAIL: otel symbols leaked' "$wt_out_file"; then
    echo "FAIL: worktree auto-detect missing leak diagnostic on stderr (rc=$wt_rc)"
    echo "--- stderr ---"
    cat "$wt_out_file"
    exit 1
fi
# Sanity: the diagnostic should mention the worktree path, not the
# top-level zig-out. Catches the case where the script "auto-detects"
# but writes the wrong path into its diagnostic.
if ! grep -q '.worktrees/probe-fixture/zig-out' "$wt_out_file"; then
    echo "FAIL: leak diagnostic should reference the worktree zig-out path"
    echo "--- stderr ---"
    cat "$wt_out_file"
    exit 1
fi

echo "PASS"
