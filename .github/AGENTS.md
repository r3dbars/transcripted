# .github

Workflows, templates, and the CI contracts that gate merges. Repo-wide rules live in `AGENTS.md`; this file covers only what bites when you edit a workflow.

## Workflows

| File | Runs | Notes |
|------|------|-------|
| `workflows/swift-ci.yml` | PRs, pushes to main, manual | Jobs `checks`, `spm-tests`, `app-build` run in parallel; `build-and-test` aggregates them. Also `hardware-smokes`, `full-qa-bench`, `staged-update-proof` (manual inputs). |
| `workflows/repo-hygiene.yml` | PRs | Ubuntu; runs `scripts/dev/linux-checks.sh --strict-tools`. |
| `workflows/concurrency-census.yml` | PRs and pushes touching `Sources/` | Fails only if a folder is above `.agents/concurrency-baseline.json` and above the PR base (`--allow-up-to`), so toolchain drift alone passes. |
| `workflows/transcripted-lab.yml` | `Tools/TranscriptedLab/**` changes | Builds and tests that package on `macos-15`. |
| `workflows/release-candidate.yml` | Manual only | Builds, signs, notarizes, and builds Sparkle metadata. Uses the signing secrets. |
| `workflows/publish-mcp-registry.yml` | Release published, manual | Repackages the already-signed `transcripted-mcp` into a `.mcpb`; builds and signs nothing. OIDC login, no secret. |
| `workflows/mac-runner-sweep.yml` | Every 30 min | Re-runs Swift CI on hosted runners if the owner's Mac went quiet. |
| `workflows/mutation-monthly.yml` | 1st of the month | Report-only mutation probe on the `transcripted-mac` runner. |

## Rules

- **Keep the job id `build-and-test`.** Branch protection requires that status context. If you split or rename jobs, the umbrella keeps its id, uses `if: always()`, and asserts every upstream job succeeded. Otherwise the required check is orphaned or silently skipped.
- **Every `Tools/*` Swift package must run in a workflow** (usually `swift-ci.yml`, or its own file like `transcripted-lab.yml`). `scripts/dev/check-known-traps.py` fails otherwise. New package: add the job and a test-matrix rule in `.agents/test-matrix.yml`.
- **App Swift jobs need macOS 26.** The sources use macOS-only SDKs and target `arm64-apple-macos26.0`. `transcripted-lab.yml` is the exception (`macos-15`, package only).
- **Runner choice.** `checks` and `spm-tests` go to the owner's Mac only when `scripts/ci/pick-ci-runner.py` says so (heartbeat fresh, no other job queued, not a fork PR). Any API error falls back to hosted `macos-26`. `app-build` always stays hosted. Details: `docs/self-hosted-mac-runner.md`, `scripts/ci/mac-runner.sh`.
- **Secrets.** Only `release-candidate.yml` reads signing secrets (`DEVELOPER_ID_CERT`, `DEVELOPER_ID_PASSWORD`, `APPLE_ID`, `APPLE_APP_PASSWORD`, `APPLE_TEAM_ID`, `SPARKLE_PRIVATE_KEY`). Never echo them, never pass them to a step that runs PR code, never add them to a PR-triggered workflow. Keep `permissions:` minimal; widen per job, not per file.
- **Release Candidate is trusted-input only.** It rejects a `source_ref` that lacks the current `origin/main` tip or differs from main in anything but `Info.plist`, and rejects an existing `v<version>` release. Don't loosen those checks. Tag the workflow's `source_ref`, not the run's head SHA.
- **Don't push empty commits to retrigger CI**, and Claude sessions can't re-run Actions jobs. Say which check is unproven.
- **Sweep and mutation workflows do nothing until the Mac runner exists** (no heartbeat variable). Keep that guard.

## Editing a workflow

- Path filters list the workflow's own file so a change to it triggers it. Match the existing pattern (the `push` filter in some files omits it on purpose).
- Prefer calling a script in `scripts/` over long inline `run:` blocks, so it can be tested locally. Every new script needs a caller; see `scripts/README.md`.
- `python3 scripts/dev/check-known-traps.py` and `bash scripts/dev/linux-checks.sh` run on Linux and catch most workflow mistakes. Nothing runs the workflow itself locally.

## Templates

`ISSUE_TEMPLATE/agent_task.md`, `bug_report.md`, `feature_request.md`, and `PULL_REQUEST_TEMPLATE.md`. The PR template carries the review-verdict and verification fields from `AGENTS.md`; keep them in sync if the review policy changes.
