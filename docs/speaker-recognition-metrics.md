# Speaker recognition metrics — the lifeline system

How Transcripted measures whether speaker recognition actually works in the
real world, keeps it from degrading over time, and gets better the more it is
used. No speaker names, embeddings, transcript text, or audio references are
ever part of this system's off-device surface.

## The mental model

Every speaker profile moves through a funnel:

```
1. BORN        first meeting → profile created in speakers.sqlite
2. NAMED       user types their name in the review sheet (enrollment)
3. LEARNING    next meetings → app suggests them, user confirms/corrects
4. GRADUATED   app is confident enough to auto-recognize silently
```

Three numbers say whether the system works:

1. **Appearances to graduation** — how many meetings until the first silent
   auto-recognition. The policy floor is 6 (`callCount > 4`, similarity > 0.92,
   margin ≥ 0.12 in `SpeakerNamingPolicy`); the metric shows whether real
   people graduate at the floor or drag on.
2. **Recognition precision** — confirmed vs corrected verdicts. Should trend up.
3. **Questions per meeting** — review rows requiring a user answer. Should
   trend down.

## The one signal everything runs on

The review sheet is a labeling UI: every submit produces a
`SpeakerNameUpdate.NamingAction` per row — `confirmed` means the suggestion
was right, `corrected` means it was wrong. Silent auto-recognitions are the
other half of the signal. Both are recorded as rows in the append-only
`speaker_match_outcomes` table inside `speakers.sqlite`:

| written by | kind | when |
| --- | --- | --- |
| `TranscriptionPipelineRunner` | `auto_accepted` | a returning speaker is silently named, recorded after the saved-transcript side effects commit (so cancelled runs leave no rows) |
| `SpeakerNamingCoordinator` | `confirmed` / `corrected` / `named` / `merged` | the review sheet is submitted and the transcript finalizes |

Each row stores only: profile UUID, kind, similarity, runner-up similarity,
pre-meeting call count, channel, transcript UUID, timestamp. Corrections
attribute to the profile that was *wrongly suggested*, so mistakes land on the
profile that made them. Two disjointness rules keep one match = one row: mic
speakers that will flow through the review sheet anyway (local split with
audio) do not get an `auto_accepted` row — their verdict arrives from the
coordinator instead — and the shared `SpeakerMatchOutcomeKind(reviewAction:)`
mapping is the single verdict classifier for both the store and analytics.

## The three loops

### 1. Self-healing profiles (anti-degradation)

`SpeakerProfileHealth.assess` demotes a profile from silent auto-accept back
to "confirm?" mode when its recent lifeline shows corrections (latest verdict
corrected, or ≥2 corrections in the last 5 outcomes, or any unresolved
dispute). The demoted profile keeps asking until a confirmation restores
trust. Errors convert into questions; answers convert into repairs — a wrong
profile can never quietly keep mislabeling meetings. Wired into both
auto-accept sites in `TranscriptionPipelineRunner` via
`SpeakerNamingPolicy.shouldAutoAccept(..., recentOutcomes:)`.

### 2. Respect the user's attention (signal supply)

- `SpeakerReviewPrioritizer` orders review rows most-informative-first:
  doubtful suggestions (lowest similarity) lead, unknown voices follow.
- The sheet shows the payoff line "Transcripted recognizes N people
  automatically" (`SpeakerNamingRequest.recognizedPeopleCount`) so confirming
  visibly makes the app smarter.

### 3. Fleet calibration (better for everyone)

Two allowlisted, bucketed PostHog events (see
`Resources/analytics-events.psv`; enforced by `AnalyticsEventPolicyTests`):

- `meeting_speaker_match_reviewed` — one per review verdict:
  `review_action`, `similarity_bucket`, `margin_bucket`, `call_count_bucket`,
  `channel`, `had_suggestion`, `surface`.
- `meeting_speaker_auto_recognized` — one per silent recognition after save:
  same buckets plus `graduated` (a profile's first-ever auto-recognition).

Correction rate by similarity/margin bucket across the fleet is exactly the
curve needed to retune the auto-accept gates (0.92 similarity / 0.12 margin /
callCount > 4) from real living rooms instead of the AMI corpus. Validate any
proposed threshold change offline with `Tools/SpeakerEvalHarness` before
shipping it.

## Watching the numbers

Local, exact, on demand:

```bash
cd Tools/TranscriptedQA
swift run transcripted-qa speaker-stats            # text with trend arrows
swift run transcripted-qa speaker-stats --format json
```

The report prints the funnel, appearances-to-graduation, and the two
north-star numbers as last-30-days vs prior-30-days with explicit
improving/regressing arrows — precision should trend up, questions per
meeting should trend down.

Fleet-wide, in PostHog, the recommended standing insights:

1. `meeting_speaker_match_reviewed` — % `review_action = corrected`, weekly.
   The fleet precision trend (down = good).
2. Same event broken down by `similarity_bucket` — the calibration curve for
   the auto-accept bar.
3. `meeting_speaker_auto_recognized` — weekly count, plus % with
   `graduated = true` (new people crossing into the magic zone).
4. `meeting_speaker_review_submitted` — `completion_kind = review_later` share
   (how often review is skipped; caveat weight for #1).

## Honest caveats

- Auto-recognition errors only surface when a user later reviews or corrects,
  so precision measured from verdicts is slightly optimistic. Track the
  review-skip rate next to it.
- `meeting_speaker_match_reviewed` fires at review submit (user intent), while
  the local lifeline rows are written only when the transcript finalizes. In
  the rare finalization-failure case PostHog counts a verdict the local store
  never recorded — an accepted intent-vs-applied gap, not a bug to chase.
- The lifeline table starts empty on upgrade; trends need a few weeks of real
  meetings before they mean anything.
- Voiceprint drift (seed vs blended embedding divergence) is visible in
  `speaker_provenance` but not yet reported by `speaker-stats`; a future pass
  can add it.
