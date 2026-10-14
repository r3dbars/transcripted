# Agent merge policy: risk-based auto-merge

Every PR gets a risk tier. Low and medium PRs may squash-merge on their own once CI is green and the AI review found nothing serious. **High-risk PRs are always merged by Justin, by hand.** Releases stay manual: nothing here tags, builds, signs, notarizes or publishes.

Code: `scripts/ops/risk-triage.py`, run by `.github/workflows/risk-triage.yml`. Tests: `python3 scripts/ops/test-risk-triage.py` (run by `scripts/dev/linux-checks.sh`, so `repo-hygiene` runs them). Design: `automerge-trust-design.md` (Option A, the GitHub App check run).

The older lane gate (`scripts/ops/auto-merge-gate.py`, `docs/auto-merge-gate.md`) uses this classifier and the same App-stored AI verdict, never merges a `risk:high` PR, and **only merges with the gate App's token** (`GATE_TOKEN`). Run from a Mac with a person's `gh` login, it refuses to merge.

## 1. The trusted signal

`risk-gate` is a **check run created by the `transcripted-gate` GitHub App**. Only that App's installation token can create check runs under its app id, and the ruleset requires `risk-gate` from that app. A PR's own workflow runs as the GitHub Actions app, so it cannot post a `risk-gate` that counts, and it cannot forge the AI verdict either: the verdict is stored in the App's check run (`output.text`), and both gates read it only from check runs whose `app.id` is `AUTOMERGE_APP_ID`.

The workflow has no `pull_request` or `pull_request_target` trigger. It runs on `workflow_run` (Swift CI / Repo Hygiene requested or completed), every 20 minutes, and by hand. Those always run the workflow file from `main`, which is also what lets the job use the main-only `automerge-app` environment holding the App key and the AI key. (GitHub blocks `pull_request_target` on public repos by default from 2026-11-02.) The job checks out `main` only and reads the PR's files and diff through the API; it never runs PR code.

**Until Justin creates the App** (`AUTOMERGE_APP_ID` unset) the gate only labels and logs: no trusted signal, no auto-merge.

## 2. Risk tiers

Each changed file, and the old name of a renamed file, is checked; **the highest match wins**. The tier is recomputed every run; the label is informational.

| Tier | What |
|---|---|
| `risk:high` (owner paths) | Release, version, Sparkle, appcast, cask, signing, notarization, entitlements, `Info.plist`, `server.json`, `glama.json`. **Every workflow and action, `CODEOWNERS`, the gate itself** (`risk-triage.py`, `test-risk-triage.py`, `auto-merge-gate.py`, the lane file, this doc) and the **CI harness** the required checks run (`scripts/ci/**`, `scripts/dev/linux-checks.sh`, `scripts/dev/agent-preflight.sh`, `scripts/dev/check-*.py`, `run-tests.sh`, `check.sh`, `run-*-smoke.sh`). |
| `risk:high` | Audio capture and `Sources/Speech/**`; database, schema, migrations, reassignment log; permissions/TCC/entitlements; privacy egress (sanitizers, redactors, scrubbers, `*Privacy*`, event policies, crash reporting, telemetry, all of `Sources/Observability/**`, analytics preferences); `Package.swift`; agent instructions and config (`AGENTS.md`, `CLAUDE.md`, `WORKFLOW.md`, `.claude/**`, `.codex/**`, `.cursor/**`, `.agents/**` except debt baselines, `**/skills/**`, `**/SKILL.md`, `.agent-review/*.md`, `.github/*.md`), checked before the `*.md` = low rule; and code the release-candidate job runs beside the signing keychain (`Tools/TranscriptedQA/**`, `scripts/ops/privacy-leak-sweep.py`, `scripts/entrypoints/**`, `Tools/*/Package.swift`, `Package.resolved`). `docs/appcast.xml` is the live Sparkle feed (`SUFeedURL` points at `main`), so merging it is releasing: owner path. |
| `risk:high` (owner-protected surfaces, from `AGENTS.md`) | Meeting detection and its prompt flow (`MicActivityMonitor`, `CameraActivityMonitor`, `MeetingPromptDetector*`, `MeetingPrompt*`, `AutoCallDetectionPreferences`); the Speakers directory (`SpeakerPeople*`, `SpeakerSettingsStore`); per-app Auto Enter (`DictationAutoSendPreferences`, `AutoEnter*`); model-cache inspection (`*ModelCache*`); the status item (`StatusItem*`); meeting-audio playback (`MeetingAudioPlayback*`). |
| `risk:high` (harness guards) | `AutomatedLaunchEnvironment*`, `NativeSmokeIsolation*`, `scripts/ops/native-smoke-isolation.py`, `scripts/vm/**`. |
| `risk:medium` | Other source changes up to **400 changed lines** for the whole PR (bigger is high). Debt baselines except the concurrency one. **Unknown paths are high.** |
| `risk:low` | Only tests, docs, copy; or at most 2 source files and 40 source lines **with a runnable test changed** (`.swift`, `.py`, `.sh`, `.rb` under the test folders; `Tests/README.md` or fixtures are not proof). |

Deleted tests, and tests renamed out of the test folders or to another extension, are high. Modified tests keep the PR's tier. An empty or incomplete file list is high.

## 3. AI review

Sent once per head commit; the verdict (head SHA, PR, status, P0/P1 counts) is stored in the App's `risk-gate` check run and reused for that commit. No key, a provider error, an unparseable answer, a diff over 120,000 characters, or a verdict for another commit all mean **no AI result, so no auto-merge**. The P0/P1 count is the larger of the model's `COUNTS` line and the tagged findings. Before the call, the diff is redacted: emails, URLs, credential-looking values, home directories and **any absolute path** (`/Applications/...`, `/workspace/...`, `~/...`). Fork PRs get no AI call.

There is **no waiver label** any more. A label or comment from @r3dbars proves nothing, because agents use that login too. If Justin thinks a finding is wrong, he merges by hand.

## 4. The gate decision

`risk-gate` concludes `success` only when all of these hold; otherwise a **high-risk PR concludes `failure`** ("Justin merges by hand") and anything else stays `in_progress` with the reasons. It is never `neutral` or `skipped`, which GitHub counts as passing a required check:

1. Not a draft, not a fork, no hold label (`hold`, `do not merge`, `needs owner review`, `waiting-on-human`, `blocked`, `automerge:off`).
2. `build-and-test` and `repo-hygiene` are **GitHub Actions check runs** (app 15368) that concluded `success` on the head commit. Commit statuses don't count. Any queued or in-progress run of a check (a rerun) means pending. A failure followed by a success on the same commit means **"passed on retry": pending**.
3. The App-stored AI verdict for the head commit has no P0/P1.
4. No trusted reviewer is requesting changes.
5. The PR is low or medium. **High never gets success**, whoever the author and whatever the approvals.
6. The branch isn't behind its base.
7. Kill switch: repo or environment variable `AUTOMERGE_ENABLED`. `true` posts success and arms squash auto-merge (`--match-head-commit`); `signal-only` posts success but never arms; anything else, or unset, holds everything.

Only the App token arms auto-merge; disabling it is done with any token, and happens before a new result is posted. An error on one PR fails that PR closed (auto-merge off, `risk-gate` in progress) and the sweep moves on.

```bash
python3 scripts/ops/risk-triage.py classify Sources/UI/Foo.swift Tests/FooTests.swift  # offline tier
python3 scripts/ops/risk-triage.py gate --pr 2190          # dry run: print the decision
```

## 5. No agent merges as Justin

Agents run `gh` as @r3dbars, so anything "only @r3dbars can do" is something every agent can do. So:
- No code path here merges or arms auto-merge with a person's token or `GITHUB_TOKEN`; only the gate App token. A test fails if any workflow or script calls `gh pr merge ... --admin`.
- The lane gate refuses to merge without `GATE_TOKEN`.
- What actually stops an agent with Justin's admin token from clicking merge is outside code: see "Justin only" in `automerge-trust-design.md` (a separate non-admin login for agents, and a ruleset whose admin bypass then only Justin holds).

## 6. CODEOWNERS

`.github/CODEOWNERS` routes review requests for owner paths to @r3dbars. "Require review from Code Owners" stays off: GitHub never counts an author's approval and @r3dbars authors most PRs.

## Turning it off

`gh variable set AUTOMERGE_ENABLED -R r3dbars/transcripted --env automerge-app -b false`, or add `automerge:off`/`hold` to one PR, or `gh workflow disable "Risk Triage" -R r3dbars/transcripted`.
