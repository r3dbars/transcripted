---
name: transcripted-live-meeting
description: Watch and answer questions about a Transcripted meeting while it is being recorded from the local live sidecar workspace, then switch to the final saved meeting Markdown when it appears.
---

# Transcripted Live Meeting

Version: 0.1.0

## Purpose

Use Transcripted's live Codex sidecar during an active meeting. The live text is provisional. The final Transcripted meeting Markdown is still the source of truth once it is saved.

## Expected Files

In the live workspace:

- `state.json`
- `live_transcript.md`
- `codex-live-meeting.md`
- `preview.html`

## Workflow

1. Read `state.json` first.
2. If `status` is `recording`, read `live_transcript.md` and answer from the live sidecar.
3. Keep source labels visible in your reasoning: `[Microphone]` and `[System]`. Lines marked `[partial]` are live hypotheses and may change.
4. If `finalTranscriptPath` exists, read that Markdown file and prefer it for participant names, diarization, quotes, decisions, and durable notes.
5. If the live stream is empty or too sparse, say that plainly instead of guessing.
6. Keep live answers short unless the user asks for depth.

## Live Answer Shape

Use the smallest useful answer:

```md
## Right Now

## What I Heard

## Open Questions

## Possible Follow-Up
```

Only include sections that help.

## Rules

- Do not alter Transcripted meeting output files unless the user asks.
- Do not treat provisional live text as final diarization.
- Do not invent names, owners, deadlines, quotes, or decisions.
- Prefer the final Markdown once `finalTranscriptPath` is present.
- When citing, include the file and any timestamp/source label available.

## Preview

If the user asks for a live transcript window inside Codex, open
`http://127.0.0.1:47834/live-preview` while Transcripted is running. If
Transcripted is closed, open `preview.html` from the workspace instead.
