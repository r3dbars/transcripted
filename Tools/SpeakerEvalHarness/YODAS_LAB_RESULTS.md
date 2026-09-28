# Speaker Lab on YODAS3: results so far

**Date:** 2026-09-28. **Plan:** `YODAS_LAB_PLAN.md`. **Status:** P0–P2 done; two changes built into the app behind beta toggles (Finding 6).

Every number here comes from simulated meetings run through the real app pipeline headless
(`speaker-eval-harness meeting-series`: real DiarizationService, real Parakeet, real speaker DB,
real naming sheet answered by a simulated user). Audio and reports are under `data/eval/yodas3/`
(gitignored). The caveats at the bottom matter; read them before quoting any number.

## What got built

| Piece | What it is | Where |
|---|---|---|
| Voice bank | 2 English YODAS3 shards (826 videos, 320 h) → **362 verified single-voice identities, 92.6 h usable**. Two independent voice models (NVIDIA TitaNet, 3D-Speaker CAM++) must both agree a window is the main voice. Long voices are densely re-checked (109 checked, median 0.8% off-voice, 3 dropped). | `scripts/speaker_lab/voicebank.py` |
| Meeting simulator | Mic + call channels shaped like a real capture: per-person device (band limit + real Opus at 8–32 kbps), room reverb for local people, backchannels cut from word times, overlaps, echo leak, a noisy calendar invite. Families A–E, plus F: a fake company that meets for weeks. | `scripts/speaker_lab/meeting_sim.py` |
| Lab runner | The real pipeline + naming sheet, headless, throwaway paths, stub stats store. About 80x real time. | `Tools/SpeakerEvalHarness/.../MeetingLab.swift` |
| E2E diarizers | NVIDIA Sortformer and LS-EEND (both already in our FluidAudio build) on the same audio. | `.../E2EDump.swift` |
| Scorers | Rows vs people, fragments, blends, missed people, word-level who-said-what; learning speed and wrong names across a series; offline naming-policy replay. | `scripts/speaker_lab/score.py`, `naming_replay.py` |

Two small Core seams, both unused by the app: `TranscriptionTaskManager.pipelineResultObserver`
(the lab sees the exact Phase 1 result) and `DiarizationService.labSpeakerBounds` (per-meeting
speaker-count bounds, added below the lines `config/hillclimb/knobs.json` pins).

## Finding 1: small calls over-split a little, big calls under-split a lot

Baseline, current app settings (67 meetings):

| Call | People | Rows shown | Exactly right | Any merged row | Missed people | Words under the right person |
|---|---|---|---|---|---|---|
| A 1:1 | 1.0 | 1.3 | 70% | 0% | 0 | 91.7% |
| B 3–4 remote | 3.3 | 3.1 | 60% | 13% | 5 | 81.2% |
| C 6–8 remote | 7.0 | **4.4** | **17%** | **67%** | **36** | **50.7%** |
| D hybrid (call side) | 3.2 | 3.5 | 50% | 20% | 1 | 77.7% |
| D hybrid (mic side) | 1.3 | 1.1 | 70% | 0% | 3 | 87.6% |
| E stress | 5.1 | 2.9 | 0% | 70% | 25 | 51.0% |

- In 1:1s, 5 of the 6 extra rows were **one 2–3 s clip**. One (A-108) was a real 48 s split.
- In big calls, quiet people get swallowed by louder ones. Per-stage dumps show **all of that loss
  happens inside the raw diarizer** (PyAnnote + VBx): on 7-person calls it outputs 4.4 speakers
  and the pipeline's post-processing loses none. This matches the AMI scale-up (69% of meetings
  under-segmented). The shipped settings were grid-searched on 16 two-person Zoom calls.
- The lab never produced more than 2 rows for 1 person. Real use sometimes shows 10–11, so that
  case comes from conditions the simulator doesn't have yet (see "Open questions").

## Finding 2: the speaker count helps, and fully fixes 1:1s

Speaker-count bounds passed to FluidAudio (it re-clusters to fit):

| Call | Baseline words right | Invite − 1 as a minimum | True count ("oracle") |
|---|---|---|---|
| A 1:1 | 91.7% (70% exact) | running | 91.7% (**100% exact, 0 extra rows**) |
| B 3–4 | 81.2% | running | 80.5% (no gain) |
| C 6–8 | 50.7% (4.4 rows) | 59.6% (5.3 rows, 26 missed) | 70.7% (6.0 rows, 17 missed) |
| E stress | 51.0% | running | 73.6% |

A 1:1 invite is almost always right, so capping voices at the invite size removes the 1:1 extra
row. For big calls it helps but doesn't finish the job: forced splits come out small and unstable,
and merged rows remain in more than half of the meetings.

## Finding 3: end-to-end models hear turns better but can't hold identities

Scored raw, each model speaker counted as a row, no cleanup:

| Call | Production | NVIDIA Sortformer | LS-EEND (phone variant) |
|---|---|---|---|
| A 1:1: words right / rows | 91.7% / 1.3 | **96.0%** / 2.2 | **97.7%** / 2.1 |
| B 3–4 | 81.2% / 3.1 | **90.6%** / 3.7 | 87.1% / 3.9 |
| C 6–8 | 50.7% / 4.4 | **69.3%** / 4.0 (4-speaker cap) | 62.5% / 5.7 |
| E stress | 51.0% / 2.9 | **66.7%** / 4.0 | 63.7% / 4.7 |

Both hear *who is talking right now* better, but they fragment people across a call. The
promising build is a **hybrid**: end-to-end turn boundaries, then our WeSpeaker fingerprints and
consolidation decide who is who. Not built yet.

## Finding 4: the calendar can roughly halve naming work, with zero wrong names

Company series (24 meetings, 4 weeks, shared DB). Today's app: "Was this X?" arrives at a
person's 2nd–4th meeting, silent naming at their **6th–11th**, and the manager (8 meetings) was
never named silently. Zero wrong names. Offline replay of naming policies on the same
fingerprints:

| Policy | User work | Silent naming starts at | Wrong silent names |
|---|---|---|---|
| Today: 5 confirmations, 0.92 / margin 0.12 | 91 | 6th meeting | 0 |
| 2 confirmations | 80 | 4th | 0 |
| Calendar lineup (invitees only), 2 confirmations @0.80 | 61 | 3rd | 0 |
| Lineup + one-voice-per-invitee assignment, 1 confirmation @0.75 | 52 | **2nd** | 0 |
| + process of elimination + hide voices under 5 s | **48 (−47%)** | 2nd | 0 |

WeSpeaker session fingerprints separated people cleanly here: same person median 0.876, different
people never above 0.469.

## Finding 5: "split generously, then merge smartly" wins, and holds on fresh calls

Forcing the invite count into FluidAudio's re-clustering merged the wrong voices. What works:
diarize at clustering threshold **0.70** (splits more), then (1) fold any voice with under **5 s**
of talk into the voice it sounds most like, (2) merge voices whose fingerprints are **≥ 0.6**
similar, (3) if a calendar invite exists, fold the quietest voices until the count fits the
invite (+1 spare seat on calls of 3+). Steps 1–2 do most of the work without any calendar; the
cap mostly helps 1:1s.

Holdout: 45 fresh meetings (new seeds, never used for tuning), run end to end through the real
pipeline with the feature on (`meeting-series --separation lab`):

| Call | Exactly right (today → new) | Merged-person meetings | Missed people | Words right |
|---|---|---|---|---|
| 1:1 | 80% → **93%** | 0% → 0% | 0 → 0 | 92.4% → 92.4% |
| 3–4 remote | 83% → 75% | 17% → **8%** | 2 → 3 | 80.5% → 80.3% |
| 6–8 remote | 0% → **60%** | 80% → **20%** | 27 → **3** | 54.8% → **78.2%** |
| Stress | 0% → **75%** | 88% → **25%** | 15 → **2** | 56.4% → **78.9%** |

3–4 person calls are a wash (fewer merges, one more missed person); everything else improves.
The one 1:1 still showing two rows had a no-show on its invite (cap 2) and a 6.2 s stray voice
just above the 5 s floor.

## Finding 6: naming holds on real voice variation

Family X: a company whose 7 regulars are cross-recording identities (the same voice found in 2–8
different YouTube videos), each meeting using a different recording. Same-person fingerprint
median 0.83 (vs 0.88 when every meeting came from one recording); strangers never above 0.49.
Replay: today's rules name only 2 of 6 regulars silently (6th–8th meeting); calendar lineup +
assignment + elimination cuts naming work 103 → 38 (**−63%**), silent naming from the 2nd meeting,
0 wrong in 41. One warning sign: in a sound-alike company two different people scored **0.93**,
above today's 0.92 auto bar; only the margin rule stopped a wrong name. That's the argument for
naming silently only against the invite lineup.

## Finding 7: NVIDIA Nemotron 3 Diarization is the strongest separator tested

Nemotron 3 Diarization (NVIDIA, released 2026-09-23, up to 8 speakers, OpenMDW license) runs on
Apple Silicon through FluidAudio 0.17.4. The app is on 0.15.4, so it runs in an isolated probe
(`scripts/speaker_lab/nemotron-probe/`, own `Package.swift`, never linked into the app) and is
scored with `scripts/speaker_lab/nemotron_cleanup.py` (fold voices under 5 s into the voice that
talks nearest in time; optional invite cap). Same 45 holdout meetings, `fast128` preset:

| Call | Words right: today / PyAnnote new / **Nemotron + fold** | Exactly right: today / PyAnnote new / **Nemotron + fold** |
|---|---|---|
| 1:1 | 92.4 / 92.4 / **96.2%** | 80 / 93 / **100%** (with cap; 87% without) |
| 3–4 remote | 80.5 / 80.3 / **92.4%** | 83 / 75 / **92%** (no cap) |
| 6–8 remote | 54.8 / 78.2 / **91.7%** | 0 / 60 / **80%** |
| Stress | 56.4 / 78.9 / **82.5%** | 0 / **75** / 50–62% |

It gets 12–14 more points of words right on group calls. Two things stand between this and the
app: it produces no voice fingerprints, so cross-meeting naming needs a hybrid (embed each
Nemotron speaker's segments with WeSpeaker and reuse the existing matcher and
`SpeakerSeparation`); and FluidAudio 0.17.x was held in #1789 for speech-to-text regressions
(slow noisy blank takes, short-clip WER). The cap helps 1:1s but hurts 3–4 person calls with
no-shows, so apply it only to one-person invites.

## What changed in the app (behind two beta toggles, off by default)

- **Separate voices on calls (beta)** → `Sources/TranscriptedCore/Speaker/SpeakerSeparation.swift` +
  `DiarizationService.diarizeOffline(samples:sampleRate:clusteringThreshold:)` +
  `TranscriptionTaskManager.speakerSeparationProvider`; the app sets it from
  `SpeakerSeparationPreferences` and the invite size (`MeetingSpeakerSeparation`).
- **Name people from your calendar (beta)** → `SpeakerNamingPolicy.InviteeBars` (2 confirmed
  meetings, similarity 0.80, margin 0.10, only for a voice whose best match is an invitee) +
  `TranscriptionTaskManager.calendarNamingProvider`; the app sets it from
  `CalendarNamingPreferences` and the invite names (`MeetingCalendarNaming`).
- Not built yet: one-voice-per-invitee assignment and process-of-elimination suggestions (they
  need the naming sheet to accept a per-row suggested invitee), and the NVIDIA/LS-EEND hybrid.

## Caveats (read before quoting)

1. **Voices are too consistent across meetings.** Each simulated person's meetings come from one
   YouTube recording (different device/codec per meeting, same voice session). Real people change
   more between meetings, so real same-person scores will be lower than 0.876. The naming thresholds
   above must be re-checked on cross-recording identities before shipping (plan phase 3: 166 voice
   pairs already look like the same person in two different videos).
2. **Trust isn't proven yet.** 0 wrong out of ~57 silent names bounds the error at about 5%, not 0.1%.
   Three sound-alike companies (72 more meetings) are running now to widen this.
3. **The simulator can't reproduce the 11-row case.** Big-call results are the solid part. The
   1:1 extra-row fix is solid for what the simulator covers.
4. The replay DB model is simplified (profile = mean of confirmed fingerprints); winners need an end-to-end
   rerun in the harness after they're built into Core.

## Open questions

- Where do real 10–11-row meetings come from? Checking the real library (counts only, opt-in)
  would tell mic-split vs call audio vs noise.
- Does a retuned diarizer (threshold / Fb sweep, running) fix big-call under-splitting without
  bringing back 1:1 fragments?
- Hybrid E2E turns + our clustering: worth a spike?
