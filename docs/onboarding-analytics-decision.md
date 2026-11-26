# Onboarding analytics: decision (Option A, partial)

Owner decision record for OBSERVABILITY-3. **Justin approved Option A (partial):**
remove the five retired dead events from the current schema and reporting, keep
`onboarding_first_dictation_started` and `onboarding_first_dictation_empty`
because `Sources/UI/Settings/PermissionsOnboardingView.swift` actively emits
them, and keep the existing `onboarding_completed` allowlisted properties
(`meeting_dry_run_completed` and `model_state`) intact.

## Current source evidence

Five names in `Resources/analytics-events.psv` had no emitter in `Sources/` or
`Tools/` and were retired:

- `onboarding_agent_cta_clicked`
- `onboarding_first_dictation_stop_clicked`
- `onboarding_meeting_dry_run_clicked`
- `onboarding_model_state_changed`
- `onboarding_reporting_toggle_changed`

Two names from the original seven-event candidate list remain live and were kept:

- `onboarding_first_dictation_started` — actively emitted by `Sources/UI/Settings/PermissionsOnboardingView.swift`
- `onboarding_first_dictation_empty` — actively emitted by `Sources/UI/Settings/PermissionsOnboardingView.swift`

`Sources/UI/Settings/OnboardingNavigation.swift` defines welcome, permissions
and done. `PermissionsOnboardingView.swift` in that folder still emits step,
permission, primary-action, first-dictation (`started` / `empty`), and completion
events. The app delegate emits `onboarding_shown`.
`Sources/UI/Overlay/DictationSessionController+Persistence.swift` still emits
`onboarding_first_dictation_saved`; it is not one of the retired names.

`Sources/UI/Shared/FirstRunExperience.swift` builds the current
`onboarding_completed` properties without `meeting_dry_run_completed` or
`model_state`. Both properties remain allowed on `onboarding_completed` under
the approved partial Option A scope. `model_state` also remains used on other
events and was not removed globally.

The emitter checker reports registered-but-unemitted names as informational.
A registry entry permits collection; it does not demonstrate that a UI emits
it. This source review establishes neither historical retirement dates nor
fleet counts, installed-version mix, delivery health or a user's drop-off.

## Existing consumers

The names appeared in `docs/privacy-first-observability.md`,
`docs/ops-credentials.md` and `docs/posthog-100-wau-dashboard.md`, and in the
ops consumers below:

- `scripts/ops/health-probe.sh`
- `scripts/ops/posthog-dashboard-queries.py`
- `scripts/ops/posthog-activation-funnel.py`
- `scripts/ops/posthog-product-context-pack.py`
- `scripts/ops/posthog-product-dashboard-summary.py`
- `scripts/ops/generate-nightly-digest.py`

Dependent schema tests (`Tests/AnalyticsEventPolicyTests.swift`), docs, and ops
queries were updated together for the five retired names while preserving live
events (`onboarding_first_dictation_started`, `onboarding_first_dictation_empty`,
`onboarding_first_dictation_saved`, and `onboarding_completed`).

## Owner choice

- [x] **A — Retire dead names from the current schema and reporting (approved — partial).**
  Remove the five genuinely unemitted event rows (`onboarding_agent_cta_clicked`,
  `onboarding_first_dictation_stop_clicked`, `onboarding_meeting_dry_run_clicked`,
  `onboarding_model_state_changed`, `onboarding_reporting_toggle_changed`) and
  their current-event doc/ops references. Keep `onboarding_first_dictation_started`
  and `onboarding_first_dictation_empty` (actively emitted by
  `PermissionsOnboardingView.swift`), and keep `onboarding_completed` properties
  unchanged (`meeting_dry_run_completed` and `model_state` retained).
- [ ] **B — Keep compatibility names and label their historical role.**
- [ ] **C — Revise the measurement plan before selecting either approach.**

Removing rows from a new app's bundled registry neither deletes stored events
nor changes an older installed app's registry.

## Proof after decision

Validated the updated registry/sanitizer boundary, schema tests, and ops
self-tests with synthetic fixtures while keeping live controls, protected
onboarding flows, and analytics/diagnostics toggles unchanged.
