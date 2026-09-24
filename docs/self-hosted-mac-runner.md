# Self-hosted Mac runner

GitHub gives this account 5 concurrent hosted macOS jobs, and every PR's Swift
CI run needs 3 of them (`checks`, `spm-tests`, `app-build`). With many PRs open,
most of them wait in line. So `checks` and `spm-tests` can run on the owner's
Mac, and only `app-build` has to use a hosted slot.

Every Mac job runs in a fresh throwaway macOS VM, never on the Mac itself.

## How a run picks its machine

`pick-runner` in `.github/workflows/swift-ci.yml` runs first, on Linux, and
calls `scripts/ci/pick-ci-runner.py`. It sends `checks` and `spm-tests` to the
`transcripted-mac` label only when all of these hold:

- the `MAC_RUNNER_MODE` repo variable is not `off`
- the run is a `push`, a `workflow_dispatch`, or a `pull_request` whose head
  branch lives in this repo (fork PRs always stay hosted)
- the `MAC_RUNNER_HEARTBEAT` repo variable is a Unix timestamp no more than 60s old
- no other run already has a Mac job queued or running. This is checked with
  the run's read-only `GITHUB_TOKEN`, so a burst of pushes goes to hosted
  instead of piling up behind one Mac.

Anything else goes to hosted `macos-26`, including a GitHub API error. If no
heartbeat is set, nothing changes from before.

## How the Mac runs a job

A launch agent in the owner's account (`mac-runner.sh serve`) loops:

1. It clones a stopped "golden" VM. Clones are APFS copy-on-write, so this
   takes seconds.
2. It asks GitHub for a just-in-time runner registration that is good for one
   job only (`generate-jitconfig`) and puts it in a folder the VM mounts
   read-only.
3. It boots the VM with no host audio and no clipboard sharing. The VM logs in
   to its own desktop, starts the runner, runs one job, and powers off.
4. It deletes the VM and the registration, then starts over.

While the VM's runner is up and idle, the service writes the current time to
the heartbeat. Otherwise it writes a word, and new runs go hosted right away:

| Word      | Meaning                                                    |
|-----------|------------------------------------------------------------|
| `paused`  | the owner ran `pause`                                      |
| `battery` | the Mac is not plugged in                                  |
| `offline` | no runner is ready yet (a VM is booting, or between jobs)  |
| `busy`    | a job is running                                           |
| `mic`     | a microphone is in use (a meeting, dictation, or a call)   |

While a job runs, the service keeps the Mac from idle-sleeping
(`caffeinate -i`). When the Mac sleeps, the heartbeat stops and goes stale
within 60s.

`app-build` never uses the Mac. Its launch smoke stays on hosted runners
(`scripts/ops/native-smoke-isolation.py`).

## What a job can and can't reach

A job runs as the VM's own user, inside a VM that gets deleted afterwards.

- **It can't reach:** the owner's files, keychain, gh login, microphone,
  clipboard, or app data. It also can't leave anything behind for the next
  job, since every job starts from a fresh clone.
- **Its only host input** is the read-only shared folder that holds its
  one-job runner registration.
- **Network:** the VM uses Tart's default NAT networking, so it can reach the
  internet, the local network, and services listening on the Mac, like any
  device on the same Wi-Fi.

The owner's gh login stays in the owner's account. Only the service and the
`install`/`rebuild`/`uninstall` commands use it, and they run as the owner.

## Keeping fork code off the Mac

This repo is public, so anyone can open a fork PR, and a fork can edit the
workflow to ask for the Mac's label. Here's what stops that:

1. `install` sets the repo's fork PR policy to require approval for every
   outside contributor, and it reads the setting back. No fork workflow runs
   until the owner clicks "Approve and run". Never do that for a fork PR that
   touches `.github/`.
2. `pick-runner` never routes a fork PR to the Mac.
3. A job-started hook inside the VM runs before any step. It starts from an
   empty environment, reads the event payload, and fails every job that isn't
   a `push`, `workflow_dispatch`, or same-repo `pull_request` on this repo.
   Building the golden VM proves the hook refuses a fork PR and accepts a
   same-repo push. If that check fails, the image isn't kept.

The hook is defense in depth. The runner starts it with `bash`, and GitHub
doesn't document whether a workflow's own `env:` (for example `BASH_ENV`)
reaches that first `bash`. Even if something got past all three, it would land
in a throwaway VM.

`install` also refuses to go on while any runner not named `transcripted-mac-*`
is registered on the repo, since another runner wouldn't be in a VM.

## Setup on the Mac

The owner runs this once from a checkout of `main`, as themself, never with
sudo. It needs no passwords:

```bash
bash scripts/ci/mac-runner.sh install
```

It needs `gh` logged in as a repo admin, Xcode, and about 120 GB free. It:

1. checks the Mac, the repo's runners, and the fork PR approval policy
2. installs the pinned, checksum- and signature-checked Tart from
   `scripts/vm/transcripted-vm.sh` into `~/.transcripted-ci`
3. builds the small microphone check (`mic-in-use`)
4. downloads the CI image (`MAC_RUNNER_IMAGE`, default Cirrus Labs'
   `macos-tahoe-xcode`, tens of GB)
5. builds the golden VM: installs the latest runner (SHA-256 checked) and the
   hook, then proves the hook works
6. starts the service

Job VMs get half the Mac's CPU cores (at least 4) and 8 GB of memory. Change
that with `MAC_RUNNER_CPU` / `MAC_RUNNER_MEMORY_MB` and `rebuild`. An idle
VM that's waiting for a job keeps its memory. The golden VM is rebuilt
automatically when it's 14 days old, which picks up newer runners.

## Day to day

```bash
bash ~/.transcripted-ci/mac-runner.sh status     # every repo runner, heartbeat, VMs, disk
bash ~/.transcripted-ci/mac-runner.sh pause      # new runs go hosted; a running job finishes
bash ~/.transcripted-ci/mac-runner.sh resume
bash ~/.transcripted-ci/mac-runner.sh rebuild    # fresh golden VM now
bash ~/.transcripted-ci/mac-runner.sh uninstall  # removes the service, VMs, images and state
```

Pause before timing-sensitive local work, like benchmarks or speed tests, so a
CI job doesn't skew the numbers. To turn routing off from GitHub without
touching the Mac, set the `MAC_RUNNER_MODE` repo variable to `off`.

Logs live in `~/.transcripted-ci/serve.log` and `~/.transcripted-ci/logs/`.

## Known limits

- **Sleep:** a run routed to the Mac in the last seconds before it sleeps waits
  until the Mac wakes. A job that's running when the lid closes fails.
- **Re-runs:** after a Mac failure, use "Re-run all jobs". "Re-run failed
  jobs" reuses the old `pick-runner` choice and sends the job back to the Mac.
- **One job at a time:** the Mac runs one job at a time, so a run's `checks`
  and `spm-tests` go one after the other when both land there. The second
  one waits for the next VM.
- **Mic check false positives:** the `mic` check counts any running device
  that has input streams. AirPods playing music read as `mic`. That only means
  fewer Mac runs.
- **Public logs** show the VM's `/Users/admin/...` paths, and the heartbeat
  variable shows whether the Mac is plugged in or paused.
