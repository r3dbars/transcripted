# UI Directory

## What This Does

`Sources/UI/` contains the current app surfaces for Transcripted's active features.
The directory is grouped by surface so the live UI tree is easier to scan:

- `Overlay/`
- `MenuBar/`
- `Settings/`
- `Shared/`

Draft-mode UI is not an active product path in this worktree.

## Files (across Overlay/MenuBar/Settings/Shared)

### Overlay/

The module card (owns, public surface, may depend on, entry points, tests, rules) is `Overlay/AGENTS.md`.

- `Overlay/DictationEscapeCancelPolicy.swift` — Esc during a dictation: a short take cancels on the first press, a long one asks ("Press Esc again to discard") and a second press inside 3 s discards
- `Overlay/DictationMeterPolicy.swift` — tiny presentation policy that decides when the dictation waveform meter should render and clamps its displayed level
- `Overlay/DictationMicrophoneLoadingPresentationPolicy.swift` — copy and timing policy for the microphone-starting / device-switching overlay state
- `Overlay/DictationNoSpeechPresentationPolicy.swift` — user-facing no-speech copy for hotkey and non-hotkey dictation attempts, plus the "Transcribe It" button title on messages about a saved recording (it runs the same import as Capture → Transcribe Audio File on that file)
- `Overlay/DictationOverlayPlacementPolicy.swift` — AX-rect-to-Cocoa conversion the Notch island uses to find the display holding the focused text field
- `Overlay/DictationRecordingStartOverlayPolicy.swift` — decides whether recording can skip the loading UI or should wait for microphone recovery
- `Overlay/DictationStartCuePolicy.swift` — decides whether the start click plays on key press (built-in or wired mic) or waits until recording starts (a headset, any input that could be one, or a mic `PinnedDictationSpeedPath` moved back to the engine)
- `Overlay/DictationSessionCapWarningPolicy.swift` — the live "28s left" countdown the listening pill shows in the last 30 seconds before the 5-minute dictation cap, worded for push-to-talk vs hands-free
- `Overlay/DictationQueuedStartPolicy.swift` — a dictation shortcut press while the last take is still transcribing is remembered and starts when that take finishes (up to 2 s), instead of being refused
- `Overlay/DictationTrigger.swift` — what started or stopped a dictation (physical key, keyboard shortcut, menu, overlay button, onboarding, session cap); the raw values are telemetry values, and `DictationStartReadinessPolicy.hotkeyTriggerRawValues` must match them
- `Overlay/DictationStartAdmission.swift` — the first step of starting a dictation: whether a press becomes a take, and how it is counted. A press while dictating or queued behind a finishing take is not counted yet; every other press is counted (`dictation_start_requested`) before any guard can refuse it, and each refusal reports its own reason. `DictationSessionController.startDictation` runs it with real closures; `Tests/DictationStartAdmissionTests.swift` runs it with fakes
- `Overlay/DictationSessionPipeline.swift` — the start and stop wiring `DictationSessionController` runs through `DictationSessionPipelineHost` (the controller conforms): start admission and refusal messages, Try Again restarts marked as retries, the start click (once per session, queued before the fast-path mic start), focus recovery after a failed background mic start, the stop task from the stale-task fence through the checkpoint and model wait to the text, a stop before capture started, an empty take (mis-tap, no speech, Paste Anyway, saved recording, Retry Saving), and Quit's mark/wait/cancel. `Tests/DictationSessionPipelineTests.swift` runs it on a fake controller
- `Overlay/DictationStartActivation.swift` — optional foreground-activation handshake (and focus restore) tried after a background microphone start fails; a recovery attempt, not a mic-readiness signal
- `Overlay/DictationSessionController.swift` — dictation session orchestration; the recovery wait-loop state machine, model-warmup wait loop, and other STTRouter control-flow decisions now live in `Sources/Speech/DictationSession.swift`/`DictationSessionTypes.swift` — this file composes that session and keeps panel geometry, tooltips, accessibility labels, paste-back, persistence, and telemetry
- `Overlay/DictationWarmupPresentationPolicy.swift` — user-facing copy and progress for the voice-model warmup overlay, phrased differently before recording starts (waiting on the mic) vs after it stops (audio captured, waiting to transcribe); `DictationPostStopModelWaitPolicy` in the same file decides the model-unavailable copy after that post-stop wait and keeps paste-back on the original app after a long wait instead of following focus
- `Overlay/FloatingOverlayController.swift` — the dictation state machine (starting, loading, listening, writing, message, success), its timers, the global Esc monitor and confirm, and the not-pasted notice; it has no window of its own and pushes each state to the Notch island as a `NotchIslandDictationContent` snapshot
- `Overlay/MeetingPromptPriority.swift` — pure precedence lattice for the meeting overlay's four warning-driven prompts (audio inactivity, system-audio degradation, audio route instability, mic boost), extracted out of `MeetingOverlayController` so the rule is defined once
- `Overlay/MeetingDurationFormatter.swift` — Foundation-pure timer and inactivity-duration formatting for the meeting overlay
- `Overlay/MeetingOverlayController.swift` — the meeting's overlay state machine: session subscriptions, prompts (warnings, missed-call nudge), timers, and actions (including the saved and error states' Open, which reveals the meeting on the Meetings page, and the island's right-click "Discard Recording…" with its confirm). It has no window of its own and pushes `NotchIslandMeetingContent` snapshots to the Notch island; detected-meeting Record/Not now/Remind actions live only in `CapturePillController`
- `Overlay/CapturePillController.swift` — the detected-meeting call prompt (Record / Not now / Remind): the island shows it as Not now / Later / Record with a countdown ring around Not now; this owns the countdown and auto-dismiss timing. The timeout (`CallPromptTimeoutClock`) pauses while the pointer is over the island and while the prompt waits behind a dictation (off-screen waiting is capped at two minutes per prompt, then it expires unanswered). It has no window of its own
- `Overlay/NotchIslandController.swift` — the Notch island, the only dictation, meeting and call-prompt window (the old near-text and mini cursor dictation windows, the meeting pill, the call prompt pill and the speaker naming window are deleted): one black shape that grows out of the MacBook notch, or hangs from the top edge of a display without one, and carries dictation, meetings, and the call-detected prompt. `FloatingOverlayController`, `MeetingOverlayController`, and `CapturePillController` keep their state machines, timers, and actions and push plain snapshots here, and the island routes taps back to them. It picks its display once per show (`NotchIslandScreenChoice` in `NotchIslandGeometry.swift`): for a dictation with more than one display, the one holding the focused text field (one Accessibility read), else the one under the pointer, else the main display; it keeps that display while shown. Motion runs in Core Animation: the panel is built at launch (`prewarm`), opens at a fixed envelope size (`NotchIslandGeometry.envelope`) and never resizes mid-animation, and a continuous-corner mask layer springs out of the notch (or swells from a small nub at the top edge of a display without one) while the content blurs in; the wings ride the same spring when the island resizes. Mouse monitors make the envelope click-through everywhere except over the island and drive hover. It opens its drop-down on hover (0.12 s in, 0.38 s out) and by itself for messages and prompts (a click closes those until something new needs saying), and lingers ~2.6 s on a finished dictation with Copy / Paste again
- `Overlay/NotchIslandPresentation.swift` — Foundation-pure rules for what the island shows: the two wings and the drop-down for every dictation, meeting, and call-prompt state. A live meeting keeps the left wing while a dictation takes the right; the call prompt waits while a dictation runs; with a drop-down open the wings only report status, so no button shows twice. Also says when the call prompt is on screen and when the speaker review may keep the keyboard
- `Overlay/NotchIslandGeometry.swift` — pure geometry: notch detection from the screen's safe area and top areas, content-sized wings (equal around the camera in notch mode), the 460 pt drop-down, the grow/shrink frames, the fixed envelope window, and a screen-width clamp; plus `NotchIslandMotion` (the grow/edge/shrink springs, fades and blur timing)
- `Overlay/NotchIslandView.swift` — AppKit drawing for the island (wings, level bars, meters, rings, the drop-down's rows and buttons; a click on a dictation message's words doesn't dismiss it); no SwiftUI hosting
- `Overlay/NotchIslandPanel.swift` — borderless non-activating panel at the status-bar level, excluded from screen capture (so screenshots can't show the island; review changes by rendering `NotchIslandView` offscreen with `NSView.cacheDisplay(in:to:)`, since `layer.render(in:)` drops AppKit text), never key except while "Who was on this call?" is up and someone clicks a name box (`acceptsKeyForTyping`); once naming ends or the review leaves the screen, `NotchIslandController` hands the keyboard back to the app the person was in without hiding the island or activating Transcripted. Allowed to sit over the menu bar
- `Overlay/NotchIslandSpeakerReviewPolicy.swift` — Foundation-pure rules for the island's "Who was on this call?": yes/no vs name box per voice, the first three calendar invitees as one-tap names (an arrow reveals the rest), name-box autocomplete from saved people with invitees first, the 20 s Later ring, and the "Everyone's named" copy; what Return/Tab and Done/Later save from the name box (the arrowed-to row, else an exact match, else the typed name as a new person, never a longer saved name), the Later ring running only while the review is on screen and not hovered, and the "Not Taylor?" / recognized-only copy; also the rules carried over from the review window: the calendar 1:1 name (`oneOnOnePrefill`, wrapping `MeetingInviteeSuggestionPolicy.oneOnOnePrefill`; an untouched filled-in name saves on Done but not on Later), and the "All me" (keep local mic as You) / "Not a person" (discard) locks (Keep as You wins over a discard; discard only on an asked voice with its name box open)
- `Overlay/NotchIslandSpeakerReviewView.swift` — the island's speaker review, the only post-meeting review (the old review window is deleted): recognized voices, "Is this Maya?" Yes/No, No → name box with invitee chips that step aside once you type, leaving a match list of up to five people (invitees first, "Me" on a local mic voice, then `Add “…”` for someone new), a play/pause clip button whose ring fills as the clip plays, Later (ring; stops once you touch anything) and Done → "Everyone's named" with Open. It fills the one remote voice's name box in a calendar 1:1 (still editable, saved on Done), puts the local mic voices under an "All me" toggle (it reads "Undo" while on) (`.collapsedToMe` for each), and offers a small × (hover shows "Don't save this voice", drawn by the island because system tooltips don't show over the non-activating panel) / "Undo" on an asked voice whose name box is open (`.discardedFromDatabase`). Builds the `SpeakerNameUpdate`s Core writes back and reports the review analytics with `surface: speaker_review_island`. It also opens when every remote voice was recognized: it lists who was on the call ("On <meeting>"), asks nothing, and closes on Done or its ring; hovering a recognized name offers "Not Taylor?", which opens the name box and saves a correction that the naming coordinator records against the recognized person. Only the island gets such a request: Core queues a recognized-only review (and cuts its clips) only while `reviewListsRecognizedVoicesProvider` says the island is selected, it doesn't count as a pending review for failed-meeting retry or update installs, and it closes itself after about two minutes even while hidden (`NotchIslandSpeakerReviewPolicy.recognizedOnlyHardCapSeconds`; a pointer on it holds the close)
- `Overlay/NotchIslandSpeakerReviewControls.swift` — the speaker review's small AppKit controls: the clip play/pause button with its progress ring, the name box, the suggestion rows, and the × for Not a person with its hover label

The overlay area holds the live transient recording surfaces: dictation in the
Notch island and the meeting prompt / recording overlay.
`DictationMeterPolicy` keeps the live meter visibility rule out of view code, so
UI tweaks to when the level meter shows up should land there instead of being
re-implemented in controllers or views.
The other dictation overlay policy files own startup/loading and no-speech copy
so tiny transient states do not get duplicated inside controllers.

### MenuBar/

- `MenuBar/MenuBarActionRowView.swift` — AppKit control backing the two side-by-side buttons (`.button` size: short title, shortcut only when it fits, detail as tooltip) and the utility rows, with tone, size, and press-handler styling
- `MenuBar/MenuBarGlyph.swift` — the menu bar status item icon: the app icon's speech bubble with the hidden T, drawn in code as a template image (outline when idle, filled while dictating, filled with a dot while a meeting records); geometry mirrors `docs/assets/menu-bar-icon/make_menu_bar_icons.py`
- `MenuBar/MenuBarContentView.swift` — root content view for the menubar popover; transparent so NSPopover's native material provides the surface
- `MenuBar/MenuBarHeaderLayoutPolicy.swift` — small layout policy for the menubar header status and model rows
- `MenuBar/MenuBarHeaderStatusPresentation.swift` — Foundation-pure policy for the header status line's text and tone (recording wins over ready/warmup; "Starting…"/"Saving…" around it)
- `MenuBar/MenuBarHeaderView.swift` — popover header with no title: hidden entirely when idle and ready; shows a status line for warmup, a transcript being made, and starting/saving a meeting (a steady recording has no line: the red Stop button with its timer says it), plus hotkey warnings (clickable when they have a fix to open)
- `MenuBar/MenuBarMeetingCapturePhase.swift` — Foundation-pure starting/recording/saving phase of a live meeting capture, used by the popover header and the meeting row
- `MenuBar/MenuBarShortcutWarningPresentation.swift` — Foundation-pure copy and click action for the header's shortcut warning (Accessibility access); the macOS Fn key conflict is kept out of the menu and shown in Settings > Shortcuts instead
- `MenuBar/MenuBarPanelController.swift` — NSPopover controller for the menubar; while a meeting records, the meeting row's trailing slot shows the live elapsed timer instead of the start shortcut
- `MenuBar/MenuBarPrimaryActionsView.swift` — the Record and Dictate buttons, side by side at the top of the popover (Paste Last Dictation keeps its shortcut but has no row)
- `MenuBar/MenuBarPrimaryButtonTitle.swift` — Foundation-pure short titles for those two buttons ("Record", "Stop", "Dictate", "Done"); the full title stays the accessibility label
- `MenuBar/MenuBarShortcutLabel.swift` — Foundation-pure shortcut text for those buttons: the full shortcut, then the first key of a pair ("Fn / Right ⌥" → "Fn") when the pair doesn't fit
- `MenuBar/MenuBarUtilityActionsView.swift` — the Open Transcripted, Check for Updates, and Quit rows under the buttons (Settings lives inside Open Transcripted)
- `MenuBar/MenuTokens.swift` — design tokens for menubar views; colors are dynamic so the popover follows the system light/dark appearance, and layer-bound colors re-resolve through `NSView.menuResolvedCGColor(_:)` on appearance changes
- `MenuBar/PasteLastDictationFeedback.swift` — presentation model (title, detail, tone, dismiss delay) for the toast shown after Paste Last Dictation, covering pasted/copied-fallback/failed/no-saved-dictation outcomes

The agent-connect surface is the Settings window's Agent page (onboarding no
longer has a connect stage). It keeps one mental model:

- one row per agent found on the Mac, one Connect button each
- every row points the agent's own MCP config at the same installed helper
- the universal copy-prompt row covers agents we cannot configure directly
- folders, the Codex inbox automation, and config details stay behind Advanced

### Settings/

- `Settings/AgentConnectionSettingsPage.swift` — Settings' agent page: detected-agent connect rows (Claude Desktop, Claude Code, Codex, Cursor), the universal copy-prompt row, and the Advanced disclosure (folders, Codex inbox, config details)
- `Settings/AutoEnterDisplayNameResolver.swift` — Foundation-pure fallback chain for Auto Enter app display names
- `Settings/HomeDeleteConfirmationPolicy.swift` — confirmation copy for deleting recent home captures
- `Settings/HomeFailedMeetingInlinePresentation.swift` — presentation policy for failed-meeting inline recovery rows on Home, including the one-line "fix this first" reason a retry-ready row shows for each `MeetingFailureKind`
- `Settings/HomePresentation.swift` — Foundation-pure Home copy, day labels, stable feedback ids, and speaker palette slot selection
- `Settings/HomeMeetingSearchIndex.swift` — in-memory index behind the Home meetings search; covers every saved meeting (title, date, named speakers), not just the loaded slice
- `Settings/HomeRootAlertPolicy.swift` — Foundation-pure priority and dismissal routing for the single Home alert presenter
- `Settings/HomeTranscriptionActivityPresentation.swift` — presentation model derived from `MeetingSessionController` state for the home page's live transcription activity card (tone, progress, transcript URL)
- `Settings/HomeTranscriptionActivityCopy.swift` — pure transcript-name and failed-transcription copy helpers extracted out of `HomeTranscriptionActivityPresentation` so they stay unit-testable without its `MeetingSessionController`/`DisplayStatus` dependency
- `Settings/HomeView.swift` — `HomeViewModel` plus Home building blocks: day-grouped capture lists with hover-reveal row actions and load-more, search field, scan-warning card, inline failed-meeting recovery rows, the feedback sheet, and preview/attention models
- `Settings/QuietHomeLibrary.swift` — quiet-library Meetings components (header sentence, meeting/working rows, in-place expansion with speaker labels and naming)
- `Settings/QuietDictationLibrary.swift` — per-entry Dictations rows and inline expansion, mirroring the meeting pair
- `Settings/HomeMeetingAudioPlayer.swift` — meeting-audio player and speaker color palette shared by the Home expansion
- `Settings/MeetingLanguageSettingRow.swift` — meeting/import language picker row (separate from dictation settings)
- `Settings/MeetingMicrophoneSettingRow.swift` — "Use Mac-selected microphone" toggle row for meetings
- `Settings/HotkeyRecorderAppKitView.swift` — AppKit view for recording custom hotkey bindings
- `Settings/PermissionsOnboardingView.swift` — first-launch permissions walkthrough; permission refresh is event-driven so an idle window never creates recurring ScreenCaptureKit probes
- `Settings/SettingsRecentCaptureRefreshPolicy.swift` — central policy for whether Settings should refresh the home dashboard, the recent meetings/dictations lists, or neither when navigation changes
- `Settings/RetainedDataSourceComboBox.swift` — `NSComboBox` subclass that owns its data source (AppKit only holds `dataSource` unretained), used by both speaker name boxes so a freed source can't crash the box mid-keystroke (Sentry APPLE-MACOS-2H)
- `Settings/SpeakerNameAutocompleteField.swift` — SwiftUI `NSComboBox` wrapper that gives the Speakers screen's "Who is this?" field name autocomplete (via `SpeakerNameSelectionPolicy`)
- `Settings/SpeakerNamingSheet.swift` — presenter for the post-meeting speaker review: watches Core's naming request and asks in the Notch island (`NotchIslandSpeakerReviewView`), never on top of a meeting that is recording. There is no review window any more
- `Settings/SpeakerReviewPresentationGate.swift` — Foundation-pure rule for when the speaker review may appear: a review that arrives while a meeting records waits until Stop, and an open review stays open
- `Settings/SpeakerPeopleSettingsSection.swift` — settings section for the speakers surface: "Name these people", one card per call (name, day, length) holding the voices still unnamed from it with that call's invitees as one-tap names and a saved "Skip this call", compact duplicate-merge suggestions, and a searchable all-speakers list with per-row play, rename, merge, and delete. The rows live in `Settings/SpeakerPeopleRows.swift`, the view model in `Settings/SpeakerPeopleSettingsViewModel.swift` (duplicate detection and clip files in its `+Duplicates.swift` extension)
- `Settings/SpeakerVoiceRowPresentation.swift` — Foundation-pure presentation/policy for the voice-to-name rows: the play/pause toggle state machine, overflow-menu actions, and name-autocomplete data source, kept view-free for unit tests
- `Settings/TranscriptedSettingsGeneralControls.swift` — `SettingsCard`, control/toggle/action rows, the dictation overlay mode picker, and `GeneralInfo` popovers
- `Settings/TranscriptedOnboardingWindowController.swift` — dedicated first-launch window that hosts onboarding before users drop into the menubar flow
- `Settings/TranscriptedSettingsActions.swift` — focused capture and support callbacks (start dictation, start meeting, import audio, send feedback, and send a diagnostic event) injected into the settings view
- `Settings/TranscriptedSettingsComponents.swift` — shared SwiftUI building blocks (`persistedSettingsBinding`, `SettingsPageIntro`, hover/inline button styles, `SettingsStatusCard`, permission status rows) used across settings pages
- `Settings/TranscriptedSettingsNavigationModel.swift` — observable navigation state for the current `TranscriptedSettingsPage` selection, plus the ⌘F Home find-focus token
- `Settings/TranscriptedSettingsPage.swift` — enum of window pages (today, home, dictations, writing, general, people, connectAgent) with titles, SF Symbol names, and navigation shortcuts (⌘1 Today through ⌘6 Agent, Writing on ⌘4), plus `WritingSidebarNewBadge.isShown` (the badge's defaults key lives in `Sources/Writing/WritingSidebarNewBadge.swift`); Meetings keeps the `home` raw value so automation ids and analytics `page_id` stay stable; `.storage`/`.about` and the earlier legacy alias cases were deleted once configuration collapsed onto the single combined settings page
- `Settings/TranscriptedSettingsRows.swift` — reusable Settings rows for correction editing, model choices, and Auto Enter apps
- `Settings/TranscriptedSettingsSidebar.swift` — sidebar section model: content-first primary rows (Today/Meetings/Dictations/Writing/Speakers/Agent), and the row view with its optional trailing "New" badge (Writing, until setup finishes); configuration is one combined scrolling settings page reached from the sidebar gear (no tab strip)
- `Settings/TodayPresentation.swift` — Foundation-pure Today numbers and copy: today/this-week counts, the seven-day tape marks (`TodayTapeBuilder`), the day's sessions (`TodaySessionBuilder`), and the latest-captures merge
- `Settings/TodayViewModel.swift` — loads the Today snapshot off-main from the cached meeting index, the dictation day files, and the `Writing_<date>.md` day files; local files only
- `Settings/Pages/TodaySettingsPage.swift` — the Today page: a one-sentence header for the picked day (with a per-app writing breakdown), the seven-day week strip top right, the picked day as three lanes (meetings, dictation, writing) with a hover/click preview card under them (after the Context app's Days view), and the picked day split into sessions (`TodaySessionBuilder`: a 30-minute pause starts a new one; titles by rule, no model)
- `Settings/TranscriptedSettingsView.swift` — main settings view; still owns every Home side effect (delete/rename/copy/retranscribe, the shared root alert, undo staging, analytics) even after the Home page view moved out. Its code is split across `TranscriptedSettingsView+*.swift` extensions (see `Settings/AGENTS.md`)
- `Settings/TranscriptedSettingsWindowController.swift` — NSWindowController for settings
- `Settings/Pages/` — standalone settings pages split out of `TranscriptedSettingsView` (`AboutSettingsPage.swift`, `DictationsSettingsPage.swift`, `GeneralSettingsPage.swift`, `HomeSettingsPage.swift`, `PeopleSettingsPage.swift`, `StorageSettingsPage.swift`, `WritingSettingsPage.swift`); model, shortcut, permission, and reporting editors are injected into General's cards by the shell: they're the `general*Editor` properties in `TranscriptedSettingsView+GeneralEditors.swift` (model, speaker matching, shortcuts, Bluetooth mic, microphone, auto-send, permissions, mic processing, reporting). Settings copy is inline, so to find a label grep its exact quoted text instead of reading the big files by line range. The former Beta and Support pages dissolved in settings redesign phase 1: Support's two rows (email support, send diagnostics) moved into About under a "Support" section, and the Beta page's Nemotron toggle was later removed along with the Nemotron model itself. `HomeSettingsPage.swift` is pure view assembly (header, scan-warning/activity rows, search field, day-grouped meeting list, expanded-row preview, inline failed-meeting rows) — it takes the meeting day sections and every row action as injected values/closures and holds no runtime logic

This is a summary of `Settings/`. `Sources/UI/Settings/AGENTS.md` has the full per-file list, including the small presentation/policy helpers.

### Shared/

- `Shared/AgentConnectionGuide.swift` — shared starter prompt, folder paths, Codex inbox, and portable meeting bundle copy for the agent-connect flow
- `Shared/AccessibilityDisplayPolicy.swift` — shared AppKit policy for honoring Reduce Motion and Reduce Transparency on overlay and Settings surfaces
- `Shared/AppSoundPlayer.swift` — UI sound preferences and playback helpers
- `Shared/CaptureUndo.swift` — shared "delete now, offer Undo for a few seconds" seam used by Home and Dictations in place of delete-confirmation dialogs; performs and reverses the move/rewrite and runs the grace-window bookkeeping
- `Shared/DictionaryPastMeetingFix.swift` — applies a Settings dictionary correction to saved meetings using the same matcher live transcription uses (longer rules win, as live). Only the spoken turns between `## Transcript` and the next section change: never frontmatter, the title, labels, timestamps, trailing notes/summaries, links, paths, or code. Backs up each original under `state/dictionary-fix-backups/` (kept 3 days; pruned at launch, and a meeting's backup is dropped when it is deleted from Home or goes missing) before writing, keeps creation dates, writes through the transcript-update serializer, and undoes only files nobody changed since. Meetings are found by file name in the current meetings folder, so a moved library keeps its Undo; busy meetings keep their backups so Undo can try again
- `Shared/FeedbackIssueBuilder.swift` — builds sanitized support email payloads and links from current app state
- `Shared/FirstRunExperience.swift` — shared first-run menu and onboarding state helpers for permission, local-model, dictation, and meeting CTA copy
- `Shared/FocusOrderContract.swift` — single source of truth for the Tab/keyboard-focus order of the menu bar popover and settings sidebar, checked against shipping views by `FocusOrderContractTests`
- `Shared/HomeCaptureRefreshObserver.swift` — bridges `.meetingCaptureArtifactsDidChange` into a plain callback so Home's scan-time cache silently reloads its transcript/audio URLs after background recompression or transcript rename
- `Shared/HomeMeetingDeletion.swift` — shared deletion service for Home meeting rows; fresh planning and reversible Trash/Undo run off-main through the transcript-update serializer so background rewrites cannot resurrect a deleted transcript. Includes legacy summary sidecar and retained-audio cleanup, stale-row checks, and active-retranscription protection.
- `Shared/HomeMeetingRename.swift` — renames an app-owned meeting from the Rename item in a Home meeting row's ⋯ menu (the expanded preview's title is plain, non-editable text): rewrites the `title:` frontmatter and body heading, then moves the transcript, retained audio, and legacy summary sidecar to the canonical `YYYY-MM-dd <title>` stem via `MeetingArtifactRenamer`
- `Shared/HomeMeetingRowActionTargets.swift` — resolves transcript and retained-audio Finder reveal targets for Home meeting row menu actions
- `Shared/MeetingPillFinishPresentation.swift` — Foundation-pure copy and timing for how a meeting finishes: transcribing percent and "N more waiting" on the pill and menu bar header, the saved pill's dwell and meeting name, and when the error pill offers Open
- `Shared/LibraryTokens.swift` — shared design tokens (accent, ink levels, hairline, radii, type roles) for the main-window surfaces (Home, Dictations, Speakers, Agent, Settings, menu bar popover); overlays keep their own tokens
- `Shared/MeetingAudioArchiveResolver.swift` — resolves retained meeting-audio attachments that belong to a saved transcript for review playback
- `Shared/MeetingAudioPlayback.swift` — shared play/pause/resume/seek-from-timestamp `NSSound`-backed controller for recent-meeting audio previews in Settings
- `Shared/OwnFileResolver.swift` — single resilient resolver every Home/meeting own-file access routes through; tolerates post-scan file drift (WAV→M4A recompression, transcript/audio rename) for reveal-in-Finder and open/read/play, and fails loud instead of dead-clicking
- `Shared/RecentCaptureScanners.swift` — `RecentMeetingsScanner` that loads recent meeting transcripts plus retained audio attachments for the Settings home page, and builds the full-library rows for the Home meetings search (`loadSearchIndex`)
- `Shared/HomeMeetingPreviewFormatter.swift` — builds transcript preview content and staged speaker-correction/naming plans for the Home meeting expansion
- `Shared/RecentMeetingMetadataCache.swift` — SQLite-backed cache of derived Home meeting-row metadata keyed by transcript path and validated by mtime/size, so a warm refresh skips re-parsing every transcript
- `Shared/SpeakerClipPlayback.swift` — reusable audio-preview helper for persisted speaker sample clips
- `Shared/SpeakerReviewQueueScanner.swift` — loads saved speaker-review queue items for the people settings and review flows
- `Shared/SystemAudioPermissionRevalidator.swift` — single owner for revalidating System Audio Recording permission from the Settings shell and onboarding, with an in-flight-task guard so both call sites can't run overlapping checks
- `Shared/SupportEmailDispatcher.swift` — native mail handoff and explicit failure fallback; callers retain feedback drafts when handoff fails, and the public support address is copied only on request
- `Shared/TranscriptedSupportActions.swift` — support flows for feedback and manually queued diagnostic events

Cross-cutting permission checks now live in `Sources/Support/TranscriptedPermissionAccess.swift`
so the meeting prompt detector and the settings/onboarding flows share the same
app-level permission logic outside the UI tree.

Cross-cutting local-speaker behavior is split between settings and review UI:
`TranscriptedSettingsView` owns the persisted toggle for local mic diarization,
while the island's speaker review (`NotchIslandSpeakerReviewView`) is where users
name or confirm voices after a meeting.

The main window is content-first: the sidebar leads with Today, then Meetings,
Dictations, Writing, Speakers, and Agent, and the window opens on Today; the sidebar gear opens one combined scrolling settings
page in the content pane (the General/Storage/About tab strip was removed —
everything is found by scrolling). Meetings
(the `.home` page case) is the meetings surface — a page title with one status
sentence, failed-meeting recovery, and the day-grouped meetings list; Dictations is
the separate dictation history. `HomeView` keeps recent
captures to small paged slices so the window still opens quickly for users with
large capture libraries, and `SettingsRecentCaptureRefreshPolicy` keeps those
refreshes scoped to the pages that actually need them.

Keep user-visible TCC prompts user-initiated. Background warmup paths should
not request microphone, system-audio-recording, or calendar access on their own;
onboarding and Settings own those prompts so the dialogs appear in context.

## Observation Pattern

Controllers own Combine subscriptions and push explicit `update(...)` calls into
AppKit views. Views are renderers, not observable state owners.

Settings is the exception: its SwiftUI pages can own local `@State` and
`@ObservedObject` view models. Keep runtime side effects routed through injected
controllers, preference helpers, or `TranscriptedSettingsActions` so the window
does not become another app coordinator.

## Verification

After changing UI code:

```bash
bash build.sh --no-open
bash run-tests.sh
```

For menu bar, Home, Settings, or navigation automation changes, also run when
local Accessibility permission is available:

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode ui
```

If `bash scripts/dev/concurrency-census.sh --check` flags new warnings in UI
code, the usual fixes are: a constant becomes `nonisolated static let`
(`Shared/CaptureUndo.swift`), and off-main work goes through a continuation
over GCD (`Shared/RecentCaptureScanners.swift`). After clearing older warnings,
lower the baseline with `bash scripts/dev/concurrency-census.sh --shrink`.

Manual checks:

- dictation overlay starts, stops, and auto-pastes cleanly
- detected-meeting prompts appear only when appropriate and can start, dismiss, or remind a meeting cleanly
- meeting overlay warms up and records cleanly
- imported-audio transcription can be started from the menubar and lands in the normal recent-meetings flow
- menubar popover renders shortcuts, primary actions, settings actions, and the agent-connect page cleanly
- speaker settings can preview clips, surface duplicates, toggle local-speaker splitting, and rename / merge people cleanly
- the island's post-meeting speaker review names and confirms voices, plays clips, and Later leaves the rest for Speakers
- recent meetings on Home and in Settings can play retained audio attachments; clicking a transcript row's time plays from there (keeping the picked source), but the transcript doesn't track playback position, so only the player's own play/pause/seek state has to stay correct
- failed meetings surface retained audio on Home so users can play it, reveal it in Finder, or retry transcription from the preserved files
- the Settings home dashboard opens quickly, shows grouped recent dictations and meetings, and its load-more actions keep working on large libraries
- permissions onboarding and first-run onboarding window still open correctly
- first-run CTA copy updates correctly as permissions and local-model state change
- settings window still opens correctly

Relevant direct coverage:

- `Tests/AgentConnectionGuideTests.swift`
- `Tests/DictationMeterPolicyTests.swift`
- `Tests/DictationMicrophoneLoadingPresentationPolicyTests.swift`
- `Tests/DictationNoSpeechPresentationPolicyTests.swift`
- `Tests/DictationRecordingStartOverlayPolicyTests.swift`
- `Tests/DictationSoundsTests.swift`
- `Tests/FeedbackIssueBuilderTests.swift`
- `Tests/HomeCaptureRefreshTests.swift`
- `Tests/HomePresentationTests.swift`
- `Tests/HomeRootAlertPolicyTests.swift`
- `Tests/HomeMeetingDeletionTests.swift`
- `Tests/HomeMeetingRenameTests.swift`
- `Tests/FirstRunExperienceTests.swift`
- `Tests/HomeMeetingPreviewFormatterTests.swift`
- `Tests/HomeTranscriptionActivityCopyTests.swift`
- `Tests/MenuBarHeaderStatusPresentationTests.swift`
- `Tests/MenuBarMeetingCapturePhaseTests.swift`
- `Tests/MenuBarShortcutWarningPresentationTests.swift`
- `Tests/StatusItemPresentationTests.swift`
- `Tests/MeetingAudioArchiveResolverTests.swift`
- `Tests/MeetingDurationFormatterTests.swift`
- `Tests/MeetingPillFinishPresentationTests.swift`
- `Tests/NotchIslandPresentationTests.swift`
- `Tests/NotchIslandGeometryTests.swift`
- `Tests/OwnFileResolverTests.swift`
- `Tests/RecentCaptureScannersTests.swift`
- `Tests/SettingsRecentCaptureRefreshPolicyTests.swift`
- `Tests/AutoEnterDisplayNameResolverTests.swift`
- `Tests/SpeakerReviewQueueScannerTests.swift`
- `Tests/SpeakerReviewPresentationGateTests.swift`
- `Tests/SpeakerVoiceRowPresentationTests.swift`
- `Tests/TodayPresentationTests.swift`
- `Tests/UIAutomationSurfaceContractTests.swift`
- `bash scripts/ops/transcripted-qa-bench.sh --mode ui` for live AX smoke of first-run onboarding, menu bar, Home, Settings, and navigation
