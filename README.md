# Transcripted

Transcripted helps your Mac remember what was said.

It records meetings, handles dictation, and saves clean local transcripts your
agent can read. Everything important stays on your Mac.

## Why this exists

Most agents only know what you type.

But a lot of your real context shows up in speech instead:

- meetings
- quick voice notes
- decisions made out loud
- promises you made on a call

Transcripted keeps that spoken context from disappearing.

## What it does today

### Record meetings locally

Start a meeting recording, let Transcripted capture your mic and system audio,
and when you stop it, it saves a local transcript.

Useful when you want a simple record of:

- what happened
- who said what
- what got decided
- what needs a follow-up

Meeting transcripts are currently saved here:

`~/Library/Application Support/Draft/meetings/transcripts`

That Draft-named path stays in place for now so local data does not break
during the transition.

### Dictate into any app

Click into any text field, start dictation, speak, and Transcripted pastes the
text back into the app you were already using.

Useful for:

- messages
- notes
- docs
- quick thoughts

## Where the agent part fits

Transcripted is not trying to be another meeting bot, note-taking app, or chat
app.

The job is simpler:

- capture spoken context locally
- save it in clean files
- make it easy for your agent or your own tools to work from what actually
  happened

If your agent can read a folder, it can work from Transcripted's output.

## Privacy

Transcripted is local-first.

- dictation stays on your Mac
- meeting audio stays on your Mac
- transcripts stay on your Mac

Beta builds can optionally talk to the update/log proxy, but core dictation and
transcription do not depend on cloud APIs.

## What this repo is

`main` currently carries the Draft app codebase, which is becoming the new
Transcripted direction.

The old standalone Transcripted app is preserved on:

- branch: `legacy/transcripted-standalone`
- tag: `pre-draft-takeover-2026-04-06`

This transition is manual for now:

- existing Transcripted installs do not auto-upgrade into the new app
- Transcripted should currently be treated as a new install
- permissions and settings do not carry over automatically

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

Transcripted captures spoken context on your Mac so your agent does not have to
start blind.
