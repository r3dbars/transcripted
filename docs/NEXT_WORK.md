# Transcripted — What's Next

_Refreshed 2026-07-02 after verifying the tree (original list was written before most of it shipped). The theme still holds: turn the local meeting library into a thing an agent can actually answer questions over. That's the moat cloud notetakers can't copy on private data._

## SHIPPED (verified in source, don't redo)

1. ~~Index the summary fields into the search DB~~ — `meeting_summary_items` + FTS5, populated during reconcile.
2. ~~Make recap/recent_context return the real summary~~ — both prefer structured summary facts over opening small-talk now (PR #1352).
3. ~~Crash-safe dictation saves~~ — `DictationTranscriptWriter`/`Store` write atomically.
4. ~~Cross-meeting tools~~ — `list_action_items`, `list_decisions`, `digest` live in the MCP server.
5. ~~Always-on cheap extraction at save time~~ — `MeetingQuickSummaryWriter` runs on every saved meeting.
6. ~~Local semantic search~~ — `semantic_search` MCP tool via on-device `NLEmbedding`, no bundled model needed (PR #1352). English-optimized v1; revisit with a bundled multilingual model only if real usage demands it.
7. ~~Reversible speaker merges~~ — provenance + un-merge landed (PR #1330).

Also shipped from the same push (PR #1352): action items carry real `done`/`due`
metadata via trailing bullet markers, so `list_action_items status:"open"`
finally means open — closing an item is editing its bullet in the saved
Markdown.

## DO NEXT

1. **Negative exemplars** — when a user corrects a wrong speaker, learn "not this person" instead of just freezing the profile. Turns every correction into training signal. (M)
2. **Multi-exemplar voiceprints** — store several voice samples per person instead of one averaged blob, so clean-mic and Zoom versions of the same voice both match. ERes2Net landed, so this is unblocked. (L)
3. **Action-item completion detection** — the marker grammar exists; the missing half is noticing "I sent that yesterday" in a *later* meeting and suggesting the earlier item be marked done. Cross-meeting linking, probably behind the heavy summarizer. (L)
4. **Index meetings for the Home list** — verify first whether Home still re-reads every transcript file on refresh; if it does, point the list at the table that already exists. (L, unverified premise)

## NEEDS A MAC (blocked on hardware/infra, not code)

- **Onboarding meeting dry-run** — meetings-first onboarding still never records a real meeting; the specced `meeting_dry_run_*` events were never built. Needs someone running the app, not blind SwiftUI.
- **Hardware-smoke CI lane** — the `hardware-smokes` job still just echoes instructions; needs a self-hosted macOS runner so mic → transcribe → paste gets automated coverage.
- **Pre-sleep dictation audio** — wake during dictation deliberately discards the buffer instead of transcribing what was said before sleep. Real-time recovery semantics; change only with hardware testing.
- **Settings/Home god-object split** — `TranscriptedSettingsView.swift` (~4.5k LOC) reimplements Home inline. Velocity tax on every UI change; needs a compiler in the loop.

## THE ONE BET

**Speaker-identity trust (#1 + #2).** The retrieval moat is now built end-to-end — indexed facts, rollups, semantic search, open/done state. What limits it now is attribution quality: an action item assigned to the wrong speaker is worse than no action item. Every correction a user makes should make the system smarter, not just less wrong once.
