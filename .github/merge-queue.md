# Merge queue — status and enablement

## Why we want it

Parallel PRs go stale against a fast-moving `main`. When two branches both
build green in isolation but touch the same ground, whichever lands second
carries a silent conflict: PSV registry collisions, duplicate Swift
declarations, family-name renames. These have been the #1 source of manual
conflict-resolution work on this repo.

GitHub's native **merge queue** removes the class of bug: it rebases each PR
onto the current `main`, runs the required CI against that temporary merged
ref, and only lands if it still passes — serially, one PR at a time. A branch
can never land against a `main` it wasn't just tested against.

## Current status: BLOCKED on repository ownership

Merge queue is **not available for user-owned repositories**. GitHub offers it
only for repositories owned by an **organization** (public org repos on any
plan; private org repos on GitHub Enterprise Cloud). `r3dbars/transcripted` is
owned by the user account `r3dbars`, so the `merge_queue` ruleset rule is
rejected at the API with `422 Validation Failed — Invalid rule 'merge_queue'`.

This is a platform restriction, not a permissions or plan gap on the current
account, and there is no Settings toggle that changes it for a user-owned repo.
The only way to unblock is to move the repo under an organization.

The repo is otherwise **ready**: both required CI workflows now declare the
`merge_group:` trigger (see `.github/workflows/swift-ci.yml` and
`.github/workflows/repo-hygiene.yml`), so the queue's checks will fire the
moment merge queue is turned on.

## To enable (once the repo is org-owned)

1. **Transfer the repo to a GitHub organization** (Settings → General →
   Danger Zone → Transfer, or `gh api`), or create it under an org.

2. **Create the merge-queue ruleset** with the exact payload below. The
   required checks are the job names GitHub reports, `build-and-test` (from
   Swift CI) and `repo-hygiene` (from Repo Hygiene) — not the workflow display
   names. Config chosen for this repo: merge-commit method to match convention,
   and batch size 1 (`max_entries_to_build: 1`) because the macOS Swift build
   is long and batching PRs behind it wastes a rebuild on every failure.

   ```bash
   gh api -X POST /repos/<org>/transcripted/rulesets --input .github/merge-queue-ruleset.json
   ```

3. **Verify it is live:**

   ```bash
   gh api /repos/<org>/transcripted/rulesets \
     --jq '.[] | select(.name=="merge-queue-main") | {id, enforcement}'
   ```

   Then confirm the `merge_queue` rule resolved:

   ```bash
   RID=$(gh api /repos/<org>/transcripted/rulesets --jq '.[]|select(.name=="merge-queue-main").id')
   gh api /repos/<org>/transcripted/rulesets/$RID --jq '.rules[].type'
   ```

The ready-to-apply payload lives beside this file at
`.github/merge-queue-ruleset.json`.

## Notes on the config

- **Required checks stay `strict: false`.** The queue itself guarantees each
  PR is tested against current `main`, so the classic "require branches up to
  date" flag is redundant and would only add friction.
- **`hardware-smokes` is unaffected.** It is gated on
  `github.event_name == 'workflow_dispatch'`, so it never runs for a
  `merge_group` event and can never block the queue.
- The existing classic branch-protection rule on `main` (required PR,
  conversation resolution, no force-push, admins included) can remain; the
  ruleset layers the queue on top.
