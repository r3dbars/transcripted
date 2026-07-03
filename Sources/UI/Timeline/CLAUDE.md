# Timeline UI Directory

## What this directory does

`Sources/UI/Timeline/` owns the SwiftUI surface for the Dayflow-style
Transcripted timeline. It renders screen-activity cards alongside meetings
and dictations, exposes timeline navigation, day and week views, and a chat
shell over timeline data, and surfaces capture/permission pause states. Keep
this folder focused on rendering and presentation policy; timeline capture,
storage, and analysis belong outside the UI tree. Views should render from
protocol/sample data until the capture/database seam is ready. It does not
run screenshot capture or card generation.

## Current files

- `TimelineHomePresentation.swift` — mock/sample data, layout policy, and the
  debug flag for previewing the timeline home.
- `TimelineHomeView.swift` — compact home composition / day canvas.
- `TimelineCanvasCard.swift` — positioned card block on the vertical timeline.
- `TimelineDetailPanel.swift` — selected card detail panel.
- `TimelineLiveStatusCard.swift` — current generating/paused/resume status row.
- `TimelineDayNavigation.swift` — day picker/navigation strip.
- `TimelineTokens.swift` — local colors, spacing, and typography.
- `TimelineWeekGridView.swift` — seven-day 4 AM to 4 AM week grid.
- `TimelineDashboardView.swift` — compact weekly dashboard backed by `WeeklyStatsBuilder`.
- `TimelineChatView.swift` — lightweight chat panel shell over `TimelineChatMessage`; renders a question composer, message list, local/off-device privacy state, and empty states.

## Planned files (future phases)

- `ScreenshotSlideshowView.swift` — future fullscreen screenshot playback and scrubber
- `CategoryPickerView.swift` — future category edit/swap overlay

## Current notes

- Keep UI state on the main actor.
- Use `TimelinePreferences` and `TranscriptedPermissionKind.screenRecording` for settings and permission affordances.
- Do not send screen-derived titles, OCR text, app names, URLs, or screenshot paths to Sentry or PostHog.
- Do not make Timeline Home the default settings Home until the backend and
  permission/onboarding path are landed. Use the preview/debug flag only.
- Keep views local-first. Do not emit analytics payloads from these views unless
  the payload is bucketed and covered by observability policy tests.
- Show a clear inline notice before a cloud provider can receive timeline text.
- Keep heavy data loading and provider calls outside the view.

## Verification

After changing timeline UI source:

```bash
bash build.sh --no-open
bash run-tests.sh
```
