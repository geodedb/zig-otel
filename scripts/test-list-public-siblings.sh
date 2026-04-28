#!/usr/bin/env bash
# Smoke test: the script must print otel itself (known public) and exit 0.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
out="$("$HERE/list-public-siblings.sh")"
echo "$out" | grep -qx "otel" || { echo "FAIL: 'otel' not in output"; exit 1; }
echo "PASS"
