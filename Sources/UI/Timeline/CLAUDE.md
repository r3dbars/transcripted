# Timeline UI Directory

## What this directory does

`Sources/UI/Timeline/` owns the SwiftUI surface for the Dayflow-style
Transcripted timeline. It renders screen-activity cards alongside meetings
and dictations, exposes timeline navigation, and surfaces capture/permission
pause states. Keep this folder focused on rendering and presentation policy;
timeline capture, storage, and analysis belong outside the UI tree.

## Current files (Phase 4)

- `TimelineHomePresentation.swift` — mock/sample data, layout policy, and the
  debug flag for previewing the timeline home.
- `TimelineHomeView.swift` — compact home composition / day canvas.
- `TimelineCanvasCard.swift` — positioned card block on the vertical timeline.
- `TimelineDetailPanel.swift` — selected card detail panel.
- `TimelineLiveStatusCard.swift` — current generating/paused/resume status row.
- `TimelineDayNavigation.swift` — day picker/navigation strip.
- `TimelineTokens.swift` — local colors, spacing, and typography.

## Planned files (future phases)

- `ScreenshotSlideshowView.swift` — future fullscreen screenshot playback and scrubber
- `TimelineWeekGridView.swift` — future weekly overview
- `TimelineDashboardView.swift` — future weekly analytics
- `TimelineChatView.swift` — future chat over a day
- `CategoryPickerView.swift` — future category edit/swap overlay

## Current notes

- Keep UI state on the main actor.
- Use `TimelinePreferences` and `TranscriptedPermissionKind.screenRecording` for settings and permission affordances.
- Do not send screen-derived titles, OCR text, app names, URLs, or screenshot paths to Sentry or PostHog.
- Do not make Timeline Home the default settings Home until the backend and
  permission/onboarding path are landed. Use the preview/debug flag only.

## Verification

After changing timeline UI source:

```bash
bash build.sh --no-open
bash run-tests.sh
```
