# Install Attribution Map

Use this when checking the anonymous path from public interest to first value:

`website pageview -> download intent -> GitHub/Sparkle download -> first app launch -> first useful local Markdown artifact`

The goal is directional attribution, not person-level tracking. Keep the lanes
aggregate, bucketed, and privacy-safe.

## Privacy Boundary

Do not add any user-level join keys between the website and the app.

Do not send raw referrers, URLs, IPs, transcript text, audio references,
meeting titles, speaker names, emails, tokens, absolute file paths, source app
names, or raw device names to PostHog or Sentry.

Allowed signals are coarse counts and bucketed app events that already pass
through `AnalyticsEventPolicy` and `AnalyticsPayloadSanitizer`.

## Current Signal Map

| Funnel stage | Signal | Source | Notes |
| --- | --- | --- | --- |
| Website interest | Page views, requests, deployment freshness | Cloudflare Pages and Web Analytics for `transcripted.app` | Directional only. Cloudflare can show public-site demand, but it should not be joined to app devices. |
| Download intent | `/download` page loads and `/download/latest.dmg` redirect health | Live site plus Cloudflare | Good for checking the handoff works. Path-level counts depend on Cloudflare analytics access. |
| Release download | GitHub release asset download count | GitHub Releases | Counts public DMG downloads, including repeat downloads and automation. |
| In-app update download | `update_check_finished`, `update_download_started`, `update_download_finished`, `update_ready_to_install`, `update_relaunching`, `update_installed` | PostHog | App-side update funnel. Use version-scoped aggregate counts. |
| First launch | `app_launched` with `app_version` and `build_version` default properties | PostHog | Anonymous device/session signal only. |
| First useful artifact | `activation_first_artifact_saved` | PostHog | Strict first saved dictation or meeting Markdown artifact, emitted once per install without inspecting content. |
| Saved-artifact continuity | `onboarding_first_dictation_saved`, `dictation_completed`, `meeting_transcript_saved` | PostHog | Legacy/proxy row for older builds and useful-dictation volume. Do not use it as strict first-artifact proof when `activation_first_artifact_saved` is available. |
| Agent payoff | `activation_artifact_action_clicked`, `activation_agent_prompt_action_clicked`, `activation_agent_setup_cta_clicked`, `activation_return_proxy_observed` | PostHog | Coarse proof of opening artifacts, copying/using agent prompts, setup CTAs, and later return via Home. |
| Reliability filter | Release-scoped issues and allowed non-fatal events | Sentry | Use to avoid mistaking broken first-run paths for weak demand. |

## Standard Read-Only Checks

Load ops credentials only in your shell and do not print them:

```bash
set -a
[ -f "$HOME/.hermes/.env" ] && source "$HOME/.hermes/.env"
[ -f "$HOME/.zprofile" ] && source "$HOME/.zprofile" >/dev/null 2>&1 || true
set +a
```

Then run the aggregate probes:

```bash
bash scripts/ops/health-probe.sh all
python3 scripts/ops/release-health-card.py --version "$(plutil -extract CFBundleShortVersionString raw Info.plist)" --hours 168
curl -sSIL https://transcripted.app/download/latest.dmg
curl -sSL https://transcripted.app/appcast.xml | head -40
```

For the attribution story, report:

- Cloudflare 7-day page views and whether the live download page has the
  analytics beacon
- GitHub latest-release DMG download count and asset size
- live `/download/latest.dmg`, live appcast, and `llms-full.txt` release parity
- PostHog 7-day app launches, update events, dictation completions, meeting
  transcript saves, activation agent/artifact events, and return-proxy events
- Sentry release blockers that could suppress launch or first value

## Missing Signals To Keep Explicit

- There is no privacy-safe identity join from a website visitor to a GitHub
  download to an app device. Treat that as intentional.
- GitHub release downloads are not installs. They can include repeat downloads,
  bots, failed installs, or users saving the DMG for later.
- Cloudflare page views are not download completions unless a path-level
  analytics read proves the specific `/download` or `/download/latest.dmg`
  route.
- `app_launched` does not prove a first useful artifact. Use
  `activation_first_artifact_saved` for strict first saved-Markdown proof.
  Keep `dictation_completed`, `onboarding_first_dictation_saved`, and
  `meeting_transcript_saved` as continuity/proxy signals for older builds.
- Artifact events do not prove agent answer quality. The closest safe proxy is
  `activation_agent_prompt_action_clicked` plus `activation_return_proxy_observed`.

If the story is still fuzzy after these checks, prefer adding a coarse
allowlisted event or aggregate script output over adding tracking IDs.
