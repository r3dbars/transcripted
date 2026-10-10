# Agent merge policy: risk-based auto-merge

Every PR gets a risk label. Low and medium PRs squash-merge on their own once CI is green and the AI review found nothing serious. High-risk PRs need a person. **Releases stay manual**: nothing here tags, builds, signs, notarizes or publishes.

The code is `scripts/ops/risk-triage.py`, run by `.github/workflows/risk-triage.yml`. Tests: `python3 scripts/ops/test-risk-triage.py` (also part of `scripts/dev/linux-checks.sh`, so `repo-hygiene` runs them).

This sits next to the older lane gate (`docs/auto-merge-gate.md`, `scripts/ops/auto-merge-gate.py`), which still runs on its own. A PR merges when either path allows it; both demand green `build-and-test` and `repo-hygiene`. **The old gate also runs this classifier and never merges a PR it calls `risk:high`**, whatever its lane allows. So a lane PR that deletes a test, renames one away, or edits a folder `AGENTS.md` now waits for Justin.

## 1. Risk tiers

Path rules decide the tier. Each changed file (and the old name of a renamed file) is checked, and **the highest match wins**.

| Tier | What | Who must approve |
|---|---|---|
| `risk:high` + owner | Release, version, Sparkle, appcast, cask, signing and notarization: `scripts/release/**`, `build*.sh`, `Casks/**`, `**/appcast*.xml`, `Info.plist` files, `server.json`, `glama.json`, `config/entitlements/**`, `*.entitlements`, any path containing `Sparkle`, `notari`, `codesign` or `Signing`, `TranscriptedAppVersion.swift`. Also every GitHub workflow and action, `CODEOWNERS`, and this policy's own files. | One approval from someone other than the author, **and** an approval from @r3dbars |
| `risk:high` | Audio capture (`Sources/TranscriptedCore/Audio/**`, `Sources/Capture/**`, `MeetingCapture*`, `MeetingMicCapture*`, dictation audio, system/pinned mic capture); database and schema (`*Migration*`, `*Schema*`, `*Database*.swift`, `SQLite*.swift`, the speaker reassignment log); permissions (`*TCC*`, `*Permission*.swift`, `*Entitlement*`); `Package.swift` | One approval from someone other than the author |
| `risk:medium` | Normal bug fixes: source changes under `Sources/**` or `Tools/*/Sources/**` that aren't high or low, up to **400 changed lines** (additions plus deletions across the whole PR); a bigger medium PR counts as **high**. Debt baselines (`.agents/*-baseline.json`, except the concurrency baseline) are medium. Any path not listed anywhere is **high** (fail closed) | None (auto-merge) |
| `risk:low` | Only tests, docs (`*.md`), copy (`*.strings`), review images; or a small isolated fix: at most 2 source files and 40 changed source lines, **with** a test file changed | None (auto-merge) |

Tests:
- **Modified tests keep the PR's tier.** Most fixes edit existing tests. Weakened assertions are left to CI and the AI review's P0/P1.
- **Deleted tests are high**, and so are tests **renamed out of the test folders** (`Tests/**`, `Tools/*/Tests/**`, `test_*.py`, `test-*.py`). A rename that stays inside the test folders keeps the tier.

An empty or incomplete file list (GitHub stops at 3,000 files) is treated as high, and it needs Justin.

The label is informational. The gate recomputes the tier from the file list every time, so removing or editing a label changes nothing.

## 2. AI review

On every push the triage job sends the PR diff to an AI model and posts (or updates) one comment with the tier, the reasons and the findings, each tagged `[P0]` (data loss, security, crash), `[P1]` (a real bug users will hit), `[P2]` or `[P3]`. A hidden verdict line records the head commit and the P0/P1 counts.

- **Provider secret:** none exists today. Add repo secret `AI_REVIEW_API_KEY` (Anthropic by default). Optional repo variables: `AI_REVIEW_PROVIDER` (`anthropic` or `openai`) and `AI_REVIEW_MODEL`.
- **Degrades safely:** no key, a provider error, an unparseable answer, a diff over 120,000 characters, or a review for an older commit all count as *no AI result*, and **no AI result means no auto-merge**.
- The P0/P1 count is the larger of the model's `COUNTS` line and the number of tagged findings, so an under-reported count can't clear the gate.
- **Resolving findings:** push a fix (the next review must come back clean), or, if Justin judges a finding wrong, he adds the label `ai-findings-waived` and comments `ai-findings-waived <full head sha>`. The gate only honours that when @r3dbars did both, and only for low/medium: a waiver never lets a high-risk PR pass.
- The diff is untrusted input. The prompt tells the model to ignore instructions in it, but an AI "clear" is never enough on its own: high-risk PRs still need people.
- Fork PRs get a label but no AI call.

## 3. The merge gate

The gate publishes a commit status named `risk-gate` on the PR head. It is `success` only when **all** of these hold:

1. Not a draft, branch is in this repo (forks never auto-merge), and no `hold`, `do not merge`, `needs owner review`, `waiting-on-human` or `blocked` label.
2. `build-and-test` and `repo-hygiene` both concluded `success` on the head commit. Skipped, neutral, cancelled, pending and missing never count as green; the newest run of each check wins.
3. The AI review exists for the head commit and has no unresolved P0/P1.
4. No trusted reviewer's latest review requests changes.
5. The PR is low or medium. **A high-risk PR never gets `success`**, whoever authored it (agent PRs are authored by @r3dbars too), however many approvals it has, and with or without `ai-findings-waived`. Its status lists what's still missing (e.g. approvals) as a note for Justin.

When `risk-gate` is `success` and the PR is low or medium, the gate runs `gh pr merge --auto --squash --match-head-commit <sha>`. **High PRs are never auto-merged**: their `risk-gate` stays pending even after approvals, and Justin merges them by hand.

It runs on PR events, when Swift CI or Repo Hygiene finishes, every 20 minutes, and by hand:

```bash
python3 scripts/ops/risk-triage.py classify Sources/UI/Foo.swift Tests/FooTests.swift  # offline tier
python3 scripts/ops/risk-triage.py triage --pr 2190          # dry run: print label + comment
python3 scripts/ops/risk-triage.py gate --pr 2190            # dry run: print the decision
python3 scripts/ops/risk-triage.py gate --apply              # what the workflow does, every open PR
```

## 4. Why `pull_request_target` is safe here

The workflow needs a write token and the AI secret, so it uses `pull_request_target`, which runs the workflow file from `main`, not from the PR. It checks out only the base or default branch (`persist-credentials: false`) and reads the PR's files and diff through the API as data. It never checks out, builds or runs PR code. There is deliberately no `pull_request_review` trigger, because that event runs the PR's own copy of the workflow.

A PR could add a workflow that posts a fake `risk-gate` status. That's why every file under `.github/workflows/` is high plus owner in the classifier and owned by @r3dbars in `CODEOWNERS`: high risk never passes `risk-gate` automatically, so such a PR can't merge without Justin merging it by hand.

## 5. CODEOWNERS

`.github/CODEOWNERS` assigns the release, signing, update-feed, entitlement, workflow and merge-policy paths to @r3dbars. It only routes review requests: "Require review from Code Owners" stays off (see setup step 3), because @r3dbars authors most PRs, agent PRs included, and GitHub never counts an author's own approval. Keep it in sync with `RELEASE_PATTERNS` in the script.

## 6. Repo settings this needs (owner applies; agents don't)

Read 2026-10-09: `allow_auto_merge` is off; squash, merge and rebase merges are all allowed; branch protection requires `build-and-test` and `repo-hygiene` (not strict), 0 approvals, no code-owner review, conversation resolution on, admins enforced; no rulesets; no AI provider secret.

1. Turn on auto-merge: `gh api -X PATCH repos/r3dbars/transcripted -F allow_auto_merge=true`
2. Do **not** add `risk-gate` to the required checks. High-risk PRs keep `risk-gate` pending forever by design, and with admins enforced a required pending check would block Justin's manual merge too. The gate enforces itself instead: it is the only thing that turns on auto-merge, and only for a green low/medium PR. Nothing to run for this step.
3. Dismiss stale approvals on new pushes (code-owner review stays off):
   `gh api -X PATCH repos/r3dbars/transcripted/branches/main/protection/required_pull_request_reviews -F dismiss_stale_reviews=true` (do not enable require_code_owner_reviews: GitHub never counts self-approval, and with admins enforced it would lock @r3dbars out of their own release PRs)
4. Add the AI key: `gh secret set AI_REVIEW_API_KEY -R r3dbars/transcripted` (and optionally `gh variable set AI_REVIEW_PROVIDER -R r3dbars/transcripted -b anthropic`).
5. Optional: `gh secret set AUTOMERGE_TOKEN -R r3dbars/transcripted` with a fine-grained token (contents, pull requests and statuses write), so auto-merges trigger push CI on `main`. Merges made with the default `GITHUB_TOKEN` don't start other workflows.
6. Create the labels: `for l in risk:low risk:medium risk:high ai-findings-waived; do gh label create "$l" -R r3dbars/transcripted; done`

What the settings change, exactly:
- Before step 1, GitHub refuses `gh pr merge --auto`, so the gate can't merge anything; it only labels, comments and posts `risk-gate`. Manual merges work as today (they need `build-and-test` and `repo-hygiene`).
- After step 1, the gate turns on squash auto-merge for low/medium PRs whose `risk-gate` is green, and turns it off again if a later push breaks the gate.
- `risk-gate` is never a required check, so branch protection does not stop a person (or an agent with merge rights) from merging by hand while it is pending. Agents must not merge high-risk PRs; Justin merges those by hand.
- High-risk PRs never auto-merge: `risk-gate` stays pending for them whoever the author is, approvals and `ai-findings-waived` included.

## Turning it off

Disable the workflow (`gh workflow disable "Risk Triage" -R r3dbars/transcripted`), or add `hold` to a single PR. Turning `allow_auto_merge` back off (`gh api -X PATCH repos/r3dbars/transcripted -F allow_auto_merge=false`) stops every automatic merge.

## Hardening notes

- `AGENTS.md` and `CLAUDE.md` (any directory) are high risk: they steer every engineer agent.
- High-risk PRs never pass `risk-gate` automatically, whoever the author is (agent PRs on `cursor/*` and `agent/*` branches are also authored by @r3dbars). The gate stays pending and Justin merges them by hand; the `ai-findings-waived` label and comment never bypass high risk.
- A review requesting changes blocks the gate at every risk level.
- `ai-findings-waived` only counts when @r3dbars added the label and also commented `ai-findings-waived <full head sha>` for the current head. A new push voids the waiver.
- The `risk-gate` status is always posted with the workflow's `GITHUB_TOKEN`, so it is attributed to the GitHub Actions app.
- If a PR has auto-merge enabled but the gate no longer passes (or it is high risk), the gate turns auto-merge off.
- Release build entrypoints (`scripts/entrypoints/build*.sh`, `scripts/entrypoints/lib/`) are owner-required, like the root wrappers.
- Diffs are redacted (emails, home paths, credential-looking values) before any external AI call.
- Both jobs check out the default branch only. Reads and the `risk-gate` status use `GITHUB_TOKEN`; `AUTOMERGE_TOKEN` is used only for the merge call.
- A PR whose branch is behind its base never gets auto-merge enabled; it must be updated so CI reruns on current main.
- Code-owner review: GitHub never lets the author satisfy a code-owner review, and @r3dbars authors most PRs, so "Require review from Code Owners" stays **off**. Owner sign-off on release/signing paths comes from `risk-gate` (high, never auto-merged) plus the owner merging by hand.
- Redaction is pattern-based (emails, absolute paths, URLs, credential-looking values). It cannot recognise transcript text or names; keep real transcripts out of PR diffs.
- Known limit: a same-repo PR that adds a `pull_request` workflow could post its own `risk-gate` status (it is also the Actions app). Because `risk-gate` is not required and the gate itself only enables auto-merge after recomputing the verdict from the file list, a forged status can't make this gate merge anything; and workflow changes are high, so the gate never auto-merges them.
- Reviews count only from OWNER/MEMBER/COLLABORATOR; `Sources/Speech/**` is high; removing a test file or renaming it out of the test folders is high; medium over 400 changed lines is high; the old lane gate never merges a triage-high PR; privacy egress files (`*PayloadSanitizer*`, `*EventPolicy*`) are high; an empty or incomplete file list is high and owner-required; change requests from untrusted accounts are ignored; the behind-base guard applies to every green result, high included.
