# UI Directory

## What This Does

`Sources/UI/` contains the current app surfaces for Transcripted's active features.
The directory is grouped by surface so the live UI tree is easier to scan:

- `Overlay/`
- `MenuBar/`
- `Settings/`
- `Shared/`
- `Timeline/`

Draft-mode UI is not an active product path in this worktree.

`Timeline/` is Phase 0 scaffolding for the future Dayflow-style timeline home
surface. Touching it means also reading `Sources/UI/Timeline/CLAUDE.md` and the
engine boundary in `Sources/Timeline/CLAUDE.md`.

## Files (82 Swift files)

### Overlay/

- `Overlay/DictationCancelHintPolicy.swift` — decides when the compact dictation overlay should show the cancel hint instead of only the shortcut hint
- `Overlay/DictationMeterPolicy.swift` — tiny presentation policy that decides when the dictation waveform meter should render and clamps its displayed level
- `Overlay/DictationMicrophoneLoadingPresentationPolicy.swift` — copy and timing policy for the microphone-starting / device-switching overlay state
- `Overlay/DictationNoSpeechPresentationPolicy.swift` — user-facing no-speech copy for hotkey and non-hotkey dictation attempts
- `Overlay/DictationRecordingStartOverlayPolicy.swift` — decides whether recording can skip the loading UI or should wait for microphone recovery
- `Overlay/DictationSessionController.swift` — dictation session orchestration
- `Overlay/FloatingOverlayController.swift` — owns the dictation overlay panel lifecycle and Combine subscriptions
- `Overlay/FloatingOverlayPanel.swift` — non-activating NSPanel for the dictation overlay
- `Overlay/OverlayDraftingView.swift` — legacy-named dictation processing and error state view
- `Overlay/OverlayHeaderView.swift` — overlay title bar with centered listening layout, live waveform host, and inline stop control for active dictation
- `Overlay/OverlayRootView.swift` — top-level AppKit view that keeps dictation compact in normal listening mode and only expands for loading or error/recovery content
- `Overlay/OverlayTokens.swift` — design tokens (colors, spacing, sizing) for overlay views
- `Overlay/PanelDragView.swift` — drag handle for repositioning the overlay panel
- `Overlay/WaveformLayer.swift` — Core Animation layer drawing the audio waveform
- `Overlay/MeetingLiveTranscriptDrawerView.swift` — self-contained drawer container (hover-revealed copy + overflow menu, status line, scrolling transcript, drag-to-resize grip) shown below the recording strip, clipped and faded as one unit while the panel resizes
- `Overlay/MeetingLiveViewAffordancePolicy.swift` — presentation policy for the pill-body transcript toggle, context/overflow menu titles, and drawer status copy, including the one-click enable copy when live meetings is off
- `Overlay/MeetingPillRestPolicy.swift` — rest/bloom policy for the recording pill: when the unattended pill condenses to the dot+timer capsule and when hover renders it full again
- `Overlay/LiveTranscriptPlainTextRenderer.swift` — Foundation-pure copy renderer for the live transcript drawer
- `Overlay/MeetingDurationFormatter.swift` — Foundation-pure timer and inactivity-duration formatting for the meeting overlay
- `Overlay/MeetingOverlayController.swift` — non-activating panel for detected-meeting prompts, model warmup, recording, and transcription status; the recording pill is click-to-toggle for the embedded live transcript drawer (fed by `MeetingSessionController.liveTranscriptFeed`), rests to a compact capsule when unattended, and carries a context menu (transcript toggle, pin, browser view, discard)

The overlay area holds both live transient recording surfaces: the compact
dictation overlay and the meeting prompt / recording overlay.
`DictationMeterPolicy` keeps the live meter visibility rule out of view code, so
UI tweaks to when the waveform shows up should land there instead of being
re-implemented in controllers or views.
The other dictation overlay policy files own startup/loading and no-speech copy
so tiny transient states do not get duplicated inside controllers.
`OverlayHeaderView` owns the inline dictation stop affordance and centered
listening layout, while `OverlayRootView` decides when the pill should expand
into a taller loading or error state.

### MenuBar/

- `MenuBar/MenuBarActionRowView.swift` — AppKit control backing both primary and utility action rows, with tone, size, and press-handler styling
- `MenuBar/MenuBarContentView.swift` — root content view for the menubar popover; transparent so NSPopover's native material provides the surface
- `MenuBar/MenuBarHeaderLayoutPolicy.swift` — small layout policy for the menubar header status and model rows
- `MenuBar/MenuBarHeaderStatusPresentation.swift` — Foundation-pure policy for the header status line's text and tone (recording wins over ready/warmup)
- `MenuBar/MenuBarHeaderView.swift` — popover header with app name and status; hidden entirely when idle and ready, visible for warmup, hotkey warnings, and the red "Recording" state while a meeting records
- `MenuBar/MenuBarPanelController.swift` — NSPopover controller for the menubar; while a meeting records, the meeting row's trailing slot shows the live elapsed timer instead of the start shortcut
- `MenuBar/MenuBarPrimaryActionsView.swift` — groups the dictation, meeting, paste, and recent-meetings action rows at the top of the popover
- `MenuBar/MenuBarUtilityActionsView.swift` — groups the connect-agent, feedback, updates, settings, and quit action rows at the bottom of the popover
- `MenuBar/MenuTokens.swift` — design tokens for menubar views; colors are dynamic so the popover follows the system light/dark appearance, and layer-bound colors re-resolve through `NSView.menuResolvedCGColor(_:)` on appearance changes

The agent-connect surface is the Settings window's Agent page plus the
onboarding connect stage. Both keep one mental model:

- one row per agent found on the Mac, one Connect button each
- every row points the agent's own MCP config at the same installed helper
- the universal copy-prompt row covers agents we cannot configure directly
- folders, the Codex inbox automation, and config details stay behind Advanced

### Settings/

- `Settings/AgentConnectionSettingsPage.swift` — Settings' agent page: detected-agent connect rows (Claude Desktop, Claude Code, Codex, Cursor), the universal copy-prompt row, the live-meetings toggle, and the Advanced disclosure (folders, Codex inbox, config details)
- `Settings/AutoEnterDisplayNameResolver.swift` — Foundation-pure fallback chain for Auto Enter app display names
- `Settings/HomeCanvasGreeting.swift` — time-of-day greeting helper for the Home canvas header
- `Settings/HomeDeleteConfirmationPolicy.swift` — confirmation copy for deleting recent home captures
- `Settings/HomeFailedMeetingInlinePresentation.swift` — presentation policy for failed-meeting inline recovery rows on Home
- `Settings/HomePresentation.swift` — Foundation-pure Home copy, day labels, stable feedback ids, and speaker palette slot selection
- `Settings/HomeRootAlertPolicy.swift` — Foundation-pure priority and dismissal routing for the single Home alert presenter
- `Settings/HomeMeetingSummaryBetaPresentationPolicy.swift` — presentation gates for the opt-in local AI meeting-summary beta on the Home dashboard
- `Settings/HomeMeetingPreviewFormatter.swift` — formats recent meeting preview metadata for the Settings home dashboard
- `Settings/HomeTranscriptionActivityPresentation.swift` — presentation model derived from `MeetingSessionController` state for the home page's live transcription activity card (tone, progress, transcript URL)
- `Settings/HomeView.swift` — Home canvas (greeting header with inline stats line, needs-attention pills, day-grouped capture lists with hover-reveal row actions), meeting-audio playback, failed-meeting recovery, preview/feedback sheets with AI-summary lead, and the stats detail sheet
- `Settings/HotkeyRecorderAppKitView.swift` — AppKit view for recording custom hotkey bindings
- `Settings/PermissionsOnboardingView.swift` — first-launch permissions walkthrough
- `Settings/SettingsContentLayoutPolicy.swift` — layout policy for compact settings content spacing and scroll behavior
- `Settings/SettingsRecentCaptureRefreshPolicy.swift` — central policy for whether Settings should refresh the home dashboard, the recent meetings/dictations lists, or neither when navigation changes
- `Settings/SpeakerNameAutocompleteField.swift` — SwiftUI `NSComboBox` wrapper that gives the Speakers screen's "Who is this?" field the same name autocomplete (via `SpeakerNameSelectionPolicy`) the post-meeting naming sheet uses
- `Settings/SpeakerNamingSheet.swift` — sheet for reviewing speakers in a completed meeting, grouped into local room speakers vs remote participants, with a "Keep as You" escape hatch for local mic splits
- `Settings/SpeakerPeopleSettingsSection.swift` — settings section and view model for the speakers surface: a voice-to-name queue grouped to one row per distinct voice, compact duplicate-merge suggestions, and a searchable all-speakers list with per-row play, rename, merge, and delete
- `Settings/SpeakerVoiceRowPresentation.swift` — Foundation-pure presentation/policy for the voice-to-name rows: the play/pause toggle state machine, overflow-menu actions, and name-autocomplete data source, kept view-free for unit tests
- `Settings/TranscriptedSettingsGeneralControls.swift` — shared General-page headings, grouped rows, disclosure rows, and info popovers
- `Settings/TranscriptedOnboardingWindowController.swift` — dedicated first-launch window that hosts onboarding before users drop into the menubar flow
- `Settings/TranscriptedSettingsActions.swift` — struct of callbacks (start dictation, start meeting, import audio, paste, connect agent, check updates, send feedback, copy/send diagnostics) injected into the settings view
- `Settings/TranscriptedSettingsComponents.swift` — shared SwiftUI building blocks (`SettingsPageIntro`, `SettingsSection`) used across settings pages
- `Settings/TranscriptedSettingsNavigationModel.swift` — observable navigation state for the current `TranscriptedSettingsPage` selection
- `Settings/TranscriptedSettingsPage.swift` — enum of window pages (home, dictations, people, connectAgent, plus the gear-gated settings pages) with titles, summaries, and SF Symbol names
- `Settings/TranscriptedSettingsRows.swift` — reusable Settings rows for correction editing, model choices, Auto Enter apps, retained-audio playback, and failed meetings
- `Settings/TranscriptedSettingsSidebar.swift` — sidebar section model: content-first primary rows (Home/Dictations/Speakers/Agent); settings pages render as a tab strip in the content pane, reached from the sidebar gear
- `Settings/TranscriptedSettingsView.swift` — main settings view
- `Settings/TranscriptedSettingsWindowController.swift` — NSWindowController for settings
- `Settings/TypingTimeSavedFormatter.swift` — Foundation-pure formatter for Home's typing-time-saved stat

### Shared/

- `Shared/AgentConnectionGuide.swift` — shared starter prompt, folder paths, Codex inbox, live-sidecar, and portable meeting bundle copy for the agent-connect flow
- `Shared/AccessibilityDisplayPolicy.swift` — shared AppKit policy for honoring Reduce Motion and Reduce Transparency on overlay and Settings surfaces
- `Shared/AppSoundPlayer.swift` — UI sound preferences and playback helpers
- `Shared/FeedbackIssueBuilder.swift` — builds sanitized support email payloads and links from current app state
- `Shared/FirstRunExperience.swift` — shared first-run menu and onboarding state helpers for permission, local-model, dictation, and meeting CTA copy
- `Shared/HomeCaptureRefreshObserver.swift` — bridges `.meetingCaptureArtifactsDidChange` into a plain callback so Home's scan-time cache silently reloads its transcript/audio URLs after background recompression or transcript rename
- `Shared/HomeMeetingDeletion.swift` — shared deletion service for Home meeting rows, including transcript, summary, and retained-audio cleanup
- `Shared/HomeMeetingRename.swift` — renames an app-owned meeting from the Home preview's editable title: rewrites the `title:` frontmatter and body heading, then moves the transcript, retained audio, and summary sidecar to the canonical `YYYY-MM-dd <title>` stem via `MeetingArtifactRenamer`
- `Shared/HomeMeetingRowActionTargets.swift` — resolves transcript and retained-audio Finder reveal targets for Home meeting row menu actions
- `Shared/MeetingAudioArchiveResolver.swift` — resolves retained meeting-audio attachments that belong to a saved transcript for review playback
- `Shared/MeetingAudioPlayback.swift` — shared play/pause/resume `NSSound`-backed controller for recent-meeting audio previews in Settings
- `Shared/OwnFileResolver.swift` — single resilient resolver every Home/meeting own-file access routes through; tolerates post-scan file drift (WAV→M4A recompression, transcript/audio rename) for reveal-in-Finder and open/read/play, and fails loud instead of dead-clicking
- `Shared/RecentCaptureScanners.swift` — `RecentMeetingsScanner` that loads recent meeting transcripts plus retained audio attachments for the Settings home page
- `Shared/SpeakerClipPlayback.swift` — reusable audio-preview helper for persisted speaker sample clips
- `Shared/SpeakerReviewQueueScanner.swift` — loads saved speaker-review queue items for the people settings and review flows
- `Shared/SupportDiagnosticsBundle.swift` — privacy-safe support summary used for copied diagnostics and manual diagnostic events, including recent coarse reliability packet summaries
- `Shared/TranscriptedSupportActions.swift` — support flows for feedback, copied diagnostics, and manually queued diagnostic events

Cross-cutting permission checks now live in `Sources/Support/TranscriptedPermissionAccess.swift`
so the meeting prompt detector and the settings/onboarding flows share the same
app-level permission logic outside the UI tree.

Cross-cutting local-speaker behavior is split between settings and review UI:
`TranscriptedSettingsView` owns the persisted toggle for local mic diarization,
while `SpeakerNamingSheet` is where users confirm local-vs-remote speakers or
collapse the local side back into a single "You" track.

The main window is content-first: the sidebar leads with Home, Dictations,
Speakers, and Agent; the sidebar gear opens a settings area in the content
pane with a capsule tab strip (General/Storage/Beta/Support/About). Home is the meetings surface — an editorial canvas (time-of-day
greeting, stats line, needs-attention pills, failed-meeting recovery, the
day-grouped meetings list); Dictations is the separate dictation history. `HomeView` keeps recent
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

Manual checks:

- dictation overlay starts, stops, and auto-pastes cleanly
- detected-meeting prompts appear only when appropriate and can start, dismiss, or remind a meeting cleanly
- meeting overlay warms up and records cleanly
- imported-audio transcription can be started from the menubar and lands in the normal recent-meetings flow
- menubar popover renders shortcuts, primary actions, settings actions, and the agent-connect page cleanly
- speaker settings can preview clips, surface duplicates, toggle local-speaker splitting, and rename / merge people cleanly
- completed meeting review cleanly separates "People in the room" from remote participants, can resolve retained meeting audio playback, and "Keep as You" restores the single-speaker local path when needed
- recent meetings on Home and in Settings can play retained audio attachments without losing sync between transcript rows and playback state
- failed meetings surface retained audio on Home and Settings so users can play it, reveal it in Finder, or retry transcription from the preserved files
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
- `Tests/HomeCanvasGreetingTests.swift`
- `Tests/HomeCaptureRefreshTests.swift`
- `Tests/HomePresentationTests.swift`
- `Tests/HomeRootAlertPolicyTests.swift`
- `Tests/HomeMeetingDeletionTests.swift`
- `Tests/HomeMeetingRenameTests.swift`
- `Tests/HomeMeetingSummaryBetaPresentationPolicyTests.swift`
- `Tests/FirstRunExperienceTests.swift`
- `Tests/HomeMeetingPreviewFormatterTests.swift`
- `Tests/MenuBarHeaderStatusPresentationTests.swift`
- `Tests/MeetingAudioArchiveResolverTests.swift`
- `Tests/MeetingLiveViewAffordancePolicyTests.swift`
- `Tests/MeetingDurationFormatterTests.swift`
- `Tests/LiveTranscriptPlainTextRendererTests.swift`
- `Tests/MeetingPillRestPolicyTests.swift`
- `Tests/OwnFileResolverTests.swift`
- `Tests/RecentCaptureScannersTests.swift`
- `Tests/SettingsContentLayoutPolicyTests.swift`
- `Tests/SettingsRecentCaptureRefreshPolicyTests.swift`
- `Tests/AutoEnterDisplayNameResolverTests.swift`
- `Tests/TypingTimeSavedFormatterTests.swift`
- `Tests/SpeakerReviewQueueScannerTests.swift`
- `Tests/SpeakerVoiceRowPresentationTests.swift`
- `Tests/SupportDiagnosticsBundleTests.swift`
- `Tests/UIAutomationSurfaceContractTests.swift`
- `bash scripts/ops/transcripted-qa-bench.sh --mode ui` for live AX smoke of first-run onboarding, menu bar, Home, Settings, and navigation
