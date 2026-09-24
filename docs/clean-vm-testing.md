# Clean VM testing

A throwaway macOS 26 virtual machine for testing what a brand-new Transcripted
user sees: first launch, permission prompts, model download, first meeting,
first dictation, and upgrading from an older version. It never touches the
host's real data, preferences or permissions.

Tool: [Tart](https://tart.run) on Apple Silicon (Apple's Virtualization.framework
underneath). Script: `scripts/vm/transcripted-vm.sh`. Screen driver:
`scripts/vm/vnc.py`.

Status: written 2026-09-23. Four real runs on a Mac on 2026-09-24. Setup, the
clean snapshot, boot, VNC, install and launch all worked. On runs 1 and 2 the
VM died on the first screenshot after Transcripted launched: Apple's VNC
server crashed tart when a new VNC client connected. Run 3 kept one VNC
connection and stayed up, but macOS Setup Assistant covered the desktop the
whole time. Run 4 reached a clear desktop, but the "downloaded from the
Internet" prompt stayed open, so the app never started. Tart's VNC port is
also open to the network. All of that is handled below. "What the real runs showed" at the bottom has the details and
what is still unconfirmed.

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
- `up` boots the clone headless: commands run in it, but there's no screen
  access and no VNC port. `up --vnc` turns on Tart's built-in VNC server for
  runs that need the screen. Input sent over VNC arrives as virtual keyboard
  and mouse hardware, so it can click the system permission prompts that
  ignore synthetic clicks from inside the guest.
- **One VNC connection per boot.** On both real runs, tart crashed (SIGTRAP,
  an assertion in `-[_VZVNCServer _setupVirtualMachineAccessor]` inside
  Apple's Virtualization framework) the first time a new VNC client connected
  after Transcripted launched. So `up --vnc` starts one `vnc.py serve`
  session that connects once and stays connected until the VM stops.
  `screenshot`, `click`, `type` and `key` all go through that session's local
  socket, never a new connection. If the session ends, they say so instead
  of reconnecting. Its log is `~/.transcripted-vm/logs/<vm>.vnc.log`.
- **With `--vnc`, the VNC port is open to the network.** Tart hands out a
  `127.0.0.1` URL, but its VNC server (Apple's private `_VZVNCServer`)
  listens on every interface, and Tart has no option to change that. A
  `sandbox-exec` lockdown was tried on the Mac and didn't close it. It has a
  random password, but VNC only uses the first 8 characters (about 17 bits
  here), so someone on the same network could guess it. So: VNC is off
  unless asked for, `up --vnc` is refused on open or unencrypted Wi-Fi
  (override `TVM_ALLOW_VNC_ON_OPEN_WIFI=1`), and first-run shuts the VM down
  when it's done. The one real fix is a Mac setting: the macOS firewall set
  to block incoming connections for tart. That's Justin's call. `vnc-check`
  dials the port on each of the Mac's own addresses, IPv4 and IPv6, and
  fails if a VNC server answers there. It reads the `RFB` greeting, so a bare
  TCP handshake doesn't count, and only the VMs' own vmnet subnet
  (192.168.64.0/24 by default) is exempt. The macOS firewall doesn't filter
  the Mac's own connections, so with the firewall on the check can fail even
  though neighbors are blocked (it errs safe). Run `vnc-check` before
  launching the app: it opens short-lived connections of its own.
- **After login, `up` waits for the desktop (the Dock).** If macOS Setup
  Assistant is showing its own screens instead, `up` records what it was and
  closes it, because no app opens while it's up. The result is in
  `~/.transcripted-vm/run/<vm>.setup`, and first-run puts it in the report.
  The snapshot prep also marks Setup Assistant as done for the image's build.
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
  internet" dialog shows, then copied to `/Applications`. It switches
  analytics and crash reporting off first, so test runs don't pollute the real
  PostHog funnel or Sentry. Pass `--keep-telemetry` to leave them on.
- The app doesn't start until that prompt is approved. `approve-download`
  first asks Gatekeeper (`spctl --assess`) with the flag still on and fails
  if Gatekeeper would reject the app, so a broken notarization shows up here.
  Then it clicks the prompt's Open button over the VNC session, like a user
  (it finds the blue default button on screen; `click-default-button
  --dry-run` shows where), and presses Return if the click only brought the
  prompt forward. Without screen access, or if both fail, it falls back to
  clearing the quarantine flag and says so.

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
so running it again is quick. When this script's snapshot prep has changed
since the snapshot was made, it rebuilds the snapshot from the downloaded
image, which takes a few minutes and downloads nothing big. Then it:

- boots a fresh clone with screen access and host audio off
- records who can reach the VNC port and Gatekeeper's status in the guest
- installs the latest release
- photographs the "downloaded from the Internet" prompt, asks Gatekeeper,
  approves the prompt, and waits for the app to start
- checks whether screenshots work from inside the guest (`screencapture`)
- watches the VM for 5 minutes, runs `diagnose`, and shuts it down

Each step in the report has a timestamp. The report and screenshots land in
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
$V reset --vnc                    # fresh clone of the clean snapshot, booted, screen on
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

Each scenario starts with `reset --vnc --audio` unless it says otherwise,
because the prompts need the screen, and recording and the mic prompt need a
mic device in the guest. **Before every
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
7. **Onboarding screens only** (`reset --vnc`, no host audio). First launch,
   Gatekeeper, the onboarding copy and layout, and the call-audio prompt. Stop
   before anything records.

Record what happened per scenario (pass/fail, screenshot names, relevant log
lines) and keep private data out, per `docs/test-automation-strategy.md`.

## Driving it from an agent

- Screen commands need `up --vnc` or `reset --vnc`, and they all share the
  boot's one VNC session. Don't point another VNC viewer at the port: a new
  connection is what crashed tart.
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

## What the real runs showed

Four runs on 2026-09-24 on Justin's MacBook Pro: repo `65f196ce`, `84d5df95`,
`7b3c7ff5` and `bec8525c`.

Confirmed:

- The pinned Tart 2.37.0 download, checksum and signature, and the pinned
  macOS 26.6.2 image (one layer needed a retry after "network connection
  lost"; Tart retried it).
- Tart accepts `--no-clipboard`, `--no-audio`, `--vnc-experimental` and
  `--no-graphics` together, prints a `vnc://` URL, and `vnc.py` can log in
  and take a screenshot.
- `tart exec` works against the vanilla image.
- Installing 1.1.62 from GitHub releases into the guest, and `open`.
- The Mac session could run the whole thing as one background command.
- One VNC connection held for the whole boot (run 3): no tart crash, the VM
  stayed up 10 minutes, and every screenshot went over that one connection.
- Gatekeeper in the guest reports "assessments disabled", and
  `spctl --assess` accepts the release as "Notarized Developer ID".
- `du` reports about 100 GB for `~/.transcripted-vm`. Most of that is APFS
  clones (image cache, base, clean snapshot, test clone) that share blocks,
  so the real disk use is much lower. `df` before and after is the honest
  number.

Found and fixed:

- **The VM died right after Transcripted launched, on both runs.** The
  first run's log said nothing, so `supervise.py` was added to log how tart
  ends. The second run's log said SIGTRAP, and the Mac's crash reports
  (`tart-2026-09-23-215938.ips`, `tart-2026-09-24-011443.ips`) show the same
  assertion both times: `-[_VZVirtualMachineAccessor addAccessorObserver:]`
  called from `-[_VZVNCServer _setupVirtualMachineAccessor]`, on the first new
  VNC connection after the app launched. That's Apple's VNC server, not the
  app. Fixed by keeping one VNC connection per boot (see "How it works").
- **`app_launched` never came** because the app was waiting behind the
  "downloaded from the Internet" prompt. first-run now photographs and
  approves the prompt before it waits.
- **Clearing the quarantine flag didn't close the prompt (run 4).** The
  prompt already on screen stayed, and launching again only brought it
  forward, so the app never started. `approve-download` now clicks Open over
  VNC, which is also what a user does.
- **The VNC check said ok on a wildcard bind.** `vnc-check` now fails when
  the port answers on a network address. On the second run it answered on
  Wi-Fi, a second network interface and IPv6, with the Mac's firewall off.
  `--lockdown` (a `sandbox-exec` profile) didn't change that, so it was
  removed, and VNC is now off unless `up --vnc` asks for it.
- **The Cirrus image reopens a Terminal window from its own build** at every
  login. The snapshot prep now closes it and stops windows coming back.
- **Setup Assistant covered the desktop on run 3** with its "Update Mac
  Automatically" screen, from boot to shutdown. No Finder, no Dock, so
  Transcripted never showed and in-guest `screencapture` failed. Runs 1 and 2
  (older snapshot prep) reached the desktop, so the trigger is in the
  rebuilt snapshot, but which change set it off isn't known. Two fixes: the
  prep marks Setup Assistant done for the build (and no longer deletes the
  login window's per-Mac settings file), and `up` closes Setup Assistant if
  it still shows (see "How it works").

Still to confirm:

- Whether one long-lived VNC connection survives Transcripted's launch (runs
  3 and 4 never got the app past the download prompt).
- That clicking Open over VNC starts the app (the report says whether it
  clicked, pressed Return or fell back).
- Whether `screencapture` works from inside the guest. Run 4 had a clear
  desktop and it still failed ("could not create image from display"),
  probably because the guest command has no Screen Recording permission.
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
