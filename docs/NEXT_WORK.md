# Transcripted — What's Next

The ~30 things in flight are converging (UI polish, speaker accuracy, data-loss, telemetry). This is what to do *after* that lands. The theme: turn the local meeting library into a thing an agent can actually answer questions over. That's the moat cloud notetakers can't copy on private data.

## DO NEXT
Ranked by impact-for-effort. Do them in order.

1. **Index the summary fields (Decisions / Action Items / Open Questions) into the search DB.** The summarizer already writes these to each meeting; the search index never reads them. This one hop is the whole "ask my history" unlock. (M)
2. **Make recap/recent_context return the real summary, not the first 15 lines of small-talk.** Today the agent's orientation tools return greetings and audio checks. The summary is already in the same file — just point at it. Cheapest high-value fix here. (S)
3. **Make dictation saves crash-safe.** The most-used capture surface is the one place a crash mid-write can silently corrupt a whole day's entries. Everything else already writes atomically; copy that pattern. (M)
4. **Add the cross-meeting tools: list_action_items, list_decisions, digest.** Once the fields are indexed (#1), this is the demo: "every open action item assigned to me, across every call." No cloud tool can do this on private data. (M)
5. **Always-on cheap extraction at save time.** Right now summaries only exist if you opt into the heavy beta. Extract on every save so the moat covers 100% of meetings, not a subset. (M)

## AFTER THAT
6. **Local semantic search** — bundle a small embedding model so paraphrase queries hit ("pricing pushback" finds "they balked at the cost"). The one thing cloud RAG still beats us on. (L)
7. **Multi-exemplar voiceprints** — store several voice samples per person instead of one averaged blob, so clean-mic and Zoom versions of the same voice both match. Land after the ERes2Net upgrade. (L)
8. **Reversible speaker merges** — a wrong auto-merge permanently fuses two real people today, with no undo. Add provenance + un-merge before the more-aggressive merge work goes live. (L)
9. **Negative exemplars** — when a user corrects a wrong speaker, learn "not this person" instead of just freezing the profile. Turns every correction into training signal. (M)
10. **Index meetings for the Home list** — stop re-reading every transcript file on every Home refresh; point the list at the table that already exists. (L)

## THE ONE BET
**Index the summary fields and ship the cross-meeting tools (#1 + #4).** It's wiring, not machine learning, and it's the only thing here that gives the agent a memory cloud notetakers structurally can't match — and that moat gets stronger every meeting added.
