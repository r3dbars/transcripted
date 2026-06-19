# Operations Credentials Guide

This document describes the observability lanes used by Transcripted and how to obtain the credentials needed for operational health checks.

## Observability Lanes

| Lane | What it Reports | Required Env Vars | Required Scopes | How to Obtain Credential | Probe Command |
|------|-----------------|-------------------|-----------------|--------------------------|---------------|
| **Sentry** | Crash and reliability diagnostics | `SENTRY_AUTH_TOKEN` | `project:read` | Create an auth token at [Sentry API Tokens](https://sentry.io/settings/account/api/auth-tokens/) with `project:read` scope | `curl -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" "https://sentry.io/api/0/projects/r3dbars/apple-macos/issues/?query=is:unresolved&limit=10"` |
| **Sentry Releases** | Release registration and debug symbols | `SENTRY_AUTH_TOKEN` or configured `sentry-cli` auth | `project:releases`, `project:write`, plus `org:read` for `sentry-cli` release management | Use the same Sentry token surface, with release-management scopes added only on release machines | `bash scripts/release/register-sentry-release.sh <version>` |
| **PostHog** | Anonymous usage statistics | `POSTHOG_PERSONAL_API_KEY`, `POSTHOG_PROJECT_ID` | Personal API key | Create a Personal API Key in PostHog project settings (Settings -> Personal API keys) | `bash scripts/ops/health-probe.sh posthog` |
| **GitHub** | Release metadata, traffic stats | None (uses `gh auth`) | None (uses authenticated CLI) | Run `gh auth login` in your terminal | `gh api repos/r3dbars/transcripted` |
| **Cloudflare Pages Read** | Pages project, deployment, zone, and analytics status | `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | Account-level `Pages Read`, plus `Zone Read` and analytics read access for the checked zones | Create an API Token at [Cloudflare Tokens](https://dash.cloudflare.com/profile/api-tokens) with Pages read access for the account and zone analytics read access for `transcripted.app` and `r3d.bar` | See `scripts/ops/health-probe.sh cloudflare` |
| **Cloudflare Pages Deploy** | Manual Pages deploys for live web surfaces | `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | Account-level `Pages Write` | Use a deployment-scoped token only on machines allowed to publish Pages artifacts | Deploy from the web repo after source and live-release checks pass |

## Important Notes

### Write-Only Keys Are Not Readable

The app's `Info.plist` contains write-only keys that **must not be repurposed** for read operations:

- `TranscriptedSentryDSN` — Sentry Data Source Name (write-only, for client-side crash reporting)
- `TranscriptedPostHogAPIKey` — PostHog API Key (write-only, for client-side analytics)

These keys are embedded in the app binary and are designed for **outbound data transmission only**. They do not grant read access to the corresponding dashboards or APIs. Always use the dedicated read tokens described above for operational health checks.

### Privacy Contract

When running health checks or operational probes, **never** log or expose:

- Transcript text or audio file references
- Meeting titles or speaker names
- Bundle IDs or absolute file paths
- Email addresses, tokens, or raw URLs
- Full event payloads or user identifiers

Only report aggregate counts, status codes, deployment IDs, and issue titles. For the full privacy contract, see [`privacy-first-observability.md`](./privacy-first-observability.md).

### PostHog Probe Shape

The PostHog probe reports aggregate 7-day counts for active devices, workflow events, onboarding events, and first-value events. It also prints a 7-day daily active-device trend so operators can see whether DAU is rising, flat, or missing without inspecting user-level data. First-value events are limited to `dictation_completed`, `onboarding_first_dictation_saved`, `meeting_transcript_saved`, `onboarding_agent_cta_clicked`, `activation_first_artifact_saved`, `activation_artifact_action_clicked`, `activation_agent_prompt_action_clicked`, `activation_agent_setup_cta_clicked`, and `activation_return_proxy_observed`, so the health lane can see whether users reached successful dictation, a saved Markdown artifact, or agent payoff without exposing transcript text, file paths, titles, or user identifiers.

For the full anonymous website-to-first-value attribution contract, see
[`install-attribution-map.md`](./install-attribution-map.md).

If `POSTHOG_HOST` points at the app ingest host, such as `https://us.i.posthog.com`, the probe normalizes it to the matching PostHog API host before running HogQL. The probe only sends `POSTHOG_PERSONAL_API_KEY` to HTTPS PostHog API hosts by default. Set `POSTHOG_ALLOW_UNTRUSTED_HOST=1` only when using a trusted self-hosted PostHog endpoint.

For a deeper activation decision read, run:

```bash
python3 scripts/ops/posthog-activation-funnel.py --days 30
```

That report writes aggregate Markdown and JSON under
`/tmp/transcripted-posthog-activation-funnel/<run-id>/`. It models the funnel as
launch -> onboarding -> permission ready -> first dictation -> saved Markdown
-> artifact action -> agent setup/prompt signal -> return proxy. It does not
export distinct IDs, person rows, transcript text, file paths, meeting titles,
raw URLs, or raw payload rows. Treat the agent setup and prompt-copy rows as
proxies only; they are not proof that an agent answered from a saved artifact.
The desired true-use event is `agent_capture_query_observed`, which should stay
zero/unknown until that privacy-safe instrumentation exists.

### Cloudflare Read vs Deploy

The health probe reads Pages project/deployment status and zone analytics for
`transcripted.app` and `r3d.bar`. A token that can run
`bash scripts/ops/health-probe.sh cloudflare` is not proof that it can publish a
Pages deployment. Manual deploys need `Pages Write`; identity or read-only
project access can still fail at deploy time.

## Quick Start

1. Set your credentials as environment variables (or in your shell profile):
   ```bash
   export SENTRY_AUTH_TOKEN="your-sentry-token"
   export POSTHOG_PERSONAL_API_KEY="your-posthog-key"
   export POSTHOG_PROJECT_ID="your-project-id"
   export CLOUDFLARE_API_TOKEN="your-cloudflare-token"
   export CLOUDFLARE_ACCOUNT_ID="your-account-id"
   ```

2. Run the health probe script:
   ```bash
   bash scripts/ops/health-probe.sh all
   ```

3. For individual lanes:
   ```bash
   bash scripts/ops/health-probe.sh github
   bash scripts/ops/health-probe.sh sentry
   bash scripts/ops/health-probe.sh posthog
   bash scripts/ops/health-probe.sh cloudflare
   ```

If required credentials are missing, the script will print `SKIP <lane>: missing <VAR_NAME>` and exit with code 0 (non-fatal).
