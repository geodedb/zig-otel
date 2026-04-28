#!/usr/bin/env bash
# verify-consumer-noop.sh [--skip-build] <consumer-repo-name>
#
# Build the consumer with -Dwith_otel=false and grep for otel/observability
# symbols in the resulting object/exe set. If any appear, fail loudly.
#
# `--skip-build` skips the `zig build` step and only walks an existing
# `zig-out/`. This is intended for the test harness, which synthesizes a
# `zig-out/` containing a known-leaky archive to exercise the guard's
# find/nm/grep path without running a real Zig build.
#
# ROOT resolution mirrors list-public-siblings.sh / pull-public-siblings.sh
# so this works whether the script is invoked from the main otel checkout
# (otel/scripts/...) or from a worktree (otel/.worktrees/<name>/scripts/...):
# we use `git --git-common-dir` to find the shared .git, whose parent is the
# main otel checkout, then go up one more directory to reach the siblings root.
set -euo pipefail

skip_build=0
while [ "${1:-}" = "--skip-build" ]; do
    skip_build=1
    shift
done

repo="${1:?usage: verify-consumer-noop.sh [--skip-build] <consumer-repo>}"
[ "$repo" != "otel" ] || { echo "ERROR: 'otel' is not a consumer target" >&2; exit 2; }

script_dir="$(cd "$(dirname "$0")" && pwd)"

common_git="$(git -C "$script_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "$common_git" ] && [ -d "$common_git" ]; then
    otel_root="$(dirname "$common_git")"
    ROOT="$(dirname "$otel_root")"
else
    ROOT="$(cd "$script_dir/../.." && pwd)"
fi

dir="$ROOT/$repo"
[ -d "$dir" ] || { echo "no such repo dir: $dir" >&2; exit 2; }

if [ "$skip_build" -eq 0 ]; then
    (
        cd "$dir"
        rm -rf zig-out .zig-cache
        zig build -Dwith_otel=false -Doptimize=ReleaseSafe
    )
fi

# Walk every build artifact and assert no otel symbols are present.
#
# Zig's typical output is a statically linked executable. `nm -D` (dynamic
# symbol table) is empty for those, so a leak would slip through if we only
# checked the dynamic table. We run `nm --defined-only` (the regular symbol
# table — present on un-stripped Zig output) AND `nm -D --defined-only`
# (covers shared libs and dynamic exports) and flag a hit on either.
#
# Regex: we use a bare alternation `(otel|observability)` rather than `\b…\b`.
# `_` is a POSIX word character, so `\botel\b` requires a NON-word char on
# both sides — but every realistic Zig symbol (`otel_init`, `observability_z`,
# `main.otel_export_func`, …) has `_` adjacent to the keyword, so the
# word-boundary form silently never matches. The bare alternation is slightly
# more false-positive-prone in arbitrary English text, but symbol output from
# nm will not contain unrelated prose like "protocol" or "notebook" inside a
# defined-symbol entry, so it's safe here.
#
# `nm` failures: we do NOT swallow nm's exit code. If nm cannot read an
# artifact (corrupt file, unsupported format, permission), we treat the
# artifact as UNREADABLE and fail hard at the end — silently passing an
# unreadable artifact would defeat the point of a confidentiality guard.
hits=0
unreadable=0
while IFS= read -r f; do
    [ -f "$f" ] || continue
    leaked=""

    # Capture nm output and rc separately. `set -e` would abort on a failed
    # nm if we used a plain `static_out=$(nm ...)`, so we wrap the assignment
    # in a `set +e` / `set -e` window to inspect rc explicitly.
    set +e
    static_out=$(nm --defined-only "$f" 2>/dev/null)
    static_rc=$?
    set -e
    if [ "$static_rc" -ne 0 ]; then
        echo "ERROR: nm --defined-only failed (rc=$static_rc) on $f" >&2
        unreadable=$((unreadable + 1))
        continue
    fi
    if printf '%s\n' "$static_out" | grep -E '(otel|observability)' >&2; then
        leaked="static"
    fi

    set +e
    dyn_out=$(nm -D --defined-only "$f" 2>/dev/null)
    dyn_rc=$?
    set -e
    if [ "$dyn_rc" -ne 0 ]; then
        echo "ERROR: nm -D --defined-only failed (rc=$dyn_rc) on $f" >&2
        unreadable=$((unreadable + 1))
        continue
    fi
    if printf '%s\n' "$dyn_out" | grep -E '(otel|observability)' >&2; then
        leaked="${leaked:+$leaked,}dynamic"
    fi

    if [ -n "$leaked" ]; then
        echo "FAIL: otel symbols leaked into $f ($leaked symbol table)" >&2
        hits=$((hits + 1))
    fi
done < <(find "$dir/zig-out" -type f \( -executable -o -name '*.a' -o -name '*.so' \))

if [ "$unreadable" -gt 0 ]; then
    echo "FAIL: $unreadable artifact(s) unreadable by nm — refusing to claim clean" >&2
    exit 3
fi
[ "$hits" -eq 0 ] || exit 1
echo "PASS: no otel symbols in disabled build of $repo"
