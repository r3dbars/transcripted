# Parakeet lifecycle executor integration tests

Run from the repository root:

```bash
bash scripts/dev/test-parakeet-lifecycle.sh
```

`bash run-integration-smoke.sh` also runs this harness.

This compiles the **actual** `Sources/Speech/ParakeetModelLifecycle.swift`
extension, along with the production identity, state, generation, teardown,
download-progress and admission policies. It links a test-only `FluidAudio`
module that suspends download, CoreML load and manager initialization until
the test releases each operation. The fake deliberately ignores cancellation;
this models native work that continues after its caller has canceled.

Cases exercise same-version initialization joins; initialization joining a
prefetch; current progress/error and retry; v3 → v2 → v3 supersession; stale
download success, progress, manager success and manager errors; watchdog
cancellation and retry; active recording/transcription/inference admission;
deferred teardown; and cleanup before successor allocation. The watchdog is
given an aged production progress tracker, not a reduced production timeout.
Each operation wait has a one-second deadline and the executable has a
30-second process deadline, including waits on task completion.

`EngineScaffold.swift` supplies only the engine state and excluded collaborators.
It must never duplicate lifecycle decisions or executor methods. The fake
module lives only under `build/parakeet-lifecycle-tests` and is not referenced
by app build scripts. An app build against the real pinned FluidAudio remains
required to catch API drift that the fake module cannot validate.

Limits: this is executor integration proof, not full `ParakeetEngine`/router,
CoreAudio, SwiftUI or real CoreML integration. The active-inference test drives
the activity flags and idle callback directly, so it does not establish that
every audio inference call site releases its lease. Real model inference,
cache migration, artifact E2E and live/UI testing are separate acceptance gates.
