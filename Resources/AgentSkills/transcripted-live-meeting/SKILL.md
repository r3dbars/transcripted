---
name: transcripted-live-meeting
description: Watch and answer questions about a Transcripted meeting while it is being recorded from the local live sidecar workspace, then switch to the final saved meeting Markdown when it appears.
---

# Transcripted Live Meeting

Version: 0.2.1

## Purpose

Use Transcripted's live sidecar during an active meeting in Codex or Claude Cowork. The goal is to
act like a local meeting brain: answer questions about the conversation while it
is happening, then switch to the final Transcripted Markdown when it is saved.

The live text is provisional. The final Transcripted meeting Markdown is the
source of truth once it exists.

## Expected Files

In the live workspace:

- `state.json`
- `live_transcript.md`
- `agent-handoff.md`
- `agent-watcher-state.json`
- `agent-live-meeting.md`
- `preview.html`

## Workflow

1. Read `state.json` first.
2. If `status` is `recording`, read `live_transcript.md` and answer from the live sidecar.
3. Keep source labels visible in your reasoning: `[Microphone]` and `[System]`. Lines marked `[partial]` are live hypotheses and may change.
4. If mic and system audio appear duplicated, say that plainly when it matters.
5. If `agent-handoff.md` says `Status: ready` or `finalTranscriptPath` exists, read that Markdown file and prefer it for participant names, diarization, quotes, decisions, and durable notes.
6. Before waking the user or posting a post-meeting brief for a ready final transcript, read `agent-watcher-state.json`. Stay quiet if `lastHandledFinalTranscriptPath` already matches the ready transcript.
7. After handling a ready final transcript, update `agent-watcher-state.json` with `lastHandledFinalTranscriptPath` and `lastHandledAt`.
8. If the live stream is empty, stale, or too sparse, say that plainly instead of guessing.
9. Keep live answers short unless the user asks for depth.
10. After the final Markdown is ready, produce a concise post-meeting brief when appropriate: summary, decisions, action items, and next steps.

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
- Do not assume Cowork can see local files. If folder access is missing, ask the user to grant the sidecar folder or paste the current live transcript.
- When citing, include the file and any timestamp/source label available.

## Preview

If the user asks for a live transcript window inside Codex, open the tokenized
browser preview URL from `agent-live-meeting.md` while Transcripted is running.
In Cowork, use the granted workspace folder or `preview.html` if local folder
access is available. If Transcripted is closed, open `preview.html` from the
workspace instead.

## Product Intent

This skill exists so Transcripted can give knowledge workers a first-rate live
sidecar in Codex or Claude Cowork: visible transcript, local Q&A while the meeting
is happening, and automatic handoff into the final saved Markdown after the meeting ends.
