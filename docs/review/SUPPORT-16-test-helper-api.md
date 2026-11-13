# SUPPORT-16: test-only helper scope and owner choices

Status: proposal only. No choice is selected; no source or test removal is implemented.

The supplied REVIEW.md entry says “Test-only helpers left after their UI went away (owner's call, not dead)” but supplies no API names. A bounded lookup beside that report and in the audit checkout found no detailed SUPPORT-16 list. The two candidates below are a fresh source survey, not names attributed to the original auditor. This worksheet prepares owner review; it does not establish that the original unspecified finding is resolved, or that an old UI should return.

Source snapshot: main `8a38235eef00816a79daa1324387a21ef880204d`. Direct-call searches covered tracked `Sources/`, `Tests/`, and `Tools/`; they do not establish absence of consumers on other branches or outside this repository.

## Confirm the scope first

- [ ] Use the two candidates below as the bounded scope for this owner decision.
- [ ] Supply the original intended API list or a different scope before deciding.

Selected scope and owner: **unset**.

## Current candidate inventory

| Candidate | Current behavior | Current direct consumers found |
| --- | --- | --- |
| [`SpeakerNameSelectionPolicy.completedLabel(for:labels:optionsByLabel:displayName:callCount:)`](../../Sources/Support/SpeakerNameSelectionPolicy.swift) | Returns the sole normalized prefix match after ranking; returns nil for empty or ambiguous prefixes. | Two calls in [`SpeakerNameSelectionPolicyTests.swift`](../../Tests/SpeakerNameSelectionPolicyTests.swift) check unique and ambiguous prefixes; one in [`SpeakerVoiceRowPresentationTests.swift`](../../Tests/SpeakerVoiceRowPresentationTests.swift) checks a unique prefix. No production direct call found in the searched snapshot. |
| [`SpeakerNameSelectionPolicy.option(matching:optionsByLabel:displayName:)`](../../Sources/Support/SpeakerNameSelectionPolicy.swift) | Resolves an exact identity label first, otherwise one unambiguous normalized display name. | One call in [`SpeakerNameSelectionPolicyTests.swift`](../../Tests/SpeakerNameSelectionPolicyTests.swift) checks that a disambiguated duplicate-name label returns the selected UUID. No production direct call found in the searched snapshot. |

These are internal Swift helpers with meaningful behavior and actual test consumers. “Test-only” does not by itself authorize deleting their contracts. The VoiceRow test's assertion about inline completion is test evidence for this helper, not proof that the current view invokes it.

## Choices for each candidate

Select one direction per candidate only after confirming scope. Every option is currently unselected.

| Direction | Consequence |
| --- | --- |
| Retain in Support | Keep the helper and its tests as deliberate supported internal behavior; name who maintains it and why. |
| Move to test support | If the behavior is only useful for fixtures, move it deliberately and label tests accordingly. Tests of a copied helper would not prove production UI behavior. |
| Integrate into a product flow | Specify the actual surface, interaction and acceptance criteria before wiring it. Inline completion and identity selection are product choices, not automatic cleanup. |
| Retire deliberately | Approve the contract's retirement, account for all consumers, and revise obsolete tests without weakening coverage of the live naming paths. Check active branches before removal. |

`completedLabel`:

- [ ] Retain in Support.
- [ ] Move to test support.
- [ ] Integrate into a specified product flow.
- [ ] Retire deliberately.

`option(matching:)`:

- [ ] Retain in Support.
- [ ] Move to test support.
- [ ] Integrate into a specified product flow.
- [ ] Retire deliberately.

Chosen surface or rationale, compatibility plan, acceptance criteria and implementation owner: **unset**.

## Live behavior outside this proposal

[`SpeakerNameTypingSuggestionPolicy`](../../Sources/Support/SpeakerNameTypingSuggestionPolicy.swift) uses live identity-label creation and ranking; [`SpeakerNameAutocompleteField`](../../Sources/UI/Settings/SpeakerNameAutocompleteField.swift) invokes its suggestions. The island also uses label creation in [`NotchIslandVoiceRowView`](../../Sources/UI/Overlay/NotchIslandVoiceRowView.swift) and ranking in [`NotchIslandSpeakerReviewPolicy`](../../Sources/UI/Overlay/NotchIslandSpeakerReviewPolicy.swift). Those paths and `uniqueSavedPerson` are excluded from retirement here. Speakers review, rename, merge and delete remain part of the product surface.

Model-cache formatting was excluded: [`ModelCacheSnapshot.diagnosticsFields`](../../Sources/Support/ModelCacheInventory.swift) uses formatted values, [`TranscriptedSupportActions`](../../Sources/App/TranscriptedSupportActions.swift) consumes those diagnostics, and [`StorageSettingsPage`](../../Sources/UI/Settings/Pages/StorageSettingsPage.swift) uses reclaimable-size formatting. Permission request helpers were also excluded: [`TranscriptedPermissionAccess`](../../Sources/Support/TranscriptedPermissionAccess.swift) uses microphone/calendar request defaults, and [`DictationSessionController`](../../Sources/UI/Overlay/DictationSessionController.swift) calls the microphone helper. These are not blanket dead-code candidates.

## Evidence and follow-up

This proposal changes documentation only. Source/reference inspection was read-only; no user-state, permission, model, UI or broad test runtime was invoked. A later implementation requires its own full diff review and mapped checks. Any selected product integration also needs real interaction acceptance; helper tests alone cannot supply it. No implementation or runtime result is claimed by this worksheet.
