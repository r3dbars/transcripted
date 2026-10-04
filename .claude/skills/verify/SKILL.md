---
name: verify
description: Check that a Transcripted change actually works in the app, not just that tests pass. Use after any code change to dictation, meetings, the UI, or the launch path, before saying it's done or opening a PR. Runs the right app checks for what changed, fixes what fails, reruns, and reports proof.
---

# Verify a change in the app

`bash check.sh` proves the code builds and the tests pass. That doesn't prove the change does what Justin asked. This skill does the checks he'd otherwise do by hand: dictate something, import a meeting, open the screen, see if launch got slower.

## When to run it

After you finish a code change and `bash check.sh` passes, and before you say it's done or open a PR. Skip it for docs-only or test-only changes.

## The loop

1. See what will run: `bash scripts/dev/verify-change.sh --list`
2. Run it: `bash scripts/dev/verify-change.sh`
3. If a check says FAIL, read its log in `.build/verify/<check>.log`, fix the cause, and run step 2 again. Keep going until nothing fails. Don't loosen a check to make it pass.
4. Do the extra steps below that the script can't do.
5. Paste `.build/verify/summary.md` into the PR body (or your reply), plus any screenshots.

## What each check proves

| Check | Runs when you touch | Pass means |
|---|---|---|
| dictation | `Sources/Speech`, `Dictation`, `Capture`, `Accessibility` | dictated text lands in a slow fake text field |
| meetings | `Sources/Meeting`, `TranscriptedCore` | an imported recording saves a valid meeting Markdown file and its audio |
| ui | `Sources/UI`, `App`, `Writing` | the built app opens onboarding, the menu bar, Home and Settings |
| speed | launch-path code | 10 cold launches, p95 under 400 ms |

Everything runs in a throwaway home folder. None of it touches Justin's real recordings or settings.

Force a check with `--only ui,speed`, or run all of them with `--all`.

## Extra steps the script can't do

- **UI changes: look at it.** After the ui check passes, open the screen you changed in the built app (`build/Transcripted.app`) and take a screenshot with computer use. Check it against what was asked: layout, wording, light and dark mode. Attach the screenshot. If Justin's copy of Transcripted is running, the ui check is skipped. Don't quit his app; tell him it needs quitting for this check.
- **Audio changes: hand off to Justin.** If the summary says "Needs a live check by Justin", say so plainly in your reply. Real mics and AirPods can't be faked. He runs `bash check.sh hardware` and dictates once with the built-in mic and once with AirPods.
- **Speed failures: rerun once.** One slow run can be a busy machine (other sessions benchmarking, a build running). If it fails twice, it's real.

## Rules

- SKIP isn't PASS. Say which checks were skipped and why.
- Never say a change was verified in the app if you're in a cloud or Linux session. These checks need this Mac. Say "not verified in the app" instead.
- Don't rebuild while Justin is running the app from this worktree's `build/` folder. The build script refuses on its own; don't override it.

## Adding a check

When Justin catches something by hand and tells you to fix it, ask whether it could be measured: a time budget, a pass/fail smoke, an AX check. If yes, add it to `scripts/dev/verify-change.sh` (when it runs, what passing means, where the log goes) and add a row to the table above.
