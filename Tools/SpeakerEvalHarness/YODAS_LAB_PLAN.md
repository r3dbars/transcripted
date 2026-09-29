# Speaker Lab on YODAS3: plan

**Status:** in progress, started 2026-09-28. Branch `claude/yodas-speaker-lab`.
**Data:** [espnet/yodas3](https://huggingface.co/datasets/espnet/yodas3), CC BY 3.0. Audio,
derived clips, embeddings, and reports stay local under `data/eval/yodas3/` (gitignored), the
same rule AMI follows. Cite Chen et al., Interspeech 2026, in anything we publish from it.

## The goal in one line

After any call, Transcripted should ask you to name **exactly the people who were there, once
each**. It should learn a voice in as few meetings as it can. And it must **never** put the
wrong name on someone.

Today it can show 10 or 11 naming rows for a call with one other person, which means the user
types the same name 11 times. It takes 5 confirmed meetings before a voice is named silently
(`SpeakerNamingPolicy.requiredConfirmedMeetings`). The calendar only suggests names; it doesn't
help decide.

## What the data is (checked 2026-09-28)

- English: 1,000 shards, each an ~8.5 GB tar plus a metadata parquet. Shard 0000 alone is
  543 videos and 163 hours. Median video is 3 minutes; 76 videos run 30 minutes or longer.
- Transcripts come with sentence timestamps, and ASR tracks also have word timestamps
  (339 of 543 in shard 0000). The other 204 are uploader-written subtitles.
- 54 of 543 videos contain YouTube's `>>` speaker-change marker, which means real
  multi-speaker talk with rough turn labels.
- 430 of 543 have two genuinely different stereo channels.
- **No channel or uploader ID.** Video IDs are encrypted, so we can't link one person's
  videos together from metadata. Every identity in this lab starts as "the main voice of one
  video." Phase 2 below adds linking across videos.

## How it fits together

```text
YODAS3 shards ──► 1. Voice bank ──► 2. Meeting simulator ──► 3. Lab runner ──► 4. Scoreboard
                  who's who,        fake calls with an       the REAL app       rows, trust,
                  verified          answer key + a fake      pipeline, plus a   learning speed
                                    calendar invite          simulated user
```

### 1. Voice bank: `scripts/speaker_lab/voicebank.py`

A bank of clean voice clips where we know who is speaking.

1. Decode each video (Opus in WebM) to 16 kHz mono with PyAV.
2. Cut speech regions from the subtitle timestamps. Drop `[Music]`/`[Applause]` cues and
   anything under 1 s.
3. Embed 3 s windows with **two independent voice models that are not the app's**: NVIDIA
   TitaNet-large and 3D-Speaker CAM++, both run through sherpa-onnx. The app uses WeSpeaker
   (and optionally ERes2Net), so the labels don't share the app's blind spots.
4. Find the main voice per video. Keep a window only if **both** models agree it's the main
   voice. Keep the video only if at least 90% of its speech is that voice. That filters out
   podcasts, interviews, and reaction videos. This matters most, because a "one speaker" clip
   that secretly holds two voices would make the diarizer look wrong when it's right.
5. Save per identity: chunk list (start, end, words), labeler embeddings, bandwidth, SNR estimate,
   and minutes of clean speech.
6. Build a **sound-alike index**: pairwise similarity between identities under the labeler models.
   The simulator uses it to cast people who sound alike on purpose (hard negatives).
7. Mark videos with `>>` as the **real multi-speaker set** (used in section 5).

Long videos (≥ 20 minutes of clean speech) become **recurring cast**. Each one is cut into
separate "days," so one person can appear in many meetings without reusing audio.

Known gap: every "day" of a person comes from one recording session, so cross-meeting variation
is gentler than real life. Section 2 makes up for part of that with per-meeting device and room
changes. Phase 2 fixes it properly with cross-video identity linking.

### 2. Meeting simulator: `scripts/speaker_lab/meeting_sim.py`

Builds calls that look like what Transcripted records. Each meeting has two files: `mic.wav`
(people in your room) and `system.wav` (people on the call). It also writes an answer key
(`truth.json`: who spoke when, on which channel, with which words) and a fake calendar invite
(`calendar.json`).

**Conversation model.** Speaker choice follows a Markov chain with per-person dominance,
because some people talk way more. Turn lengths are lognormal, with occasional long monologues.
Short "yeah"/"right" backchannels are cut from word timestamps. 5–15% of turns overlap the
previous one. Gaps are 0.1–1.5 s.

**Channel model.**
- Remote people (`system.wav`): band-limited to wideband, 16 kHz, or 8 kHz telephone.
  Opus-encoded at 12–32 kbps through PyAV. Random level and slight AGC pumping.
- Local people (`mic.wav`): synthetic room impulse responses (pyroomacoustics), mic distance,
  background noise. Optional echo of the call audio leaking into the mic.
- Device switch mid-call: one person changes bandwidth, codec, or EQ halfway through, the way
  someone does when they grab their AirPods.

**Scenario families (each one reports on its own):**

| ID | What | Why |
|---|---|---|
| A | 1:1 remote call, 10–60 min | the "11 boxes for one person" bug; target is exactly 1 remote row |
| B | 3–4 remote people | normal team call |
| C | 6–8 remote people | the big call you asked about |
| D | 2–3 people sharing your mic plus 2–4 remote | hybrid room, local speaker split |
| E | Stress: sound-alikes, heavy overlap, device switch, music bed, long monologue | find the breaking points |
| F | Recurring series: a fake company of ~40 people over 6 weeks | naming and learning over time |

Family F calendar: a weekly 1:1 with a manager, a daily 5-person standup, a weekly 8-person team
sync, a monthly all-hands, and external calls with people seen once. Names are fake. On purpose
it includes a collision ("Sam Lee" and "Sam Patel") and a nickname ("Robert"/"Bob").

**Calendar model.** The invite is the truth with realistic noise: 15% chance an invitee doesn't
show, 10% chance someone uninvited joins, 10% nickname variants, 5% email-only invitees, and
the organizer counts as an invitee.

### 3. Lab runner: `speaker-eval-harness meeting-series`

Runs the **real app pipeline** headless, not a copy of it:

1. Builds a real `TranscriptionTaskManager` with the real `DiarizationService` and Parakeet
   (the same way `transcripted import-audio` builds its `Transcription`). Uses a throwaway
   speaker database and temp directories.
2. Calls `startTranscription(micURL:systemURL:splitLocalSpeakers:)` for each meeting in order.
3. Records the naming sheet exactly as the app would show it: every `SpeakerNamingEntry`,
   `needsNaming` vs `needsConfirmation`, the suggested person, and similarity/margin. Also
   records which speakers were auto-named silently.
4. A **simulated user** answers the sheet through the real `handleNamingComplete`. It types the
   true name, confirms a correct suggestion, and denies a wrong one. The speaker database learns
   exactly the way it does for a real user.
5. Writes `result.json` per meeting for the scorer.

Guardrails: temp paths only, `TRANSCRIPTED_DISABLE_FILE_LOGGER=1`, and never the real speaker
database or capture library.

Fast path for sweeps: `speaker-eval-harness dump` (diarizer only) on the same `system.wav`, plus
new dump modes for FluidAudio's **NVIDIA Sortformer** and **LS-EEND** diarizers, which already
ship inside our FluidAudio build.

### 4. Scoreboard: `scripts/speaker_lab/score.py`

**Level 1: did we split people right?** (per channel, per scenario family)
- Row count vs true people: % exact, % over, % under, and the average extra rows.
- **Fragments**: extra rows for a person already shown. That's the 11-boxes bug, measured.
- **Blends**: one row that holds two real people (≥ 20% of its time from a second person).
  This is critical, because a blended row can only ever get one right name.
- DER / JER with optimal speaker mapping, split into miss, false alarm, and confusion.

**Level 2: how fast do we learn a voice?** (family F)
- For each person: the meeting where we first **suggest** them ("Was this Taylor?") and the
  meeting where we first **auto-name** them.
- How often a suggestion is right.

**Level 3: can we be trusted?**
- **Wrong auto-names**: must be zero. Reported with a 95% upper bound, because 0 wrong out of
  300 only proves "under 1%." Showing "under 0.1%" takes about 3,000 clean auto-names.
- Wrong suggestions: less costly, but they erode trust.

**North star: user work per meeting.** Typing a name costs 3, confirming costs 1, a fragment row
costs 3 (wasted), and fixing a wrong auto-name costs 10. We also report the % of meetings that
need zero work.

### 5. Real-world checks (so we don't overfit fake calls)

- **AMI** stays as the regression test for in-person rooms.
- **YODAS `>>` videos**: real multi-speaker talk. `>>` gives rough turn boundaries, so we can
  score speaker count and changes.
- **Your own library (opt-in, on-device, counts only)**: in meetings where you already named
  speakers, count rows vs unique names you gave them. That's the 11-boxes rate in real life.
  No names or text leave the analysis. **Ask before running.**

## Experiments (the theories to test)

Each one is a config or code change scored against the same frozen simulated set. A change
wins only if it improves its target **without** increasing blends or wrong auto-names.

### Splitting people (Level 1)

| # | Theory | How |
|---|---|---|
| S0 | Baseline | current app |
| S1 | The diarizer settings were tuned on 16 Zoom calls; retune on thousands | grid/Bayes search over `OfflineDiarizerConfig` (clustering threshold, Fa, Fb, min durations) through `dump` |
| S2 | The invite size tells us roughly how many voices to expect | cap or prior on cluster count from the invitee count, allowing for no-shows and extras |
| S3 | NVIDIA Sortformer / LS-EEND count speakers better | run both on the same audio; also try a hybrid where the end-to-end model's speaker count steers clustering |
| S4 | Fragments can be glued back using the whole meeting | merge clusters whose long-window voice fingerprints match and which **never talk at the same time**; also treat a sentence split across two clusters as a merge hint |
| S5 | A better voice model separates better | WeSpeaker vs ERes2Net (already in the code) |
| S6 | Tiny clusters shouldn't become rows | a minimum talk-time bar before a cluster earns a naming row; fold short ones into the nearest voice or hide them |

### Naming people (Levels 2 and 3)

| # | Theory | How |
|---|---|---|
| N0 | Baseline | 5 confirmations, auto bar 0.92, margin 0.12 |
| N1 | 5 meetings is more than we need | sweep required confirmations 1–5 and the auto bars; plot learning speed vs wrong names |
| N2 | Suggest sooner | show "Was this Taylor?" after 1 confirmation when the margin is clear |
| N3 | **The calendar shrinks the lineup** | only compare voices against the invitees; solve all rows at once as a one-person-one-row assignment; process of elimination for the last unknown voice |
| N4 | Learn a voice from one meeting | enroll with extra copies of the voice run through codec, bandwidth, and room simulation, so the profile already knows "Taylor on a bad connection" |
| N5 | Combine every clue into one number | a calibrated model of voice score + lineup + recurring series + channel gives one probability; auto-name only above the bar where the lab measures zero wrong |
| N6 | Names said out loud ("Thanks, Sarah") | a small local model pulls out names people use. Can't be tested honestly on fake calls, because YouTubers don't say our fake names. Test on the `>>` set and the opt-in library check instead |

Offline replay first. The runner saves each row's session embedding and every profile score, so
naming policies N1–N5 can be replayed in Python in seconds. Winners then get built into
TranscriptedCore behind a lab flag and confirmed end to end in the runner.

## Phases

| Phase | Deliverable | Done when |
|---|---|---|
| P0 | Voice bank v0 (2 shards), simulator v0, runner, scorer, baseline on families A–D | the baseline report exists and its numbers pass a sanity listen |
| P1 | Splitting experiments S1–S6 | a config beats baseline on fragments with zero new blends |
| P2 | Family F plus naming experiments N1–N5 | a learning-speed chart and a trust number with a real upper bound |
| P3 | Scale: 20+ shards, cross-video identity linking, `>>` real set, opt-in library check | the winners hold on the real sets |
| P4 | Ship: winners into the app behind flags, then default on | AMI + library check + lab all green |

## Commands

```bash
bash scripts/speaker_lab/download_yodas.sh en 0000 0001      # shards to data/eval/yodas3/raw
data/eval/yodas3/venv/bin/python scripts/speaker_lab/voicebank.py --lang en
data/eval/yodas3/venv/bin/python scripts/speaker_lab/meeting_sim.py --family A --count 40
Tools/SpeakerEvalHarness/.build/release/speaker-eval-harness meeting-series --series <dir>
data/eval/yodas3/venv/bin/python scripts/speaker_lab/score.py --series <dir>
```
