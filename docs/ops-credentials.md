# Operations Credentials Guide

This document describes the observability lanes used by Transcripted and how to obtain the credentials needed for operational health checks.

## Observability Lanes

| Lane | What it Reports | Required Env Vars | Required Scopes | How to Obtain Credential | Probe Command |
|------|-----------------|-------------------|-----------------|--------------------------|---------------|
| **Sentry** | Crash and reliability diagnostics | `SENTRY_AUTH_TOKEN` | `project:read` | Create an auth token at [Sentry API Tokens](https://sentry.io/settings/account/api/auth-tokens/) with `project:read` scope | `curl -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" "https://sentry.io/api/0/projects/r3dbars/apple-macos/issues/?query=is:unresolved&limit=10"` |
| **PostHog** | Anonymous usage statistics | `POSTHOG_PERSONAL_API_KEY`, `POSTHOG_PROJECT_ID` | Personal API key | Create a Personal API Key in PostHog project settings (Settings -> Personal API keys) | `bash scripts/ops/health-probe.sh posthog` |
| **GitHub** | Release metadata, traffic stats | None (uses `gh auth`) | None (uses authenticated CLI) | Run `gh auth login` in your terminal | `gh api repos/r3dbars/transcripted` |
| **Cloudflare** | Pages deployment status | `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID` | Account-level `Zone:Read` | Create an API Token at [Cloudflare Tokens](https://dash.cloudflare.com/profile/api-tokens) with Account permissions for `Zone:Read` | See `scripts/ops/health-probe.sh cloudflare` |

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

The PostHog probe reports aggregate 7-day counts for active devices, workflow events, onboarding events, and first-value events. First-value events are limited to `onboarding_first_dictation_saved` and `onboarding_agent_cta_clicked`, so the health lane can see whether users reached a saved Markdown artifact or agent payoff without exposing transcript text, file paths, titles, or user identifiers.

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
