# Settings UI

## What this directory owns

`Sources/UI/Settings/` owns the standalone Settings window, first-run
onboarding, the Home dashboard, people/speaker review settings, and the
settings-side agent connection flow.

## Main split

- `TranscriptedSettingsView.swift` - settings shell, navigation, shared state,
  page routing, and page-level actions. General, Storage, and About
  presentation live in focused page files. Pages own local disclosure and
  confirmation state; persisted state and runtime work stay behind injected
  bindings and actions.
- `TranscriptedSettingsSidebar.swift` - sidebar sections and rows: a primary
  content section (Home/Dictations/Speakers/Agent); the settings pages are
  reached via the sidebar gear and an in-content tab strip (General, Storage,
  About — the settings redesign phase 1 pass dissolved the Beta and Support
  tabs, and the legacy `.models`/`.shortcuts`/`.privacy`/`.beta`/`.support`
  alias cases were later deleted from `TranscriptedSettingsPage` once no live
  caller produced them).
- `TranscriptedSettingsGeneralControls.swift` - compact General-page rows,
  disclosure rows, headings, and info popovers.
- `TranscriptedSettingsRows.swift` - small reusable rows used by Settings:
  model choices, custom corrections, and Auto Enter apps.
- `AgentConnectionSettingsPage.swift` - Settings' agent page: one connect row
  per detected agent (via `AgentMCPConnector`), the universal copy-prompt row,
  and the Advanced disclosure.
- `AutoEnterDisplayNameResolver.swift` - Foundation-pure fallback chain for
  Auto Enter app display names.
- `HomePresentation.swift` - Foundation-pure Home copy, day labels, stable
  feedback ids, and speaker palette slot selection.
- `HomeView.swift` - Home canvas components (Meetings-title header with stats line,
  attention pills, capture list sections), recent capture rows, preview,
  feedback, failed meeting recovery, and retained-audio controls.
- `PermissionsOnboardingView.swift` - first-run onboarding: three quiet steps; permission refresh is event-driven and never uses a repeating ScreenCaptureKit probe
  (welcome, permissions, done), single path, no use-case branching or agent
  setup — agent connection now lives only in `AgentConnectionSettingsPage.swift`.
- `SpeakerPeopleSettingsSection.swift` - speakers surface: the voice-to-name
  queue (one row per distinct voice), compact duplicate-merge suggestions, and
  the searchable all-speakers list with per-row play/rename/merge/delete.
- `SpeakerNamingSheet.swift` - completed-meeting speaker review sheet.
- `Pages/` - one file per standalone settings page split out of
  `TranscriptedSettingsView` (`AboutSettingsPage.swift`,
  `DictationsSettingsPage.swift`, `GeneralSettingsPage.swift`,
  `PeopleSettingsPage.swift`, and `StorageSettingsPage.swift`). Model,
  shortcut, and privacy editors still live behind General disclosures. New
  settings pages should land here as their own file instead of growing the
  shell.
  `BetaSettingsPage.swift` and `SupportSettingsPage.swift` were dissolved in
  the settings redesign phase 1 pass: the two Support rows (email support,
  send diagnostics) moved into `AboutSettingsPage.swift` under a "Support"
  section, and the Beta page's Nemotron toggle was later removed entirely
  along with the Nemotron model itself.
- `TranscriptedSettingsSupportViews.swift` - shared small SwiftUI views used
  across multiple settings pages (support/diagnostics-adjacent rows, now
  rendered from `AboutSettingsPage.swift`).

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

## Verification

```bash
bash build.sh --no-open
bash run-tests.sh
```

Manual checks:

- open Settings and switch every sidebar page
- Home dashboard loads recent dictations, meetings, failed meetings, and stats
- failed meeting retry, reveal, delete, and retained-audio playback work
- custom dictionary edits persist and preview correctly
- Auto Enter app allow/remove controls work
- Agent page can connect detected agents, copy the universal prompt, reveal
  config and folders, and set up the Codex inbox from Advanced
