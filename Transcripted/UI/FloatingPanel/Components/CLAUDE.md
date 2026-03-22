# FloatingPanel Components

21 SwiftUI views for the morphing pill UI — aurora state visualizations, transcript browsing, speaker naming, error display, and celebrations. All @MainActor.

## File Index

| File | Purpose |
|------|---------|
| `AuroraIdleView.swift` | Collapsed pill (40x20). Hover-expands to 200x44 with Record + Transcripts buttons. |
| `AuroraRecordingView.swift` | Recording state (200x44). Live aurora fog: coral mic (left) + teal system (right). |
| `AuroraProcessingView.swift` | Processing state (200x44). Progress-based aurora intensity. Warning at 90s+. |
| `AuroraSuccessView.swift` | Success feedback (200x44). Animated checkmark + "Saved" + Copy/Open buttons. |
| `TranscriptTrayView.swift` | Recent transcript list (280x300 max). Frosted glass. Date separators. |
| `TranscriptRowView.swift` | Single row: smart title, relative date, duration, copy button. |
| `TranscriptDetailView.swift` | Full transcript viewer. Groups lines by speaker with colored left borders. |
| `SpeakerNamingView.swift` | Post-recording speaker naming container. 3s dismiss guard. |
| `SpeakerNamingCard.swift` | Per-speaker card: name input, autocomplete, confirm/reject/merge actions. |
| `ClipAudioPlayer.swift` | AVAudioPlayer wrapper for speaker clip playback (one at a time). |
| `ToastNotificationView.swift` | Error notification toast, slides in, auto-dismisses after 8s. Hover pauses timer. |
| `ContextualErrorBanner.swift` | ContextualError enum: classifies errors by keyword into typed categories. |
| `PillErrorView.swift` | Coral-tinted pill with shake animation for errors. |
| `PillCalloutView.swift` | Onboarding coach mark with glassmorphism and bouncing arrow. |
| `PillOverlayViews.swift` | FailedBadgeOverlay (red circle count), RecordingDotView, SystemAudioWarningIndicator. |
| `PillIdleView.swift` | Legacy idle pill (mostly replaced by AuroraIdleView). |
| `PillRecordingView.swift` | Legacy recording pill (mostly replaced by AuroraRecordingView). |
| `PillProcessingView.swift` | Legacy processing pill (mostly replaced by AuroraProcessingView). |
| `AttentionPromptView.swift` | Silence warning + still-recording detection prompt. |
| `CelebrationViews.swift` | CelebrationOverlay with ring/checkmark animations. |
| `WaveformViews.swift` | EdgePeekView, WaveformMiniView, DormantWaveformView, MinimalWaveformIcon. |

## Aurora Views — Dimensions & Behavior

| State | Width | Height | Audio-reactive | Notes |
|-------|-------|--------|----------------|-------|
| Idle (collapsed) | 40 | 20 | No | Hover-expands to 200x44. mic.fill icon (10pt) |
| Idle (expanded) | 200 | 44 | No | Record + Transcripts buttons. Spring(0.15, 0.8) |
| Recording | 200 | 44 | Yes (mic only) | Coral left fog + teal right breathing fog |
| Processing | 200 | 44 | No | Progress-based aurora brightness (3 phases) |
| Success | 200 | 44 | No | Checkmark anim + Copy/Open, green radial glow |

**AuroraRecordingView params:**
- Smoothing: 0.08 at 30fps. Orbs: 2 per fog layer. Blur: 8px. Opacity: 0.75 (mic), 0.7 (system)
- AudioBoost: 0.6 + audioLevel * 1.5 (range 0.6-2.1x)
- Position bias: -0.8 (left/mic), +0.8 (right/system). Speed: time * 0.15 (calm)
- Breathing oscillation: 1.0 + breatheNoise * 0.12. `drawingGroup()` for GPU

**AuroraProcessingView phases:**
- <15% progress: opacity 0.45, speed 0.03/4s (slow)
- 15-75%: opacity 0.60, speed 0.08/2s (moderate)
- >75%: opacity 0.75, speed 0.15/1s (fast)
- Warning text: 90s → "Still working...", 120s → "Taking longer..."
- Celebration bloom: 0.15s delay, brightness 0.3 fading out in 0.2s

**AuroraSuccessView checkmark animation:**
- Phase 1 (0-0.3s): Scale 0→1.0, spring(0.4, 0.6)
- Phase 2 (0.3-0.45s): Bounce to 1.15, spring(0.2, 0.5)
- Phase 3 (0.45s+): Settle to 1.0, spring(0.15, 0.8)
- Phase 4 (0.2-0.45s): Text fade-in, easeOut(0.25)
- Copy button: 1.5s checkmark feedback before reverting to doc.on.doc

**AuroraIdleView `hasSettled`:**
- Starts at success dimensions (200x44) when coming from success state
- Animates down to idle collapsed (40x20) after settling
- Prevents jarring size jump on success→idle transition

## Transcript Tray Views

**TranscriptTrayView:** 280x300 max, 10 recent transcripts, frosted glass + triangle connector. Frosted glass (hudWindow material). Date separators between groups.

**TranscriptRowView — smart title logic:**
1. Prefer Qwen-generated title (if not "Meeting")
2. Fall back to speaker names (first 2 names or "N speakers")
3. Generic "Meeting" as last resort
- Copy puts AI-ready dialogue (no YAML) on clipboard
- Copy states: .isCopied (checkmark 1.5s), .copyFailed (xmark)
- Relative date: "Today at HH:MM a", "Yesterday at HH:MM a", "MMM d at HH:MM a"

**TranscriptDetailView:**
- MessageGroup model: groups consecutive lines by same speaker, generates stable ID from content
- DialogueBlockView: 3px left border colored by speaker hash
- Speaker colors: 5 colors via hash — blue, purple, teal, amber, rose (muted values). User (Mic/*) always accentBlue
- Max height: 280

## Speaker Naming (SpeakerNamingView + SpeakerNamingCard)
- 3-second dismiss guard on appear (prevents accidental close)
- SpeakerNamingEntry: id, clipURL, sampleText, currentName, needsNaming, needsConfirmation, matchSimilarity, qwenResult
- Autocomplete: 150ms debounce, max 4 suggestions, filters out self (entry.id)
- Play button: 32x32 circle, stop.fill (blue) when active / play.fill when idle
- Source labels: "Voice match · XX%" or "Detected from conversation" (sparkles icon)
- Merge flow: show candidate → confirm (checkmark) or cancel (xmark)
- SpeakerNameUpdate.NamingAction: `.named`, `.confirmed`, `.corrected`, `.merged(targetProfileId)`

## Error & Notification Views

**ContextualError enum (ContextualErrorBanner.swift):**
| Case | Keywords | Icon | Color |
|------|----------|------|-------|
| `.microphoneError` | microphone, mic | mic.slash.fill | amber |
| `.transcriptionFailed` | speech, transcri | waveform.badge.exclamationmark | amber |
| `.networkError` | network, connection | wifi.exclamationmark | amber |
| `.storageFull` | disk, storage, full | externaldrive.badge.xmark | red |
| `.permissionDenied` | permission, denied | lock.shield.fill | red |
| `.unknown` | (default) | exclamationmark.triangle.fill | amber |

**PillErrorView:** Frame: recordingWidth+40, recordingHeight+8. Shake: offsets [5,-5,4,-4,3,-3,2,-2,1,-1,0], 0.05s per step (5 cycles). Auto-dismiss: 4 seconds.

**ToastNotificationView:** Auto-dismiss per PillAnimationTiming.toastDuration. Hover pauses countdown. Entry: spring(0.3, 0.8), offset(y: 50→0). Icon circle: 28x28.

## Attention & Celebration Views

**AttentionPromptType enum (AttentionPromptView.swift):**
- `.startRecording(appName)` — icon: mic.fill, title: "\(appName) Active"
- `.stillRecording(duration, silenceMinutes)` — icon: waveform.badge.exclamationmark
- Auto-dismiss: 10 seconds. Glass background (hudWindow). Icon bg: 36x36 coral gradient circle.

**CelebrationStyle enum (CelebrationViews.swift):**
- `.ring(color)` — expanding ring stroke (3pt, 0.8→1.5 scale, opacity 0.8→0.0, easeOut 0.6s)
- `.checkmark` — 48x48 circle + checkmark, spring(0.4, 0.5) bounce

## Overlay Views (PillOverlayViews.swift)
- RecordingDotView: 10x10 red circle, pulsing scale 0.9-1.1 at 0.6s
- SystemAudioWarningIndicator: status enum (reconnecting=blue, silent=amber, failed=amber, active)
- FailedBadgeOverlay: red circle with count number, offset (28, -14)

## Legacy Views
PillIdleView, PillRecordingView, PillProcessingView — **mostly unused**, replaced by Aurora views. Kept for fallback / accessibility. New features should use Aurora views.

## Relationships
- Dimensions defined in PillDimensions (Design/Dimensions.swift)
- State transitions managed by PillStateManager.swift (parent folder)
- Root view is FloatingPanelView.swift (parent folder)
- Combine subscriptions in FloatingPanelController.swift (parent folder)
- Speaker naming data flows from TranscriptionPipelineRunner → TaskManager → FloatingPanelController → SpeakerNamingView

## Gotchas
- `hasSettled` in AuroraIdleView starts false after success to allow smooth 200x44→40x20 transition
- SpeakerNamingView is STICKY (no escape dismiss until 3s guard passes)
- MessageGroup in TranscriptDetailView is presentation-only — not in TranscriptStore
- All aurora views respect `accessibilityReduceMotion`
- Copy in TranscriptRowView strips YAML — pastes only dialogue text
- PillViews are legacy: don't add new features to them
