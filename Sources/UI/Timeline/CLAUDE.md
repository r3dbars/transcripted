# Timeline UI Directory

## What this directory does

`Sources/UI/Timeline/` owns the future SwiftUI surface for the Dayflow-style
Transcripted timeline. It will render screen-activity cards alongside meetings
and dictations, expose timeline navigation, and surface capture/permission
pause states.

Phase 0 is scaffolding only. Do not add the timeline home screen or settings UI
until the matching UI phase.

## Planned files

- `TimelineHomeView.swift` — future day canvas and default home surface
- `TimelineCanvasCard.swift` — future card block on the vertical timeline
- `TimelineDetailPanel.swift` — future selected-card detail view
- `TimelineLiveStatusCard.swift` — future generating/paused/resume card near now
- `TimelineDayNavigation.swift` — future day pills and calendar popover
- `ScreenshotSlideshowView.swift` — future fullscreen screenshot playback and scrubber
- `TimelineWeekGridView.swift` — future weekly overview
- `TimelineDashboardView.swift` — future weekly analytics
- `TimelineChatView.swift` — future chat over a day
- `CategoryPickerView.swift` — future category edit/swap overlay
- `TimelineTokens.swift` — future timeline design tokens

## Current notes

- Keep UI state on the main actor.
- Use `TimelinePreferences` and `TranscriptedPermissionKind.screenRecording` for settings and permission affordances.
- Do not send screen-derived titles, OCR text, app names, URLs, or screenshot paths to Sentry or PostHog.

## Verification

After changing timeline UI source:

```bash
bash build.sh --no-open
bash run-tests.sh
```
