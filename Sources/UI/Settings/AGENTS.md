# Settings UI

`Sources/UI/Settings/` owns the main window (sidebar, Today, Meetings, Dictations, Writing, Speakers, Agent, and the combined settings page), first-run onboarding, Home, and speaker naming and review. The surface summary is `Sources/UI/AGENTS.md`; this file is the per-file guide.

## Module

`UISettings` in `.agents/modules.json`.

- **Public surface:** `TranscriptedSettingsWindowController`, `TranscriptedSettingsPage`, `PermissionsOnboardingView` and its window controller, `SpeakerNamingSheet`, `HomeView`, the `Pages/` views.
- **May depend on:** UIShared, UIOverlay, AppState, Capture, WritingBridge, WritingCore, WritingRuntime, Meeting, Dictation, Speech, Support, Observability, Core `core-vocab`. Only AppShell and UIMenuBar may depend on it.
- **Speaker persistence:** Settings reaches database edits, migration status, saved merge history and naming metadata through Meeting-owned `SpeakerSettingsStore`, `SpeakerSettingsMigration` and `SpeakerNamingMetadata`. Keep Core engine types behind those seams; presentation and edit completion stay in this directory.
- **Start at:** `TranscriptedSettingsWindowController.swift` (opens the window), `TranscriptedSettingsView.swift` (the shell).
- **Tests:** `bash run-tests.sh --filter Home`, `--filter Settings`, `--filter Speaker`, `--filter UIAutomationSurfaceContract`.
- **Product surface to keep:** Speakers directory (review, rename, merge, delete), per-app Auto Enter, model-cache inspection and cleanup, retained-audio playback.

## Rules

- `TranscriptedSettingsView` stays the shell. New row or view helpers go in a focused sibling file; new pages go in `Pages/`.
- Views can own local `@State`, but runtime side effects go through injected bindings, controllers, preferences, or `TranscriptedSettingsActions`. Pages own local confirmation state only.
- Keep General-page row styling in `TranscriptedSettingsGeneralControls.swift` so editors stay aligned. Row explanations live in each row's ⓘ `GeneralInfo` popover, not in captions.
- Agent setup stays in `AgentConnectionSettingsPage.swift` and shares copy through `AgentConnectionGuide`; don't duplicate prompt text.
- No transcript parsing, speaker database work, or retained-audio cleanup here. Use `Sources/Meeting/`, `Sources/TranscriptedCore/`, or `Sources/UI/Shared/`.
- Writing views are driven by `WritingSettingsModel` in `Sources/Writing/`; runtime changes go through `WritingController`, never from a view.
- Source-pinned: `Tests/UIAutomationSurfaceContractTests.swift` reads `TranscriptedSettingsView.swift` (Home row actions) and `HomeView.swift` as text, and `PermissionsOnboardingView.swift`, `QuietHomeLibrary.swift` and `SpeakerPeopleSettingsSection.swift` are pinned too. Run `python3 scripts/dev/check-source-pins.py --changed-only` before moving code.
- Redraw gate: anything new the shell reads from `meetingSession` in its body must be added to `SettingsMeetingShellState.swift`, or the window won't redraw.
- A closed window does no I/O. Gate work for a window nobody can see on `navigation.isWindowOpen` (`SettingsClosedWindowPolicy.swift`).
- Per-mark work on Today runs once per snapshot, off main. Don't put it back in a view body.
- Privacy: no new analytics event from here beyond `settings_action_clicked` action ids. Today is local files only, no network.

## The shell

`TranscriptedSettingsView.swift` holds stored state, `init`, `body`, and the Home row actions (copy, re-transcribe, expansion, row menus, delete with undo). It still owns every Home side effect (delete, rename, copy, retranscribe, the shared root alert, undo staging, analytics). The rest are extensions:

- `+Pages.swift` - sidebar, detail column, page routing, page hosts.
- `+HomeMeetingActions.swift` - `RootAlert`, rename, speaker naming, failed meetings, `revealOwnFile`/`openOwnFile`, failure alerts.
- `+GeneralEditors.swift` - the combined page and its injected `general*Editor` properties (model, speaker matching, shortcuts, Bluetooth mic, microphone, auto-send, permissions, mic processing, reporting).
- `+ShortcutEditor.swift` - shortcut recorder editor (dictation key, its behavior, meetings).
- `+DictationMuffle.swift` - the "Muffle other audio" toggle; turning it on asks for System Audio Recording here, so dictation never prompts.
- `+Refresh.swift` - state refresh, analytics, model cache, launch at login.
- `+Preferences.swift` - corrections, capture library, Auto Enter, update actions.

The combined settings page is card-based: every setting is an always-visible row inside a `SettingsCard`, no disclosures. The corrections editor opens as a sheet. All configuration is on that one scrolling page, reached from the sidebar gear; there is no tab strip, and the old `.storage`/`.about`/`.models`/`.shortcuts`/`.privacy`/`.beta`/`.support` page cases are deleted.

## Files

### Shell, navigation, shared pieces

- `TranscriptedSettingsPage.swift` - page enum. `.today` is first and the default (⌘1). Meetings keeps the `home` raw value (⌘2) so automation ids, analytics `page_id`, and source pins stay stable. Dictations ⌘3, Writing ⌘4, Speakers ⌘5, Agent ⌘6; `navigationShortcutKey` feeds both the sidebar tooltips and the Go menu (`TranscriptedMenuCommandCatalog.swift`).
- `TranscriptedSettingsSidebar.swift` - sidebar sections and rows. The Writing row shows a quiet "New" badge until `WritingSidebarNewBadge.dismissedDefaultsKey` is set (key lives in `Sources/Writing/WritingSidebarNewBadge.swift`).
- `TranscriptedSettingsNavigationModel.swift` - `@Observable` selected page, the ⌘F Home find-focus token, `isWindowOpen`, `requestHomeRevealMeeting`.
- `TranscriptedSettingsGeneralControls.swift` - `SettingsCard`, label/control/toggle/action rows, the dictation overlay mode picker, `GeneralInfo` popovers.
- `TranscriptedSettingsComponents.swift` - `persistedSettingsBinding`, `SettingsPageIntro`, button styles, `SettingsStatusCard`, permission rows, hotkey recorder container.
- `TranscriptedSettingsRows.swift` - rows for model choices, custom corrections, Auto Enter apps.
- `ShortcutSettingsRows.swift` - key rows for the dictation key and meetings, and `ShortcutRecorderModel`, which records a shortcut in place (the dictation key is one key with hold/tap behavior; no Hands-Free or paste-last rows).
- `MeetingLanguageSettingRow.swift` / `MeetingMicrophoneSettingRow.swift` / `MicrophoneSettingsPolicy.swift` - meeting language picker, Mac-selected-mic toggle, and which mic rows General shows (Foundation-pure).
- `TranscriptedSettingsActions.swift` - app-level closures injected into the shell (start dictation/meeting, import audio, feedback, diagnostics).
- `TranscriptedSettingsWindowController.swift` / `TranscriptedOnboardingWindowController.swift` - AppKit windows. The settings controller owns `TodayViewModel`.
- `TranscriptedMenuCommandCatalog.swift` - the ⌘ commands as values, consumed by `Sources/App/TranscriptedMenuCommands.swift`.
- `SettingsMeetingRenderGate.swift` - coalesces a chatty ObservableObject, publishes only on key change; also `HomeActivityPercent`.
- `SettingsMeetingShellState.swift`, `SettingsRecordingClock.swift` / `QuietRecordingElapsedLabel.swift` - meeting values the shell shows; Home's 1 Hz elapsed label as an environment-fed leaf so the tick doesn't redraw the shell.
- `SettingsClosedWindowPolicy.swift` - what a closed window still does. An in-flight Today snapshot can be held until `present()`; hidden saves start no new scans; reopening marks the snapshot as updating until the read finishes.
- `SettingsRecentCaptureRefreshPolicy.swift` - which pages refresh captures on navigation.
- Failure copy: `AgentSetupFailureCopy.swift`, `SettingsActionFailureCopy.swift`.

### Today

`TodayPresentation.swift`, `TodayViewModel.swift`, `Pages/TodaySettingsPage.swift`, `TodayWritingDayFileCache.swift`.

- Data comes from local files only: `RecentMeetingsScanner.loadTodayIndex`, `DictationTranscriptStore.savedDictationDayCounts`, and `Writing_<date>.md` files (`TodayWritingParser`, cached by mtime+size).
- The rolling seven-day tape retitles the header and swaps numbers when you pick a day (`TodayTapeBuilder.dayStats`). Below it, the day splits into sessions (`TodaySessionBuilder`): a pause over 30 minutes starts a new one, titled by rule, never a model (first meeting's title, else the first dictation's opening words cut at a whole word, else "Writing in <app>"). Picking a session picks its latest mark and vice versa.
- Writing bar lengths are estimated from word count (the files keep only the first keystroke); a writing click opens its day file.
- Meeting clicks reuse `requestHomeRevealMeeting`; dictation clicks open Dictations. Stream colors are `LibraryTokens.meetingsStream`/`dictationStream`/`writingStream`.
- Performance: `TodayTapeDay` stores `allMarks` and `sessions`; each `TodayTapeMark` carries its `hoverText`; `TodayTapeSelection` resolves hovered/picked once per draw; the shell passes a minute-granular `now` from `TimelineView(.everyMinute)`; the day card and week cells are `Equatable`.

### Home (Meetings) and Dictations

- `Pages/HomeSettingsPage.swift` - pure view assembly: header, scan-warning and activity rows, search, day-grouped list, expanded preview, inline failed-meeting rows. Takes day sections and every action as injected values/closures.
- `HomeViewModel.swift` - refresh, paging, scan-warning latch, search index and debounce, `groupByDay`, activation return-proxy.
- `HomeMeetingSearchIndex.swift` / `HomeSearchMatching.swift` - Foundation-pure index over every saved meeting (title, date words, named speakers), built off-main from `RecentMeetingsScanner.loadSearchIndex`; audio is resolved only for shown matches.
- `HomeView.swift` - row actions, the ⋯ menu, inline failed-meeting row, feedback sheet, Load more. Kept together because the contract test reads it.
- `HomeCaptureList.swift`, `HomeScanWarningCard.swift`, `HomeModels.swift`, `HomeFeedbackModels.swift` - list, warning card, value types, feedback types.
- `QuietHomeLibrary.swift` - Meetings rows and in-place expansion with speaker labels and naming.
- `HomeMeetingAudioPlayer.swift` - meeting-audio player and speaker color palette.
- Foundation-pure policies and copy: `HomePresentation.swift`, `HomeRootAlertPolicy.swift` (single alert presenter, `HomeActionFailureCopy`), `HomeDeleteConfirmationPolicy.swift`, `HomeScanWarningPolicy.swift`, `HomeTranscriptionActivityPresentation.swift` / `HomeTranscriptionActivityCopy.swift`, `HomeFailedMeetingInlinePresentation.swift`, `FailedMeetingRecoveryPresentation.swift`.
- `QuietDictationLibrary.swift` - Dictations cards: bar on top, text clamped to four lines with Show more, Copy and ⋯ on hover. `DictationPlaybackBar.swift` is the bar and inline player (Reduce Motion becomes plain state changes). `DictationPlaybackController.swift` plays one take at a time with `AVAudioPlayer` (output only) and lazily reads kept-audio length. `DictationCardPresentation.swift` holds the metadata line and Transcribe again rules. `DictationTranscribeAgainRunner.swift` runs one at a time through `STTRouter.transcribeSavedDictation`, which keeps `isTranscribing` true so a new dictation queues behind it; never an audio engine.
- `DictionaryPastMeetingsLine.swift` - the "Also in N past meetings. Fix them" line under a correction in the Corrections sheet: debounced background count, confirm with the count before the first write, Fix, Undo/Try again. Results are keyed by row id so editing keeps Undo, and reload from on-disk backups after relaunch. File work is in `Sources/UI/Shared/DictionaryPastMeetingFix.swift`.

### Agent page

- `AgentConnectionSettingsPage.swift` - one connect row per detected agent (via `AgentMCPConnector`), the universal copy-prompt row, the `CompanionSettingsCard()`, and the Advanced disclosure (folders, Codex inbox, config).
- `CompanionSettingsCard.swift` - ChatGPT companion plugin card. Readiness describes the local bridge; it never implies ChatGPT has connected.
- Onboarding has no agent step; connection lives only here.

### Onboarding

- `PermissionsOnboardingView.swift` - three steps (welcome, permissions, done), one path. Permission refresh is event-driven; never add a repeating ScreenCaptureKit probe. The Done screen watches `STTRouter` and says "Almost set." with download progress until the voice model is on this Mac. After a Don't Allow on the microphone, "Skip for now" still reaches file import and Done says the mic is off.
- `OnboardingNavigation.swift`, `OnboardingAbandonmentReasonPolicy.swift` - step navigation; maps an exit to its telemetry reason.

### Speakers

- `SpeakerPeopleSettingsSection.swift` - "Name these people": one card per call with its still-unnamed voices (a voice heard in several calls shows once, under the most recent) and that call's invitees as one-tap names; "Skip this call" is saved (`SpeakerReviewSkippedCalls`) and moves its voices to the list below. Then the searchable list of everyone else, by voice print. The page title's line under it is `SpeakerPrintDirectory.headerLine` (`Pages/PeopleSettingsPage.swift`). Queue rows: `SpeakerPeopleRows.swift`. View model: `SpeakerPeopleSettingsViewModel.swift`, with duplicates and clip files in `+Duplicates.swift`.
- `SpeakerPeoplePrintSections.swift` / `SpeakerPeoplePersonRow.swift` - the list: "Named automatically · N" (full, glowing prints and a glowing dot per person), "Still learning" (partial prints), then "Not named yet" (unnamed voices outside the open card). Each row is the person's `VoicePrintRepresentable` (UIOverlay; play in the center plays their saved clip, so there's no separate play button; with no clip it's only a picture and the click opens the card), name, "14 meetings · today" (`SpeakerPrintDirectory.metaLine`), and "One more yes" (person color) or "N more"; hover shows ••• (rename, merge, undo merge, delete) and a click elsewhere on the row opens the card in place. A click on a playable print plays without toggling the card: the row's tap would also fire for the AppKit view, so the print claims it with its own tap gesture. Settings lists everyone, so each person keeps `VoicePrintStyle(id:).preferredColorIndex` (no per-call de-duplication), drawn with the palette's light hexes on a light window. "One more yes" is small text, so on a light window it takes a darker shade of the same hue (`SpeakerPrintTextInk`, 4.5:1, tested). The print celebrates nowhere here, so no `cascadeOutset` room is needed.
- `SpeakerPrintDirectory.swift` - Foundation-pure sections, the meta line, the hint's text ink, lit rings and hints from Meeting's `SpeakerNamingStanding` (computed in the off-main Speakers snapshot, `SpeakerSettingsStore.namingStandings`; unnamed voices get none). Ring count and the hover explanation come from `Sources/UI/Shared/SpeakerNamingTierPresentation.swift`, shared with the island.
- `SpeakerReviewStack.swift` - Foundation-pure card stack: call order (skipped out, Later last), which voices Everyone hides (only the open top card's, never during a search, so deeper voices stay reachable with a "Waiting in review" badge), Home's "speakers need names" count (skipped calls don't count). The model rebuilds it when the queue, a skip, or Later changes.
- `SpeakerNamingSheet.swift` - presenter for the post-meeting review. Held while a meeting records (`SpeakerReviewPresentationGate.swift`), then asks in the Notch island (`Sources/UI/Overlay/NotchIslandSpeakerReviewView.swift`). Later saves what was answered and the rest waits in Speakers. Calendar invitees come from `MeetingInviteeSuggestionPolicy`. There is no review window.
- `SpeakerVoiceRowPresentation.swift`, `SpeakerMergeTargets.swift`, `SpeakerDuplicateNameMatching.swift`, `SpeakerDuplicateDetection.swift` - Foundation-pure row policies, merge-target index (built once per snapshot), duplicate-name rule, and a whole-profile duplicate cache (only unchanged profiles reuse the all-pairs result; clips, review rows, undo reload).
- `SpeakerNameAutocompleteField.swift` / `RetainedDataSourceComboBox.swift` - `NSComboBox` autocomplete; the subclass keeps its data source alive (a dangling `assign` data source crashed).
- `AutoEnterDisplayNameResolver.swift` - fallback chain for Auto Enter app names.

### Pages/

One file per page split out of the shell: `AboutSettingsPage.swift` (includes the Support section: email support, send diagnostics), `DictationsSettingsPage.swift`, `GeneralSettingsPage.swift`, `HomeSettingsPage.swift`, `PeopleSettingsPage.swift`, `StorageSettingsPage.swift` (meeting audio retention, dictation audio keep window), `TodaySettingsPage.swift`, `WritingSettingsPage.swift`. The Beta and Support pages were dissolved; Nemotron is the diarization default with no toggle (`Sources/Support/DiarizationBackendPreferences.swift`), while Core itself defaults to pyannote (`Sources/TranscriptedCore/AGENTS.md`).

### Writing/

Views for the Writing tab: `WritingIntroView.swift` (two intro pages until setup is done), `WritingDemoView.swift` + `WritingDemoScript.swift` (looping autocomplete demo drawn from data), `WritingSetupFlowView.swift` (steps 1 to 3 only fill the draft; "Turn on writing" applies it), `WritingEverydayView.swift`, `WritingSettingsSection.swift` (features, personalized suggestions, model switch, storage meter, Delete all writing), `WritingComponents.swift`. Copy lives in `Sources/Writing/WritingSetupPresentation.swift`.

## Verify

```bash
bash build.sh --no-open
bash run-tests.sh
```

Then open Settings and check by hand:

- every sidebar page switches; Meetings and Dictations load recent items, failed meetings, stats
- failed meeting retry, reveal, delete, and retained-audio playback work
- custom dictionary edits persist and preview
- Auto Enter app add/remove works
- Agent page connects detected agents, copies the universal prompt, reveals config and folders, sets up the Codex inbox from Advanced

Core engine types stay behind Meeting seams. The module boundary check has no grandfathered crossings.
