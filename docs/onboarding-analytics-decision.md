# Onboarding analytics: decision pending

Owner worksheet for OBSERVABILITY-3. **No option is selected.** This document
changes no event schema, emitter, onboarding step, query, test or user control.
The source review uses main `8a38235eef00816a79daa1324387a21ef880204d`.

## Current source evidence

These names remain in `Resources/analytics-events.psv`, but no emitter was
found for them in the current `Sources/` or `Tools/` code:

- `onboarding_agent_cta_clicked`
- `onboarding_first_dictation_empty`
- `onboarding_first_dictation_started`
- `onboarding_first_dictation_stop_clicked`
- `onboarding_meeting_dry_run_clicked`
- `onboarding_model_state_changed`
- `onboarding_reporting_toggle_changed`

`Sources/UI/Settings/OnboardingNavigation.swift` defines welcome, permissions
and done. `PermissionsOnboardingView.swift` in that folder still emits step,
permission, primary-action and completion events. The app delegate emits
`onboarding_shown`. `Sources/UI/Overlay/DictationSessionController+Persistence.swift`
still emits `onboarding_first_dictation_saved`; it is not one of the seven.

`Sources/UI/Shared/FirstRunExperience.swift` builds the current
`onboarding_completed` properties without `meeting_dry_run_completed` or
`model_state`. Both remain allowed on that event. `model_state` remains used
on other events and must not be removed globally as part of this decision.

The emitter checker reports registered-but-unemitted names as informational.
A registry entry permits collection; it does not demonstrate that a UI emits
it. This source review establishes neither historical retirement dates nor
fleet counts, installed-version mix, delivery health or a user's drop-off.

## Existing consumers

The names appear in `docs/privacy-first-observability.md`,
`docs/ops-credentials.md` and `docs/posthog-100-wau-dashboard.md`.
The following ops consumers include subsets in event sets, aggregates,
combined query stages or reporting heuristics:

- `scripts/ops/health-probe.sh`
- `scripts/ops/posthog-dashboard-queries.py`
- `scripts/ops/posthog-activation-funnel.py`
- `scripts/ops/posthog-product-context-pack.py`
- `scripts/ops/posthog-product-dashboard-summary.py`
- `scripts/ops/generate-nightly-digest.py`

`Tests/AnalyticsEventPolicyTests.swift` requires these schema entries and calls
some active. The product-context pack's self-test also requires the old agent
CTA to remain queryable. Combined stages include live alternatives, so a zero
for an old name does not by itself mean no capture or agent activity occurred.

## Owner choice

- [ ] **A — Retire these names from the current schema and reporting.** Remove the
  seven event rows and current-event doc entries, plus only the two unused
  properties from `onboarding_completed`. Update dependent schema tests and
  the relevant ops sets, queries, labels and heuristics together. Preserve
  live events and their meanings. Check whether unused reviewed-property
  entries should also be removed; retain `model_state` for its other events.
- [ ] **B — Keep compatibility names and label their historical role.** Retain
  schema/query compatibility, but describe these names as not emitted by the
  reviewed current source. Qualify current funnel labels and interpretation
  so a zero is not presented as user drop-off. Do not add emitters or restore
  removed onboarding steps implicitly. Retained allowlist rows still permit
  future collection; they do not enforce retirement.
- [ ] **C — Revise the measurement plan before selecting either approach.**

Removing old members from combined queries changes historical or mixed-version
aggregates. Decide whether separate historical queries are needed. Removing
rows from a new app's bundled registry neither deletes stored events nor
changes an older installed app's registry.

## Proof after a decision

Validate the selected registry/sanitizer boundary and ops output with synthetic
fixtures, preserving live controls and historical-query intent. Recheck all
consumers before implementation. Protected onboarding, menu actions and the
analytics/diagnostics toggles remain unchanged by this worksheet.

No private analytics query, event delivery, live onboarding or native permission
flow was exercised. No security, privacy-risk or retention policy is adopted.
