#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright (c) 2026 DevNW
#
# A/B runner for the zero-overhead-when-disabled bench system. Builds
# the comparison-layer harness twice (once with -Dotel_disabled=false,
# once with =true) and runs each, writing ref-a.json and ref-b.json
# into the run directory. The hard-criterion check then reads both
# files and asserts the comptime-disabled target.
#
# Usage:
#   scripts/bench_ab_runner.sh [--out-dir <path>] [--ops <N>] [--quiet]
#
# Defaults:
#   --out-dir = docs/performance/<today>-zero-overhead-when-disabled/results
#
# Environment:
#   ZIG          override the zig executable (default: zig from PATH)
#   OPTIMIZE     override the build optimize mode (default: ReleaseFast)

set -euo pipefail

OUT_DIR=""
OPS=""
QUIET=""
ZIG="${ZIG:-zig}"
OPTIMIZE="${OPTIMIZE:-ReleaseFast}"
RUN_DATE="$(date +%Y-%m-%d)"
DEFAULT_OUT_DIR="docs/performance/${RUN_DATE}-zero-overhead-when-disabled/results"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir)
      OUT_DIR="$2"
      shift 2
      ;;
    --ops)
      OPS="$2"
      shift 2
      ;;
    --quiet)
      QUIET="--quiet"
      shift
      ;;
    -h | --help)
      sed -n '4,18p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "${OUT_DIR}" ]]; then
  OUT_DIR="${DEFAULT_OUT_DIR}"
fi
mkdir -p "${OUT_DIR}"

REF_A="${OUT_DIR}/ref-a.json"
REF_B="${OUT_DIR}/ref-b.json"

EXTRA_ARGS=()
if [[ -n "${OPS}" ]]; then
  EXTRA_ARGS+=("--ops" "${OPS}")
fi
if [[ -n "${QUIET}" ]]; then
  EXTRA_ARGS+=("--quiet")
fi

GIT_SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
GIT_DIRTY=""
if ! git diff-index --quiet HEAD -- 2>/dev/null; then
  GIT_DIRTY=" (dirty tree)"
fi

echo "bench-ab-runner: HEAD=${GIT_SHA}${GIT_DIRTY} optimize=${OPTIMIZE}"
echo "bench-ab-runner: writing ref-a (otel_disabled=false) → ${REF_A}"
"${ZIG}" build bench-ab "-Doptimize=${OPTIMIZE}" "-Dotel_disabled=false" -- \
  --output "${REF_A}" "${EXTRA_ARGS[@]}"

echo "bench-ab-runner: writing ref-b (otel_disabled=true) → ${REF_B}"
"${ZIG}" build bench-ab "-Doptimize=${OPTIMIZE}" "-Dotel_disabled=true" -- \
  --output "${REF_B}" "${EXTRA_ARGS[@]}"

echo "bench-ab-runner: running hard-criterion check"
"${ZIG}" build hard-criterion-check -- --ref-a "${REF_A}" --ref-b "${REF_B}"

echo "bench-ab-runner: done. results in ${OUT_DIR}"
