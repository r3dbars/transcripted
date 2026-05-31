# Live Meeting Agent Sidecar

This is the product contract for Transcripted's live meeting sidecar in Codex
and Claude Cowork.

## Intent

Transcripted should make Codex or Claude Cowork feel like a live, local meeting brain.

While a meeting is recording, a knowledge worker should be able to keep a
sidecar open, see the live mic and system transcript, and ask questions about
the conversation they are currently in. When the meeting ends, the normal
Transcripted Markdown remains the canonical artifact. The agent then switches
from the provisional live sidecar to that final Markdown for names, diarization,
quotes, decisions, action items, and durable notes.

This is not a replacement for Transcripted's saved output. It is an interactive
local layer around the meeting while it is happening.

## User Experience

The target flow is:

1. Turn on `Live meeting sidecar` in Transcripted.
2. Open the live sidecar in Codex, or copy the Claude Cowork setup prompt.
3. Start a meeting recording.
4. Watch the sidecar update with `[Microphone]` and `[System]` lines.
5. Ask the agent questions like:
   - what did I miss
   - what is the current decision
   - what is the tension in this conversation
   - what should I ask next
   - summarize the last five minutes
6. Stop the recording.
7. Transcripted saves its normal final Markdown.
8. The agent reads the final Markdown and produces the post-meeting brief or runs
   the configured Transcripted artifact skill.

The sidecar should feel calm, compact, and automatic. The user should not need
to copy prompts, reload pages, or explain where the transcript lives.

## Local Contract

- Live data stays local.
- The live sidecar reads app-owned files under
  `~/Library/Application Support/Transcripted/AgentLiveMeeting/`.
- The browser preview is served from `http://127.0.0.1:47834/live-preview`.
- The live transcript is provisional.
- The final Transcripted Markdown is canonical.
- The sidecar must not mutate or replace normal meeting output.
- The agent should say when the live stream is sparse, duplicated, stale, or still
  recording instead of guessing.

## Files

Transcripted owns this workspace:

```text
~/Library/Application Support/Transcripted/AgentLiveMeeting/
```

Important files:

- `state.json` - current status, live transcript path, final transcript path
- `live_transcript.md` - provisional live mic and system transcript
- `agent-handoff.md` - automatic marker for the final saved transcript
- `agent-watcher-state.json` - agent-owned marker for the last final transcript already handled
- `agent-live-meeting.md` - setup prompt for Codex or Claude Cowork
- `preview.html` - local fallback preview

Status contract:

- `recording` means answer from `live_transcript.md`.
- `transcript_saved` or `Status: ready` means read `finalTranscriptPath`.
- `stopped` means wait for final Markdown.
- `cancelled` or `failed` means explain that no final handoff is ready.

## Agent Behavior

During recording, the agent should:

- read `state.json` first
- answer from `live_transcript.md`
- preserve source labels when useful
- treat `[partial]` lines as hypotheses
- keep answers short unless asked for depth
- flag duplicate mic/system capture when it affects interpretation

After save, the agent should:

- read the final Markdown from `finalTranscriptPath`
- read `agent-watcher-state.json` before waking the user
- stay quiet if `lastHandledFinalTranscriptPath` already matches the ready final transcript
- prefer final diarization and participant names
- produce a concise brief when appropriate
- update `agent-watcher-state.json` after handling the final transcript
- hand the artifact to the Transcripted processing skill when that workflow is
  available

## Quality Bar

This becomes a first-rate feature when:

- the live panel opens from Transcripted in one action
- the panel updates without strobing or manual refresh
- Codex and Cowork can answer live questions without losing the final transcript contract
- post-meeting handoff is automatic and not noisy
- stale handled transcripts do not keep waking the user
- duplicate mic/system capture is visible enough to diagnose
- the whole loop works without cloud transcription or remote transcript storage

## Next Product Moves

1. Keep the in-app enablement flow obvious: one toggle, then Codex, Cowork, and
   preview actions.
2. Store the last handled final transcript path so watchers do not repeatedly
   wake on old meetings.
3. Add a proper post-meeting handoff action that routes the final Markdown into
   the Transcripted summarize/artifact skill.
4. Improve live duplicate handling when mic and system audio contain the same
   speech.
5. Add a compact live Q&A surface in the sidecar once agent chat bridges expose
   a stable local path.
