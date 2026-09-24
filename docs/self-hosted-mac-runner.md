# Self-hosted Mac runner

GitHub gives this account 5 concurrent hosted macOS jobs, and every PR's Swift
CI run needs 3 of them (`checks`, `spm-tests`, `app-build`). With many PRs open,
most of them wait in line. So `checks` and `spm-tests` can run on the owner's
Mac, and only `app-build` has to use a hosted slot.

Every Mac job runs in a fresh throwaway macOS VM, never on the Mac itself, and
a VM only exists while a job is waiting for it.

## How a run picks its machine

`pick-runner` in `.github/workflows/swift-ci.yml` runs first, on Linux, and
calls `scripts/ci/pick-ci-runner.py`. It sends `checks` and `spm-tests` to the
`transcripted-mac` label only when all of these hold:

- the `MAC_RUNNER_MODE` repo variable is not `off`
- the run is a `push`, a `workflow_dispatch`, or a `pull_request` whose head
  branch lives in this repo (fork PRs always stay hosted)
- the `MAC_RUNNER_HEARTBEAT` repo variable is a bare Unix timestamp no more
  than 60s old
- no other Swift CI run already has a Mac job queued or running, so a burst of
  pushes goes to hosted instead of piling up behind one Mac

Anything else goes to hosted `macos-26`, including a GitHub API error. If no
heartbeat is set, nothing changes from before.

## How the Mac runs a job

A launch agent in the owner's account (`mac-runner.sh serve`) checks GitHub
for Swift CI jobs queued for the `transcripted-mac` label: every 20 seconds
while it has said "free" in the last 10 minutes, and every 2 minutes
otherwise, since no new job can be on its way then.
When one is waiting, it:

1. clones a stopped "golden" VM (APFS copy-on-write, so this takes seconds)
2. boots it at low priority, with no host audio and no clipboard sharing
3. once the VM is up, asks GitHub for a just-in-time runner registration that
   is good for one job only, and puts it in a folder the VM mounts read-only
4. waits while the VM logs in to its own desktop, turns on its firewall,
   starts the runner, and runs one job
5. deletes the VM and the registration

No VM runs while nothing is waiting, so CI holds no memory, CPU, or VM slot
between jobs. macOS allows two running VMs at once, across every app (this
service, `scripts/vm/transcripted-vm.sh`, UTM), and the service counts them
before it starts one.

A job that is already waiting always gets run, even if the Mac is paused, on
battery, or a mic is in use. It was sent here while the Mac said it was free,
and nothing else will pick it up. So both of a run's jobs finish even if the
owner pauses between them. While a mic is in use, a running job drops to
background priority (efficiency cores and throttled disk) instead of failing.

If the Mac can't start a waiting job for 15 minutes (low disk, both VM slots
taken, or VMs failing to boot), the service cancels that run and re-runs it,
and the re-run goes to hosted runners. If the Mac stops answering altogether
(asleep, off, or its service died), `.github/workflows/mac-runner-sweep.yml`
does the same every 30 minutes for any run whose Mac job has waited more than
15 minutes while the heartbeat hasn't changed for 10. That workflow always runs
main's copy of the script, since it holds an `actions: write` token, and does
nothing until the heartbeat variable exists. So a required `build-and-test`
check can't sit pending on the Mac forever.

A re-run redoes the whole run, including a hosted `app-build` that may already
be partway through. GitHub can't re-run just the two Mac jobs with a new
runner choice, because "re-run failed jobs" keeps `pick-runner`'s old answer.

A VM that fails to boot makes the service back off (1, 2, 4 ... up to 30
minutes). It only asks GitHub for a registration once a VM has booted.

## The heartbeat

The service writes `MAC_RUNNER_HEARTBEAT` at least every 40 seconds. A bare
timestamp means "free". Otherwise it's `<word>:<timestamp>`, and new runs go
hosted right away:

| Word      | Meaning                                                    |
|-----------|------------------------------------------------------------|
| `paused`  | the owner ran `pause`                                      |
| `battery` | the Mac is not plugged in                                  |
| `disk`    | less than 40 GB free                                       |
| `vms`     | two VMs are already running on the Mac                     |
| `mic`     | a microphone is in use (a meeting, dictation, or a call)   |
| `busy`    | a job is waiting or running                                |
| `offline` | no CI image yet, a GitHub API error, or backing off        |

The timestamp in both forms lets `pick-runner` tell a live Mac from one that
went quiet. While a VM runs, the service keeps the Mac from idle-sleeping
(`caffeinate -i`).

`app-build` never uses the Mac. Its launch smoke stays on hosted runners
(`scripts/ops/native-smoke-isolation.py`).

## What a job can and can't reach

A job runs inside a VM that gets deleted afterwards, as the VM's `admin` user,
which has no admin rights (it isn't in the `admin` group and can't `sudo`).

- **Network:** a firewall inside the VM (`pf`, loaded at every boot before the
  runner may start) lets the job reach the internet, but blocks every private
  and link-local address. So it can't reach the Mac running it (AirPlay
  Receiver, SSH, file sharing, any dev server), other VMs such as the
  `transcripted-vm.sh` test VM, or anything on the local network. The only
  local traffic allowed is DNS to the VM network's resolver and DHCP. IPv6 is
  blocked, and nothing can connect in. Building the golden VM probes, as the
  job's user, the Mac's AirPlay and SSH ports, Tailscale's 100.100.100.100,
  private LAN addresses and an IPv6 address. None may connect, pf's own
  counters must show it blocked them, and GitHub must still work.
- **What the firewall doesn't cover:** DNS goes through the Mac's resolver,
  so a job can look up local and Tailscale names (the addresses they point to
  stay blocked). Public addresses the Mac can route to, like the router's
  outside address with its port forwards or a VPN route to a public range,
  are reachable, the same as from any hosted runner.
- **The firewall can't be turned off by the job,** since that needs root and
  the job's user has no admin rights. Building the golden VM proves `sudo`
  fails for that user, with and without the image's default password.
- **It can't reach:** the owner's files, keychain, gh login, microphone,
  clipboard, or app data. It also can't leave anything behind for the next
  job, since every job starts from a fresh clone.
- **Its only host input** is the read-only shared folder that holds its
  one-job runner registration.

The host never reads anything the VM produces. It learns how the job is going
only from GitHub's runner API.

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
   a `push`, `workflow_dispatch`, or same-repo `pull_request` on this repo. It
   also fails any job other than `checks` and `spm-tests`, since GitHub gives
   the VM's runner the default `self-hosted`/`macOS`/`ARM64` labels too.
   Building the golden VM proves the hook refuses a fork PR and accepts a
   same-repo push. If that check fails, the image isn't kept.

The hook is defense in depth. The runner starts it with `bash`, and GitHub
doesn't document whether a workflow's own `env:` (for example `BASH_ENV`)
reaches that first `bash`. Even if something got past all three, it would land
in a throwaway VM behind the firewall.

`install` also refuses to go on while any runner not named
`transcripted-mac-<timestamp>` is registered on the repo, since another runner
wouldn't be in a VM.

## Setup on the Mac

The owner runs this once from a checkout of `main`, as themself, never with
sudo. It needs no passwords:

```bash
bash scripts/ci/mac-runner.sh install
```

It needs `gh` logged in as a repo admin, Xcode, and about 120 GB free. It:

1. checks the Mac, the repo's runners, and the fork PR approval policy
2. installs the Tart version pinned in `scripts/vm/transcripted-vm.sh` into
   `~/.transcripted-ci` (checksum and code signature checked). It never
   touches that script's own `~/.transcripted-vm` folder.
3. builds the small microphone check (`mic-in-use`)
4. downloads the CI image, Cirrus Labs' `macos-tahoe-xcode` (macOS 26, Xcode
   26.5), pinned by digest in `mac-runner.sh` (tens of GB)
5. builds the golden VM: installs the latest runner (SHA-256 checked), the
   hook and the firewall, removes the job user's admin rights, and proves the
   hook, the firewall and the lockdown all work
6. starts the service

Job VMs get half the Mac's CPU cores (at least 4) and 8 GB of memory, but only
while a job runs. Change that with `MAC_RUNNER_CPU` / `MAC_RUNNER_MEMORY_MB`
and `rebuild`. The golden VM is rebuilt automatically when it's 14 days old,
which picks up newer runners.

To update a live setup (a new image pin, a new Tart pin, or script changes),
run `install` again from an updated checkout. It waits for any running job,
stops the service, rebuilds, and starts it again. A pause stays in place.

## Day to day

```bash
bash ~/.transcripted-ci/mac-runner.sh status     # runners, heartbeat, waiting jobs, VMs, disk
bash ~/.transcripted-ci/mac-runner.sh pause      # new runs go hosted; jobs already sent here finish
bash ~/.transcripted-ci/mac-runner.sh resume
bash ~/.transcripted-ci/mac-runner.sh rebuild    # fresh golden VM now
bash ~/.transcripted-ci/mac-runner.sh uninstall  # removes the service, VMs, images and state
```

Pause before timing-sensitive local work, like benchmarks or speed tests, then
wait until `status` shows no waiting jobs and no `ci-job-` VM. At most the two
jobs of one run can still land after a pause. To turn routing off from GitHub
without touching the Mac, set the `MAC_RUNNER_MODE` repo variable to `off`.

Logs live in `~/.transcripted-ci/serve.log` and `~/.transcripted-ci/logs/`.

## Known limits

- **Cold starts:** a Mac job waits for a VM to boot (about a minute or two),
  and every job starts with an empty checkout. The deps cache still applies.
- **Sleep:** a job running when the lid closes fails, and a job waiting then
  gets run after wake, or re-run on hosted once it has waited 15 minutes and
  another Swift CI run starts.
- **Re-runs:** after a Mac failure, use "Re-run all jobs". "Re-run failed
  jobs" reuses the old `pick-runner` choice and sends the job back to the Mac.
- **One job at a time:** a run's `checks` and `spm-tests` go one after the
  other when both land on the Mac.
- **Mic check false positives:** the `mic` check counts any running device
  that has input streams. AirPods playing music read as `mic`. That only means
  fewer Mac runs, or a slower one.
- **API use:** the service uses the owner's gh login. A poll costs one call
  plus one per Swift CI run it hasn't looked at yet: a run whose two jobs went
  hosted is remembered and skipped. That's a few hundred calls an hour, well
  under gh's 5,000. If fewer than 1,000 are left, the service polls every 2
  minutes and stops taking new runs until the quota recovers.
- **Public logs** show the VM's `/Users/admin/...` paths. `pick-runner`'s log
  only says "the Mac is not free", never why. The heartbeat variable itself
  (readable by repo admins) does show whether the Mac is plugged in, paused,
  or on a call.
