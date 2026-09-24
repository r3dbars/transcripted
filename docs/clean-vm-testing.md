# Clean VM testing

A throwaway macOS 26 virtual machine for testing what a brand-new Transcripted
user sees: first launch, permission prompts, model download, first meeting,
first dictation, and upgrading from an older version. It never touches the
host's real data, preferences or permissions.

Tool: [Tart](https://tart.run) on Apple Silicon (Apple's Virtualization.framework
underneath). Script: `scripts/vm/transcripted-vm.sh`. Screen driver:
`scripts/vm/vnc.py`.

Status: written 2026-09-23. First real run on a Mac 2026-09-24: setup, the
clean snapshot, boot, VNC, install and launch all worked. Two problems came
out of it and are fixed below: the VM died a few minutes after launch, and
Tart's VNC port turned out to be open to the network. "What the first real
run showed" at the bottom has the details and what is still unconfirmed.

## How it works

- `install-tart` installs Tart 2.37.0 into `~/.transcripted-vm`. The download
  is pinned by version and sha256, and its code signature is checked before
  use. Homebrew is not used, and nothing is installed system-wide.
- `golden` downloads Cirrus Labs' vanilla macOS 26.6.2 image once
  (`ghcr.io/cirruslabs/macos-tahoe-vanilla`, pinned by digest, about 24 GB,
  user `admin`, password `admin`, auto-login), boots it once to switch off sleep and auto-updates and make two
  short spoken test clips, checks there is no Transcripted anywhere, and shuts
  it down. That VM, `transcripted-clean`, is the clean snapshot. It is never
  booted again, and the script refuses to boot, change, save over or delete
  it (only `golden --force` rebuilds it).
- Every test run clones the snapshot (`new`). APFS clones take seconds and
  almost no disk. A clone has its own fresh TCC (permissions) database, fresh
  preferences, and no app data.
- `up` boots the clone with Tart's built-in VNC server. Input sent over VNC
  arrives as virtual keyboard and mouse hardware, so it can click the system
  permission prompts that ignore synthetic clicks from inside the guest.
  `vnc.py` only connects to loopback.
- **The VNC port is open to the network.** Tart hands out a `127.0.0.1` URL,
  but its VNC server (Apple's private `_VZVNCServer`) listens on every
  interface, and Tart has no option to change that. It has a random password,
  but VNC only uses the first 8 characters (about 17 bits here), so someone
  on the same network could guess it. `vnc-check` dials the port on the
  Mac's own network addresses and fails if it answers. Keep the VM down when
  you're not using it, and avoid shared Wi-Fi. `up --lockdown` (experimental)
  runs Tart in a sandbox that refuses inbound connections unless they come
  over loopback; first-run tries it, and `vnc-check` shows whether it works.
- `up` starts Tart through `scripts/vm/supervise.py`, which puts it in its
  own session so it doesn't die with the command that started it, keeps the
  Mac from idle-sleeping while the VM runs, and writes how Tart ended (exit
  status or signal) to `~/.transcripted-vm/logs/<vm>.log`. The previous
  boot's log is kept as `<vm>.prev.log`. `diagnose` collects that plus host
  sleep/wake, crash reports, disk, and the guest's own shutdown cause.
- Commands run inside the guest through `tart exec` (guest agent, no network)
  or SSH as a fallback.
- A host folder (`share`) is mounted in the guest at
  `/Volumes/My Shared Files/tvm` for moving files both ways. Clipboard sharing
  with the host is off, so the host clipboard can't leak into paste-back
  tests.
- **Host audio is off by default.** The guest still gets a silent speaker, so
  call-audio capture can be tested, but it has no mic input. `up --audio`
  passes the Mac's default input and output through. That opens the host's
  default mic, so if the default input is AirPods they flip into call mode,
  the same bug as today's AirPods issues. Before `--audio`, set the Mac's
  input to the built-in mic in System Settings > Sound. The first `--audio`
  run may also show a host mic prompt for Tart or the app that launched it.
  That's a real grant on the Mac, so Justin decides.
- Everything lives under `~/.transcripted-vm`, including Tart's own image
  cache and VMs (`TART_HOME` points there). `status` shows the size.
  `purge --yes` deletes all of it. `TVM_HOME` can move it (say, to an
  external drive), but the path must end in `/.transcripted-vm`, and the
  script only uses a folder it created itself (it leaves a marker file). It
  refuses anything else, so a typo can't point `purge` at real data.
- `install-app` installs the way a user does: DMG into `~/Downloads`, stamped
  with the browser quarantine flag so Gatekeeper's "downloaded from the
  internet" dialog shows, then copied to `/Applications`. The app doesn't
  start until that prompt is approved: click Open, or run `approve-download`
  (clears the flag and closes the prompt). It switches
  analytics and crash reporting off first, so test runs don't pollute the real
  PostHog funnel or Sentry. Pass `--keep-telemetry` to leave them on.

## What a VM can and can't test

| Area | In the VM? | Notes |
|---|---|---|
| First launch, Gatekeeper dialog, onboarding screens | Yes | Real, every run starts clean |
| Microphone permission prompt (Allow and Don't Allow) | Yes | Fresh TCC per clone. Click via VNC |
| System audio (call audio) permission prompt | Yes, expected | Core Audio process taps use `kTCCServiceAudioCapture`; the prompt should behave like on real hardware. Unproven until first run |
| Call audio actually captured | Probably | Guest audio is played with `play`/`say` and the tap should capture it. Unproven |
| Mic audio content | Partly, opt-in | Only with `up --audio`, which passes the host's default input through. Real sound, not a controlled clip. See the AirPods warning above |
| Anything that opens the mic, without `--audio` | **Not realistic** | Without `--audio` the guest has no mic device at all, which no real Mac user has. Don't read a mic failure in such a run as an app bug |
| Accessibility grant for paste-back | Yes | Real System Settings flow, password `admin` |
| Model download | Yes | Real network, real HuggingFace download |
| Model warm-up and transcription speed | **No** | VMs get no Neural Engine and a virtual GPU. Timings are not representative. Correctness should be fine; anything that needs the ANE or specific Metal features could fail in the VM and not on real Macs |
| First meeting saved, first dictation saved | Yes | Check with `logs` and `cli -- context-recent` |
| Upgrade from 1.1.61 with data carried over | Yes | Install 1.1.61, use it, install 1.1.62 over it (or Sparkle once the appcast has it) |
| AirPods, Bluetooth, any headset | **No** | No Bluetooth in the VM. Stays on a real Mac |
| Device switching (plugging in a mic, changing output) | **No** | The guest has one virtual audio device |
| Sleep and wake | **No** | VM suspend is not laptop sleep |
| Real Zoom, Meet, FaceTime calls | Not really | Sign-in and camera make it impractical |
| Performance, battery, heat | **No** | |

Also: Apple Silicon allows at most two macOS VMs running at once.

## One-time setup on the Mac

Needs Apple Silicon, macOS 26 or newer, python3 (Xcode Command Line Tools),
and about 60 GB free disk. `golden` checks the space before it downloads.

The first time, one command does everything and writes a report:

```bash
bash scripts/vm/transcripted-vm.sh first-run
```

It runs `doctor`, `install-tart` (pinned Tart, checksum + signature checked)
and `golden` (the long download). The last two skip work that's already done,
so running it again is quick. Then it boots a fresh clone with host audio
off, checks the VNC port isn't reachable from the network, installs the
latest release, photographs the "downloaded from the Internet" prompt,
approves it, waits for the app to start, watches the VM for 5 minutes, and
runs `diagnose`. Last it reboots once with `--lockdown` to see whether that
closes the VNC port. Each step in the report has a timestamp. The report and screenshots land in
`~/.transcripted-vm/reports/first-run-<time>/`. If a required step fails, the
run stops there, and the report still says which step failed and why. `purge`
deletes the reports too, so copy them out first.

Or step by step:

```bash
bash scripts/vm/transcripted-vm.sh doctor
bash scripts/vm/transcripted-vm.sh install-tart
bash scripts/vm/transcripted-vm.sh golden
```

## Each test run

```bash
V="bash scripts/vm/transcripted-vm.sh"
$V reset                          # fresh clone of the clean snapshot, booted
$V install-app --latest           # or --version 1.1.61, or --dmg path/to/Transcripted-1.1.62.dmg
$V launch
$V approve-download               # or click Open on the "downloaded from the Internet" prompt
$V launch
$V screenshot /tmp/tvm.png        # look, then click what a user would click
$V click 720 450
$V logs 40
$V down                           # or just reset again for the next run
```

To get the disk back: `$V purge --yes`.

Use `--vm NAME` (anywhere before `--`) to run two VMs side by side (the limit
is two). Names may only use letters, digits, `.`, `_` and `-`.

## New-user test plan

Each scenario starts with `reset --audio` unless it says otherwise, because
recording and the mic prompt need a mic device in the guest. **Before every
`--audio` run, set the Mac's input to the built-in mic** (System Settings >
Sound > Input) so AirPods are never touched. Take a screenshot before every
click.

1. **Fresh install, allow everything.** Install the release under test,
   launch, click Open on the Gatekeeper dialog, then Set Up. Allow the
   microphone prompt, then the system audio prompt. Skip Accessibility.
   Continue, then Open Transcripted. Watch the menubar for model download
   progress until the model is ready (`wait-event models_loaded --timeout 1200`). Start a
   meeting from the menubar, run `play ~/tvm-fixtures/call-a.wav` and
   `play ~/tvm-fixtures/call-b.wav`, stop. Expect `wait-event meeting_transcript_saved --new`
   in `logs` and the meeting in `cli -- context-recent`, with the call clips'
   words in the transcript.
2. **Don't Allow the mic.** Continue must stay disabled and the row must point
   to Settings. Then grant it in System Settings and check onboarding
   recovers.
3. **Don't Allow system audio.** The meeting should still record the mic and
   say clearly that call audio is missing.
4. **First dictation.** Open TextEdit, start dictation from the menubar, speak
   near the Mac, stop. With no Accessibility grant, check what the user is
   told. Then grant Accessibility and check paste-back.
5. **Upgrade from 1.1.61.** Install `--version 1.1.61`, finish onboarding,
   record one meeting, quit. Optionally `down` then `save with-1.1.61` to
   reuse this state. Install the new version over it and launch. Expect no
   onboarding, permissions still granted, the old meeting still listed, and no
   second model download.
6. **Sparkle update.** From 1.1.61, Check for Updates once the appcast lists
   the new version.
7. **Onboarding screens only** (plain `reset`, no host audio). First launch,
   Gatekeeper, the onboarding copy and layout, and the call-audio prompt. Stop
   before anything records.

Record what happened per scenario (pass/fail, screenshot names, relevant log
lines) and keep private data out, per `docs/test-automation-strategy.md`.

## Driving it from an agent

- Coordinates are screen pixels in the screenshot (display is 1440x900 by
  default, `TVM_DISPLAY`). Use `screenshot --shrink 2` for a smaller image and
  double the coordinates you read off it.
- `key cmd-q`, `key return`, `type "text"`. `key delete` is backspace, like
  the Mac key; `key forwarddelete` is forward delete. If Command shortcuts do nothing,
  set `TVM_VNC_CMD_KEYSYM=meta` (VNC servers disagree on which key is Command).
- Useful in-app shortcuts while Transcripted is frontmost: ⌘R start/stop
  meeting, ⌘D dictation, ⌘, Settings.
- `wait-event NAME` blocks until the app writes that event to its local
  `events.jsonl` (`app_launched`, `models_loaded`, `meeting_start_requested`,
  `meeting_transcript_saved`, `dictation_export_saved`, ...). `--new` ignores
  events already in the file. It exits 1 on timeout, so it works as a pass/fail
  step in a script.
- The app has no URL scheme or AppleScript. State checks go through `logs`,
  `cli`, and files under `~/Library/Application Support/Transcripted` via
  `exec`.
- `exec` runs as the logged-in `admin` user, so `open`, `say` and `~` behave
  like a real user's.

## What the first real run showed

First run 2026-09-24 on Justin's MacBook Pro (repo `65f196ce`).

Confirmed:

- The pinned Tart 2.37.0 download, checksum and signature, and the pinned
  macOS 26.6.2 image (one layer needed a retry after "network connection
  lost"; Tart retried it).
- Tart accepts `--no-clipboard`, `--no-audio`, `--vnc-experimental` and
  `--no-graphics` together, prints a `vnc://` URL, and `vnc.py` can log in
  and take a screenshot.
- `tart exec` works against the vanilla image.
- Installing 1.1.62 from GitHub releases into the guest, and `open`.
- `du` reports about 100 GB for `~/.transcripted-vm`. Most of that is APFS
  clones (image cache, base, clean snapshot, test clone) that share blocks,
  so the real disk use is much lower. `df` before and after is the honest
  number.

Found and fixed:

- **The VM died a few minutes after launch** with nothing in Tart's log.
  Tart logs a line whenever the guest shuts down, Virtualization reports an
  error, or `tart stop` is used, so a silent log means the tart process was
  killed from outside. The best guess is the tool running the script killing
  its process group or tree. `up` now starts Tart through `supervise.py` (own
  session, stays awake, logs how it ended), and first-run watches the VM for
  5 minutes and runs `diagnose`. If it still dies, the log names the signal.
- **`app_launched` never came** because the app was waiting behind the
  "downloaded from the Internet" prompt. first-run now photographs and
  approves the prompt before it waits.
- **The VNC check said ok on a wildcard bind.** See the VNC bullet under
  "How it works". `vnc-check` now fails when the port answers on a network
  address.

Still to confirm:

- Whether `up --lockdown` closes the VNC port and still allows screenshots
  and `exec`. If it does, make it the default.
- Whether the VM now stays up. If it still dies, `diagnose` names the signal.
- Which Command keysym the VNC server wants (Super or Meta).
- Whether `tart exec` lands as root or as `admin` (the script handles both).
- Transcripted's system audio prompt appears in the guest, and the process tap
  captures audio the guest plays.
- Transcription works (slowly) without a Neural Engine.
- With `--audio`: whether Tart asks for host mic permission, and who it's
  attributed to.

## Later

- Deterministic mic input: a loopback audio driver in the golden image so a
  known clip can be "spoken" into the mic.
- `Tools/TranscriptedQA` refuses its UI and first-run smokes when it runs as
  the console user (`NativeSmokeIsolation`). Inside this VM that refusal is
  unnecessary. It could accept the marker file this VM writes at
  `/Users/Shared/transcripted-test-vm.json`.
- An Accessibility grant for the guest shell in the golden image, so agents
  can read the app's accessibility identifiers instead of relying on
  screenshots.
