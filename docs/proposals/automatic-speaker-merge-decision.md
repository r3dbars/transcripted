# Automatic speaker duplicate merging: owner decision

Status: unselected proposal for REVIEW.md item CORE-SPEAKER-5. No threshold,
automatic merge, saved identity, or Speakers workflow changes in this proposal.

## What needs a decision

The pipeline can combine saved voice profiles automatically after transcription.
The Speakers page also suggests possible duplicates for a person to review.
These actions use different rules. Decide how much identity-changing work may
happen automatically before choosing numerical thresholds or changing tests.

## Current source evidence

Reviewed against main at `8a38235eef00816a79daa1324387a21ef880204d`.

- `TranscriptionPipelineRunner.swift` calls `mergeDuplicates(protecting:)` after
  building the pending-review protection set. The database overload uses its
  model-specific `thresholds.duplicateProfileMerge`.
- `SpeakerProfileMerger.swift` skips protected profile IDs, disputed profiles,
  and pairs whose nonempty normalized names differ. It compares the saved
  embeddings, keeps the profile with more calls (the first on a tie), then uses
  the transactional merge implementation. This is an actual identity mutation,
  not just a suggestion in the directory.
- `SpeakerEmbeddingThresholds.swift` defines these presets. The match column
  below is the adaptive base for four or more segments, not every matching
  guard, maturity bonus, naming rule, or a calibrated probability.

| Preset | Automatic duplicate merge | Base match, four or more segments |
| --- | --- | --- |
| WeSpeaker | 0.600 | 0.700 |
| ERes2Net | 0.600 | 0.550 |
| ReDimNet2 b4 | 0.598 | 0.707 |

The claim that the merge bar is below the match floor is therefore not universal
across presets. Database construction and calibration overrides also matter.
Source values alone do not establish an acceptable false-merge rate.

- In Settings, `SpeakerDuplicateMatchPolicy` uses a voice similarity bar of
  0.90, or 0.96 for conflicting unrelated names, and requires zero disputes on
  both profiles for a voice match. Equal or related names can still produce a
  candidate without meeting a voice bar. The report's “only duplicates at 0.90”
  wording misses those name-only candidates and the conflicting-name case.
- `SpeakerDuplicateDetection` builds review candidates; finding a candidate is
  distinct from automatically merging the database pair. Making all these
  numbers equal would not by itself align the actions or their guard conditions.

No real speaker data, database, recordings, or model evaluation was opened or run
to prepare this source inventory.

## Choose the intended behavior

All options are unselected; the owner may revise them.

- [ ] A. Keep automatic cleanup and review suggestions as distinct actions.
      Define and validate the acceptable false-merge risk for each supported
      embedding model, then calibrate and document their separate rules.
- [ ] B. Require an explicit review action before combining saved identities.
      Define how suggestions are queued and how duplicate accumulation is shown
      without burying the existing rename, merge, delete, and review controls.
- [ ] C. Use a stricter automatic subset and offer the rest for review. Specify
      eligibility, model-specific evidence, disagreement handling, and the
      relationship to pending reviews before implementing it.

Any implementation must preserve protected-review IDs, disputes, saved transcript
references, provenance, and the intended merge/Undo behavior. Review how an
automatic merge affects those promises before changing the mutation path.
Do not choose a new cosine cutoff from the numerical comparison alone.

After a decision, add deterministic eligibility and boundary tests, run the
mapped checks and independent diff review, and report model-quality evidence
separately from synthetic test results. This worksheet does not establish a
safe new threshold or complete CORE-SPEAKER-5.

Owner selection and conditions: pending.
