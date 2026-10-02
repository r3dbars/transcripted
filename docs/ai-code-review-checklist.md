# AI-generated code: review checklist

Use this before you accept a change an agent wrote. The idea: you stay the engineer. Read it, understand how it fits, and rewrite by hand the parts that matter most, so the code's quality stays yours and your skills don't stall.

Work top to bottom. If you can't tick a box, that's the part to slow down on.

## 1. Read it and understand it

- [ ] I read every changed line, not just the summary or the diff stats.
- [ ] I can explain in my own words what the change does and why it's built this way.
- [ ] I know which files changed and why each one had to.
- [ ] Nothing in it is "magic" to me: every API, flag and helper it calls is one I understand or looked up.
- [ ] I checked that the names match what the code really does (no `isValid` that also saves, no `cleanup` that deletes user data).
- [ ] There's no dead code, leftover debug logging, commented-out blocks or TODOs it invented.
- [ ] Comments say *why*, match the surrounding density, and aren't restating the code.

## 2. Check the architecture and how the pieces fit

- [ ] The change lives in the layer that owns it (for this repo, check the folder's `CLAUDE.md` and `docs/repo-layout.md`).
- [ ] It doesn't add a new responsibility to a hotspot file that already does too much.
- [ ] It reuses the existing helper instead of writing a near-copy of one.
- [ ] Data flows the same way the rest of the code does: same ownership, same threading model, same error style.
- [ ] Concurrency is right for where it runs (in this repo: UI and session state on `@MainActor`; no I/O, locks, allocations or ObjC in CoreAudio real-time callbacks).
- [ ] Anything touching audio engines or `inputNode` says what happens with AirPods / a Bluetooth headset as the default input.
- [ ] It doesn't widen what leaves the machine: no transcript text, names, paths, tokens or device names in logs or telemetry, and telemetry keys don't trip the sanitizer substrings.
- [ ] A clean text merge isn't assumed to be a working one: new enum cases, counts and renamed helpers still line up with code elsewhere.

## 3. Prove it works

- [ ] Tests check a named promise through inputs and outputs, not source text or wall-clock time.
- [ ] I ran the checks the change needs (`bash check.sh`) and read the failures instead of retrying.
- [ ] I tried the unhappy paths myself: empty input, missing permission, device switch, cancel halfway, run it twice.
- [ ] For UI, I looked at it on screen, in light and dark, at a narrow width.

## 4. Decide what to rewrite by hand

Rewrite it yourself, or at least retype it line by line, when it's:

- [ ] **Core logic you'll have to debug at 2am**: state machines, recovery paths, anything with retries or timeouts.
- [ ] **Security or privacy sensitive**: permissions, file deletion, paths, anything that sends data out.
- [ ] **Real-time or concurrency code** where a subtle mistake only shows up in the field.
- [ ] **Clever**: if it took you more than a minute to see why it works, simplify it until it doesn't.
- [ ] **A pattern you'll copy**: the first instance sets the shape for every later one.
- [ ] **Something you want to get better at**: hand-writing it is the practice.

Fine to keep as written, once reviewed: boilerplate, glue code, test scaffolding, one-off scripts, and docs you've proofread.

## 5. Before you accept

- [ ] I'd be comfortable explaining this change in review without the agent's summary.
- [ ] Meaningful code got an independent review of the full diff (`/code-review`, `codex review`, or a second session).
- [ ] The commit message says what changed and why, in my words.
