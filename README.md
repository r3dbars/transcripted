# Draft

This public repository keeps the **`transcripted`** name for now, but the product
on `main` is **Draft**.

Draft is a Mac app for two things:

- dictation
- meeting transcription

It keeps both workflows local on your Mac.

## Important transition note

The old standalone Transcripted app is preserved on:

- branch: `legacy/transcripted-standalone`
- tag: `pre-draft-takeover-2026-04-06`

This repo cutover uses the **manual migration** path:

- existing Transcripted installs do **not** auto-upgrade into Draft
- Draft should be treated as a **new install**
- permissions and settings do not carry over automatically

## What Draft does

### Dictation

Click into any text field, start dictation, speak, and Draft pastes the text back
into the app you were using.

Useful for:

- messages
- notes
- docs
- quick thoughts

### Meetings

Start a meeting recording, let Draft capture your mic and system audio, and when
you stop it, Draft saves a transcript.

Useful when you want to keep track of:

- what people said
- what got decided
- what questions came up
- what needs to happen next

Meeting transcripts are saved here:

`~/Library/Application Support/Draft/meetings/transcripts`

## Privacy

Draft is local-first.

- your dictation stays on your Mac
- your meeting recordings stay on your Mac
- your transcripts are saved locally

## Build

```bash
bash build-deps.sh
bash build.sh
```

## Tests

```bash
bash run-tests.sh
```

If you touch meeting integration or `TranscriptedCore`, also run:

```bash
bash run-integration-smoke.sh
```

## In Short

Draft is a simple Mac app for capturing spoken context.

You can use it to dictate into any app and to save transcripts of your meetings.
