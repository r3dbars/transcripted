# Concurrency debt backlog

Swift 6 strict concurrency flags data races and wrong-thread calls. The app still builds in Swift 5 mode, so we don't get errors for them. We get a count instead.

`scripts/dev/concurrency-census.sh` does a `swiftc -typecheck` pass with `-strict-concurrency=complete` and counts the concurrency warnings per `Sources/` folder. The parser is `scripts/dev/concurrency-census.py`; it dedups by (file, line, message). The counts live in `.agents/concurrency-baseline.json`.

```bash
bash scripts/dev/concurrency-census.sh            # report
bash scripts/dev/concurrency-census.sh --check    # fail if any folder went up
bash scripts/dev/concurrency-census.sh --shrink   # lower the baseline to the new counts
```

`--shrink` is the only allowed way to edit the baseline. Never raise it.

At origin/main `ab7e811c` the baseline is 94 warnings: Capture 8, Meeting 7, Observability 13, Speech 16, Support 15, TranscriptedWriting 4, UI 31.

This page is the part of that backlog the cleanup PRs did not take. Each item either changes timing or isolation on a hot path, or touches the audio real-time path. It is a list of what to be careful about, not a to-do list, and none of it has been fixed. The line numbers are as of `ab7e811c` and will drift, so search by the warning text if they don't match.

The tables don't cover every warning in the baseline, only the ones that got a RISKY or LEAVE call, plus the deferred ones at the bottom.

- **RISKY**: a fix is possible, but someone has to review the threading or isolation first. Usually it means `@unchecked Sendable` on a class with mutable state, or a closure type that every caller has to change.
- **LEAVE**: don't touch without the owner. These sit on the AirPods-sensitive engine path or the CoreAudio device-switching path (read `Sources/Speech/AGENTS.md` first).

## RISKY

### Capture

| Where | Warning | Why it's risky | What a real fix needs |
| --- | --- | --- | --- |
| `Sources/Capture/ContextCaptureEngine.swift:198` (twice, a second "isolated closure" variant) | The `Thread` closure in `startTapThread` captures `self` (`PhysicalShortcutDetector`: not Sendable, lock-protected mutable state) | This is the hotkey event-tap thread. Both ways out (`@unchecked Sendable` on a class with mutable state, or restructuring the closure) touch the tap path | `PhysicalShortcutDetector` declared `@unchecked Sendable` after auditing `stateLock`, or the thread closure restructured. Needs an owner-reviewed design |

### Meeting

| Where | Warning | Why it's risky | What a real fix needs |
| --- | --- | --- | --- |
| `Sources/Meeting/CameraActivityMonitor.swift:138` | `scanAndEmit` copies the non-Sendable `onChange` closure and calls it in `DispatchQueue.main.async` | Camera activity monitor is a hot path. Making `onChange` `@Sendable` changes the property type and every setter assigns a main-actor-style closure. Reading `onChange` on main instead would race with queue-confined state | `onChange` as `(@Sendable (Bool) -> Void)?` (or delivered via `@MainActor`), and update all assigners. Threading review |
| `Sources/Meeting/MeetingAudioStorageManager.swift:431` | `static var maintenanceFailureHandler` is mutable global state | Genuinely shared mutable state, always accessed under `maintenanceFailureLock`. The only direct fix is `nonisolated(unsafe)`, which is never a safe-by-default call. Set once from `TranscriptedAppState` | Either `nonisolated(unsafe)` with a comment that every access holds the lock, or a small Sendable final class holding handler plus lock. Reviewer decides |
| `Sources/Meeting/MicActivityMonitor.swift:387`, `:394`, `:401` | `onChange`, `onOutputChange`, `onBrowserOutputChange` copies captured in `main.async` `@Sendable` closures | Mic activity monitor (`@unchecked Sendable` class) is a hot path. Fix is a `@Sendable` callback type across callers | `@Sendable` closure types (or a Sendable wrapper snapshot) and update the assigners |
| `Sources/Meeting/MicActivityMonitor.swift:468`, `:469` | Weak `self` var captured by the inner `queue.async` in the default-input-device observer | Probably a one-liner (`guard let self` before the hop), but it sits in the default-device listener, the CoreAudio device-switch reaction, and it turns a weak ref into a strong one across the hop | `guard let self else { return }; self.queue.async { [weak self] in ... }`, or capture `let queue = self.queue` plus a weak copy bound in the inner closure. Rerun the call-detection tests |

### Observability

| Where | Warning | Why it's risky | What a real fix needs |
| --- | --- | --- | --- |
| `Sources/Observability/AnalyticsReporter.swift:330` | `static let shared`: final class with mutable state (`pendingCaptures`, `inFlightCaptureIDs`, timers) guarded by `deliveryQueue`, not Sendable | Singleton called from many threads (`track()` from main, URLSession callbacks, notification observers). Only fix is `@unchecked Sendable` on a class with mutable state, or an actor/queue redesign | A reviewed decision: `@unchecked Sendable` only after auditing that every mutable var is touched solely on `deliveryQueue` (or behind a lock), with the invariant written down. One change fixes the whole group below |
| `AnalyticsReporter.swift:529` | `[weak self]` in the `UserDefaults.didChangeNotification` observer (`queue: nil`) in a `@Sendable` closure | Preference-change observer on the same singleton | Resolved by the class-level decision above |
| `AnalyticsReporter.swift:533` | `deliveryQueue.async` inside that observer captures the weak `self` | Same class-level question; calls `clearPendingCaptures` | Same |
| `AnalyticsReporter.swift:545` | App-will-terminate observer (`queue: nil`) captures weak `self` and does the final synchronous persist | Quit-time persist on a many-thread singleton. An isolation change could lose buffered events | Same |
| `AnalyticsReporter.swift:712` | `enqueue()`: `deliveryQueue.async` uses `self` to append to `pendingCaptures` | The `track()` hot path from main-thread callers | Same |
| `AnalyticsReporter.swift:728` | `flushPendingCaptures()`: `deliveryQueue.async` captures `self` | Same delivery-queue pattern | Same |
| `AnalyticsReporter.swift:839`, `:840` | URLSession `dataTask` completion captures weak `self` and hops onto `deliveryQueue`; nested async captures it again | Network completion callback on the singleton | Same |
| `AnalyticsReporter.swift:840` (second warning) | "Reference to captured var self" in the nested async block (`[weak self]` is a var) | Fix is rebinding `guard let self` before the hop, which changes the reporter's retain lifetime during delivery | After the class-level decision, `guard let self else { return }` before `self.deliveryQueue.async`. Review the retain-lifetime change first |
| `AnalyticsReporter.swift:847` | `completeDelivery()`: `deliveryQueue.async` captures `self` | Same delivery-queue pattern | Same |
| `Sources/Observability/CrashReporter.swift:13` | `static let shared`: class with unsynchronized mutable `hasStarted` and `sessionTrackingEnabled` | Used from many threads with no lock, so `@unchecked Sendable` would hide a real race | Guard both flags with an `NSLock` (or make setup main-only and `@MainActor`), then `@unchecked Sendable`. Review every caller thread |
| `Sources/Observability/UsageHealthStore.swift:5` | `static let shared`: class whose `State` is guarded by an `NSLock`; `defaults` is `UserDefaults` | Recorded from many threads. `@unchecked Sendable` is probably accurate, but it is still unchecked on a class with mutable state | Audit that every read and write of `state` is under `lock`, then add `: @unchecked Sendable` with a comment naming the lock. Not without the audit |

### Speech

| Where | Warning | Why it's risky | What a real fix needs |
| --- | --- | --- | --- |
| `Sources/Speech/ParakeetAudioEngineSupport.swift:29` | `static let shared = ParakeetRetiredAudioEngineStore()`: NSLock-guarded array of `AVAudioEngine` kept alive after retirement | Holds `AVAudioEngine` on the AirPods-sensitive teardown path (`ParakeetEngine.swift:504`). `AVAudioEngine` isn't Sendable, so `@unchecked Sendable` papers over holding non-Sendable engines | Read `Sources/Speech/AGENTS.md`. If the lock really guards all access, `final class ... : @unchecked Sendable` with a justification. Needs engine-teardown owner review |
| `ParakeetAudioEngineSupport.swift:47` | `asyncAfter` closure (`[weak self, engine]`) in `retire()` captures a weak non-Sendable store and the engine | The deferred-release timer for retired engines. Changing capture or isolation changes when the engine is released | Resolved with the item above. Capturing the engine needs a Sendable wrapper, which is a review item |
| `Sources/Speech/ParakeetAudioGraphOwnership.swift:239` | `static let wallClockTimeouts: TimeoutScheduler`; the `TimeoutScheduler` typealias is a non-`@Sendable` closure type stored in a static | Used by the input-device refresh and notification-lookup coordinators (audio device switching) and by tests that inject timers. `@Sendable` on the typealias forces every injected scheduler to be Sendable | `typealias TimeoutScheduler = @Sendable (UInt64, @escaping @Sendable () -> Void) -> Void`, then check every call site and test timer. Likely cascades into the coordinator items under LEAVE |
| `ParakeetAudioGraphOwnership.swift:242` | `asyncAfter(execute: expire)` where `expire` is a non-`@Sendable` closure in that type | Same typealias. `expire` has to become `@Sendable`, which forces the coordinator's timeout closure (around line 340) to be Sendable, and it captures the mutable `didComplete`/`didStart` vars | Done together with the line 239 change and the state box under LEAVE |

### Support

| Where | Warning | Why it's risky | What a real fix needs |
| --- | --- | --- | --- |
| `Sources/Support/AppSoundPlayer.swift:124` | `static let shared = AppSoundPlayer()`: non-Sendable class with mutable state (`players`, `attemptedCues`, `warningReporter`) confined to a private serial queue | Queue-confined, so `@unchecked Sendable` would be correct in principle. But it plays the dictation start/stop cues (14 call sites), and unchecked on a class with mutable state needs a reviewer to confirm every mutable access runs on `queue`, including init and preload | `final class AppSoundPlayer: @unchecked Sendable` with a comment that all mutable state is confined to `queue`. Audit that no property is touched off-queue first |
| `AppSoundPlayer.swift:148`, `:154`, `:163` | `queue.async { [weak self] }` in `setWarningReporter`, `preload` and `play` captures non-Sendable `self` | Same conformance fixes all three. `play()` runs on dictation start/stop | Same as above |

### UI

| Where | Warning | Why it's risky | What a real fix needs |
| --- | --- | --- | --- |
| `Sources/UI/Overlay/DictationStartActivation.swift:43` | `receive` parameter of `observeExternalActivation` captured in the `@Sendable` NSWorkspace notification block (queue `.main`, `MainActor.assumeIsolated` inside) | Dictation-start foreground recovery path (activation, restore, 500 ms window). Real fix changes the seam type, which also changes the test seam signatures | Type the seam as `(@escaping @MainActor (FocusTarget) -> Void) -> (() -> Void)` and update the tests that pass fake observers, or capture via a MainActor-isolated box. Run the dictation-start activation tests |
| `Sources/UI/Settings/HomeView.swift:192` | `ClosureMenuItem.invoke` captures non-Sendable `handler` in `DispatchQueue.main.async` | The doc comment says the next main-runloop turn matters so SwiftUI alerts and sheets present after `popUp`'s tracking loop. Switching to `Task` or `MainActor` changes that timing. Also means changing `HomeRowMenuItem.action`, which `HomeView`, `DictationsSettingsPage` and `TranscriptedSettingsView` construct | `HomeRowMenuItem.action` as `@MainActor () -> Void`, keep `DispatchQueue.main.async`, call via `MainActor.assumeIsolated`. Check all call sites compile and check by hand that Delete and Reveal still present their alerts |
| `Sources/UI/Settings/TranscriptedSettingsComponents.swift:28`, `:30`, `:31`, `:32`, `:33` | `persistedSettingsBinding` captures `state`, `track`, `persist` and `sideEffect` in `Binding(get:)`'s `@Sendable` closures | Generic helper used at about 20 settings sites. Fix decides the order and threading of track, persist and sideEffect, and the analytics-ordering doc comment makes that load-bearing. Not mechanical | Make the helper `@MainActor` with `MainActor.assumeIsolated` inside get/set and params typed `@MainActor (Value) -> Void`. Fix the ~20 call sites. Keep the track, persist, sideEffect order unchanged |

## LEAVE

All of these are in `Sources/Speech/`, on the AirPods-sensitive engine path or the CoreAudio device-switching path.

### `ParakeetAudioGraphOwnership.swift`

This is `ParakeetReplaceableSystemInputWorkCoordinator.schedule`, the timeout/circuit coordinator for system-input and device work (CoreAudio HAL calls, default-input-device refresh). Making its closures `@Sendable` ripples through `DefaultInputDeviceMonitor` and the `ParakeetEngine` call sites.

| Where | Warning | Why it's LEAVE | What a real fix needs |
| --- | --- | --- | --- |
| `:326` | `lease.0.async` closure captures non-Sendable `work: () -> T` | Coordinator above; signature change touches device monitor and engine call sites | Make `work`, `completion` and `cleanupAfterLateCompletion` `@Sendable` (`T: Sendable`). Owner review |
| `:334` | Same closure captures `completion: (Result<T, Error>) -> Void` | Same | Same |
| `:337` | Same closure captures `cleanupAfterLateCompletion: ((T) -> Void)?` | The late-completion reconcile path for stuck HAL calls | Same |
| `:320`, `:321`, `:328`, `:329` | Local `var didComplete` / `var didStart` read and mutated from the queue-async closure | The timeout-vs-completion race state. Already guarded by `completionLock`, but the compiler can't see it. Fix is a redesign of timing-critical code | A small final class state box with the lock inside, `@unchecked Sendable`, covering all four in one change. Owner review |

### `ParakeetTimedAudioEngineWorkLimiter.swift`

This is the timed `AVAudioEngine` work runner (`ParakeetEngine.runTimedAudioEngineWork`). It runs engine start/stop and device work on a serial queue with a timeout and late cleanup, and there is a lease/timeout race. It's the AirPods-sensitive engine path.

| Where | Warning | Why it's LEAVE | What a real fix needs |
| --- | --- | --- | --- |
| `:111` | `queue.async` closure captures non-Sendable `isWorkCurrent: (() -> Bool)?` | Engine work runner above | Make `isWorkCurrent`, `work` and the cleanup closures `@Sendable` and `Resource: Sendable` (or wrap the `AVAudioEngine` in an unchecked Sendable box). Recheck every call site in `ParakeetEngine` and `ParakeetAudioGraph`. Owner review |
| `:118` | Same closure captures `work: (Resource) throws -> T` | Same | Same |
| `:118` (second warning) | Same closure captures generic `resource: Resource` (an `AVAudioEngine` in production) | Declaring it Sendable, or wrapping it unchecked, is a statement about engine thread-safety on the AirPods path | Same |
| `:125` | Same closure captures `cleanupAfterCancellation: ((Resource) -> Void)?` | Cancellation cleanup of a live engine on the worker queue; the ordering is deliberate (see the comments) | Same |
| `:137` | Same closure captures `cleanupAfterLateCompletion: ((Resource) -> Void)?` | Late-completion cleanup of a live engine after a timeout; the inputNode path | Same |

## Skipped because another PR had the file open

These are CLEAR (no timing or isolation change at runtime) but were deferred because another PR had the file open when the cleanup ran. Check that the file is free, then take them.

| Where | Warning | Fix |
| --- | --- | --- |
| `Sources/Capture/ContextCaptureEngine.swift:18` | Private global `var hotkeyActionDebouncer = HotkeyActionDebouncer()` (mutable struct) used by the free func `shouldAcceptHotkeyAction` | Mark the global `@MainActor private var` and `shouldAcceptHotkeyAction` `@MainActor`. All callers (`handlePhysicalMeetingPress`, `pasteLast`, `handlePhysicalDictationHandsFreePress`) are already in the `@MainActor` engine and its extensions, and it isn't called from the CGEventTap thread. Confirm with grep that there is no non-main caller. Tests only build their own debouncer |
| `ContextCaptureEngine.swift:4`, `:208`, `:209` (the `:208` and `:209` ones twice, plain and "isolated closure" variants) | `CFRunLoopSource` and `CFMachPort` captured in the `@Sendable` Thread closure, plus the compiler's `@preconcurrency` suggestion | One line: `@preconcurrency import CoreFoundation`. It only downgrades Sendable diagnostics for CF types; thread-start order doesn't change. Check with the census that the warnings actually go away |
| `Sources/Support/PhysicalDictationTriggerPreferences.swift:90`, `:91` | `private static let functionKeyUsageDomain` and `functionKeyUsageKey` (`as CFString`) | Immutable constants only used as arguments to `CFPreferences` calls, so make both computed `private static var ... : CFString { "..." as CFString }` |
| `PhysicalDictationTriggerPreferences.swift:1` | The compiler's `@preconcurrency` suggestion for CoreFoundation | Probably moot once the statics are computed. Add `@preconcurrency import CoreFoundation` only if the warning stays |
