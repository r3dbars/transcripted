# Microphone fallback speaker handling: owner decision

Status: **unselected proposal** for CORE-REST-4. This worksheet does not change
runtime behavior, choose a speaker policy, or authorize voiceprint deletion.

## Verified current behavior

These observations describe the current source at main commit
`8a38235eef00816a79daa1324387a21ef880204d`. They are source review, not a
model, recording, database, or UI execution result.

- People in the room is off by default. The app snapshots the preference for
  recorded meeting jobs; imported audio does not enable local-speaker splitting.
  See [LocalSpeakerPreferences](../../Sources/Support/LocalSpeakerPreferences.swift)
  and [MeetingTranscriptionRequestBuilder](../../Sources/Meeting/MeetingTranscriptionRequestBuilder.swift).
- When the system-audio URL is absent, the
  [pipeline entry point](../../Sources/TranscriptedCore/Pipeline/TranscriptionPipelineRunner+EntryPoints.swift)
  uses the separate microphone-only runner. It forwards the local-speaker flag
  when the microphone file exists.
- With that flag enabled, the
  [microphone-only transcription stage](../../Sources/TranscriptedCore/Pipeline/TranscriptionPipeline+MicrophoneOnly.swift)
  runs the shared [mic diarization stage](../../Sources/TranscriptedCore/Pipeline/TranscriptionPipeline+MicDiarization.swift).
  That stage can create speaker profiles and update matched profiles before
  returning utterances, identity contexts, and newly created profile IDs.
  A matched profile's blend weight can be zero; this does not mean every match
  changes its embedding. The [speaker database](../../Sources/TranscriptedCore/Speaker/SpeakerDatabase.swift)
  can still update its appearance count, last-seen time, and confidence.
- The separate microphone-only runner then saves with empty speaker mappings,
  sources, and database-ID mappings, and no speaker store. It does not prepare
  the naming/review flow used by the normal runner.
  The [formatter](../../Sources/TranscriptedCore/Storage/TranscriptFormatter.swift)
  therefore omits the `speakers` frontmatter and labels every microphone
  utterance **You** in the full transcript. The analytics breakdown can still
  distinguish numbered microphone speakers.
- This is narrower than all failed or missing system-audio files. A non-nil
  system URL whose loaded track is unusable or too short stays in the
  [normal pipeline](../../Sources/TranscriptedCore/Pipeline/TranscriptionPipeline.swift)
  when the microphone is usable. That path preserves local-speaker
  classification and review.
- Intentional mic-only recording normally supplies a silent system track so
  the normal path remains available. The
  [capture bridge](../../Sources/Meeting/MeetingCaptureBridge.swift) creates it;
  [failed-meeting retry](../../Sources/TranscriptedCore/Pipeline/TranscriptionTaskManager+Retry.swift)
  attempts to recreate it when needed. Failure to create that stand-in can
  still leave the system URL absent. Neither default-off nor the stand-in
  eliminates the separate fallback path.

The gap is therefore: **an enabled room-speaker pass can mutate the speaker
store, while the nil-system-URL save path does not carry those identities into
saved speaker metadata or review**. No stale-voiceprint replay, data loss, or
frequency of occurrence has been demonstrated here.

## Options for the owner

All choices remain unchecked. None is recommended or adopted by this document.

- [ ] **A — Keep this fallback as one You track.** Disable local-speaker
  diarization only in the nil-system-URL fallback. Preserve transcription and
  saving, while avoiding speaker-profile creation and updates from that pass.
  Room-speaker identities would be unavailable precisely when the system URL
  is absent, even if People in the room was enabled. Normal two-track and
  non-nil-but-unusable-system handling would remain unchanged.
- [ ] **B — Preserve room-speaker identification through this fallback.** Carry
  the microphone result through a shared classification, saved-metadata, and
  speaker-review lifecycle. This requires design for review clips, known and
  unknown voices, cancellation, save failure, and retained-audio ownership;
  adding labels alone would not complete it. Existing voiceprint write-back
  remains a separate consideration within that design.
- [ ] **C — Revise the intended fallback behavior.** Record another desired
  outcome and its scope before implementation.

Owner selection: **pending**.

This choice does not decide whether deleting a person removes voiceprint
history, change general profile retention, or authorize cleanup of existing
profiles. Those decisions remain separate.

## Future implementation proof

This is an unexecuted design for tests after a choice is made, not a report of
passing checks or an approved runnable fixture.

Use a new, narrowly filtered fixture that exercises the actual
nil-system-URL manager path. Inject a recording memory speaker store, fake
diarization and speech-to-text engines, notifier, stats, and format providers.
Use synthetic microphone audio and explicit owned storage paths. Audit the
full constructor chain and cleanup before running it; do not use standard
preferences, a real speaker database, model downloads, or native capture.

The cases should distinguish:

- local-speaker splitting off versus on;
- a new voice versus a matched voice, including a zero-blend match;
- an absent system URL versus a non-nil unusable system-track control;
- the selected option's speaker-store mutations, saved words, speaker
  frontmatter, displayed labels, and review request;
- cancellation and save-failure consequences appropriate to the chosen design.

For A, prove that the fallback does not perform local diarization or speaker
mutations while retaining the words. For B, prove that actual saved identities
and review remain connected to the result and owned audio. Keep normal
non-fallback behavior covered. Existing mixed pipeline suites are not local
fixture-safety evidence; they require their own review or a suitable isolated
hosted account. Native recording and real model quality remain separate proof.
