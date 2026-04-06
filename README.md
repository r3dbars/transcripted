# Draft

**Local dictation and meeting transcription for personal context capture.**

Draft is a macOS app with two focused workflows:

- `Dictation`: speak anywhere and paste the transcription back into the active app
- `Meetings`: record microphone plus system audio, then save a structured transcript after the meeting ends

Draft is local-first, minimal in the UI, and optimized for reliable capture rather than live AI rewriting.

## Product direction

Draft is no longer a ghostwriting, style-matching, or AI drafting product.

The current product is built around:

- fast dictation
- dependable meeting capture
- clean final transcripts
- creating useful raw context you can use later with your own tools or agents

## Core flows

### Dictation

1. Focus any text field.
2. Tap the right `Option` key, or use your configured dictation shortcut.
3. Speak naturally.
4. Stop dictation.
5. Draft transcribes locally and pastes the result back into the app you were using.

### Meetings

1. Press `Option + M`.
2. Draft records microphone audio plus system audio.
3. Press `Option + M` again when the meeting ends.
4. Draft runs the offline transcription + diarization pipeline.
5. The transcript is saved under `~/Library/Application Support/Draft/meetings/transcripts`.

## Permissions

Draft needs three permissions:

- `Microphone`: for dictation and your side of meetings
- `Accessibility`: for global shortcuts and paste-back
- `Screen Recording`: so meeting capture can access system audio from calls and media apps

## Why it exists

If personal agents are going to matter, they need better context than a chat box.

Draft is meant to capture two of the highest-signal sources of that context:

- what you intentionally say through dictation
- what actually happened in your meetings

That gives you a durable record of what people are asking, deciding, pushing on, and trying to solve.

## Build

```bash
bash build-deps.sh
bash build.sh
```

## Tests

```bash
bash run-tests.sh
```

## Notes

- Speech recognition is powered by local Parakeet models.
- Meeting transcripts are generated after recording, not from a live streaming transcript UI.
- If you still see old references to drafting, style learning, or agent-writing behavior elsewhere in the repo, those are legacy cleanup remnants rather than active product features.
