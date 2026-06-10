# Settings UI

## What this directory owns

`Sources/UI/Settings/` owns the standalone Settings window, first-run
onboarding, the Home dashboard, people/speaker review settings, and the
settings-side agent connection flow.

## Main split

- `TranscriptedSettingsView.swift` - settings shell, navigation, shared state,
  page routing, and page-level actions.
- `TranscriptedSettingsSidebar.swift` - sidebar sections and rows: a primary
  content section (Home/Meetings/Dictations/Speakers/Agent) plus Setup/Trust
  sections revealed by the sidebar Settings toggle.
- `TranscriptedSettingsGeneralControls.swift` - compact General-page rows,
  disclosure rows, headings, and info popovers.
- `TranscriptedSettingsRows.swift` - small reusable rows used by Settings:
  model choices, custom corrections, Auto Enter apps, failed meetings, and
  recent-meeting audio controls.
- `AgentConnectionSettingsPage.swift` - Settings' agent page, including Claude
  Desktop install/copy/reveal flows.
- `HomeMeetingSummaryBetaPresentationPolicy.swift` - Home dashboard gates for
  showing opt-in local AI meeting-summary titles, previews, badges, and menu
  actions.
- `HomeView.swift` - Home canvas components (greeting header, attention pills,
  context ring view, capture list sections), recent capture rows, preview,
  feedback, and failed meeting entry points.
- `HomeContextCompleteness.swift` - pure scoring model behind the sidebar
  context ring plus the time-of-day greeting helper.
- `PermissionsOnboardingView.swift` - first-run permissions and agent setup
  walkthrough.
- `SpeakerPeopleSettingsSection.swift` - people/speaker profile list, naming,
  merging, review filters, and local-speaker split preference UI.
- `SpeakerNamingSheet.swift` - completed-meeting speaker review sheet.

## Guardrails

- Keep `TranscriptedSettingsView` as the shell. New row/view helpers should
  usually live in a focused sibling file instead of being appended there.
- Keep the agent setup flow in `AgentConnectionSettingsPage.swift`; it should
  share copy through `AgentConnectionGuide`, not duplicate prompt text.
- Keep General-page row styling in `TranscriptedSettingsGeneralControls.swift`
  so model, shortcut, privacy, and correction editors stay visually aligned.
- Settings SwiftUI views can own local `@State`, but app/runtime side effects
  should still route through injected controllers, preferences, or actions.
- Do not put meeting transcript parsing, speaker database work, or retained
  audio cleanup here. Use `Sources/Meeting/`, `Sources/TranscriptedCore/`, or
  `Sources/UI/Shared/` for those ownership seams.
- Local AI meeting summary actions must stay blocked during active dictation,
  active meeting recording, model prep, background meeting work, and speaker
  review. Keep those gates in shared policy instead of duplicating state checks
  across row actions.

## Verification

```bash
bash build.sh --no-open
bash run-tests.sh
```

Manual checks:

- open Settings and switch every sidebar page
- Home dashboard loads recent dictations, meetings, failed meetings, and stats
- failed meeting retry, reveal, delete/dismiss, and retained-audio playback work
- custom dictionary edits persist and preview correctly
- Auto Enter app allow/remove controls work
- Agent page can copy prompts, reveal config, and install/repair Claude Desktop
