# UI/Shared module

Module `UIShared` in `.agents/modules.json`. The file-by-file notes for this folder stay in `Sources/UI/AGENTS.md` ("Shared/"); this page is the module card.

## Owns

Presentation and library services that more than one surface uses: Home and Dictations (scanning, metadata cache, rename, deletion, Undo), meeting-audio and speaker-clip playback, the dictionary past-meeting fix, first-run state, support and feedback actions, and the shared design tokens.

## Public surface

`LibraryTokens`, `RecentMeetingsScanner`, `RecentMeetingMetadataCache`, `RecentMeetingItem`, `MeetingAudioPlayback`, `MeetingAudioArchiveResolver`, `SpeakerClipPlayback`, `SpeakerReviewQueueScanner`, `HomeMeetingRename`, `HomeMeetingDeletion`, `HomeMeetingRowActionTargets`, `CaptureUndoManager`, `OwnFileResolver`, `DictionaryPastMeetingFix`, `AccessibilityDisplayPolicy`, `FirstRunExperience`, `FocusOrderContract`, `MeetingPillFinishPresentation`, `AppSoundPlayer`, `FeedbackIssueBuilder`, `SupportEmailDispatcher`.

## May depend on

Meeting, Dictation, Speech, WritingBridge, Support, Observability, and Core's `core-vocab` tier. Not AppState, UISettings, UIOverlay or UIMenuBar: those sit above this module. `.agents/modules.json` is the source of truth; `python3 scripts/dev/check-module-boundaries.py --explain <file>` prints it.

Grandfathered crossings (in `.agents/module-boundary-baseline.json`): `HomeMeetingRename` and `SpeakerReviewQueueScanner` name Home preview types from `UI/Settings/HomeMeetingPreviewFormatter.swift` (fixed by moving that file here), and `TranscriptedSupportActions` takes `TranscriptedAppState` (fixed by moving it to `Sources/App/`). Both moves wait for #1946.

## Entry points

- `RecentCaptureScanners.swift` (`RecentMeetingsScanner`) feeds Home and the Meetings search.
- `HomeMeetingDeletion.swift`, `HomeMeetingRename.swift`, `CaptureUndo.swift` are the only paths that delete, rename or restore a saved meeting from the UI.
- `MeetingAudioPlayback.swift` is retained meeting-audio playback (a product-surface rule in the root `AGENTS.md`).

## Tests

`bash run-tests.sh --filter HomeMeeting`, `--filter CaptureUndo`, `--filter FocusOrderContract`, `--filter SupportDiagnosticsBundle`.

## Rules

- Deletes, renames and rewrites of saved meetings go through the transcript-update serializer, and anything that deletes checks the path is under the capture library first.
- Retained meeting-audio playback stays: clicking a row's time plays from there, and rows don't follow the playhead.
- Nothing here sends transcript text, titles, speaker names or paths off the device; `SupportDiagnosticsBundle` is the privacy-safe summary.
