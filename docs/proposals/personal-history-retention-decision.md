# Personal History retention: owner decision

Status: unselected proposal for REVIEW.md item WRITING-RUNTIME-11.
No retention, deletion, consent, predictor or preference behavior changes.

## Current source evidence

Reviewed against main at `8a38235eef00816a79daa1324387a21ef880204d`.

`EncryptedPersonalHistoryStore` appends authenticated, encrypted batches to its
history log. Its 64 KiB encrypted-record ceiling bounds an individual record,
not total log size. The separate trained-model file has an 8 MiB ceiling.
`PersonalHistoryController` replays at most the newest 4 MiB of log bytes on
configuration; this bounds replay work without removing older disk records.
A torn trailing write may be truncated during append. That repair is not an
age or total-size retention policy.

The trained model can preserve learning from records outside the replay window.
Pruning the log alone would not establish that the predictor has forgotten the
removed material. Any forgetting contract must cover model/checkpoint contents,
sequence ownership and rebuild behavior as well as encrypted log records.

`PersonalSuggestionStats` writes one `personal-suggestions.YYYY-MM-dd` dictionary
of source counts per local calendar day in the keyboard preferences suite, with
a standard-defaults fallback. It has no age/size prune in that writer, and
nothing in the app reads the buckets back. These buckets contain
counts, not suggestion text; they are separate from the encrypted history log.

The existing Personal History delete path removes the log, trained model,
partial model and Keychain key and resets learning ownership. The app's Delete
all writing action also invokes outcome-store and saved-writing deletion.
Neither the reviewed count writer nor `TildeLocalOutcomeStores.deleteAll()`
removes the personal-suggestion daily preference keys. Define their intended
relationship to Delete all explicitly before changing it.

Other limits do not solve this item: the outcome ledger rotates separately,
and closed saved-writing recovery has a separate bounded journal. Saved writing
Markdown files and encrypted learning history have different purposes.

This review read source only. No user history, preferences, Keychain, model,
file sizes or growth rate was inspected; no store or runtime was constructed.

## Choose the retention contract

All options remain unselected; the owner may revise them.

- [ ] A. Keep history until explicit deletion. Explain that choice and decide
      whether storage visibility or a warning is needed. Choose a separate
      retention period for the daily count buckets.
- [ ] B. Bound encrypted log storage while retaining the trained model's prior
      learning. Choose byte/age limits and describe this as storage compaction,
      without promising that removed records are forgotten.
- [ ] C. Apply a learning-forgetting window. Choose the window and require a
      coherent model/checkpoint rebuild or reset so expired material cannot
      survive solely in derived learning. Define effects on personalization.

Owner conditions remain pending: limits, whether existing data is migrated,
whether count buckets follow Delete all, and what happens when compaction or
model replacement fails. Do not pick an arbitrary number of days in code.

Implementation must preserve consent and app-scope gates, owner-only encrypted
storage, authenticated records and sequence consistency. Replacement must survive
interruption and concurrent ingest without losing admitted new data. Keep saved
writing and unrelated preferences outside the selected policy's deletion scope.
Validate with synthetic owned stores, boundary dates/bytes, interrupted writes,
model recovery and explicit-delete cases before any real-data operation.
This worksheet does not select a policy or complete WRITING-RUNTIME-11.
