# Versioned change history: owner decision

Status: unselected proposal for REVIEW.md item DOCS-8. No changelog entry,
release note, version, feed, cask, tag, workflow, or published asset changes.

## What needs a decision

Choose which record readers should use for changes in each released version,
then decide how much historical reconstruction is needed. The current mixed
Unreleased section cannot safely be assigned to one release wholesale.

## Current checked-in evidence

Reviewed against main at `8a38235eef00816a79daa1324387a21ef880204d`.

- `CHANGELOG.md` says it documents all notable user-facing changes. Its newest
  version heading is 1.1.50, dated 2026-07-14. The Unreleased section above it
  contains multiple categories without per-version attribution.
- Checked-in `Info.plist` and `Casks/transcripted.rb` name 1.1.76. These values
  alone do not prove what was published, installed, or included in that version.
- The legacy `docs/appcast.xml` contains 25 entries newer than 1.1.50, spanning
  1.1.51 through 1.1.75, with version-specific release-note links. Its freeze
  record is `config/release/legacy-appcast-freeze.json`.
- `docs/sparkle-updates.md` identifies the current feed as the appcast asset of
  the latest GitHub release. The frozen legacy feed is not a current release
  inventory. This proposal does not claim all 26 later versions were independently
  verified against hosted release contents.
- `docs/release-notes-template.md` provides editorial guidance for a candidate,
  including user-visible changes, reliability and caveats. It does not attribute
  the existing mixed changelog bullets to historical versions.

No hosted release contents, customer installation, updater, signing credential,
or production surface was inspected or changed to prepare this inventory.

## Choose the record and backfill scope

Both options are unselected; the owner may revise them or choose a combined
approach with an explicit source of truth.

- [ ] A. Keep a versioned `CHANGELOG.md` as the complete human-readable history.
      Reconstruct missing sections from reviewed release notes and exact source
      tags or release references. Attribute each bullet to evidence, keep
      uncertainty visible, and define a future rollover step before publication.
- [ ] B. Use GitHub Releases as the per-version record for later releases.
      Qualify the changelog's completeness claim and clearly label its historical
      entries and mixed aggregation. Link readers to the approved release record;
      do not keep calling already-shipped changes Unreleased without attribution.

Owner fill-ins:

- Canonical record and date/version from which it applies: pending.
- Versions to reconstruct and evidence required for each: pending.
- How to label bullets whose first shipped version cannot be established: pending.
- Who updates the record and at what point in an approved release: pending.

After a choice, review the version-to-change mapping and user-facing wording.
Treat actual release-note, release-workflow, feed, cask, and download changes as
release-impacting work with their required checks and approval boundaries. A
history backfill is not authorization to publish a release or move an update feed.

This worksheet does not backfill the changelog, select a record, validate a
release, or complete DOCS-8. Owner choice: pending.
