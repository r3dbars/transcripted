# Mutation Testing

Mutation testing breaks production code on purpose, one small change at a
time, and runs the tests to see if any of them notice. A change the tests miss
points at a missing assertion, and a test that never notices any change is
probably not checking much.

`scripts/dev/mutation-probe.py` is a small, dependency-free probe for this. It
works on one Swift file under `Sources/` at a time.

## Run it

Plan first. `--list` prints the mutants it would try and touches nothing:

```bash
python3 scripts/dev/mutation-probe.py Sources/Speech/DictationReadinessWaitPolicy.swift --list --max 20
```

Then run it with a test command that exercises that file:

```bash
python3 scripts/dev/mutation-probe.py Sources/Speech/DictationReadinessWaitPolicy.swift \
    --test "TZ=America/Chicago bash run-tests.sh --filter DictationReadinessWaitPolicy" \
    --max 20
```

Options:

- `--test "<shell command>"`: exit 0 means green. Runs from the repo root.
- `--max N` (default 25, `0` = all) and `--seed S` (default 1): when a file has
  more sites than `--max`, the probe picks a sample. The same file, seed, and
  max always pick the same mutants.
- `--operators equality,logical`: only some kinds of change.
- `--lines 86,150-155`: only these lines. Useful for re-checking survivors
  against a wider test command.
- `--report path.json`: default is `build/mutation/<file>.json` (gitignored).
  Per-mutant logs go next to it in `build/mutation/<file>-logs/`.
- `--timeout SECONDS`: per mutant. Default is 3x the baseline plus 60s.
- `--self-test`: offline checks of the probe itself. Also runs in
  `scripts/dev/linux-checks.sh`.

What it changes, one site per mutant, never inside comments, strings, or `#if`
lines:

| Name | Change |
|------|--------|
| `equality` | `==` and `!=` swap |
| `less` | `<` and `<=` swap |
| `greater` | `>` and `>=` swap |
| `logical` | `&&` and `\|\|` swap |
| `bool` | `true` and `false` swap |
| `return-bool` | `return true` and `return false` swap |
| `int-plus-one` | a single-digit integer `n` becomes `n+1` |
| `negate-if` | a one-line `if cond {` becomes `if !(cond) {` |

Operators need a space on both sides, which skips generics (`Array<Int>`),
`->`, `...`, and `..<`. Operator declarations (`static func ==`), `where T ==
U` constraints, enum raw values, and `#available` lines are skipped too.

### Safety

The probe edits a real source file, so it is careful about it:

- It refuses anything outside `Sources/`, untracked files, and files with
  unstaged or staged changes. It also checks that the bytes it read are the
  git index copy, so it can never save a mutant as "the original".
- It runs your test command once on the unmutated code first. If that fails it
  stops: the baseline must be green.
- The original bytes go back after every mutant, in a `finally` block, on
  Ctrl-C / SIGTERM / SIGHUP, and at exit. At the end it runs `git diff --quiet`
  on the file and says so.
- While a run is live, a copy of the original sits in
  `build/mutation/.backup/`. If the probe gets `kill -9`'d, the next run
  refuses the dirty file and tells you to run `git checkout -- <file>`.
- Only one probe runs per checkout at a time (`build/mutation/.probe.lock`),
  because `run-tests.sh` writes one shared test binary.
- Restoring gives the file a fresh mtime. For a `Sources/TranscriptedCore/`
  file that means `build.sh` will ask for `bash build-deps.sh --force` next
  time. That is on purpose: it forces a rebuild instead of trusting objects
  built from a mutant.

Don't edit the target file while a run is going, and commit only after it ends.

### How long it takes

Each mutant is a full test run. With `run-tests.sh` that means a cold compile
of every fast-test app source, because the fast-test object cache is keyed by
file contents. On the M5 Max these numbers came from, a filtered run took 45
to 70 seconds and the whole fast suite about 2 minutes. The probe sets
`TRANSCRIPTED_FAST_TESTS_NO_CACHE=1` for its runs (unless you set it
yourself) so mutants don't evict your warm cache. Budget about a minute per
mutant with `--filter`: `--max 20` is roughly 20 minutes.

## Read the results

Each mutant ends as one of:

- `KILLED`: some test went red. Good.
- `KILLED (timeout)`: the tests hung or ran past the timeout. Counted as
  killed.
- `SURVIVED`: every test stayed green with the code broken. This is the
  interesting one.
- `COMPILE-ERROR`: the mutant did not build. Counted as neither.

The mutation score is `killed / (killed + survived)`.

A survivor means one of two things:

1. A real gap: no test pins that behavior. Write the assertion that would
   have caught it.
2. An equivalent mutant: the change cannot alter behavior (for example a
   default argument every caller overrides, or `>` vs `>=` where the equal
   case cannot happen). Skip it.

Before writing a new test for a survivor, re-run just those lines against a
wider test command, since a filtered run only sees one test file:

```bash
python3 scripts/dev/mutation-probe.py <file> --lines 86,152 --max 0 \
    --test "TZ=America/Chicago bash run-tests.sh"
```

The JSON report also says which tests did the killing, parsed from the
fast-test output:

- `kills_by_assertion`: the `FAIL [File.swift:line]` locations that caught
  each mutant. These are exact.
- `kills_by_test_case` and `test_cases_that_killed_nothing`: the last
  `Running <case>...` line before each failure. Treat these as a hint. A suite
  that prints `FAIL` outside `runSuite` gets its failures pinned on the
  previous case.

A test case that kills nothing across several seeds and a full `--max 0` run
is a candidate for deletion or a rewrite. One 20-mutant sample is not enough
to call a test useless. In the first run below, "waits while recovery is
active" killed nothing only because the sample never flipped
`if isRecovering`.

## First results

Run on 2026-09-27 at `f1fe3db4` with `--max 20 --seed 1`, each file against
its own fast test (`TZ=America/Chicago bash run-tests.sh --filter <Name>`).
Each run took about 17 minutes.

| File | Sites | Run | Killed | Survived | Compile error | Score |
|------|------:|----:|-------:|---------:|--------------:|------:|
| `Sources/Speech/DictationReadinessWaitPolicy.swift` | 27 | 20 | 17 | 3 | 0 | 85% |
| `Sources/Speech/DictationInputDeviceSelectionPolicy.swift` | 151 | 20 | 11 | 9 | 0 | 55% |

The 9 `DictationInputDeviceSelectionPolicy` survivor lines were then re-run
against the whole fast suite (`--lines ... --max 0 --test "TZ=America/Chicago
bash run-tests.sh"`, 2363 test cases, about 2 minutes per mutant). 8 of the 9
still survived. The one the wider suite caught was line 534 (the default
`initialDelayNanoseconds` going from 0 to 1), which
`Tests/DictationInputBindingSettleTests.swift` pins. That is why a filtered
survivor needs a second look before it counts as a gap.

### `DictationReadinessWaitPolicy.swift`

- **Line 38**, `forcedRecoveryAttempts < maxForcedRecoveryAttempts` to `<=`.
  With the mutant, the ready-input branch can force one more recovery than the
  cap allows, and every test stays green. The test called "ready failure hard
  recovery stays bounded" passes `readyStartFailures: 4` with
  `forcedRecoveryAttempts: 2`, so the failure threshold (2 x 3 = 6) is never
  reached. The answer comes out right, but the cap never has to decide it. The
  same test with `readyStartFailures: 6` would pin it.
- **Line 75**, `now - startedAt >= timeout` to `>`. The "times out at timeout"
  test uses `startedAt: 10.0, now: 10.9, timeout: 0.9`, but `10.9 - 10.0` is
  `0.9000000000000004` as a Double, so the exact boundary is never hit. Values
  that are exact in binary (10, 11, 1) would test it.
- Line 24 (the default `readinessRefreshes: Int = 0` becoming 1) is an
  equivalent mutant for the current callers. Skip it.

### `DictationInputDeviceSelectionPolicy.swift`

All of these survived the whole fast suite, not just the filtered file.

- **Line 518**, `DictationInputDeviceBindingPolicy.requireSelection`:
  `selection.selectedInput.id != 0` to `== 0`. That makes every real
  selection throw `selectionUnavailable` and lets device 0 through.
  `ParakeetEngine.audioInputSnapshot` (engine prewarm and engine-path
  starts) calls it, and all 2363 fast-test cases stay green. The only direct
  test passes `nil` (`DictationInputBindingSettleTests.swift:131`). It needs
  the positive case: a real id comes back unchanged, and id 0 throws.
- **Line 450**, `isBluetoothAudioDevice`: `isBluetoothTransport(...) ||
  isBluetoothHeadsetName(...)` to `&&`. The Bluetooth fixtures in `Tests/`
  all pair a Bluetooth transport with a headset-sounding name ("AirPods Pro",
  "Bluetooth Headset", "Headset"), so a Bluetooth headset with a plain product
  name is never tested. That is the call-mode fallback for non-Apple headsets.
- **Line 154**, `PinnedDictationInputPolicy.selection`:
  `!(lidClosed && isLidMicrophone($0))` to `!(lidClosed || ...)`. With the lid
  closed, that drops any mic the user chose, not just the dead MacBook mic.
  The lid-closed test only ever chooses the MacBook mic. It needs a lid-closed
  case where the user chose a USB mic.
- Smaller ones: the USB-first sort in `preferredExternalInput` (lines 209-210)
  survives rank changes because the only fixture lists the webcam before the
  USB mic. Repeating it with the inputs reversed should kill those; that is not
  verified yet. Line 426 (the built-in mic rank tying with the Studio Display
  mic), line 461 (the `"beats"`/`"buds"` name checks), and line 556
  (`budget > 0` to `> 1`, close to equivalent) are low value.

## Suggested cadence

Once a month, run the probe on a few hot policy files, with a fresh seed each
time (for example the month number) so the sample rotates:

- `Sources/Speech/DictationInputDeviceSelectionPolicy.swift` (Bluetooth and
  AirPods routing)
- `Sources/Speech/DictationReadinessWaitPolicy.swift`
- `Sources/Speech/ParakeetPrewarmPolicy.swift`
- `Sources/Meeting/MeetingMicBoostPromptPolicy.swift`
- `Sources/Observability/AnalyticsEventPolicy.swift` and
  `Sources/Observability/SentryEventPolicy.swift` (privacy gates)
- any file a recent bug fix touched

Write down the score and survivors in the PR that adds the missing tests, so
the next run has something to compare against. Keep it out of CI: at about a
minute per mutant it is too slow to gate PRs on.

## Limits

- It reads Swift as text, not as a syntax tree. Bare `/regex/` literals are
  not recognized as strings (none were found in `Sources/` when this was
  written). `#/regex/#` literals are.
- `negate-if` only handles a one-line `if cond {` with no `let`, `var`,
  `case`, `,`, or closures in the condition. `guard` is not mutated.
- Files outside the fast-test `APP_SOURCES` list need a different `--test`
  command, for example `swift test --filter '^SpeakerTests\.'` for a
  `Sources/TranscriptedCore/Speaker/` file.
