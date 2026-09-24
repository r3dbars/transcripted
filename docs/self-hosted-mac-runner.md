# Self-hosted Mac runner

GitHub gives this account 5 concurrent hosted macOS jobs, and every PR's Swift
CI run needs 3 (`checks`, `spm-tests`, `app-build`). With many PRs open most
of them wait in line. So `checks` and `spm-tests` can run on the owner's Mac
instead, and only `app-build` has to use a hosted slot.

## How a run picks its machine

`pick-runner` in `.github/workflows/swift-ci.yml` runs first on Linux and calls
`scripts/ci/pick-ci-runner.sh`. It sends `checks` and `spm-tests` to
`[self-hosted, transcripted-mac]` only when all of these hold:

- the `MAC_RUNNER_MODE` repo variable is not `off`
- the run is a `push`, `workflow_dispatch`, or a `pull_request` whose head
  branch lives in this repo (fork PRs always stay hosted)
- the `MAC_RUNNER_HEARTBEAT` repo variable is a Unix timestamp no more than
  150s old

Anything else goes to hosted `macos-26`, the same as before this existed. With
no heartbeat set, nothing changes.

The Mac writes the heartbeat every 30s from a launchd agent
(`scripts/ci/mac-runner.sh heartbeat`). It writes the current time when at
least one of its runners is online and idle, and `busy`, `paused`, or
`battery` otherwise, so new runs flip to hosted right away instead of waiting
behind the Mac. When the Mac sleeps the heartbeat stops and goes stale within
150s.

`app-build` never uses the Mac. Its launch smoke only runs on an isolated
account (`scripts/ops/native-smoke-isolation.py`), and the owner's login isn't
one.

## Safety

This repo is public, so anyone can open a fork PR, and a fork can edit the
workflow to target the Mac's labels. Three layers keep fork code off the Mac:

1. `pick-runner` never routes a fork PR to the Mac.
2. Each runner has a job-started hook (`mac-runner.sh job-started-hook`) that
   runs before any step. It fails every job that is not a `push`,
   `workflow_dispatch`, or same-repo `pull_request` on this repo. This is the
   one that holds even when a fork rewrites the workflow.
3. `install` sets the repo's fork PR policy to require approval for every
   outside contributor, so no fork workflow runs until the owner approves it.

The jobs run as the owner's macOS user, the same way `bash run-tests.sh` and
`swift test` run for any contributor working locally. Runner work dirs live
under `~/actions-runners/transcripted-N/_work`, never in `~/transcripted`.
The runners also set `TRANSCRIPTED_DISABLE_FILE_LOGGER=1`, so test binaries
never write to the real app logs.

## Setup on the Mac

From a checkout of `main`:

```bash
bash scripts/ci/mac-runner.sh install
```

It needs `gh` logged in as a repo admin. It registers two runners
(`transcripted-mac-1`, `transcripted-mac-2`; set `MAC_RUNNER_COUNT` to change),
installs them as launchd services, installs the heartbeat agent, and prints
`status`. It copies itself into `~/actions-runners/`, so switching branches in
the checkout later doesn't change what the services run. Re-running it is safe.

## Day to day

```bash
bash ~/actions-runners/mac-runner.sh status     # runners, heartbeat, pause state
bash ~/actions-runners/mac-runner.sh pause      # new runs go hosted; running jobs finish
bash ~/actions-runners/mac-runner.sh resume
bash ~/actions-runners/mac-runner.sh uninstall  # unregister everything
```

Pause the Mac before timing-sensitive local work (benchmarks, speed tests), so
CI jobs don't skew the numbers. To turn routing off from GitHub without
touching the Mac, set the `MAC_RUNNER_MODE` repo variable to `off`.

## Known limits

- A run routed to the Mac in the few seconds before it sleeps waits until the
  Mac wakes. A job running when the lid closes fails when the runner drops, and
  needs a re-run or a new push.
- A burst of pushes inside one heartbeat window can all land on the Mac and
  queue there. The next heartbeat says `busy` and later runs go hosted.
- The dispatch-only `hardware-smokes` job targets `[self-hosted, macOS, ARM64]`,
  which these runners also match. It needs the runner to hold Microphone and
  System Audio Recording grants, which this setup doesn't give it.
