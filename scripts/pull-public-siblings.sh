#!/usr/bin/env bash
# For every public sibling reported by list-public-siblings.sh:
#   1. git fetch origin --prune
#   2. detect default branch (main|master)
#   3. if working tree clean: git checkout <default> && git pull --ff-only
#      else: warn and skip
# Exit non-zero if any clean repo failed to fast-forward.
#
# ROOT resolution mirrors list-public-siblings.sh so this works whether the
# script is invoked from the main otel checkout (otel/scripts/...) or from a
# worktree (otel/.worktrees/<name>/scripts/...): we use `git --git-common-dir`
# to find the shared .git, whose parent is the main otel checkout, then go up
# one more directory to reach the siblings root.
#
# Usage:
#   pull-public-siblings.sh             # real run (mutates sibling repos)
#   pull-public-siblings.sh --dry-run   # print "would fetch <repo>" only
set -euo pipefail

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

script_dir="$(cd "$(dirname "$0")" && pwd)"

common_git="$(git -C "$script_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
if [ -n "$common_git" ] && [ -d "$common_git" ]; then
    otel_root="$(dirname "$common_git")"
    ROOT="$(dirname "$otel_root")"
else
    ROOT="$(cd "$script_dir/../.." && pwd)"
fi

[ -d "$ROOT" ] || { echo "ROOT not found: $ROOT" >&2; exit 1; }

mapfile -t repos < <("$script_dir/list-public-siblings.sh")
fail=0
for r in "${repos[@]}"; do
    dir="$ROOT/$r"
    if [ ! -e "$dir/.git" ]; then
        echo "skip $r (no .git)" >&2
        continue
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        echo "would fetch $r"
        continue
    fi
    echo "==> $r"
    git -C "$dir" fetch origin --prune
    default="$(git -C "$dir" symbolic-ref refs/remotes/origin/HEAD --short 2>/dev/null \
                 | sed 's@^origin/@@')"
    default="${default:-main}"
    if [ -n "$(git -C "$dir" status --porcelain)" ]; then
        echo "  dirty working tree; skipping pull" >&2
        fail=1
        continue
    fi
    git -C "$dir" checkout "$default"
    if ! git -C "$dir" pull --ff-only origin "$default"; then
        fail=1
        continue
    fi
done
exit "$fail"
