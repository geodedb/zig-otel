# Runbook: rotating `OTEL_INTEGRATION_AUTH_HEADER`

**Owner:** <benji@codepros.org>
**Tracks:** GitLab issue #80 (H-7, confidential)
**Cadence:** quarterly (next: 2026-07-26); plus this one-time
post-audit rotation by **2026-05-03**.

This runbook describes how to rotate the GitLab CI/CD variable
`OTEL_INTEGRATION_AUTH_HEADER` used by the `otlp-integration-live`
job to authenticate against the GitLab Observability collector.

## Why rotate

Phase-3 of the 2026-04-26 PM re-audit closed all code-side
exposure paths (commits `43330db`, `e508627`, `553502b`,
`ea94ef9`). H-7 remains open as an operator action: until the
token in CI variables is rotated, treat the previous value as
**potentially compromised by policy**, even though no leak is
suspected. CI logs from the audit window are also worth a sweep
before rotation completes — see step 3.

## Steps

### 1. Generate the new token

In GitLab Observability:

1. Navigate to **Settings → Tokens** in the GitLab UI for the
   `5333796.otel.gitlab-o11y.com` collector.
2. Create a new ingest token. Scope: `traces:write`,
   `metrics:write`, `logs:write` — match the existing token's
   scopes; do not over-grant.
3. Copy the token value to your local secret store. Do **not**
   paste it into chat, email, or PR descriptions.

### 2. Pre-rotation CI log audit

While the old token is still valid, run the audit script against
the last 90 days of `otlp-integration-live` job logs:

```bash
scripts/audit_ci_logs.sh --days 90 --job otlp-integration-live
```

The script greps for `Authorization`, `Bearer<space>`, and the
collector hostname `5333796.otel.gitlab-o11y.com`. Any hit is a
disclosure event that needs to be triaged before rotation
completes (rotating early invalidates the leaked token, but the
incident still needs documentation).

If the audit returns no hits, proceed to step 3. If it returns
hits, fork to the standard incident-response runbook (out of scope
for this document).

### 3. Replace the GitLab CI variable

1. **Project → Settings → CI/CD → Variables.**
2. Find `OTEL_INTEGRATION_AUTH_HEADER`. Open the row for editing.
3. Replace the value with the new token. Confirm scope flags:
   * **Masked:** YES (so the value is `[masked]` in logs)
   * **Protected:** YES (only available to protected branches)
   * **Expanded:** NO (do not expand `$VAR` references)
4. Save.

### 4. Verify

Trigger one `otlp-integration-live` pipeline (manual run is fine):

```bash
glab ci run --variables 'OTEL_RUN_INTEGRATION=true' \
            --branch main
```

Watch the job log:

* It must show `OTLP integration test PASS`.
* It must NOT echo the new token (the masking should redact it
  to `[masked]`).
* If you see the token echoed, a previously-recorded test or
  shell tracing is logging it — triage and patch before
  rotating again.

### 5. Revoke the old token

Once verification passes, revoke the previous token in GitLab
Observability:

1. Navigate back to **Settings → Tokens**.
2. Find the old token (the one you replaced in step 3).
3. Click **Revoke**.

The previous value is now invalid for any future ingest attempt.

### 6. Update the rotation tracker

Edit `docs/SECURITY_GAP_ANALYSIS.md` step 5 ("Quarterly token-
rotation cron") to set the next rotation date to today + 90 days.

Update GitLab issue #80 (confidential) with:

```text
Rotated YYYY-MM-DD; next rotation YYYY-MM-DD; CI log audit clean (or triaged → ticket #NNN).
```

## After rotation

* The previous token is **dead**. Any future log line that
  contains it is now an after-the-fact disclosure of a revoked
  secret — still worth scrubbing on your normal cadence, but
  no operational risk.
* The 90-day cron is the steady-state ongoing process. Set a
  calendar reminder for the next rotation date.

## Out-of-band escalation

If at any step you suspect an active disclosure (token visible
in a public log, unexpected ingest from an unfamiliar source,
etc.):

1. **Revoke the old token immediately** (step 5, out of order).
2. Open a confidential GitLab issue under the project's
   `security-incident` label.
3. Notify <security@codepros.dev>.
4. Fork to the incident-response runbook.
