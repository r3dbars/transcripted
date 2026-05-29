---
name: transcripted-live-meeting
description: Watch and answer questions about a Transcripted meeting while it is being recorded from the local live sidecar workspace, then switch to the final saved meeting Markdown when it appears.
---

# Transcripted Live Meeting

Version: 0.2.0

## Purpose

Use Transcripted's live Codex sidecar during an active meeting. The goal is to
act like a local meeting brain: answer questions about the conversation while it
is happening, then switch to the final Transcripted Markdown when it is saved.

The live text is provisional. The final Transcripted meeting Markdown is the
source of truth once it exists.

## Expected Files

In the live workspace:

- `state.json`
- `live_transcript.md`
- `codex-handoff.md`
- `codex-live-meeting.md`
- `preview.html`

## Workflow

1. Read `state.json` first.
2. If `status` is `recording`, read `live_transcript.md` and answer from the live sidecar.
3. Keep source labels visible in your reasoning: `[Microphone]` and `[System]`. Lines marked `[partial]` are live hypotheses and may change.
4. If mic and system audio appear duplicated, say that plainly when it matters.
5. If `codex-handoff.md` says `Status: ready` or `finalTranscriptPath` exists, read that Markdown file and prefer it for participant names, diarization, quotes, decisions, and durable notes.
6. If the live stream is empty, stale, or too sparse, say that plainly instead of guessing.
7. Keep live answers short unless the user asks for depth.
8. After the final Markdown is ready, produce a concise post-meeting brief when appropriate: summary, decisions, action items, and next steps.

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
- Keep the workflow local. Do not ask the user to paste the transcript elsewhere.
- Do not keep notifying about a final transcript that was already handled.
- When citing, include the file and any timestamp/source label available.

## Preview

If the user asks for a live transcript window inside Codex, open
`http://127.0.0.1:47834/live-preview` while Transcripted is running. If
Transcripted is closed, open `preview.html` from the workspace instead.

## Product Intent

This skill exists so Transcripted can give knowledge workers a first-rate live
sidecar in Codex: visible transcript, local Q&A while the meeting is happening,
and automatic handoff into the final saved Markdown after the meeting ends.
