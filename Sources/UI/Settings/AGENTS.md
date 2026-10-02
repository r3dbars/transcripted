# Settings UI

## What this directory owns

`Sources/UI/Settings/` owns the standalone Settings window, first-run
onboarding, the Home dashboard, people/speaker review settings, and the
settings-side agent connection flow.

## Module

`UISettings` in `.agents/modules.json`.

- **Owns:** the main window (sidebar, Today, Meetings, Dictations, Writing, Speakers, Agent, the combined settings page), first-run onboarding, and speaker naming and review.
- **Public surface:** `TranscriptedSettingsWindowController`, `TranscriptedSettingsPage`, `PermissionsOnboardingView` and the onboarding window, `SpeakerNamingSheet`, `HomeView`, the `Pages/` views.
- **May depend on:** UIShared, UIOverlay, AppState, Capture, WritingBridge, WritingCore, WritingRuntime, Meeting, Dictation, Speech, Support, Observability, Core `core-vocab`. Only AppShell and UIMenuBar may depend on it.
- **Grandfathered crossings:** the Speakers directory (`SpeakerPeopleSettingsSection.swift`, `SpeakerNamingSheet.swift` and friends) uses Core engine types like `SpeakerDatabase`, `SpeakerClipExtractor` and `TranscriptSaver` directly; the target is Meeting facades. `HotkeyRecorderAppKitView.swift` names `MenuTokens` from the menu bar. Both are in `.agents/module-boundary-baseline.json`; don't add more.
- **Entry points:** `TranscriptedSettingsWindowController.swift` opens the window; `TranscriptedSettingsView.swift` is the shell.
- **Tests:** `bash run-tests.sh --filter Home`, `--filter Settings`, `--filter Speaker`, `--filter UIAutomationSurfaceContract`.
- **Rules:** keep the Speakers directory with review, rename, merge and delete, per-app Auto Enter, and model-cache inspection and cleanup (product surface). See "Guardrails" below.

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
  retranscribe, the shared root alert, undo staging, analytics).
  The shell file keeps the stored state, `init`, `body`, and the Home row
  actions (copy, re-transcribe, expansion, row menus, delete with undo), which
  `Tests/UIAutomationSurfaceContractTests.swift` still pins by source text.
  The rest are extensions of the same view:
  `TranscriptedSettingsView+Pages.swift` (sidebar, detail column, page
  routing, Today/Meetings/Dictations and the other page hosts),
  `+HomeMeetingActions.swift` (the shared `RootAlert`, rename, speaker
  naming, failed meetings, `revealOwnFile`/`openOwnFile`, failure alerts),
  `+GeneralEditors.swift` (the combined page and its injected editors),
  `+Refresh.swift` (state refresh, analytics, model cache, launch at login),
  and `+Preferences.swift` (corrections, capture library, Auto Enter,
  update actions).
- `TranscriptedSettingsSidebar.swift` - sidebar sections and rows: a primary
  content section (Today/Meetings/Dictations/Writing/Speakers/Agent); the
  Writing row carries a quiet trailing "New" badge until
  `WritingSidebarNewBadge.dismissedDefaultsKey` is set. All configuration lives
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
- `TranscriptedSettingsPage.swift` - the sidebar page enum. `.today` is first
  and the default on open (⌘1); Meetings keeps the `home` raw value (⌘2) so
  automation ids, analytics `page_id`, and source pins stay stable. Then
  Dictations ⌘3, Writing ⌘4, Speakers ⌘5, Agent ⌘6. Also holds
  `WritingSidebarNewBadge`, whose defaults key the Writing page sets when
  setup finishes.
- `TodayPresentation.swift` / `TodayViewModel.swift` /
  `Pages/TodaySettingsPage.swift` - the Today page. The header sentence, the
  rolling seven-day tape, and the sessions list all come from local capture
  files: the cached meeting index (`RecentMeetingsScanner.loadSearchIndex`),
  the dictation day files (`DictationTranscriptStore.savedDictationDayCounts`),
  and Save my writing's `Writing_<date>.md` files (`TodayWritingParser`).
  Picking a day in the week strip retitles the header and swaps in that
  day's numbers (`TodayTapeBuilder.dayStats`). Under the tape, the picked day is split into sessions
  (`TodaySessionBuilder`): a pause over 30 minutes starts a new one, and each
  is titled by rule, never a model: the first meeting's title, else the first
  dictation's opening words cut at a whole word, else "Writing in <app>".
  Opening a session picks its latest mark on the tape, and picking a mark
  opens its session. Writing bars are estimated
  from word count, since the files keep only the first keystroke; a writing
  click opens its day file until the Writing tab lands.
  No network, no new analytics event (only `settings_action_clicked` action
  ids). Meeting clicks reuse the pill's `requestHomeRevealMeeting` path;
  dictation clicks open Dictations. The tape copies the Context app's Days
  view (week cells with mini lines, full day below, 6 AM to midnight) and
  its stream colors (`LibraryTokens.meetingsStream`/`dictationStream`/`writingStream`).
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
- `HomeViewModel.swift` - the Home view model: refresh, paging, the
  scan-warning latch, the search index and its debounce, `groupByDay`, and
  the activation return-proxy.
- `HomeModels.swift` - Home value types plus `HomeActivityRowFormatting`.
- `HomeFeedbackModels.swift` - feedback issue kind, target and submission.
- `HomeScanWarningCard.swift` - the scan-warning card.
- `HomeCaptureList.swift` - empty state, the day-grouped list, the search
  field, and the capture-list section.
- `HomeView.swift` - row actions and the ⋯ menu, the inline failed-meeting
  row (retry/retained audio), the feedback sheet view, and Load more. These
  stay together because `UIAutomationSurfaceContractTests` reads them from
  this file.
- `QuietHomeLibrary.swift` - quiet-library Meetings components (2026-08
  redesign): header sentence, meeting/working rows, and the in-place
  expansion with speaker labels and naming.
- `QuietDictationLibrary.swift` - the matching per-entry Dictations rows and
  expansion.
- `HomeMeetingAudioPlayer.swift` - meeting-audio player and speaker color
  palette shared by the Home expansion.
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
  The Done screen watches `STTRouter` and says "Almost set." with the model's
  download progress until the voice model is on this Mac. After a Don't Allow
  on the microphone, the permissions step offers "Skip for now" so people can
  still reach file import; the Done screen then says the mic is off.
- `SpeakerPeopleSettingsSection.swift` - speakers surface: "Name these
  people", one card per call (name, day, length) with the voices still
  unnamed from it (a voice heard in several calls shows once, under the most
  recent) and that call's calendar invitees as one-tap names; "Skip this
  call" is saved (`SpeakerReviewSkippedCalls`) and moves its voices to
  Everyone. Then compact duplicate-merge suggestions and the searchable
  all-speakers list with per-row play/rename/merge/delete.
- `SpeakerReviewStack.swift` - Foundation-pure card stack behind that page:
  call order (skipped calls out, Later ones last), which voices Everyone
  hides (only the open top card's, never during a search, so voices on
  cards further down stay reachable with a "Waiting in review" badge), and
  Home's "speakers need names" count (skipped calls don't count). The model
  rebuilds it once when the queue, a skip, or Later changes.
- `SpeakerNamingSheet.swift` - completed-meeting speaker review sheet. It is
  held while a meeting records (`SpeakerReviewPresentationGate.swift`) and
  its header names the meeting. When the recording started with a calendar event
  (same window as the record-this-meeting pop-up),
  its invitees show as one-click name buttons on each row and lead the name
  list, and a 1:1 pre-fills the one remote voice
  (`MeetingInviteeSuggestionPolicy`). Suggestions only; the user still saves.
  With the Notch island selected the review asks in the island instead
  (`Sources/UI/Overlay/NotchIslandSpeakerReviewView.swift`); Later there saves
  what was answered and the rest waits in Speakers.
- `SpeakerReviewPresentationGate.swift` - Foundation-pure rule for when the
  speaker review window may appear (waits for Stop while a meeting records).
- `SpeakerVoiceRowPresentation.swift` - Foundation-pure play/pause, overflow
  menu, and name-suggestion policies for the voice-to-name rows.
- `SpeakerNameAutocompleteField.swift` - SwiftUI wrapper over the naming
  sheet's `NSComboBox` autocomplete.
- `RetainedDataSourceComboBox.swift` - `NSComboBox` subclass that keeps its
  data source alive (fixes a dangling `assign` data-source crash).
- `Pages/` - one file per standalone settings page split out of
  `TranscriptedSettingsView` (`AboutSettingsPage.swift`,
  `DictationsSettingsPage.swift`, `GeneralSettingsPage.swift`,
  `HomeSettingsPage.swift`, `PeopleSettingsPage.swift`,
  `StorageSettingsPage.swift`, `TodaySettingsPage.swift`, and
  `WritingSettingsPage.swift`, which hosts the Writing intro, setup, and
  everyday views from `Sources/UI/Settings/Writing/`). Model, shortcut, and privacy editors are
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
  section, and the Beta page's Nemotron toggle was later removed. Nemotron
  is now the app's default with no Settings toggle
  (`Sources/Support/DiarizationBackendPreferences.swift`); Core itself still
  defaults to pyannote (see `Sources/TranscriptedCore/AGENTS.md`).
- `Writing/` - the Writing tab's views, all driven by `WritingSettingsModel`
  in `Sources/Writing/` (runtime changes go through `WritingController`,
  never from a view): `WritingIntroView.swift` (two intro pages until setup
  is done), `WritingDemoView.swift` + `WritingDemoScript.swift` (the looping
  autocomplete demo, drawn in SwiftUI from data), `WritingSetupFlowView.swift`
  (setup steps 1 to 3; they only fill the draft, "Turn on writing" applies
  it), `WritingEverydayView.swift` (after setup: summary, today's saved
  writing, autocomplete numbers), `WritingSettingsSection.swift` (the two
  features, personalized suggestions, model switch, storage meter, Delete
  all writing), `WritingComponents.swift` (shared buttons), and
  `WritingSetupPresentation.swift` (Foundation-pure copy and small rules from
  the approved design in `docs/writing-plan.md`; covered by
  `Tests/WritingSetupPresentationTests.swift`).

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
