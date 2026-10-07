# UI/Shared module

Module `UIShared` in `.agents/modules.json`. Parent: `Sources/UI/AGENTS.md`.

## Owns

Presentation and library services that more than one surface uses: Home and Dictations (scanning, metadata cache, rename, deletion, Undo), meeting-audio and speaker-clip playback, the dictionary past-meeting fix, first-run state, support and feedback actions, and the shared design tokens.

## Public surface

`LibraryTokens`, `MenuTokens`, `RecentMeetingsScanner`, `RecentMeetingMetadataCache`, `RecentMeetingItem`, `HomeMeetingPreviewContent` and the Home preview types in `HomeMeetingPreviewFormatter.swift`, `MeetingAudioPlayback`, `MeetingAudioArchiveResolver`, `SpeakerClipPlayback`, `SpeakerReviewQueueScanner`, `HomeMeetingRename`, `HomeMeetingDeletion`, `HomeMeetingRowActionTargets`, `CaptureUndoManager`, `OwnFileResolver`, `DictionaryPastMeetingFix`, `AccessibilityDisplayPolicy`, `FirstRunExperience`, `FocusOrderContract`, `MeetingPillFinishPresentation`, `FeedbackIssueBuilder`, `SupportEmailDispatcher`.

## May depend on

Meeting, Dictation, Speech, WritingBridge, Support, Observability, and Core's `core-vocab` tier. Not AppState, UISettings, UIOverlay or UIMenuBar: those sit above this module. `.agents/modules.json` is the source of truth; `python3 scripts/dev/check-module-boundaries.py --explain <file>` prints it.

## Files

Scanning and cache:

- `RecentCaptureScanners.swift` holds the capture value types (`RecentMeetingItem`, audio health, speaker status) and the recent-captures loading. `RecentMeetingsScanner.swift` loads recent meeting transcripts plus retained audio for Home and builds the full-library rows for the Meetings search (`loadSearchIndex`). Today uses the bounded `loadTodayIndex` path; its partial rows never populate the full speaker-search cache.
- `RecentMeetingMetadataCache.swift` is a SQLite cache of derived meeting-row metadata keyed by transcript path and validated by mtime and size, so a warm refresh skips re-parsing every transcript.
- `HomeCaptureRefreshObserver.swift` turns `.meetingCaptureArtifactsDidChange` into a callback so Home reloads transcript and audio URLs after background recompression or a rename.
- `HomeMeetingPreviewFormatter.swift` builds preview content and staged speaker-correction and naming plans for the Home expansion.
- `SpeakerReviewQueueScanner.swift` loads queued speaker-review items for the people settings and review flows.

Changing saved meetings:

- `HomeMeetingDeletion.swift` is the deletion service for Home rows. Planning and reversible Trash/Undo run off-main through the transcript-update serializer so a background rewrite can't resurrect a deleted transcript. It also cleans the legacy summary sidecar and retained audio, checks for stale rows, and refuses while a retranscription is active.
- `HomeMeetingRename.swift` renames an app-owned meeting from the row's ⋯ menu: rewrites `title:` frontmatter and the body heading, then moves transcript, retained audio and legacy sidecar to the canonical `YYYY-MM-dd <title>` stem through `MeetingArtifactRenamer`.
- `CaptureUndo.swift` is "delete now, offer Undo for a few seconds" (6 s grace window), used by Home and Dictations instead of confirm dialogs. It performs and reverses the move or rewrite and keeps the grace bookkeeping.
- `DictionaryPastMeetingFix.swift` applies a Settings dictionary correction to saved meetings with the live-transcription matcher (longer rules win). Only spoken turns between `## Transcript` and the next section change: never frontmatter, title, labels, timestamps, trailing notes or summaries, links, paths or code. Each original is backed up under `state/dictionary-fix-backups/` before writing (kept 3 days, pruned at launch, dropped when the meeting is deleted or goes missing); it keeps creation dates, writes through the serializer, and undoes only files nobody changed since. Meetings are found by file name in the current meetings folder, so a moved library keeps its Undo; busy meetings keep their backups so Undo can retry.
- `OwnFileResolver.swift` is the one resolver for Home and meeting own-file access. It tolerates drift after a scan (WAV to M4A recompression, rename) for reveal, open, read and play, and fails loudly instead of dead-clicking. `HomeMeetingRowActionTargets.swift` resolves the reveal-in-Finder targets for row menu actions.

Playback:

- `MeetingAudioPlayback.swift` is the `NSSound`-backed play/pause/resume/seek-from-timestamp controller; `MeetingAudioArchiveResolver.swift` finds the retained audio that belongs to a transcript; `SpeakerClipPlayback.swift` plays persisted speaker sample clips.

Presentation, tokens and support:

- `LibraryTokens.swift` (accent, ink, hairline, radii, type roles) serves the main-window surfaces and the popover; overlays keep their own tokens. `MenuTokens.swift` serves the menu bar and Settings' hotkey recorder; colors are dynamic and layer colors re-resolve through `NSView.menuResolvedCGColor(_:)`.
- `AccessibilityDisplayPolicy.swift` honors Reduce Motion and Reduce Transparency on overlay and Settings surfaces. `FocusOrderContract.swift` is the single source for Tab order of the popover and settings sidebar.
- `MeetingPillFinishPresentation.swift` is the copy and timing for how a meeting finishes (transcribing percent, "N more waiting", saved dwell, when the error state offers Open). `FirstRunExperience.swift` is first-run menu and onboarding state and CTA copy.
- `AgentConnectionGuide.swift` is the starter prompt, folder paths, Codex inbox and portable meeting bundle copy for agent connect. `SystemAudioPermissionRevalidator.swift` is the single owner of System Audio Recording revalidation for the Settings shell and onboarding, with an in-flight guard so they can't overlap.
- `FeedbackIssueBuilder.swift` builds sanitized support payloads. `SupportEmailDispatcher.swift` hands off to Mail with an explicit failure fallback; callers keep the draft on failure, and the support address is copied only on request.

## Tests

`bash run-tests.sh --filter HomeMeeting`, `--filter CaptureUndo`, `--filter FocusOrderContract`, `--filter RecentCaptureScanners`, `--filter OwnFileResolver`, `--filter FeedbackIssueBuilder`. Others are named for their file (`MeetingAudioArchiveResolverTests`, `MeetingPillFinishPresentationTests`, `FirstRunExperienceTests`, `AgentConnectionGuideTests`, `HomeCaptureRefreshTests`).

## Rules

- **One path to change a saved meeting.** Deletes, renames, Undo and rewrites go through `HomeMeetingDeletion`, `HomeMeetingRename`, `CaptureUndo` and the transcript-update serializer. Anything that deletes checks the path is under the capture library first.
- **Retained meeting-audio playback stays** (root `AGENTS.md`): clicking a row's time plays from there; rows don't follow the playhead.
- **Own files resolve through `OwnFileResolver`.** Don't cache a scanned URL past a refresh; files get recompressed and renamed in the background.
- **Nothing here sends transcript text, titles, speaker names or paths off the device.** The privacy-safe support summary is `Sources/Observability/SupportDiagnosticsBundle.swift`.
- **Swift concurrency.** Constants used off the main actor are `nonisolated static let`; off-main work goes through a continuation over GCD (see the parent's census note).
