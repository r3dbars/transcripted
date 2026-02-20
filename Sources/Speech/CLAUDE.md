# Speech Engine

## What This Does

Continuous speech recognition using Apple's `SFSpeechRecognizer`. Captures everything the user says without dropping words, even across long recording sessions.

## Key File

- `SpeechEngine.swift` — `@MainActor ObservableObject` with `finalTranscript` (confirmed text) and `volatileText` (current unfinalized speech)

## Critical Gotchas (Hard-Won Knowledge)

### 1. `isFinal` Does NOT Fire Between Sentences

Apple's `SFSpeechRecognitionTask` only fires `isFinal` when:
- The ~60-second task times out (error code 203 or 216)
- `endAudio()` is called
- The task completes/dies

**It does NOT fire when the user pauses between sentences.** This means you cannot rely on `isFinal` for sentence boundaries. We use a silence timer instead.

### 2. Apple Speech Has Undocumented Buffer Resets

Mid-session, Apple Speech silently resets `bestTranscription.formattedString` from hundreds of characters back to single digits — WITHOUT firing `isFinal`. If you're tracking a committed prefix offset, this will cause your prefix to exceed the new buffer length, resulting in empty volatile text = lost words.

**Detection:** `if fullText.count < committedPrefixLength` → reset prefix to 0.

This behavior was discovered through debug logging and is not documented anywhere by Apple.

### 3. Error Codes 203 and 216 Are Normal

These fire at ~60 seconds and mean "recognition task timed out." The correct response is to commit any remaining volatile text and restart the recognition task. The audio engine and its tap stay running — only the request/task need to be recreated.

### 4. Multi-Channel Audio Interfaces Break SFSpeechRecognizer

Pro audio interfaces like BEACN Mic (96kHz/4 channels) cause SFSpeechRecognizer error 1110 ("no speech detected"). The recognizer expects mono audio and can't parse multi-channel input.

**Fix:** Force the audio tap to mono at the hardware's native sample rate:

```swift
let nativeFormat = inputNode.outputFormat(forBus: 0)
let monoFormat = AVAudioFormat(standardFormatWithSampleRate: nativeFormat.sampleRate, channels: 1)!
inputNode.installTap(onBus: 0, bufferSize: 1024, format: monoFormat) { ... }
```

AVAudioEngine handles the channel mixdown automatically. **Do NOT force 16kHz** — mismatching the sample rate causes the tap to crash with an ObjC exception.

## Logging

`log()` writes to both stdout AND `~/draft-debug.log` with ISO8601 timestamps and a `SPEECH` prefix. Permission diagnostics (speech auth status, mic auth status, recognizer availability) and audio format details (native sample rate, channel count, tap format) are logged on every `startListening()` call.

Monitor in real time: `tail -f ~/draft-debug.log | grep SPEECH`

## How It Works

1. **Silence-based commitment** — Timer watches `volatileText`. When unchanged for 1.5 seconds, commits to `finalTranscript` and advances `committedPrefixLength` to `lastSeenFullTextLength`.
2. **"Done speaking" detection** — A separate timer (`doneThreshold: 2.5s`) sets `speechFinished = true` after extended silence. ContentView uses this to know the user has finished talking (distinct from mid-sentence pauses).
3. **Prefix-based extraction** — Each partial result: extract `fullText[committedPrefixLength...]` as the new volatile portion.
4. **Auto-restart on task death** — When `isFinal` or error 203/216, commit remaining text and create a fresh recognition task.
5. **Buffer reset detection** — If `fullText.count < committedPrefixLength`, Apple reset its buffer; snap prefix back to 0.

## Public Interface

```swift
@Published var finalTranscript: String   // Confirmed text (append-only)
@Published var volatileText: String      // Current unfinalized speech
@Published var isListening: Bool
@Published var statusMessage: String
@Published var speechFinished: Bool      // True after 2.5s extended silence — signals "done talking"
@Published var audioLevel: Float         // 0.0 to 1.0, RMS audio level — drives AudioWaveformView animation

var displayText: String                  // finalTranscript + volatileText
var hasText: Bool

func requestPermissions() async -> Bool
func startListening()
func stopListening()
func clear()
```

## Verification

After modifying SpeechEngine, verify with these checks:

- **Basic recording:** Speak a sentence, pause 2s, speak another → both should appear (first in white, second transitions from blue → white)
- **Task chaining:** Record for 60+ seconds → should seamlessly chain recognition tasks (watch for `🔄 RESTART TASK` in console)
- **Stop mid-sentence:** Stop while speaking → volatile text commits to final
- **Done detection:** Speak, then wait 2.5s → `speechFinished` should become true (check `🏁 DONE TIMER` in console)
- **Buffer reset:** Long recordings may trigger `🔀 BUFFER RESET` in console — text should NOT be lost
- **Multi-channel mic:** Plug in a multi-channel audio interface → record → should work normally (check `🎤 AUDIO FORMAT native` in debug log for channel count, `🎤 AUDIO FORMAT tap` should show `channels=1`)
- **Debug log:** `tail -f ~/draft-debug.log | grep SPEECH` shows all speech events in real time (includes permission diagnostics, audio format, and all recognition callbacks)
