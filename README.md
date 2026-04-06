# Draft

Draft is a Mac app for two things:

- dictation
- meeting transcription

You can use it to talk instead of type, and to save a record of what happened in your meetings.

It runs locally on your Mac and keeps the experience simple.

## What it does

### Dictation

Click into any text field, start dictation, speak, and Draft pastes the text back into the app you were using.

This is for things like:

- messages
- notes
- docs
- quick thoughts

### Meetings

Start a meeting recording, let Draft capture your mic and system audio, and when you stop it, Draft saves a transcript.

This is useful when you want to keep track of:

- what people said
- what got decided
- what questions came up
- what needs to happen next

## Why someone would use this

A lot of your best context lives in your voice.

Sometimes that is you thinking out loud.
Sometimes it is a call, a meeting, or a conversation.

Draft helps you keep that context instead of losing it.

## How to use it

### Dictation

1. Click into a text field.
2. Tap the right `Option` key, or use your dictation shortcut.
3. Speak.
4. Stop dictation.
5. Draft transcribes your words and pastes them back into the app.

### Meetings

1. Press `Option + M`.
2. Draft starts recording your mic and system audio.
3. Press `Option + M` again when the meeting is over.
4. Draft processes the recording.
5. The transcript is saved locally on your Mac.

Meeting transcripts are saved here:

`~/Library/Application Support/Draft/meetings/transcripts`

## Privacy

Draft is built to be local-first.

- your dictation stays on your Mac
- your meeting recordings stay on your Mac
- your transcripts are saved locally

## Why this matters for agents

If you want a really useful personal agent, it needs real context.

Not just what you type into a chat box once in a while.

It helps if the agent can understand:

- what you have been talking about
- what happened in your meetings
- what problems you are working through
- what you told yourself to remember

That is the bigger idea behind Draft.

## Build

```bash
bash build-deps.sh
bash build.sh
```

## Tests

```bash
bash run-tests.sh
```

## In short

Draft is a simple Mac app for capturing spoken context.

You can use it to dictate into any app and to save transcripts of your meetings.
