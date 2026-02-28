# FloatingPanel — CLAUDE.md

## Purpose
The main user-facing UI: a draggable floating pill that shows recording state, audio visualizations, processing progress, and action item review. Implements a state machine with animation guards.

## Key Files

| File | Responsibility |
|------|---------------|
| `FloatingPanelController.swift` | NSWindowController for the floating NSPanel, drag handling, position persistence |
| `PillStateManager.swift` | State machine: idle → recording → processing → reviewing, with transition guards |
| `FloatingPanelView.swift` | Main SwiftUI composition, switches view based on PillState |
| `Components/PillViews.swift` | State-specific pill layouts (IdlePill, RecordingPill, ProcessingPill, ReviewingPill) |
| `Components/WaveformViews.swift` | Audio level visualizers (EdgePeek, WaveformMini, DormantWaveform) |
| `Components/AuroraIdleView.swift` | Animated aurora background for idle state |
| `Components/AuroraRecordingView.swift` | Animated aurora background for recording state |
| `Components/AuroraProcessingView.swift` | Animated aurora for processing state |
| `Components/AuroraSuccessView.swift` | Animated aurora for success state |
| `Components/CelebrationViews.swift` | Success checkmark and confetti animations |
| `Components/ErrorViews.swift` | Error banners with recovery hints |
| `Components/AttentionPromptView.swift` | "Still recording?" silence warning |
| `Components/ReviewTrayView.swift` | Action item review tray (approve/reject items) |
| `Helpers/LawsComponents.swift` | Reusable UI primitives (buttons, status text) |

## State Machine

```
idle → recording (user taps record)
recording → processing (user stops, transcription begins)
processing → reviewing (action items found, pending approval)
processing → idle (no action items, transcript saved)
reviewing → idle (user approves/dismisses)

Guards:
- Transition cooldown prevents rapid state changes
- Lock prevents transitions during review (except emergency idle)
- Stuck transition timeout (2s) auto-recovers
```

## Common Tasks

| Task | Files to touch | Watch out for |
|------|---------------|---------------|
| Fix pill behavior | `PillStateManager.swift` | Check transition guards, cooldown, lock state |
| Fix window/dragging | `FloatingPanelController.swift` | NSPanel level, position saved in UserDefaults |
| Fix recording animations | `AuroraRecordingView.swift`, `WaveformViews.swift` | Audio level data comes from Audio.swift |
| Fix success/error states | `CelebrationViews.swift`, `ErrorViews.swift` | Triggered by PillStateManager transitions |
| Fix silence prompt | `AttentionPromptView.swift` | Reads silenceDuration from Audio.swift |
| Fix action item review | `ReviewTrayView.swift` | Binds to TranscriptionTaskManager pending items |
| Add new pill state | `PillStateManager.swift`, new view in `Components/` | Update FloatingPanelView switch |

## Failure Modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pill stuck in state | Transition guard blocking | Check `ui` logs for "Blocked transition" |
| Pill won't unlock | isLocked flag stuck | forceUnlock() exists as emergency recovery |
| Animations jittery | Too many concurrent animations | Check animation presets in DesignTokens |
| Pill position lost | UserDefaults keys cleared | Check `floatingPanelX`/`floatingPanelY` |

## Dependencies

**Imports from Core/**: Audio (levels), TranscriptionTaskManager (progress/state), FailedTranscriptionManager
**Imports from Design/**: DesignTokens (colors, spacing, PillDimensions, PillAnimationTiming)

## Logging

Subsystem: `ui` — pill transitions, blocked transitions, force unlock events.
