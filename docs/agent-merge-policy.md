# Agent merge policy: risk-based auto-merge

Every PR gets a risk label. Low and medium PRs squash-merge on their own once CI is green and the AI review found nothing serious. High-risk PRs need a person. **Releases stay manual**: nothing here tags, builds, signs, notarizes or publishes.

The code is `scripts/ops/risk-triage.py`, run by `.github/workflows/risk-triage.yml`. Tests: `python3 scripts/ops/test-risk-triage.py` (also part of `scripts/dev/linux-checks.sh`, so `repo-hygiene` runs them).

This sits next to the older lane gate (`docs/auto-merge-gate.md`), which still runs on its own. A PR merges when either path allows it; both demand green `build-and-test` and `repo-hygiene`.

## 1. Risk tiers

Path rules decide the tier. Each changed file (and the old name of a renamed file) is checked, and **the highest match wins**.

| Tier | What | Who must approve |
|---|---|---|
| `risk:high` + owner | Release, version, Sparkle, appcast, cask, signing and notarization: `scripts/release/**`, `build*.sh`, `Casks/**`, `**/appcast*.xml`, `Info.plist` files, `server.json`, `glama.json`, `config/entitlements/**`, `*.entitlements`, any path containing `Sparkle`, `notari`, `codesign` or `Signing`, `TranscriptedAppVersion.swift`. Also every GitHub workflow and action, `CODEOWNERS`, and this policy's own files. | One approval from someone other than the author, **and** an approval from @r3dbars |
| `risk:high` | Audio capture (`Sources/TranscriptedCore/Audio/**`, `Sources/Capture/**`, `MeetingCapture*`, `MeetingMicCapture*`, dictation audio, system/pinned mic capture); database and schema (`*Migration*`, `*Schema*`, `*Database*.swift`, `SQLite*.swift`, the speaker reassignment log); permissions (`*TCC*`, `*Permission*.swift`, `*Entitlement*`); `Package.swift` | One approval from someone other than the author |
| `risk:medium` | Normal bug fixes: source changes under `Sources/**` or `Tools/*/Sources/**` that aren't high or low. Any path not listed anywhere is **high** (fail closed) | None (auto-merge) |
| `risk:low` | Only tests, docs (`*.md`), copy (`*.strings`), review images; or a small isolated fix: at most 2 source files and 40 changed source lines, **with** a test file changed | None (auto-merge) |

An empty or incomplete file list (GitHub stops at 3,000 files) is treated as high.

The label is informational. The gate recomputes the tier from the file list every time, so removing or editing a label changes nothing.

## 2. AI review

On every push the triage job sends the PR diff to an AI model and posts (or updates) one comment with the tier, the reasons and the findings, each tagged `[P0]` (data loss, security, crash), `[P1]` (a real bug users will hit), `[P2]` or `[P3]`. A hidden verdict line records the head commit and the P0/P1 counts.

- **Provider secret:** none exists today. Add repo secret `AI_REVIEW_API_KEY` (Anthropic by default). Optional repo variables: `AI_REVIEW_PROVIDER` (`anthropic` or `openai`) and `AI_REVIEW_MODEL`.
- **Degrades safely:** no key, a provider error, an unparseable answer, a diff over 120,000 characters, or a review for an older commit all count as *no AI result*, and **no AI result means no auto-merge**.
- The P0/P1 count is the larger of the model's `COUNTS` line and the number of tagged findings, so an under-reported count can't clear the gate.
- **Resolving findings:** push a fix (the next review must come back clean), or, if Justin judges a finding wrong, he adds the label `ai-findings-waived`. The gate only honours that label when @r3dbars added it.
- The diff is untrusted input. The prompt tells the model to ignore instructions in it, but an AI "clear" is never enough on its own: high-risk PRs still need people.
- Fork PRs get a label but no AI call.

## 3. The merge gate

The gate publishes a commit status named `risk-gate` on the PR head. It is `success` only when **all** of these hold:

1. Not a draft, branch is in this repo (forks never auto-merge), and no `hold`, `do not merge`, `needs owner review`, `waiting-on-human` or `blocked` label.
2. `build-and-test` and `repo-hygiene` both concluded `success` on the head commit. Skipped, neutral, cancelled, pending and missing never count as green; the newest run of each check wins.
3. The AI review exists for the head commit and has no unresolved P0/P1.
4. High only: the latest review of at least one person other than the author is an approval of the head commit, no one's latest review requests changes, and for release/signing paths @r3dbars is among the approvers.

When `risk-gate` is `success` and the PR is low or medium, the gate runs `gh pr merge --auto --squash --match-head-commit <sha>`. **High PRs are never auto-merged**; a person merges them once `risk-gate` is green.

It runs on PR events, when Swift CI or Repo Hygiene finishes, every 20 minutes, and by hand:

```bash
python3 scripts/ops/risk-triage.py classify Sources/UI/Foo.swift Tests/FooTests.swift  # offline tier
python3 scripts/ops/risk-triage.py triage --pr 2190          # dry run: print label + comment
python3 scripts/ops/risk-triage.py gate --pr 2190            # dry run: print the decision
python3 scripts/ops/risk-triage.py gate --apply              # what the workflow does, every open PR
```

## 4. Why `pull_request_target` is safe here

The workflow needs a write token and the AI secret, so it uses `pull_request_target`, which runs the workflow file from `main`, not from the PR. It checks out only the base or default branch (`persist-credentials: false`) and reads the PR's files and diff through the API as data. It never checks out, builds or runs PR code. There is deliberately no `pull_request_review` trigger, because that event runs the PR's own copy of the workflow.

A PR could add a workflow that posts a fake `risk-gate` status. That's why every file under `.github/workflows/` is high plus owner in the classifier and owned by @r3dbars in `CODEOWNERS`: with code-owner review required on `main`, such a PR can't merge without Justin.

## 5. CODEOWNERS

`.github/CODEOWNERS` assigns the release, signing, update-feed, entitlement, workflow and merge-policy paths to @r3dbars. It does nothing until "Require review from Code Owners" is on for `main` (below). Keep it in sync with `RELEASE_PATTERNS` in the script.

## 6. Repo settings this needs (owner applies; agents don't)

Read 2026-10-09: `allow_auto_merge` is off; squash, merge and rebase merges are all allowed; branch protection requires `build-and-test` and `repo-hygiene` (not strict), 0 approvals, no code-owner review, conversation resolution on, admins enforced; no rulesets; no AI provider secret.

1. Turn on auto-merge: `gh api -X PATCH repos/r3dbars/transcripted -F allow_auto_merge=true`
2. Add `risk-gate` to the required checks (after this PR is merged and has posted at least once):
   `gh api -X POST repos/r3dbars/transcripted/branches/main/protection/required_status_checks/contexts -f 'contexts[]=risk-gate'`
3. Require code-owner review (approval count stays 0, so only owned paths need one):
   `gh api -X PATCH repos/r3dbars/transcripted/branches/main/protection/required_pull_request_reviews -F require_code_owner_reviews=true -F dismiss_stale_reviews=true`
4. Add the AI key: `gh secret set AI_REVIEW_API_KEY -R r3dbars/transcripted` (and optionally `gh variable set AI_REVIEW_PROVIDER -R r3dbars/transcripted -b anthropic`).
5. Optional: `gh secret set AUTOMERGE_TOKEN -R r3dbars/transcripted` with a fine-grained token (contents, pull requests and statuses write), so auto-merges trigger push CI on `main`. Merges made with the default `GITHUB_TOKEN` don't start other workflows.
6. Create the labels: `for l in risk:low risk:medium risk:high ai-findings-waived; do gh label create "$l" -R r3dbars/transcripted; done`

Until steps 1 and 2 are done the workflow only labels, comments and posts statuses; nothing merges.

## Turning it off

Disable the workflow (`gh workflow disable "Risk Triage" -R r3dbars/transcripted`), or add `hold` to a single PR. Removing `risk-gate` from required checks undoes step 2.

## Hardening notes

- `AGENTS.md` and `CLAUDE.md` (any directory) are high risk: they steer every engineer agent.
- Owner-authored high-risk PRs: GitHub won't let an author approve their own PR, so when @r3dbars is the author and no other approval exists, `risk-gate` goes green as "owner merges manually". It still never auto-merges; merging by hand is the owner's sign-off.
- A review requesting changes blocks the gate at every risk level.
- `ai-findings-waived` only counts when @r3dbars added it after the current head commit was committed. A new push voids the waiver.
- The `risk-gate` status is always posted with the workflow's `GITHUB_TOKEN`, so it is attributed to the GitHub Actions app; branch protection pins the required check to that app (app_id 15368).
- If a PR has auto-merge enabled but the gate no longer passes (or it is high risk), the gate turns auto-merge off.
