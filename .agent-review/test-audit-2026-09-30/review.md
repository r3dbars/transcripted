# Independent test-improvement review

Reviewed against `origin/main` at `85bbcc09380f6de16e73119efb672e5e6a628f72` on 2026-09-30. Reviewed the full four-file diff, `AGENTS.md`, `Tests/README.md`, the affected production contracts and test helpers. This review was read-only; no builds or tests were run, and no repository files were changed.

## Verdict

Approve the bounded test changes; no remaining actionable findings. The changed assertions test real behavior and preserve production behavior. Re-reviewed the detached-timeout cleanup adjustment on 2026-09-30.

## Resolved review finding

**P2 resolved — final work drain now has an independent escape.** The initial diff's `await workFinished.wait()` could suspend forever if a regression made `withDetachedTimeout` return `CancellationError` without invoking its supplied operation. The revised cleanup task at `Tests/TranscriptedConstantsTests.swift:231` records `cleanupNeeded` and opens both gates. The assertion at line 259 fails whenever this escape was needed, so skipped work produces a failure instead of hanging or passing. The cancellation flag remains an additional check that the supplied operation really unwound after cancellation. The bound comes from the test's own task, independently of the timeout utility under test.

## Contracts checked

- Structured timeout: the real supplied operation observes `CancellationError`; the caller receives the expected error. Task-group joining makes the cancellation flag observable before the assertion.
- Detached timeout: a continuation gate genuinely ignores task cancellation. Holding it proves the deadline returns before work completes, and releasing it then checks cancellation was requested. The former `try? Task.sleep` loop could unwind immediately on cancellation and race its finished flag.
- Operation errors: both real timeout functions preserve a distinctive operation error, rather than silently returning a value or replacing it with timeout cancellation. This is separate from successful-work and timeout coverage.
- Capture start cancellation: the injected backend's start is held until explicitly released. `cancelReturned` must complete before that release, and a separate new attempt can start meanwhile. This replaces an elapsed-time threshold and a self-releasing fake without changing capture teardown expectations.
- Personal lookup: an unresolved real race returns the timeout outcome without a provider; diagnostics are checked through an injected sink and fixed clock. A timed-out waiter does not poison a later provider answer. A second resolve cannot overwrite the first value, including an initial nil. These additions exercise production race state, not a fake that defines its own result.
- Baseline shrink: the removed wall-clock exemption corresponds to the converted personal lookup assertion. No safety, storage, privacy, security or release check was removed.

## Coverage limits

- The personal lookup replacement proves timeout outcome and independence from the provider. It does not prove the configured 250 ms budget; the production seam still uses a real sleeper and does not expose a controllable deadline clock.
- The capture test uses a synthetic backend. It does not prove native ScreenCaptureKit stop behavior, microphone/Bluetooth behavior, system audio, or paste-back.
- The first-answer tests use serialized resolve calls. They prove first-result retention, not every concurrent multiwaiter schedule.
- Successful compilation, mutation sensitivity, focused/full checks, and exact-head CI remain the parent task's proof responsibilities. This review makes no green-test claim.
