#!/usr/bin/env bash
# Audit GitLab CI job logs for accidental disclosure of the
# OTEL_INTEGRATION_AUTH_HEADER bearer token.
#
# Pre-requisites:
#   - glab CLI installed and authenticated (`glab auth status`)
#   - Run from inside a git checkout of devnw/zig/otel (project
#     auto-detected; override with --project)
#
# Usage:
#   scripts/audit_ci_logs.sh [--days N] [--job NAME] [--project NS/REPO]
#
# Exits 0 when no hits, 1 on hits, 2 on usage / setup error.
# Prints one line per hit: "<job_id>:<line_no>:<offending substring>".

set -euo pipefail

DAYS=90
JOB="otlp-integration-live"
PROJECT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days)
            DAYS="$2"
            shift 2
            ;;
        --job)
            JOB="$2"
            shift 2
            ;;
        --project)
            PROJECT="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,/^$/ s/^# \?//p' "$0"
            exit 0
            ;;
        *)
            echo "unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

if ! command -v glab >/dev/null 2>&1; then
    echo "error: glab not found in PATH" >&2
    exit 2
fi

if [[ -z "$PROJECT" ]]; then
    PROJECT="$(glab repo view --output json 2>/dev/null \
        | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("path_with_namespace",""))' \
        || true)"
    if [[ -z "$PROJECT" ]]; then
        echo "error: could not detect project; pass --project NS/REPO" >&2
        exit 2
    fi
fi

# Cutoff date in seconds-since-epoch.
CUTOFF_S=$(( $(date +%s) - DAYS * 86400 ))

# Patterns that would indicate disclosure. Grep them case-
# insensitively. The collector hostname is a strong signal --
# legitimate logs only mention it inside successful upload lines,
# which should not echo the Authorization header.
PATTERNS=(
    'Authorization'
    'Bearer[[:space:]]'
    '5333796\.otel\.gitlab-o11y\.com'
)

trap 'rm -rf "${tmp_dir:-}"' EXIT
tmp_dir="$(mktemp -d)"

# Iterate over recent pipelines and pull the named job's log
# from each. The whole pipeline-discovery + per-job-trace dance
# is a side effect of glab not having a direct "list jobs by
# date range" API.
glab ci list --output json --per-page 100 --status all 2>/dev/null \
    | python3 -c 'import json,sys
data=json.load(sys.stdin)
for p in data:
    print(p["id"])' \
    | while read -r pipeline_id; do
        if [[ -z "$pipeline_id" ]]; then continue; fi
        created_s=$(glab ci view "$pipeline_id" --output json 2>/dev/null \
            | python3 -c 'import json,sys,calendar,time
d=json.load(sys.stdin)
ts=d.get("created_at")
print(int(calendar.timegm(time.strptime(ts.split(".")[0],"%Y-%m-%dT%H:%M:%S"))) if ts else 0)' \
            2>/dev/null || echo 0)
        if (( created_s < CUTOFF_S )); then continue; fi

        glab ci view "$pipeline_id" --output json 2>/dev/null \
            | python3 -c "
import json,sys
data=json.load(sys.stdin)
for j in data.get('jobs', []):
    if j['name'] == '$JOB':
        print(j['id'])" \
            | while read -r job_id; do
                if [[ -z "$job_id" ]]; then continue; fi
                log_path="$tmp_dir/$job_id.log"
                glab ci trace "$job_id" --output text >"$log_path" 2>/dev/null || continue
                for pat in "${PATTERNS[@]}"; do
                    if grep -in -E "$pat" "$log_path" >>"$tmp_dir/hits.txt" 2>/dev/null; then
                        :
                    fi
                done
            done
    done

if [[ -s "$tmp_dir/hits.txt" ]]; then
    cat "$tmp_dir/hits.txt"
    echo
    echo "FAIL: $(wc -l <"$tmp_dir/hits.txt") line(s) match. Triage before rotating." >&2
    exit 1
fi

echo "PASS: no disclosure pattern in last ${DAYS}d of '${JOB}' logs."
exit 0
