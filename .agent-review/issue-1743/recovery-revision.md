# Recovery-only revision: code-level reliability evidence

This revision supersedes the first candidate's unconditional activation.
It is based on local commit `2de424b3`; the release comparison remains 1.1.60
(`origin/main` application code). Worktree: `/Users/redbars/transcripted-issue-1743-recovery`.
The app previously launched for the user remains unchanged in the original
candidate worktree. It was not replaced or restarted during this revision.

## Why the first proof was insufficient

The original simulated mic required prior activation by construction. Its
success demonstrated compatibility with the reporter's hypothesis, not proof
of the diagnosis. Independent review and a scheduling probe compiled against
the production helper exposed three allowed counterexamples:

1. A ready mic could start immediately in 1.1.60, but the candidate could wait
   500 ms for refused/delayed activation. Release at 100 ms then prevented
   recording. Unconditional preparation introduced a new failure window.
2. The user could select editor B while activation was pending; cleanup after
   delayed activation restored the original editor A. The original tests kept
   B permanently active and missed this ordering.
3. Activation completing after 500 ms outlived focus cleanup. Retaining an
   observer forever is not a sound fix either: AppKit does not identify which
   activation request caused an event, so stale cleanup could undo a later
   intentional user click on Transcripted.

The SDK documents that activation is neither immediate nor guaranteed. The
patch cannot make that external operation atomic or cancellable.

## Current guarantees and implementation

`DictationSession.startDictationAudioRecording` executes the production engine start
through `DictationRecordingStartAttempt.run`, shared by fast and recovery
starts. Only an actual false result may call the recovery hook. A native true
result returns directly, with no activation call or added wait. Recovery does
not manufacture success; the existing retry machinery still needs a real
successful microphone start before Listening/recording is reported.

The controller admits activation recovery at most once per session and only
for a current, uncancelled background hotkey session with no shared meeting
mic. A stopped/superseded session cannot use a late native failure to invoke
activation. The existing microphone retry budget remains responsible for
success, failure, and timeout. Initial stale readiness alone does not activate
Transcripted: an actual start attempt must fail first.

Within the bounded activation window, external-app activation notifications
update the focus restoration target. The original saved paste destination is
unchanged; intentionally moving to another editor does not silently retarget
the transcript. Stale observers cannot mutate a newer preparation's target.
Restoration is requested before returning but AppKit completes it
asynchronously; this is not a claim of completed restoration before audio IO.

## What the tests prove

`DictationRecordingStartAttemptTests` executes the production attempt runner,
including successful native result/no recovery, failed attempt/recovery/next
successful attempt, recovery that does not solve the failure, cancellation
before dispatch, cancellation during a native failure, and late native success
that must be returned so the caller can stop the actual recording.

`DictationStartActivationTests` exercises the production focus helper, including
transient editor switches followed by delayed activation, cancellation during
that sequence, observer cleanup and supersession. The post-deadline limitation
is explicitly tested/documented, not hidden behind an unconditional safety
claim. Source-contract checks cover the small controller-to-runner wiring;
they are not a full-controller integration test.

The important comparison is now independent of the mic hypothesis: a healthy
start cannot enter activation recovery at all. This removes the new activation
failure window from successful ordinary starts, rather than assuming every
microphone benefits from foregrounding.

## Remaining limits

Activation after the 500 ms preparation deadline remains outside the cleanup
contract. Failed starts can therefore still experience a late focus change.
This recovery-only revision limits that exposure to actual failed hotkey starts;
it does not make a universal "never changes focus" guarantee.

No test establishes that Falcon causes the reporter's failure or that a
foreground round trip solves it there. An early release that cancels native
startup before failure is returned still cancels capture intentionally; recording
after release would violate push-to-talk behavior. Native work that never
returns remains subject to the existing engine timeouts, not this callback.

No merge, release, reporter contact, or replacement of the currently running
candidate occurred during this work.


## Validation recorded so far

- Focus helper targeted suite: 48/48 assertions passed.
- Recording-start executor targeted suite: 21/21 assertions passed.
- `bash build.sh --no-open`: passed, including isolated launch smoke;
  launch-to-interactive 622.7 ms (3,000 ms budget).
- Source-list validation, shell syntax, preflight, and diff whitespace checks passed.
- Independent full-diff review against `origin/main`: no blocking production
  defect found. The review's stale-evidence finding is addressed by the historical
  banner in the original README and this revision report.

Logs: `/tmp/transcripted1743-recovery-{helper-tests,attempt-tests,build,tests,preflight}.log`.
The full suite result is appended below after completion. Dependencies were
copied from the prior tested worktree; input SHA256
`db0e7638bf63b0423fef4c1e54ec2a9f9996e64ab8fdae5483006595cc1b87c3`
matched before the local cached stamp timestamp was refreshed. The original
worktree and running bundle were not modified.

Final full `bash run-tests.sh`: **14,025/14,025 assertions passed, zero failures**.
The revised build remains separate from the earlier candidate currently running
on the user's Mac; no runtime swap or publication was performed.
