# Clean VM testing

A throwaway macOS 26 virtual machine for testing what a brand-new Transcripted
user sees: first launch, permission prompts, model download, first meeting,
first dictation, and upgrading from an older version. It never touches the
host's real data, preferences or permissions.

Tool: [Tart](https://tart.run) on Apple Silicon (Apple's Virtualization.framework
underneath). Script: `scripts/vm/transcripted-vm.sh`. Screen driver:
`scripts/vm/vnc.py`.

Status: written 2026-09-23 and dry-run tested on Linux against a fake `tart`
and a real VNC server. **Not yet run on a Mac.** The "Check on first real run"
list at the bottom is what the first run has to confirm.

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
- `up` boots the clone with Tart's built-in VNC server, listening on
  127.0.0.1 with a random password. Input sent over VNC
  arrives as virtual keyboard and mouse hardware, so it can click the system
  permission prompts that ignore synthetic clicks from inside the guest.
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
  `purge --yes` deletes all of it.
- `install-app` installs the way a user does: DMG into `~/Downloads`, stamped
  with the browser quarantine flag so Gatekeeper's "downloaded from the
  internet" dialog shows, then copied to `/Applications`. It switches
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

```bash
cd ~/transcripted
bash scripts/vm/transcripted-vm.sh doctor
bash scripts/vm/transcripted-vm.sh install-tart   # pinned Tart, checksum + signature checked
bash scripts/vm/transcripted-vm.sh golden         # long: downloads the macOS image
```

## Each test run

```bash
V="bash scripts/vm/transcripted-vm.sh"
$V reset                          # fresh clone of the clean snapshot, booted
$V install-app --latest           # or --version 1.1.61, or --dmg path/to/Transcripted-1.1.62.dmg
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

Each scenario starts with `reset`. Take a screenshot before every click.

1. **Fresh install, allow everything.** Install the release under test,
   launch, click Open on the Gatekeeper dialog, then Set Up. Allow the
   microphone prompt, then the system audio prompt. Skip Accessibility.
   Continue, then Open Transcripted. Watch the menubar for model download
   progress until the model is ready (`models_loaded` in `logs`). Start a
   meeting from the menubar, run `play ~/tvm-fixtures/call-a.wav` and
   `play ~/tvm-fixtures/call-b.wav`, stop. Expect `meeting_transcript_saved`
   in `logs` and the meeting in `cli -- context-recent`, with the call clips'
   words in the transcript.
2. **Don't Allow the mic.** Continue must stay disabled and the row must point
   to Settings. Then grant it in System Settings and check onboarding
   recovers.
3. **Don't Allow system audio.** The meeting should still record the mic and
   say clearly that call audio is missing.
4. **First dictation.** Open TextEdit, start dictation from the menubar, speak
   near the Mac (needs `reset --audio`, built-in mic as the host input), stop. With no Accessibility grant, check what the
   user is told. Then grant Accessibility and check paste-back.
5. **Upgrade from 1.1.61.** Install `--version 1.1.61`, finish onboarding,
   record one meeting, quit. Optionally `down` then `save with-1.1.61` to
   reuse this state. Install the new version over it and launch. Expect no
   onboarding, permissions still granted, the old meeting still listed, and no
   second model download.
6. **Sparkle update.** From 1.1.61, Check for Updates once the appcast lists
   the new version.

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
- The app has no URL scheme or AppleScript. State checks go through `logs`,
  `cli`, and files under `~/Library/Application Support/Transcripted` via
  `exec`.
- `exec` runs as the logged-in `admin` user, so `open`, `say` and `~` behave
  like a real user's.

## Check on first real run

These are assumptions the script makes that nobody has confirmed on a Mac yet:

- Tart's `--vnc-experimental` prints a `vnc://` URL the script can read, and
  `vnc.py` can authenticate to it.
- `tart exec` works against the vanilla image. If not, SSH is used, which may
  trigger a Local Network prompt on the host.
- The script's background `tart run` survives after the command that started
  it returns. If the VM dies when the command ends, run `up` as a background
  task.
- Tart's VNC server listens only on 127.0.0.1
  (`lsof -nP -iTCP -sTCP:LISTEN | grep -i tart`).
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
