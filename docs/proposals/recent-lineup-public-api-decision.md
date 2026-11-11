# Recent-lineup convenience API: owner decision

Status: unselected proposal for REVIEW.md item CORE-SPEAKER-8. No public API,
naming threshold, speaker-matching, or runtime behavior changes.

## Current source evidence

Reviewed against main at `8a38235eef00816a79daa1324387a21ef880204d`.

- `SpeakerNamingPolicy.InviteeBars.recentLineup` is a public static convenience
  value. It calls `recentLineup(for: .weSpeaker)` and represents the no-invite
  lineup bars at WeSpeaker scale.
- The separate public `recentLineup(for:)` factory accepts model-specific
  `SpeakerEmbeddingThresholds`. The active `inviteeBars` path calls that factory
  with the current thresholds when the lineup does not come from an invite.
- A repository Swift-source search found the convenience value's declaration,
  the factory declaration, and that active factory call. It found no caller of
  the convenience value in the app, tests, or Tools. This does not establish
  that external consumers never use the public value.
- The root `Package.swift` exports a `TranscriptedCore` library product. The
  Core guide describes a reusable library whose public declarations form its
  public surface. `Tools/SpeakerEvalHarness/Package.swift` consumes that product
  from the root package; CLI audio modes also use the prebuilt Core module.
- Contributor and repository-layout guides describe the package's compilation
  and test role alongside the authoritative app build. The relevant guides do
  not establish a compatibility or deprecation period for this public member.
- Broad audit commit `4f99d388896c619c93b34b8727ace3428ee68203` proposes deleting
  only the convenience value and its comment. That proposal is not the current
  main source; a proposed cleanup does not settle compatibility obligations.

No external-consumer inventory, downstream build, runtime test, or model run
was performed. Existing external use and compatibility obligations remain
unknown. Removing the member can break source that names
`SpeakerNamingPolicy.InviteeBars.recentLineup`, even though the app's active
factory call remains intact.

## Choose the compatibility contract

All options remain unselected; the owner may revise them.

- [ ] A. Retain and document the convenience value as the fixed WeSpeaker-scale
      API. Keep model-aware consumers on `recentLineup(for:)`.
- [ ] B. Deprecate the convenience value while preserving it during an
      owner-chosen migration period. Document `recentLineup(for: .weSpeaker)`
      as the equivalent replacement, and choose the period and removal criteria
      before adding a deprecation annotation or publishing a removal plan.
- [ ] C. Explicitly accept a breaking removal. Confirm the supported consumer
      scope, migration communication, and release boundary before deleting the
      public value. Preserve the model-specific factory and its active call.

Owner conditions: pending, including the supported public surface, external
consumer expectations, and any migration period or release boundary.

A later implementation should check the chosen public contract and the app's
model-aware factory path. Repository call-site absence alone does not prove
external compatibility. This worksheet selects no option, starts no migration
period, removes no API, and does not complete CORE-SPEAKER-8.
