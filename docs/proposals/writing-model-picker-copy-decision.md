# Writing model picker copy: owner decision

Status: unselected proposal for REVIEW.md item WRITING-CORE-5. No visible copy,
public API, model selection, eligibility, download or runtime behavior changes.

## Current checked-in contracts

Reviewed against main at `8a38235eef00816a79daa1324387a21ef880204d`.

- `Sources/Writing/WritingSetupPresentation.swift` defines the picker details
  as Gemma "3.4 GB, faster" and Qwen "5.6 GB, better". Both
  `WritingSetupFlowView.swift` and `WritingSettingsSection.swift` render those
  `modelOptions` details through `WritingChoiceRow`.
- `docs/writing-plan.md` specifies that same visible model copy.
  `Tests/WritingSetupPresentationTests.swift` asserts those exact details.
  These establish the checked-in presentation contract, not measured speed
  or quality evidence.
- The public `TildeModelChoice.resourceGuidance` getter in
  `Sources/TranscriptedWriting/Core/Runtime/TildeModelChoice.swift` instead
  says Gemma is the "Measured default, uses less memory and storage" and Qwen
  "Needs more memory and storage, still under study". Its comment says these
  lines appear in the pickers, but current production pickers do not call it.
- `Tests/TranscriptedWritingTests/Core/TildeProductProfileTests.swift` checks
  the Core guidance. Its comment rejects presenting the larger model as simply
  better; its assertions check the guidance strings and one-line length.
  Working-tree references to the getter are its declaration and those tests.
  The tests therefore protect different contracts rather than proving that
  the live picker consumes the Core guidance.

This review inspected source and documentation only. It did not run a model,
collect benchmarks, inspect downloads or preferences, or render either picker.
The Core comment's measurement claim was not independently verified here.

## Choose the copy and its owner

All options remain unselected.

- [ ] A. Keep the current visible copy and design-record contract. Decide how
      the public guidance getter and its tests should align with that wording;
      stop describing unused guidance as the live picker text.
- [ ] B. Adopt the existing conservative Core guidance in both pickers. Decide
      how size and guidance share the row, and update the design record and
      visible-output tests together. Review the actual layout before claiming
      the longer wording fits.
- [ ] C. Revise the claims using owner-approved measurements. Define the models,
      hardware, workload and evidence required before choosing speed or quality
      wording. Select one authoritative copy source after that review.

Owner fill-ins remain pending: exact text, evidence supporting each claim,
the authoritative declaration, and whether any public API change is intended.
`resourceGuidance` is public in the separate Writing Core library; having no
repository production caller does not make deleting it a private cleanup.
Prefer forwarding or retaining the API unless a compatibility change is chosen.

After a choice, wire both picker surfaces to the selected source, retain model
identity/default/order/eligibility behavior, and test the actual presentation
values. Foundation-only fixtures can validate those values without starting a
model or settings runtime; rendered picker checks remain separate.

This worksheet neither selects wording nor consolidates the declarations. The
owner decision and implementation portion of WRITING-CORE-5 remain pending.
