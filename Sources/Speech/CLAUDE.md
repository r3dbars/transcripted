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

## How It Works

1. **Silence-based commitment** — Timer watches `volatileText`. When unchanged for 1.5 seconds, commits to `finalTranscript` and advances `committedPrefixLength` to `lastSeenFullTextLength`.
2. **Prefix-based extraction** — Each partial result: extract `fullText[committedPrefixLength...]` as the new volatile portion.
3. **Auto-restart on task death** — When `isFinal` or error 203/216, commit remaining text and create a fresh recognition task.
4. **Buffer reset detection** — If `fullText.count < committedPrefixLength`, Apple reset its buffer; snap prefix back to 0.

## Public Interface

```swift
@Published var finalTranscript: String   // Confirmed text (append-only)
@Published var volatileText: String      // Current unfinalized speech
@Published var isListening: Bool
@Published var statusMessage: String

var displayText: String                  // finalTranscript + volatileText
var hasText: Bool

func requestPermissions() async -> Bool
func startListening()
func stopListening()
func clear()
```

## Testing

- Speak a sentence, pause 2s, speak another → both should appear (first in white, second transitions from blue → white)
- Record for 60+ seconds → should seamlessly chain recognition tasks
- Stop mid-sentence → volatile text commits to final
