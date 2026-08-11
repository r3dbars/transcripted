# Settings UI

## What this directory owns

`Sources/UI/Settings/` owns the standalone Settings window, first-run
onboarding, the Home dashboard, people/speaker review settings, and the
settings-side agent connection flow.

## Main split

- `TranscriptedSettingsView.swift` - settings shell, navigation, shared state,
  page routing, and page-level actions. General, Storage, About, and Home
  presentation live in focused page files. The combined settings page is
  card-based (2026-08 restyle): every setting is an always-visible row inside
  a `SettingsCard` — no disclosures — with per-topic editors injected from
  the shell as closures (shortcuts, Bluetooth mic, auto-send, speakers,
  model, mic processing, permissions, reporting). Row explanations live in
  each row's ⓘ `GeneralInfo` popover, not in captions; the corrections
  editor opens as a sheet. Pages own local confirmation state; persisted
  state and runtime work stay behind injected bindings and actions. Home's
  extraction (`Pages/HomeSettingsPage.swift`) only moved pure view assembly —
  the shell still owns every Home side effect (delete/rename/copy/
  retranscribe, the shared root alert, undo staging, analytics) both because
  those are runtime work and because several pieces
  (`handleCopyMeeting`/`handleRetranscribeMeeting`,
  `toggleHomeMeetingExpansion`/`collapseHomeMeetingExpansion`, the
  `RootAlert` enum and `rootAlertBinding`, `dictationRowMenuItems`/
  `meetingRowMenuItems`, `revealOwnFile`/`openOwnFile`) are pinned in place
  by literal-source-text assertions in `Tests/UIAutomationSurfaceContractTests.swift`.
- `TranscriptedSettingsSidebar.swift` - sidebar sections and rows: a primary
  content section (Home/Dictations/Speakers/Agent); all configuration lives
  on one combined scrolling settings page reached from the sidebar gear — the
  old General/Storage/About tab strip was removed, and `.storage`/`.about`
  (like the earlier `.models`/`.shortcuts`/`.privacy`/`.beta`/`.support`
  aliases) were deleted from `TranscriptedSettingsPage`.
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
  `HomeSettingsPage.swift`, `PeopleSettingsPage.swift`, and
  `StorageSettingsPage.swift`). Model, shortcut, and privacy editors still
  live behind General disclosures. New settings pages should land here as
  their own file instead of growing the shell. `HomeSettingsPage.swift` owns
  the header, scan-warning/activity rows, search field, and day-grouped
  meeting list rendering (including the expanded-row preview and inline
  failed-meeting rows); it takes the meeting day sections, attention title,
  and every row action as injected values/closures and holds no runtime
  logic of its own — see the note on `TranscriptedSettingsView.swift` above
  for why the rest of Home stayed in the shell.
  `BetaSettingsPage.swift` and `SupportSettingsPage.swift` were dissolved in
  the settings redesign phase 1 pass: the two Support rows (email support,
  send diagnostics) moved into `AboutSettingsPage.swift` under a "Support"
  section, and the Beta page's Nemotron toggle was later removed entirely
  along with the Nemotron model itself.

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
- failed meeting retry, reveal, delete, and retained-audio playback work; active transcript rows follow the selected audio source and playhead
- custom dictionary edits persist and preview correctly
- Auto Enter app allow/remove controls work
- Agent page can connect detected agents, copy the universal prompt, reveal
  config and folders, and set up the Codex inbox from Advanced
