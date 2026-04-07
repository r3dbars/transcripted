# Transcripted

Transcripted is private voice context for your Mac.

Dictate into any app, record meetings locally, and keep searchable spoken
context that can feed your personal AI agent.

## What it does

### Dictation

Click into any text field, start dictation, speak, and Transcripted pastes the
text back into the app you were already using.

Useful for:

- messages
- notes
- docs
- quick thoughts

### Meetings

Start a meeting recording, let Transcripted capture your mic and system audio,
and when you stop it, Transcripted saves a local transcript.

Useful when you want to keep track of:

- what people said
- what got decided
- what questions came up
- what needs to happen next

Meeting transcripts are currently saved here:

`~/Library/Application Support/Draft/meetings/transcripts`

That Draft-named storage path stays in place for now so the rebrand does not
break existing local data.

### Agent-ready voice context

A lot of your best context lives in your voice, not just in typed chat boxes.

Transcripted keeps that context local on your Mac so your personal AI agent can
work from what actually happened in your messages, calls, and meetings.

## Important transition note

The old standalone Transcripted app is preserved on:

- branch: `legacy/transcripted-standalone`
- tag: `pre-draft-takeover-2026-04-06`

This repo cutover uses the manual migration path:

- existing Transcripted installs do not auto-upgrade into the new app
- Transcripted should currently be treated as a new install
- permissions and settings do not carry over automatically

## Privacy

Transcripted is local-first.

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

## In short

Transcripted is a Mac app for dictation, meetings, and private voice context.
