# Self-hosted Mac runner

GitHub gives this account 5 concurrent hosted macOS jobs, and every PR's Swift
CI run needs 3 (`checks`, `spm-tests`, `app-build`). With many PRs open, most
of them wait in line. So `checks` and `spm-tests` can run on the owner's Mac,
which leaves only `app-build` needing a hosted slot.

## How a run picks its machine

`pick-runner` in `.github/workflows/swift-ci.yml` runs first, on Linux, and
calls `scripts/ci/pick-ci-runner.py`. That script sends `checks` and
`spm-tests` to the `transcripted-mac` runner only when all of these hold:

- the `MAC_RUNNER_MODE` repo variable is not `off`
- the run is a `push`, a `workflow_dispatch`, or a `pull_request` whose head
  branch lives in this repo (fork PRs always stay hosted)
- the `MAC_RUNNER_HEARTBEAT` repo variable is a Unix timestamp at most 60s old
- no other run already has a Mac job queued or running (checked with the
  run's read-only `GITHUB_TOKEN`), so a burst of pushes goes to hosted instead
  of piling up behind one Mac

Anything else goes to hosted `macos-26`, including a GitHub API error. If no
heartbeat is set, nothing changes from before.

The Mac writes the heartbeat every 20s from a launchd agent in the owner's
account (`mac-runner.sh heartbeat`). It writes the current time only when the
Mac is free. Otherwise it writes one of these words, and new runs go hosted
right away:

| Word      | Meaning                                                  |
|-----------|----------------------------------------------------------|
| `paused`  | the owner ran `pause`                                    |
| `battery` | the Mac is not plugged in                                |
| `offline` | the runner isn't running (CI account not logged in)      |
| `busy`    | a job is already running                                 |
| `mic`     | a microphone is in use (a meeting, dictation, or a call) |

When the Mac sleeps, the heartbeat stops and goes stale within 60s. While a
job is running, the heartbeat keeps the Mac from idle-sleeping (`caffeinate -i`).

`app-build` never uses the Mac. Its launch smoke stays on hosted runners
(`scripts/ops/native-smoke-isolation.py`).

## The CI account

Jobs never run as the owner. `install` creates a separate standard (non-admin)
macOS account, "Transcripted CI" (`transcripted-ci`). That account:

- has its own group, is not in `staff` or `admin`, and has a `700` home folder
- has no gh login, keychain identities, or signing certificates
- runs one runner, `transcripted-mac-1`, from `/Users/transcripted-ci/actions-runner`
- is registered with `--no-default-labels`, so its only label is
  `transcripted-mac`, and jobs that ask for generic `self-hosted`/`macOS`
  labels (like `hardware-smokes`) never land on it
- starts the runner from a root-owned launch agent
  (`/Library/LaunchAgents/com.transcripted.ci-runner.plist`) that runs only in
  that account's own login session, at `Nice` 10

The runner needs a logged-in session because the fast tests use AppKit and the
pasteboard, the same as on GitHub's hosted Macs. So the owner logs in to the CI
account once after each restart (fast user switching) and switches back.
Until then the heartbeat says `offline` and everything runs hosted.

The owner's gh login stays in the owner's account. It is used only by
`install`/`uninstall` and by the heartbeat, which runs as the owner.

## Keeping fork code off the Mac

This repo is public, so anyone can open a fork PR, and a fork can edit the
workflow to ask for the Mac's label. Three things stand in the way:

1. `install` sets the repo's fork PR policy to require approval for every
   outside contributor. No fork workflow runs until the owner clicks
   "Approve and run", and the owner should never do that for a fork PR that
   touches `.github/`. This is the hard line.
2. `pick-runner` never routes a fork PR to the Mac.
3. The runner's job-started hook (`/Library/TranscriptedCI/job-started-hook.sh`,
   root-owned) runs before any step. It starts from an empty environment, reads
   the event payload, and fails every job that isn't a `push`,
   `workflow_dispatch`, or same-repo `pull_request` on this repo.

The hook is defense in depth, not a sandbox. The runner starts it with `bash`,
and GitHub's docs don't say whether a workflow's own `env:` (for example
`BASH_ENV`) reaches that first `bash`. If a fork workflow were ever approved,
that could run code before the hook's first line. So point 1 is the real
guard. If something did get through, it would land in the CI account, which
can't read the owner's files, keychain, or gh login.

`install` also refuses to go on while any other runner is registered on the
repo, since another runner would have no hook.

## Setup on the Mac

The owner runs this from a checkout of `main`, as themself, never with sudo:

```bash
bash scripts/ci/mac-runner.sh install
```

It needs `gh` logged in as a repo admin and Xcode installed. It:

1. checks that no other runner is registered, and sets the fork PR approval policy
2. downloads the latest runner and checks its SHA-256 against GitHub's
3. builds the small microphone check (`mic-in-use`)
4. the first time only, asks for a password for the new account (twice, in a
   macOS dialog)
5. asks for the owner's Mac password once, in the standard macOS admin prompt,
   to create the account, install `/Library/TranscriptedCI`, register the
   runner as the CI account, and install the launch agent
6. starts the heartbeat in the owner's account

After that, the owner logs in to "Transcripted CI" once and switches back.
Re-running `install` is safe.

## Day to day

```bash
bash /Library/TranscriptedCI/mac-runner.sh status   # every repo runner, heartbeat, pause, login state
bash /Library/TranscriptedCI/mac-runner.sh pause    # new runs go hosted; a running job finishes
bash /Library/TranscriptedCI/mac-runner.sh resume
bash /Library/TranscriptedCI/mac-runner.sh uninstall  # removes the runner, the CI account, and the heartbeat
```

Pause before timing-sensitive local work, like benchmarks or speed tests, so a
CI job doesn't skew the numbers. To turn routing off from GitHub without
touching the Mac, set the `MAC_RUNNER_MODE` repo variable to `off`.

## Known limits

- A run routed to the Mac in the last seconds before it sleeps waits until the
  Mac wakes. A job that's running when the lid closes fails when the runner drops.
- Use **Re-run all jobs**, not "Re-run failed jobs", after a Mac failure.
  "Re-run failed jobs" reuses the old `pick-runner` choice and sends the job
  back to the Mac. "Re-run all jobs" picks again.
- The `mic` check counts any running device that has input streams. A USB
  audio interface that's playing sound can read as `mic`.
- Public job logs show `/Users/transcripted-ci/...` paths, and the heartbeat
  variable shows whether the Mac is plugged in or paused.
