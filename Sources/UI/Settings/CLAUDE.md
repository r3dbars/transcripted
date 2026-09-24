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
- `TranscriptedSettingsGeneralControls.swift` - `SettingsCard` and its
  label, control/toggle/action rows, the dictation overlay mode picker, and
  the `GeneralInfo` ⓘ popovers.
- `TranscriptedSettingsComponents.swift` - shared page pieces:
  `persistedSettingsBinding`, `SettingsPageIntro`, hover/inline button
  styles, `SettingsStatusCard`, permission status rows, and the hotkey
  recorder container.
- `TranscriptedSettingsPage.swift` - the sidebar page enum.
- `TranscriptedSettingsNavigationModel.swift` - `@Observable` selected/presented
  page plus the ⌘F Home find-focus token.
- `TranscriptedSettingsActions.swift` - app-level closures injected into the
  shell (start dictation/meeting, import audio, feedback, diagnostics).
- `TranscriptedSettingsWindowController.swift` /
  `TranscriptedOnboardingWindowController.swift` - AppKit windows hosting the
  settings shell and onboarding view.
- `TranscriptedSettingsRows.swift` - small reusable rows used by Settings:
  model choices, custom corrections, and Auto Enter apps.
- `DictionaryPastMeetingsLine.swift` - the quiet "Also in N past meetings. Fix them" line
  under a correction in the Corrections sheet, plus its main-actor model
  (debounced background count, a confirm with the count before the first
  write, Fix, Undo/Try again). While a row's edit is being recounted the line
  keeps its last state with Fix disabled, so typing doesn't make it jump.
  Fix results are keyed by row id, so editing a
  correction keeps its Undo, and reload from the on-disk backups after a
  relaunch. A recent fix whose correction was edited away is listed under
  the corrections with its own Undo. The file work lives in
  `Sources/UI/Shared/DictionaryPastMeetingFix.swift`.
- `AgentConnectionSettingsPage.swift` - Settings' agent page: one connect row
  per detected agent (via `AgentMCPConnector`), the universal copy-prompt row,
  and the Advanced disclosure.
- `AutoEnterDisplayNameResolver.swift` - Foundation-pure fallback chain for
  Auto Enter app display names.
- `HomePresentation.swift` - Foundation-pure Home copy, day labels, stable
  feedback ids, and speaker palette slot selection.
- `HomeMeetingSearchIndex.swift` - Foundation-pure in-memory index behind the
  Home meetings search box. It covers every saved meeting (not just the
  paged slice Home shows) and matches title, date words, and named speakers
  via `HomeSearchMatching.swift`. `HomeViewModel` builds it off-main from
  `RecentMeetingsScanner.loadSearchIndex`, reuses unchanged rows on rebuild,
  and resolves audio only for the matches it shows. Timed by the Home
  recent-captures benchmark.
- `HomeView.swift` - `HomeViewModel` plus Home building blocks: day-grouped
  list and capture-list sections, row action buttons/menus, search field,
  scan-warning card, inline failed-meeting row (retry/retained audio),
  feedback sheet, and the preview/attention models.
- `QuietHomeLibrary.swift` - quiet-library Meetings components (2026-08
  redesign): header sentence, meeting/working rows, and the in-place
  expansion with speaker labels and naming.
- `QuietDictationLibrary.swift` - the matching per-entry Dictations rows and
  expansion.
- `HomeMeetingAudioPlayer.swift` - meeting-audio player and speaker color
  palette shared by the Home expansion.
- `HomeMeetingPreviewFormatter.swift` - transcript preview content and staged
  speaker-correction/naming plans.
- Foundation-pure Home policy/copy helpers (fast-testable, no SwiftUI):
  `HomeSearchMatching.swift` (list filter + in-transcript find),
  `HomeRootAlertPolicy.swift` (single alert presenter routing +
  `HomeActionFailureCopy`), `HomeDeleteConfirmationPolicy.swift`,
  `HomeScanWarningPolicy.swift`, `HomeTranscriptionActivityPresentation.swift`
  and `HomeTranscriptionActivityCopy.swift`,
  `HomeFailedMeetingInlinePresentation.swift`,
  `FailedMeetingRecoveryPresentation.swift` (retry availability), and
  `SettingsRecentCaptureRefreshPolicy.swift` (when pages refresh captures).
- Plain-words failure copy: `AgentSetupFailureCopy.swift` (Agent page) and
  `SettingsActionFailureCopy.swift` (Settings actions).
- `MeetingLanguageSettingRow.swift` / `MeetingMicrophoneSettingRow.swift` -
  meeting-only language picker and Mac-selected-mic toggle rows.
- `HotkeyRecorderAppKitView.swift` - AppKit shortcut recorder.
- `OnboardingAbandonmentReasonPolicy.swift` - maps an onboarding exit to its
  telemetry abandonment reason.
- `PermissionsOnboardingView.swift` - first-run onboarding: three quiet steps; permission refresh is event-driven and never uses a repeating ScreenCaptureKit probe
  (welcome, permissions, done), single path, no use-case branching or agent
  setup — agent connection now lives only in `AgentConnectionSettingsPage.swift`.
- `SpeakerPeopleSettingsSection.swift` - speakers surface: the voice-to-name
  queue (one row per distinct voice), compact duplicate-merge suggestions, and
  the searchable all-speakers list with per-row play/rename/merge/delete.
- `SpeakerNamingSheet.swift` - completed-meeting speaker review sheet.
- `SpeakerVoiceRowPresentation.swift` - Foundation-pure play/pause, overflow
  menu, and name-suggestion policies for the voice-to-name rows.
- `SpeakerNameAutocompleteField.swift` - SwiftUI wrapper over the naming
  sheet's `NSComboBox` autocomplete.
- `RetainedDataSourceComboBox.swift` - `NSComboBox` subclass that keeps its
  data source alive (fixes a dangling `assign` data-source crash).
- `Pages/` - one file per standalone settings page split out of
  `TranscriptedSettingsView` (`AboutSettingsPage.swift`,
  `DictationsSettingsPage.swift`, `GeneralSettingsPage.swift`,
  `HomeSettingsPage.swift`, `PeopleSettingsPage.swift`, and
  `StorageSettingsPage.swift`). Model, shortcut, and privacy editors are
  injected into General's cards as closures. New settings pages should land here as
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
- failed meeting retry, reveal, delete, and retained-audio playback work
- custom dictionary edits persist and preview correctly
- Auto Enter app allow/remove controls work
- Agent page can connect detected agents, copy the universal prompt, reveal
  config and folders, and set up the Codex inbox from Advanced
