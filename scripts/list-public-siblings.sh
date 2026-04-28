#!/usr/bin/env bash
# Print one repo name per line for every sibling under gitlab.com/devnw/zig/*
# whose GitLab visibility is "public". Reads candidate names from the parent
# directory of the otel checkout (or $1 if given) by listing dirs that contain
# a .git dir.
#
# ROOT resolution works whether the script is invoked from the main otel
# checkout (otel/scripts/...) or from a worktree (otel/.worktrees/<name>/scripts/...):
# we use `git --git-common-dir` to find the shared .git, whose parent is the
# main otel checkout, then go up one more directory to reach the siblings root.
#
# Requires: curl, jq.
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"

if [ "$#" -ge 1 ] && [ -n "$1" ]; then
    ROOT="$1"
else
    common_git="$(git -C "$script_dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    if [ -n "$common_git" ] && [ -d "$common_git" ]; then
        otel_root="$(dirname "$common_git")"
        ROOT="$(dirname "$otel_root")"
    else
        ROOT="$(cd "$script_dir/../.." && pwd)"
    fi
fi

[ -d "$ROOT" ] || { echo "ROOT not found: $ROOT" >&2; exit 1; }

for d in "$ROOT"/*/; do
    name="$(basename "$d")"
    [ -e "$d/.git" ] || continue
    encoded="devnw%2Fzig%2F$name"
    body="$(curl -fsS "https://gitlab.com/api/v4/projects/$encoded?simple=true" 2>/dev/null || true)"
    [ -n "$body" ] || continue
    vis="$(printf '%s' "$body" | jq -r '.visibility // empty' 2>/dev/null || true)"
    [ "$vis" = "public" ] && printf '%s\n' "$name"
done
