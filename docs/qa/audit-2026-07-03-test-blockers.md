# Audit 2026-07-03 QA Hook Blockers

This note tracks audit findings that need implementation hooks before a useful
fast regression test can be added without testing private UI timing or raw
AppKit state.

## Capture Pill Prompt Actions

- Needed hook: `CapturePillController` should expose distinct `onExpired` and
  `onRemindSoon` callbacks.
- Needed wiring: `TranscriptedApp` should call
  `MeetingPromptHeuristics.promptTimeoutSeconds(for:calendarDefault:)` when it
  presents the capture pill, route expiry to `MeetingPromptDetector.expire`,
  and route Remind Soon to `MeetingPromptDetector.remindSoon`.
- Why blocked: `MeetingPromptHeuristics` and `MeetingPromptDetector` already
  have fast coverage for expiry/remind-soon policy, but the active capture-pill
  UI still only exposes Record and Not Now.

## Import Video Recordings

- Needed hook: a Foundation-pure import content-type policy that accepts
  `.audio` plus movie/audiovisual containers with at least one audio track.
- Needed UI wiring: the import picker should allow common video meeting
  containers such as `.mp4` and `.mov`.
- Why blocked: `MeetingImportedAudioPreparer` currently rejects any content type
  that does not conform to `.audio`, so a passing fast test would only encode
  today's rejected behavior.

## Permission Revalidation From Settings

- Needed hook: injectable system-audio revalidation in
  `TranscriptedPermissionAccess.requestAccessOrOpenSettings(for:)`, equivalent
  to the existing `requestSystemAudioRecordingAccessIfNeeded(forceRefresh:)`
  test seam.
- Why blocked: the forced meeting-start revalidation is covered, but the
  Settings/Open Settings path still trusts a cached granted state before
  opening System Settings.

## Actionable Error Dismissal

- Needed hook: a small Foundation-pure overlay error policy that states whether
  an actionable error can be dismissed, whether Escape should dismiss it, and
  whether one-shot actions such as Open Settings should hide the panel.
- Why blocked: the current behavior is embedded in `FloatingOverlayController`
  and `DictationSessionController` UI state, making a fast test either brittle
  source scanning or an AppKit timing test.
