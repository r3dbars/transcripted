import TranscriptedWritingCore
import Foundation
import Testing
@testable import TranscriptedWritingRuntime

/// Exercises `ScreenCaptureService`'s own wiring — the parts that sit in
/// front of ScreenCaptureKit itself. Everything ScreenCaptureKit-shaped
/// (SCShareableContent, SCContentFilter) is not constructible outside a
/// granted, live display, so the deeper trigger-policy branches (screen
/// lock, secure input, exclusion, cadence) are proven once, purely, in
/// CaptureTriggerPolicyTests — this file only proves the actor stops before
/// ever reaching ScreenCaptureKit when it should, and that it reads
/// `enabled`/`excludedApps` fresh rather than caching them at init.
@Suite("Screen capture service")
struct ScreenCaptureServiceTests {
    private func recordingDiagnostics() -> (
        sink: @Sendable (String, [String: String]) -> Void,
        events: EventBox
    ) {
        let box = EventBox()
        let sink: @Sendable (String, [String: String]) -> Void = { event, metadata in
            box.append((event, metadata))
        }
        return (sink, box)
    }

    @Test("Disabled service skips before ever touching ScreenCaptureKit")
    func disabledSkipsEarly() async {
        let (sink, events) = recordingDiagnostics()
        let service = ScreenCaptureService(
            enabled: { false },
            excludedApps: { [] },
            permissionGranted: { Issue.record("permissionGranted should not be checked before enabled"); return false },
            screenLocked: { false },
            secureInputActive: { false },
            recognizeText: { _ in [] },
            now: { Date() },
            diagnostics: sink
        )
        let outcome = await service.noteWindowChanged()
        #expect(outcome == .skipped(.disabled))
        #expect(events.values.contains { $0.0 == "screen-capture-skipped" && $0.1["reason"] == "disabled" })
    }

    @Test("Permission not granted skips before enumerating windows, and logs the exact reason")
    func permissionNotGrantedSkipsEarly() async {
        let (sink, events) = recordingDiagnostics()
        let service = ScreenCaptureService(
            enabled: { true },
            excludedApps: { [] },
            permissionGranted: { false },
            screenLocked: { Issue.record("screenLocked should not be checked before permission"); return false },
            secureInputActive: { false },
            recognizeText: { _ in [] },
            now: { Date() },
            diagnostics: sink
        )
        let outcome = await service.noteWindowChanged()
        #expect(outcome == .permissionNotGranted)
        #expect(events.values.contains { $0.0 == "screen-capture-skipped" && $0.1["reason"] == "no-permission" })
    }

    @Test("No text field means no ScreenCaptureKit enumeration")
    func textFieldRequiredBeforeCapture() async {
        let service = ScreenCaptureService(
            enabled: { true },
            excludedApps: { [] },
            permissionGranted: { true },
            screenLocked: { false },
            secureInputActive: { false },
            shareableContent: {
                Issue.record("shareableContent should not run without an active text field")
                throw CocoaError(.fileReadUnknown)
            },
            recognizeText: { _ in [] },
            now: { Date() },
            diagnostics: { _, _ in }
        )
        #expect(await service.noteWindowChanged() == .skipped(.noActiveTextField))
    }

    @Test("noteCompletionActivity does not disturb the enabled/permission gates")
    func completionActivityDoesNotBypassGates() async {
        let service = ScreenCaptureService(
            enabled: { true },
            excludedApps: { [] },
            permissionGranted: { false },
            screenLocked: { false },
            secureInputActive: { false },
            recognizeText: { _ in [] },
            now: { Date() },
            diagnostics: { _, _ in }
        )
        await service.noteCompletionActivity()
        let outcome = await service.noteWindowChanged()
        #expect(outcome == .permissionNotGranted)
    }

    @Test("Only the focused IMKit session can schedule typing refreshes")
    func textFieldSessionOwnership() async {
        let service = ScreenCaptureService(
            enabled: { false },
            excludedApps: { [] },
            permissionGranted: { false },
            screenLocked: { false },
            secureInputActive: { false },
            recognizeText: { _ in [] },
            now: { Date() },
            diagnostics: { _, _ in }
        )
        let focused = UUID().uuidString
        let stale = UUID().uuidString

        #expect(await service.noteTextFieldFocused(sessionIdentifier: focused) == .skipped(.disabled))
        #expect(await service.noteTypingPaused(sessionIdentifier: stale) == nil)
        #expect(await service.noteTypingPaused(sessionIdentifier: focused) == .skipped(.disabled))

        await service.noteTextFieldBlurred(sessionIdentifier: stale)
        #expect(await service.noteTypingPaused(sessionIdentifier: focused) == .skipped(.disabled))

        await service.noteTextFieldBlurred(sessionIdentifier: focused)
        #expect(await service.noteTypingPaused(sessionIdentifier: focused) == nil)
    }

    @Test("enabled is read fresh on every trigger, not cached at init")
    func enabledProviderIsReadLive() async {
        let flag = LockedFlag(true)
        let service = ScreenCaptureService(
            enabled: { flag.value },
            excludedApps: { [] },
            permissionGranted: { false },
            screenLocked: { false },
            secureInputActive: { false },
            recognizeText: { _ in [] },
            now: { Date() },
            diagnostics: { _, _ in }
        )
        // Still true: gets past `enabled`, stops at permission.
        #expect(await service.noteWindowChanged() == .permissionNotGranted)
        flag.value = false
        // Flipped without recreating the service: now stops at `enabled`.
        #expect(await service.noteWindowChanged() == .skipped(.disabled))
    }

    @Test("latestSnapshot starts nil and is never populated without a successful capture")
    func latestSnapshotStartsNil() async {
        let service = ScreenCaptureService(
            enabled: { false },
            excludedApps: { [] },
            permissionGranted: { false },
            screenLocked: { false },
            secureInputActive: { false },
            recognizeText: { _ in [] },
            now: { Date() },
            diagnostics: { _, _ in }
        )
        #expect(await service.latestSnapshot == nil)
        _ = await service.noteWindowChanged()
        #expect(await service.latestSnapshot == nil)
    }

    @Test("The actor owns one cadence reservation for all capture triggers")
    func centralCadenceReservationCoalescesTriggers() async {
        let service = makeService()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let typing = CaptureTriggerPolicy.Trigger.typingPause(
            elapsedSeconds: CaptureTriggerPolicy.typingPauseThresholdSeconds
        )

        #expect(await service.reserveCaptureSlot(trigger: .windowChanged, at: t0) == .reserved(previousCaptureAt: nil))
        #expect(await service.reserveCaptureSlot(trigger: .textFieldFocused, at: t0) == .blocked(.cadence(secondsRemaining: 0.5)))
        #expect(await service.reserveCaptureSlot(trigger: typing, at: t0.addingTimeInterval(0.5)) == .blocked(.cadence(secondsRemaining: 1.5)))
        #expect(await service.reserveCaptureSlot(trigger: .windowChanged, at: t0.addingTimeInterval(0.5)) == .reserved(previousCaptureAt: t0))
    }

    @Test("Cached screen context is bound to the exact field and window generation")
    func cachedContextRequiresExactTypingTarget() async {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let slack = "com.tinyspeck.slackmacgap"
        let session = UUID().uuidString
        let service = ScreenCaptureService(
            enabled: { true },
            excludedApps: { [] },
            permissionGranted: { false },
            screenLocked: { false },
            secureInputActive: { false },
            recognizeText: { _ in [] },
            now: { t0 },
            diagnostics: { _, _ in }
        )
        let proposed = TypingTargetIdentity(
            bundleIdentifier: slack,
            processIdentifier: 99,
            windowIdentifier: 42,
            fieldSessionIdentifier: session,
            generation: 0
        )
        _ = await service.noteTextFieldFocused(sessionIdentifier: session, target: proposed)

        func snapshot(target: TypingTargetIdentity) -> ScreenSnapshot {
            let frame = NormalizedDisplayRect(x: 0, y: 0, width: 1, height: 1)
            return ScreenSnapshot(
                capturedAt: t0,
                displayID: 1,
                blocks: [
                    ScreenSnapshot.TextBlock(
                        text: "hey are you around today",
                        boundingBox: NormalizedDisplayRect(x: 0.05, y: 0.30, width: 0.35, height: 0.05),
                        windowOwnerBundleIdentifier: slack,
                        windowIdentifier: target.windowIdentifier,
                        windowFrame: frame,
                        confidence: 0.9
                    ),
                    ScreenSnapshot.TextBlock(
                        text: "yeah free after 3pm works",
                        boundingBox: NormalizedDisplayRect(x: 0.55, y: 0.60, width: 0.35, height: 0.05),
                        windowOwnerBundleIdentifier: slack,
                        windowIdentifier: target.windowIdentifier,
                        windowFrame: frame,
                        confidence: 0.8
                    ),
                ],
                evidence: ScreenTextExtractionEvidence(
                    source: .visionFull,
                    completed: true,
                    confidence: 0.85,
                    observedAt: t0,
                    recognizedAt: t0,
                    target: target
                )
            )
        }

        let wrongWindow = TypingTargetIdentity(
            bundleIdentifier: slack,
            processIdentifier: 99,
            windowIdentifier: 41,
            fieldSessionIdentifier: session,
            generation: 1
        )
        await service.setLatestSnapshotForTesting(snapshot(target: wrongWindow))
        #expect(await service.freshScene(
            frontmostBundleID: slack,
            fieldText: "",
            fieldSessionIdentifier: session,
            now: t0
        ) == nil)

        let exact = TypingTargetIdentity(
            bundleIdentifier: slack,
            processIdentifier: 99,
            windowIdentifier: 42,
            fieldSessionIdentifier: session,
            generation: 1
        )
        await service.setLatestSnapshotForTesting(snapshot(target: exact))
        #expect(await service.freshScene(
            frontmostBundleID: slack,
            fieldText: "",
            fieldSessionIdentifier: session,
            expectedTarget: proposed,
            now: t0
        )?.mode == .replying)

        let nextWindow = TypingTargetIdentity(
            bundleIdentifier: slack,
            processIdentifier: 99,
            windowIdentifier: 43,
            fieldSessionIdentifier: session,
            generation: 0
        )
        // The request-time OS identity changes before the service receives
        // its window-change pulse: stale context still fails closed.
        #expect(await service.freshScene(
            frontmostBundleID: slack,
            fieldText: "",
            fieldSessionIdentifier: session,
            expectedTarget: nextWindow,
            now: t0
        ) == nil)
        _ = await service.noteWindowChanged(target: nextWindow)
        #expect(await service.freshScene(
            frontmostBundleID: slack,
            fieldText: "",
            fieldSessionIdentifier: session,
            now: t0
        ) == nil)
    }

    // MARK: - freshScene (Screen Memory plan Phase 2 PR 2b)

    /// `enabled` is on and `permissionGranted` is off: `freshScene` now
    /// honors the master toggle itself (an off toggle must not keep serving
    /// a snapshot taken while it was on), while the missing permission is
    /// what keeps every one of these tests away from ScreenCaptureKit.
    private func makeService() -> ScreenCaptureService {
        ScreenCaptureService(
            enabled: { true },
            excludedApps: { [] },
            permissionGranted: { false },
            screenLocked: { false },
            secureInputActive: { false },
            recognizeText: { _ in [] },
            now: { Date() },
            diagnostics: { _, _ in }
        )
    }

    /// Covenant regression for the Settings master toggle: turning Screen
    /// Memory off has to mean Tilde stops seeing the screen NOW, not once
    /// the last snapshot ages out of the 20s staleness window.
    @Test("Turning the master toggle off stops the held snapshot from being served, and clearing drops it")
    func disablingScreenMemoryStopsServingHeldScene() async {
        let enabled = LockedFlag(true)
        let service = ScreenCaptureService(
            enabled: { enabled.value },
            excludedApps: { [] },
            permissionGranted: { false },
            screenLocked: { false },
            secureInputActive: { false },
            recognizeText: { _ in [] },
            now: { Date() },
            diagnostics: { _, _ in }
        )
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let slack = "com.tinyspeck.slackmacgap"
        let frame = NormalizedDisplayRect(x: 0, y: 0, width: 1, height: 1)
        let snapshot = ScreenSnapshot(capturedAt: t0, displayID: 1, blocks: [
            ScreenSnapshot.TextBlock(
                text: "want me to grab it for you today?",
                boundingBox: NormalizedDisplayRect(x: 0.05, y: 0.30, width: 0.35, height: 0.05),
                windowOwnerBundleIdentifier: slack,
                windowFrame: frame
            ),
            ScreenSnapshot.TextBlock(
                text: "yes please, that would be great",
                boundingBox: NormalizedDisplayRect(x: 0.55, y: 0.60, width: 0.35, height: 0.05),
                windowOwnerBundleIdentifier: slack,
                windowFrame: frame
            ),
        ])
        await service.setLatestSnapshotForTesting(snapshot)
        #expect(
            await service.freshScene(
                frontmostBundleID: slack,
                fieldText: "",
                now: t0.addingTimeInterval(2)
            )?.mode == .replying
        )

        // The toggle alone silences serving, with the snapshot still well
        // inside the staleness window.
        enabled.value = false
        #expect(
            await service.freshScene(
                frontmostBundleID: slack,
                fieldText: "",
                now: t0.addingTimeInterval(3)
            ) == nil
        )

        // And the app's follow-up clears what is still held, so turning the
        // toggle back on cannot resurrect the old look at the screen.
        await service.forgetCapturedScreenState(now: t0.addingTimeInterval(3))
        #expect(await service.latestSnapshot == nil)
        enabled.value = true
        #expect(
            await service.freshScene(
                frontmostBundleID: slack,
                fieldText: "",
                now: t0.addingTimeInterval(4)
            ) == nil
        )
    }

    @Test("Clearing captured state also drops the snapshot the toggle was never off for")
    func forgettingCapturedStateDropsEverythingHeld() async {
        let service = makeService()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = ScreenSnapshot(capturedAt: t0, displayID: 1, blocks: [])
        await service.setLatestSnapshotForTesting(snapshot)

        await service.forgetCapturedScreenState(now: t0)

        #expect(await service.latestSnapshot == nil)
        // A capture that lands after the clear is behind the reset
        // watermark, so it is the wrong conversation and never served.
        await service.setLatestSnapshotForTesting(
            ScreenSnapshot(capturedAt: t0.addingTimeInterval(-1), displayID: 1, blocks: [])
        )
        #expect(
            await service.freshScene(
                frontmostBundleID: "com.apple.TextEdit",
                fieldText: "",
                now: t0
            ) == nil
        )
    }

    @Test("freshScene reads whatever the last successful capture stored, without triggering a new one")
    func freshSceneReadsLatestSnapshotOnly() async {
        let service = makeService()
        let referenceMoment = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = ScreenSnapshot(
            capturedAt: referenceMoment,
            displayID: 1,
            blocks: [
                ScreenSnapshot.TextBlock(
                    text: "hey are you around today",
                    boundingBox: NormalizedDisplayRect(x: 0.05, y: 0.30, width: 0.35, height: 0.05),
                    windowOwnerBundleIdentifier: "com.tinyspeck.slackmacgap",
                    windowFrame: NormalizedDisplayRect(x: 0, y: 0, width: 1, height: 1)
                ),
                ScreenSnapshot.TextBlock(
                    text: "yeah free after 3pm works",
                    boundingBox: NormalizedDisplayRect(x: 0.55, y: 0.60, width: 0.35, height: 0.05),
                    windowOwnerBundleIdentifier: "com.tinyspeck.slackmacgap",
                    windowFrame: NormalizedDisplayRect(x: 0, y: 0, width: 1, height: 1)
                ),
            ]
        )
        await service.setLatestSnapshotForTesting(snapshot)

        let fresh = await service.freshScene(
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            fieldText: "",
            now: referenceMoment.addingTimeInterval(5)
        )
        #expect(fresh?.mode == .replying)

        let stale = await service.freshScene(
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            fieldText: "",
            now: referenceMoment.addingTimeInterval(25)
        )
        #expect(stale == nil)
    }

    @Test("AX reader thresholds fall back to OCR rather than trusting thin trees")
    func axReaderThresholds() {
        // The walk itself needs a live AX tree; what unit tests can pin is
        // the contract that keeps Electron/Chromium windows on the OCR
        // path: too few text nodes or too little text means nil, and the
        // walk is bounded so it can never stall a capture.
        #expect(AXWindowTextReader.minimumBlocks == 6)
        #expect(AXWindowTextReader.minimumCharacters == 150)
        #expect(AXWindowTextReader.timeoutSeconds <= 0.2)
        #expect(AXWindowTextReader.nodeBudget <= 5_000)
    }

    @Test("A snapshot captured before a content reset is never served")
    func contentResetInvalidatesOlderSnapshots() async {
        let service = makeService()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let slack = "com.tinyspeck.slackmacgap"
        let frame = NormalizedDisplayRect(x: 0, y: 0, width: 1, height: 1)
        let snapshot = ScreenSnapshot(capturedAt: t0, displayID: 1, blocks: [
            ScreenSnapshot.TextBlock(text: "want me to grab it for you today?",
                boundingBox: NormalizedDisplayRect(x: 0.05, y: 0.30, width: 0.35, height: 0.05),
                windowOwnerBundleIdentifier: slack, windowFrame: frame),
            ScreenSnapshot.TextBlock(text: "yes please, that would be great",
                boundingBox: NormalizedDisplayRect(x: 0.55, y: 0.60, width: 0.35, height: 0.05),
                windowOwnerBundleIdentifier: slack, windowFrame: frame),
        ])
        await service.setLatestSnapshotForTesting(snapshot)

        // Fresh and valid before the reset...
        let before = await service.freshScene(frontmostBundleID: slack, fieldText: "", now: t0.addingTimeInterval(2))
        #expect(before?.mode == .replying)

        // ...gone the moment the content reset lands, even though the
        // snapshot is still inside the staleness window.
        await service.setLastContentResetAtForTesting(t0.addingTimeInterval(3))
        let after = await service.freshScene(frontmostBundleID: slack, fieldText: "", now: t0.addingTimeInterval(4))
        #expect(after == nil)
    }

    /// Fix item 4 of "Classify scenes by geometry, not host app": a
    /// classification must never be opaque again. Count-only -- mode plus
    /// two integers, never any of the OCR'd text.
    @Test("freshScene logs a count-only scene-classified diagnostic after a real classification")
    func freshSceneLogsCountOnlyDiagnostic() async {
        let (sink, events) = recordingDiagnostics()
        let service = ScreenCaptureService(
            enabled: { true },
            excludedApps: { [] },
            permissionGranted: { false },
            screenLocked: { false },
            secureInputActive: { false },
            recognizeText: { _ in [] },
            now: { Date() },
            diagnostics: sink
        )
        let referenceMoment = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = ScreenSnapshot(
            capturedAt: referenceMoment,
            displayID: 1,
            blocks: [
                ScreenSnapshot.TextBlock(
                    text: "hey are you around today",
                    boundingBox: NormalizedDisplayRect(x: 0.05, y: 0.30, width: 0.35, height: 0.05),
                    windowOwnerBundleIdentifier: "com.tinyspeck.slackmacgap",
                    windowFrame: NormalizedDisplayRect(x: 0, y: 0, width: 1, height: 1)
                ),
                ScreenSnapshot.TextBlock(
                    text: "yeah free after 3pm works",
                    boundingBox: NormalizedDisplayRect(x: 0.55, y: 0.60, width: 0.35, height: 0.05),
                    windowOwnerBundleIdentifier: "com.tinyspeck.slackmacgap",
                    windowFrame: NormalizedDisplayRect(x: 0, y: 0, width: 1, height: 1)
                ),
            ]
        )
        await service.setLatestSnapshotForTesting(snapshot)

        let scene = await service.freshScene(
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            fieldText: "",
            now: referenceMoment.addingTimeInterval(5)
        )
        #expect(scene?.mode == .replying)

        let logged = events.values.first { $0.0 == "scene-classified" }
        #expect(logged?.1["mode"] == "replying")
        #expect(logged?.1["turns"] == "2")
        #expect(logged?.1["refs"] == "0")
        // "P99 at every section" (2026-08-18): the classification call is
        // timed too, as a non-negative whole-millisecond integer.
        #expect(logged?.1["milliseconds"].flatMap { Int($0) }.map { $0 >= 0 } == true)
        // Never the OCR'd text itself.
        #expect(logged?.1.values.contains { $0.contains("hey are you around") } != true)
    }

    @Test("freshScene logs nothing when there is no snapshot to classify")
    func freshSceneLogsNothingWithoutASnapshot() async {
        let (sink, events) = recordingDiagnostics()
        let service = ScreenCaptureService(
            enabled: { true },
            excludedApps: { [] },
            permissionGranted: { false },
            screenLocked: { false },
            secureInputActive: { false },
            recognizeText: { _ in [] },
            now: { Date() },
            diagnostics: sink
        )
        let scene = await service.freshScene(frontmostBundleID: "com.apple.TextEdit", fieldText: "hello")
        #expect(scene == nil)
        #expect(!events.values.contains { $0.0 == "scene-classified" })
    }

    @Test("freshScene with no captured snapshot yet returns nil — today's behavior")
    func freshSceneWithNoSnapshotReturnsNil() async {
        let service = makeService()
        let fresh = await service.freshScene(frontmostBundleID: "com.apple.TextEdit", fieldText: "hello")
        #expect(fresh == nil)
    }

    /// Covenant regression: a capture taken BEFORE an app was added to the
    /// exclusion list must not keep serving that app's text for the rest of
    /// the 20s staleness window once the exclusion list changes.
    /// `excludedApps` is a live provider, so `freshScene` must consult its
    /// CURRENT value on every read, not whatever was true at capture time.
    @Test("freshScene drops blocks from an app that became excluded after the snapshot was captured")
    func freshSceneFiltersNewlyExcludedAppBlocks() async {
        let excluded = LockedSet<String>([])
        let service = ScreenCaptureService(
            enabled: { true },
            excludedApps: { excluded.value },
            permissionGranted: { false },
            screenLocked: { false },
            secureInputActive: { false },
            recognizeText: { _ in [] },
            now: { Date() },
            diagnostics: { _, _ in }
        )
        let referenceMoment = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = ScreenSnapshot(
            capturedAt: referenceMoment,
            displayID: 1,
            blocks: [
                ScreenSnapshot.TextBlock(
                    text: "hey are you around today",
                    boundingBox: NormalizedDisplayRect(x: 0.05, y: 0.30, width: 0.35, height: 0.05),
                    windowOwnerBundleIdentifier: "com.tinyspeck.slackmacgap",
                    windowFrame: NormalizedDisplayRect(x: 0, y: 0, width: 1, height: 1)
                ),
                ScreenSnapshot.TextBlock(
                    text: "yeah free after 3pm works",
                    boundingBox: NormalizedDisplayRect(x: 0.55, y: 0.60, width: 0.35, height: 0.05),
                    windowOwnerBundleIdentifier: "com.tinyspeck.slackmacgap",
                    windowFrame: NormalizedDisplayRect(x: 0, y: 0, width: 1, height: 1)
                ),
            ]
        )
        await service.setLatestSnapshotForTesting(snapshot)

        // Not yet excluded: the snapshot classifies normally.
        let beforeExclusion = await service.freshScene(
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            fieldText: "",
            now: referenceMoment.addingTimeInterval(2)
        )
        #expect(beforeExclusion?.mode == .replying)

        // The user excludes the app; the SAME cached (still-fresh) snapshot
        // must no longer surface its text, even though nothing re-captured.
        excluded.value = ["com.tinyspeck.slackmacgap"]
        let afterExclusion = await service.freshScene(
            frontmostBundleID: "com.tinyspeck.slackmacgap",
            fieldText: "",
            now: referenceMoment.addingTimeInterval(4)
        )
        #expect(afterExclusion?.mode == .composing)
        #expect(afterExclusion?.conversationTurns.isEmpty == true)
    }

    // MARK: - Duty-cycle instrumentation (Phase 1b)
    //
    // `performCapture` itself cannot be unit-tested (see the type doc
    // comment: SCShareableContent/SCContentFilter need a live, permissioned
    // display). This proves the one piece of the duration math that lives
    // outside ScreenCaptureKit — script/capture_power_probe.sh and
    // script/screen_capture_probe.swift are the real, live callers that
    // exercise the full instrumented path per docs/plans/screen-memory.md.

    @Test("A focused-window refusal skips: out of scope reads as excluded, anything unprovable as no target window")
    func focusedWindowRefusalOutcomes() {
        let app = "com.example.chat"
        #expect(ScreenCaptureService.blockReason(for: .excluded(bundleIdentifier: app))
            == .excludedWindow(appBundleIdentifier: app))
        #expect(ScreenCaptureService.blockReason(for: .outOfScope(bundleIdentifier: app))
            == .excludedWindow(appBundleIdentifier: app))
        for refusal: FocusedWindowCapturePolicy.Refusal in [
            .noTarget, .windowNotVisible, .ownerMismatch, .notNormalWindow, .unknownApp,
            .notFrontmostApp, .keyboardFocusElsewhere, .keyboardFocusUnknown, .notFocusedWindow,
        ] {
            #expect(ScreenCaptureService.blockReason(for: refusal) == .noTargetWindow)
        }
    }

    @Test("Every focused-window refusal logs its own readable reason, never the app's bundle ID")
    func focusedWindowRefusalLogReasons() {
        let app = "com.example.chat"
        let refusals: [FocusedWindowCapturePolicy.Refusal] = [
            .noTarget, .windowNotVisible, .ownerMismatch, .notNormalWindow, .unknownApp,
            .excluded(bundleIdentifier: app), .outOfScope(bundleIdentifier: app),
            .notFrontmostApp, .keyboardFocusElsewhere, .keyboardFocusUnknown, .notFocusedWindow,
        ]
        let reasons = refusals.map(ScreenCaptureService.skipReason(for:))
        // Distinct per refusal, so a skip in the log says which check closed the door.
        #expect(Set(reasons).count == refusals.count)
        for reason in reasons {
            #expect(!reason.contains(app))
            // The log writer keeps it literal instead of redacting it to a length.
            #expect(DiagnosticsMetadataRedactor.logSafeField(forKey: "reason", value: reason) == "reason=\(reason)")
        }
    }

    @Test("Moving to another window or leaving the field drops the held window text")
    func heldTextFollowsTheTypingWindow() async {
        let service = makeService()
        let session = "field-1"
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func target(window: UInt32) -> TypingTargetIdentity {
            TypingTargetIdentity(bundleIdentifier: "com.apple.TextEdit", processIdentifier: 7,
                                 windowIdentifier: window, fieldSessionIdentifier: session, generation: 0)
        }
        let held = ScreenSnapshot(capturedAt: t0, displayID: 1, blocks: [])

        _ = await service.noteTextFieldFocused(sessionIdentifier: session, target: target(window: 1))
        await service.setLatestSnapshotForTesting(held)
        // A repeat pulse for the same window keeps it.
        _ = await service.noteTypingPaused(sessionIdentifier: session, target: target(window: 1))
        #expect(await service.latestSnapshot == held)

        // Another window: the first window's text is gone.
        _ = await service.noteWindowChanged(target: target(window: 2))
        #expect(await service.latestSnapshot == nil)

        // Leaving the field: gone too.
        await service.setLatestSnapshotForTesting(held)
        await service.noteTextFieldBlurred(sessionIdentifier: session)
        #expect(await service.latestSnapshot == nil)
    }

    @Test("Capture requests backing pixels, not points, on Retina displays")
    func pixelScaleUsesBackingSize() {
        #expect(ScreenCaptureService.pixelScale(pixelWidth: 3024, pointWidth: 1512) == 2)
        #expect(ScreenCaptureService.pixelScale(pixelWidth: 3840, pointWidth: 1920) == 2)
        #expect(ScreenCaptureService.pixelScale(pixelWidth: 1920, pointWidth: 1920) == 1)
        // Unknown backing size must never shrink the capture.
        #expect(ScreenCaptureService.pixelScale(pixelWidth: 0, pointWidth: 1512) == 1)
    }

    @Test("duration milliseconds rounds to the nearest whole millisecond")
    func durationRoundsToNearestMillisecond() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(ScreenCaptureService.milliseconds(from: start, to: start.addingTimeInterval(0.1874)) == 187)
        #expect(ScreenCaptureService.milliseconds(from: start, to: start.addingTimeInterval(0.1876)) == 188)
    }

    @Test("duration milliseconds floors at zero for a clock that does not advance")
    func durationFloorsAtZero() {
        let instant = Date(timeIntervalSince1970: 1_000)
        #expect(ScreenCaptureService.milliseconds(from: instant, to: instant) == 0)
        // A clock that appears to run backward (e.g. an injected test clock
        // reset between calls) must never report a negative duration.
        #expect(ScreenCaptureService.milliseconds(from: instant, to: instant.addingTimeInterval(-1)) == 0)
    }
}

/// Thread-safe box for capturing diagnostics calls made from actor-isolated code.
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(String, [String: String])] = []

    func append(_ value: (String, [String: String])) {
        lock.lock()
        storage.append(value)
        lock.unlock()
    }

    var values: [(String, [String: String])] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Thread-safe mutable Bool for proving a provider closure is re-invoked
/// rather than snapshotted once.
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(_ initial: Bool) { storage = initial }

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

/// Thread-safe mutable Set, same purpose as `LockedFlag` but for
/// `excludedApps`-shaped providers.
final class LockedSet<Element: Hashable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Set<Element>

    init(_ initial: Set<Element>) { storage = initial }

    var value: Set<Element> {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}
