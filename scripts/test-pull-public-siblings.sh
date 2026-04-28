#!/usr/bin/env bash
# Dry-run smoke: --dry-run must list at least one fetch line and exit 0.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$("$HERE/pull-public-siblings.sh" --dry-run 2>&1)"
echo "$out" | grep -q "would fetch" || { echo "FAIL: no 'would fetch' line"; exit 1; }
echo "PASS"
