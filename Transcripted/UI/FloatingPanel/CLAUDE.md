# FloatingPanel

Morphing pill UI (Dynamic Island style) with aurora visualizations, transcript tray, and speaker naming dialog. 26 Swift files across root, Components/, and Helpers/.

## File Index

### Root (4 files)

| File | Purpose |
|------|---------|
| `PillStateManager.swift` | State machine: idle -> recording -> processing. Timeout recovery, sound feedback. |
| `FloatingPanelView.swift` | Root SwiftUI view. Tray mux (none/transcripts/speakerNaming), toast layer, pill content switch. |
| `FloatingPanelController.swift` | NSWindowController. Position persistence, Combine subscriptions to Audio/TaskManager, window setup. |
| `PillCalloutController.swift` | NSWindowController for onboarding callout positioned above the pill. |

### Components/ (21 files)

| File | Purpose |
|------|---------|
| `AuroraIdleView.swift` | Collapsed pill (40x20px). Hover-expands to 200x44px with Record + Transcripts buttons. |
| `AuroraRecordingView.swift` | Recording state (180x40px). Live aurora fog: coral (mic) + teal (system). Timer + stop. |
| `AuroraProcessingView.swift` | Processing state (180x40px). Progress-based aurora intensity. Warning at 90s+. |
| `AuroraSuccessView.swift` | Success feedback (200x44px). Animated checkmark + "Saved" + Copy/Open buttons. |
| `TranscriptTrayView.swift` | Recent transcript list (280x300px max). Frosted glass. Date separators. |
| `TranscriptRowView.swift` | Single row in transcript tray: title, relative date, duration, copy button. |
| `TranscriptDetailView.swift` | Single transcript viewer. Groups lines by speaker with colored left borders. |
| `SpeakerNamingView.swift` | Post-recording speaker naming. Play clips, confirm/reject names, merge profiles. |
| `SpeakerNamingCard.swift` | Individual speaker card: name input, autocomplete, confirm/reject/merge actions. |
| `ClipAudioPlayer.swift` | AVAudioPlayer wrapper for speaker clip playback (one at a time). |
| `ToastNotificationView.swift` | Slides in from bottom, shows error with context, auto-dismisses after 8s. |
| `ContextualErrorBanner.swift` | ContextualError enum: classifies errors by keyword into typed categories with recovery hints. |
| `PillErrorView.swift` | Coral-tinted pill with shake animation for errors. |
| `PillCalloutView.swift` | Coach mark callout SwiftUI view with arrow and glassmorphism background. |
| `PillOverlayViews.swift` | FailedBadgeOverlay (red circle count) and processing pulse dot. |
| `PillIdleView.swift` | Legacy idle pill view (mostly replaced by AuroraIdleView). |
| `PillRecordingView.swift` | Legacy recording pill view (mostly replaced by AuroraRecordingView). |
| `PillProcessingView.swift` | Legacy processing pill view (mostly replaced by AuroraProcessingView). |
| `AttentionPromptView.swift` | Silence warning + still-recording detection prompt. |
| `CelebrationViews.swift` | CelebrationOverlay with ring/checkmark animations. |
| `WaveformViews.swift` | EdgePeekView, WaveformMiniView, DormantWaveformView, MinimalWaveformIcon. |

### Helpers/ (1 file)

| File | Purpose |
|------|---------|
| `LawsComponents.swift` | AnimatedDotsView, LawsButton, FloatingTooltipModifier, Triangle connector shape. |

## Key Splits from Original Files

- `ErrorViews.swift` split into: ToastNotificationView, ContextualErrorBanner, PillErrorView
- `PillViews.swift` split into: PillIdleView, PillRecordingView, PillProcessingView
- `SpeakerNamingView.swift` split out: SpeakerNamingCard, ClipAudioPlayer
- `TranscriptTrayView.swift` split out: TranscriptRowView
- `PillCalloutController.swift` + `PillCalloutView.swift` are new (onboarding callout)
- `PillOverlayViews.swift` is new (badge + pulse dot extracted from other views)

## All files are @MainActor (SwiftUI views + NSWindowControllers)

## Gotchas
- Naming tray is STICKY (persists across pill states), transcript tray is NOT (auto-closes on processing)
- Toast notification space collapses to 0pt when tray is open
- AuroraSuccessView auto-dismiss (2.5s) is controlled by FloatingPanelController, not the view itself
- Speaker colors are hash-based (name % 5 palette), user always gets .accentBlue
- Silence prompt triggers at 120s of silence (not recording duration)
- PillCalloutController positions itself relative to the pill's NSWindow frame
