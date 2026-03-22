# FloatingPanel Components

16 SwiftUI views for the morphing pill UI — aurora state views, saved notification card, transcript browsing, speaker naming, and error display. All @MainActor.

## File Index

| File | Purpose |
|------|---------|
| `AuroraIdleView.swift` | Collapsed pill (52x26). Hover-expands to 160x36 with Record + Transcripts buttons. |
| `AuroraRecordingView.swift` | Recording state (160x36). LED dots: coral mic (left) + teal system (right). Timer + stop. |
| `AuroraProcessingView.swift` | Processing state (160x36). Progress bar + status text. Warning at 90s+. |
| `SavedPillView.swift` | Saved notification card (260x56). Title, duration, speakers, Copy/Open buttons. Green accent. |
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
| `AttentionPromptView.swift` | Silence warning + still-recording detection prompt. |

## Pill Views — Dimensions & Behavior

| State | Width | Height | Audio-reactive | Notes |
|-------|-------|--------|----------------|-------|
| Idle (collapsed) | 52 | 26 | No | Hover-expands to 160x36. mic.fill icon |
| Idle (expanded) | 160 | 36 | No | Record + Transcripts buttons. Spring(0.15, 0.8) |
| Recording | 160 | 36 | Yes (mic + system) | LED dots: coral (left) + teal (right) |
| Processing | 160 | 36 | No | Progress bar (determinate/indeterminate shimmer) |
| Saved | 260 | 56 | No | Title, duration, speakers, Copy/Open. Green accent glow |

**AuroraRecordingView — LED dots:**
- Audio level smoothing: attack 0.55 (snappy rise), decay 0.15 (quick fade)
- Core: 3-4.5px, opacity 40-100%, 0.5px blur
- Halo: 8-22px diameter, opacity 8-33%, radial gradient with 3 color stops
- Layout: stop (26px), mic LED, timer (14pt monospaced), system LED, transcripts (26px)

**AuroraProcessingView — progress bar:**
- 3px bar at bottom of capsule, fills with accentBlue
- Indeterminate shimmer: LinearGradient, 1.5s linear repeat, offset -1.0→1.0
- Warning text: 90s → "Taking a moment...", 120s → "Taking longer than usual"

**SavedPillView — notification card:**
- Checkmark entrance: scale 0.3→1.0 spring(0.4, 0.6), bounce 1.1, settle 1.0
- Content fade-in: 150ms delay, easeOut 0.2s
- Copy button: 1.5s checkmark feedback before reverting
- Background: panelCharcoal + green radial glow (0.15 opacity), green border (0.45 opacity)
- Auto-dismiss: 10s (controlled by FloatingPanelController)

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

## Attention Prompt View

**AttentionPromptType enum (AttentionPromptView.swift):**
- `.startRecording(appName)` — icon: mic.fill, title: "\(appName) Active"
- `.stillRecording(duration, silenceMinutes)` — icon: waveform.badge.exclamationmark
- Auto-dismiss: 10 seconds. Glass background (hudWindow). Icon bg: 36x36 coral gradient circle.

## Overlay Views (PillOverlayViews.swift)
- RecordingDotView: 10x10 red circle, pulsing scale 0.9-1.1 at 0.6s
- SystemAudioWarningIndicator: status enum (reconnecting=blue, silent=amber, failed=amber, active)
- FailedBadgeOverlay: red circle with count number, offset (28, -14)

## Relationships
- Dimensions defined in PillDimensions (Design/Dimensions.swift)
- State transitions managed by PillStateManager.swift (parent folder)
- Root view is FloatingPanelView.swift (parent folder)
- Combine subscriptions in FloatingPanelController.swift (parent folder)
- Speaker naming data flows from TranscriptionPipelineRunner → TaskManager → FloatingPanelController → SpeakerNamingView

## Gotchas
- SpeakerNamingView is STICKY (no escape dismiss until 3s guard passes)
- MessageGroup in TranscriptDetailView is presentation-only — not in TranscriptStore
- All aurora views respect `accessibilityReduceMotion`
- Copy in TranscriptRowView strips YAML — pastes only dialogue text
- SavedPillView uses Task.sleep for animations (auto-cancels on view dismissal)
