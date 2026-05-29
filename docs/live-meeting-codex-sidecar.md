# Live Meeting Codex Sidecar

This is the product contract for Transcripted's live meeting sidecar in Codex.

## Intent

Transcripted should make Codex feel like a live, local meeting brain.

While a meeting is recording, a knowledge worker should be able to keep a
Codex sidecar open, see the live mic and system transcript, and ask questions
about the conversation they are currently in. When the meeting ends, the normal
Transcripted Markdown remains the canonical artifact. Codex then switches from
the provisional live sidecar to that final Markdown for names, diarization,
quotes, decisions, action items, and durable notes.

This is not a replacement for Transcripted's saved output. It is an interactive
local layer around the meeting while it is happening.

## User Experience

The target flow is:

1. Turn on `Live meeting in Codex` in Transcripted.
2. Open the live Codex room from Transcripted.
3. Start a meeting recording.
4. Watch the sidecar update in Codex with `[Microphone]` and `[System]` lines.
5. Ask Codex questions like:
   - what did I miss
   - what is the current decision
   - what is the tension in this conversation
   - what should I ask next
   - summarize the last five minutes
6. Stop the recording.
7. Transcripted saves its normal final Markdown.
8. Codex reads the final Markdown and produces the post-meeting brief or runs
   the configured Transcripted artifact skill.

The sidecar should feel calm, compact, and automatic. The user should not need
to copy prompts, reload pages, or explain where the transcript lives.

## Local Contract

- Live data stays local.
- The live sidecar reads app-owned files under
  `~/Library/Application Support/Transcripted/CodexLiveMeeting/`.
- The browser preview is served from `http://127.0.0.1:47834/live-preview`.
- The live transcript is provisional.
- The final Transcripted Markdown is canonical.
- The sidecar must not mutate or replace normal meeting output.
- Codex should say when the live stream is sparse, duplicated, stale, or still
  recording instead of guessing.

## Files

Transcripted owns this workspace:

```text
~/Library/Application Support/Transcripted/CodexLiveMeeting/
```

Important files:

- `state.json` - current status, live transcript path, final transcript path
- `live_transcript.md` - provisional live mic and system transcript
- `codex-handoff.md` - automatic marker for the final saved transcript
- `codex-live-meeting.md` - setup prompt for a Codex thread
- `preview.html` - local fallback preview

Status contract:

- `recording` means answer from `live_transcript.md`.
- `transcript_saved` or `Status: ready` means read `finalTranscriptPath`.
- `stopped` means wait for final Markdown.
- `cancelled` or `failed` means explain that no final handoff is ready.

## Agent Behavior

During recording, Codex should:

- read `state.json` first
- answer from `live_transcript.md`
- preserve source labels when useful
- treat `[partial]` lines as hypotheses
- keep answers short unless asked for depth
- flag duplicate mic/system capture when it affects interpretation

After save, Codex should:

- read the final Markdown from `finalTranscriptPath`
- prefer final diarization and participant names
- produce a concise brief when appropriate
- hand the artifact to the Transcripted processing skill when that workflow is
  available

## Quality Bar

This becomes a first-rate feature when:

- the live panel opens from Transcripted in one action
- the panel updates without strobing or manual refresh
- Codex can answer live questions without losing the final transcript contract
- post-meeting handoff is automatic and not noisy
- stale handled transcripts do not keep waking the user
- duplicate mic/system capture is visible enough to diagnose
- the whole loop works without cloud transcription or remote transcript storage

## Next Product Moves

1. Add an in-app "Open Codex Sidecar" action that launches the local preview and
   a prepared Codex room.
2. Store the last handled final transcript path so watchers do not repeatedly
   wake on old meetings.
3. Add a proper post-meeting handoff action that routes the final Markdown into
   the Transcripted summarize/artifact skill.
4. Improve live duplicate handling when mic and system audio contain the same
   speech.
5. Add a compact live Q&A surface in the sidecar once Codex exposes a stable
   local chat bridge.
