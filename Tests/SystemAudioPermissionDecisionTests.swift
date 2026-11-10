import Foundation

// These cases call the canonical permission entrypoints with every external
// effect supplied explicitly. They do not construct the live dependencies.
@MainActor
func testSystemAudioPermissionDecision() async {
    typealias Access = TranscriptedPermissionAccess
    typealias State = Access.SystemAudioPermissionState
    typealias Result = Access.SystemAudioPermissionProbeResult

    for initial: State in [.unknown, .denied, .granted] {
        for authorized in [false, true] {
            await runSuite("System audio decision — recorded TCC answer overrides \(initial), authorized=\(authorized)") {
                let fixture = SystemAudioDecisionFixture(
                    initial: initial, tcc: authorized ? .authorized : .denied
                )
                let decision = await Access.systemAudioRecordingAccessDecision(dependencies: fixture.dependencies)
                assertEqual(decision.state, authorized ? .granted : .denied, "TCC must correct the historical cache")
                assertEqual(decision.canProceed, authorized, "the current TCC answer controls admission")
                assertEqual(decision.probeResult, authorized ? .granted : .explicitlyDenied, "record definitive evidence")
                assertEqual(fixture.store.state, decision.state, "persist the corrected cache state")
                assertEqual(fixture.store.preflights, 1, "the canonical entrypoint must preflight TCC")
                fixture.assertNoPromptOrProbe()
            }
        }
    }

    for response: Bool? in [true, false, nil] {
        await runSuite("System audio decision — undetermined TCC clears cache before requesting \(String(describing: response))") {
            let fixture = SystemAudioDecisionFixture(initial: .granted, tcc: .notDetermined, requestResult: response)
            fixture.probeResult = .indeterminate(.prepareCapture)
            let decision = await Access.systemAudioRecordingAccessDecision(dependencies: fixture.dependencies)
            assertEqual(fixture.store.requestStates, [.unknown], "a reset must discard stale evidence before requesting")
            assertEqual(fixture.store.requests, 1, "use the injected macOS request path")
            if let response {
                assertEqual(decision.state, response ? .granted : .denied, "record the direct answer")
                assertEqual(decision.canProceed, response, "direct TCC answer controls admission")
                assertEqual(decision.probeResult, response ? .granted : .explicitlyDenied, "retain direct evidence")
                assertEqual(fixture.probeStates, [], "a direct answer needs no tap probe")
                assertEqual(fixture.notifications, 1, "recording the direct answer notifies permission consumers")
            } else {
                assertEqual(decision.state, .unknown, "an unavailable request plus failed setup is not a denial")
                assertFalse(decision.canProceed, "a transport failure cannot authorize a fresh start")
                assertEqual(decision.probeResult, .indeterminate(.prepareCapture), "retain fallback evidence")
                assertEqual(fixture.probeStates, [.unknown], "fallback probes use the cleared injected cache")
            }
            assertTrue(fixture.activations > 0, "the prompt path uses the supplied activation callback")
        }
    }

    await runSuite("System audio decision — unavailable TCC reuses a grant until forced") {
        let fixture = SystemAudioDecisionFixture(initial: .granted)
        fixture.probeResult = .explicitlyDenied
        let cached = await Access.systemAudioRecordingAccessDecision(dependencies: fixture.dependencies)
        assertTrue(cached.canProceed, "an unavailable TCC API preserves a verified historical grant")
        assertEqual(cached.state, .granted, "retain the cache")
        assertNil(cached.probeResult, "a cache hit is not a new probe")
        fixture.assertNoPromptOrProbe()
        let forced = await Access.systemAudioRecordingAccessDecision(forceRefresh: true, dependencies: fixture.dependencies)
        assertFalse(forced.canProceed, "forced rechecking must use the actual result")
        assertEqual(forced.state, .denied, "definitive denial clears the old grant")
        assertEqual(fixture.probeStates, [.granted], "pass the injected cached state to the probe")
        assertEqual(fixture.activations, 1, "activate only when a probe is needed")
        assertEqual(fixture.store.preflights, 2, "cache reuse must not bypass TCC")
    }

    for result: Result in [.granted, .explicitlyDenied] {
        await runSuite("System audio decision — definitive fresh probe \(result.diagnosticName) updates memory cache") {
            let fixture = SystemAudioDecisionFixture(initial: .unknown)
            fixture.probeResult = result
            let decision = await Access.systemAudioRecordingAccessDecision(dependencies: fixture.dependencies)
            let granted = result == .granted
            assertEqual(decision.state, granted ? .granted : .denied, "only definitive evidence changes unknown state")
            assertEqual(decision.canProceed, granted, "the admission result follows definitive evidence")
            assertEqual(decision.probeResult, result, "return the terminal evidence")
            assertEqual(fixture.store.state, decision.state, "write through the injected cache")
            assertEqual(fixture.probeStates, [.unknown], "probe the actual injected unknown state")
        }
    }

    // Explicit current stages: retired ScreenCaptureKit transport cases are
    // not resurrected by the test fixture.
    let stages: [Access.SystemAudioPermissionProbeStage] = [
        .timedOut, .cancelled, .startCapture, .prepareCapture, .silentAudio
    ]
    for initial: State in [.unknown, .denied, .granted] {
        for stage in stages {
            await runSuite("System audio decision — \(stage.rawValue) preserves \(initial) without inventing evidence") {
                let fixture = SystemAudioDecisionFixture(initial: initial)
                fixture.probeResult = .indeterminate(stage)
                let decision = await Access.systemAudioRecordingAccessDecision(forceRefresh: true, dependencies: fixture.dependencies)
                assertEqual(decision.state, initial, "indeterminate capture is not a TCC answer")
                assertEqual(fixture.store.state, initial, "do not manufacture or revoke a grant")
                assertEqual(fixture.store.cacheChanges, 0, "indeterminate evidence must not write or clear the cache")
                assertEqual(decision.probeResult, .indeterminate(stage), "retain the evidence limitation")
                let allowed = stage == .silentAudio || (initial == .granted && stage != .cancelled)
                assertEqual(decision.canProceed, allowed, "preserve current cached-grant, cancellation and quiet-capture policy")
            }
        }
    }

    await runSuite("System audio request wrapper — bool result follows canonical TCC decision") {
        let fixture = SystemAudioDecisionFixture(initial: .granted, tcc: .denied)
        let granted = await Access.requestSystemAudioRecordingAccessIfNeeded(dependencies: fixture.dependencies)
        assertFalse(granted, "the bool wrapper must not return an obsolete cached grant")
        assertEqual(fixture.store.state, .denied, "the wrapper shares canonical cache updates")
        assertEqual(fixture.store.preflights, 1, "the wrapper must use TCC-aware decision logic")
        fixture.assertNoPromptOrProbe()

        fixture.store.tcc = .unavailable
        fixture.probeResult = .granted
        let refreshed = await Access.requestSystemAudioRecordingAccessIfNeeded(forceRefresh: true, dependencies: fixture.dependencies)
        assertTrue(refreshed, "forced wrapper uses the injected probe")
        assertEqual(fixture.store.state, .granted, "record a fresh grant")
        assertEqual(fixture.probeStates, [.denied], "probe the current injected state")
    }

    for initial: State in [.unknown, .denied, .granted] {
        for tcc: SystemAudioCaptureTCCStatus in [.authorized, .denied, .notDetermined] {
            await runSuite("System audio revalidation — \(tcc.rawValue) refreshes \(initial) without probing") {
                let fixture = SystemAudioDecisionFixture(initial: initial, tcc: tcc)
                let granted = await Access.revalidateSystemAudioRecordingStatus(dependencies: fixture.dependencies)
                let expected: State = tcc == .authorized ? .granted : (tcc == .denied ? .denied : .unknown)
                assertEqual(fixture.store.state, expected, "fold the current TCC record into the cache")
                assertEqual(granted, expected == .granted, "return the refreshed grant")
                assertEqual(fixture.notifications, initial == expected ? 0 : 1, "notify only a changed permission state")
                assertEqual(fixture.store.preflights, 1, "revalidation consults TCC")
                fixture.assertNoPromptOrProbe()
            }
        }
    }

    await runSuite("System audio revalidation — unavailable TCC applies successive grant and denial") {
        let fixture = SystemAudioDecisionFixture(initial: .denied)
        fixture.probeResult = .granted
        let granted = await Access.revalidateSystemAudioRecordingStatus(dependencies: fixture.dependencies)
        assertTrue(granted, "a fresh probe replaces the prior denial")
        assertEqual(fixture.store.state, .granted, "record the grant")
        fixture.probeResult = .explicitlyDenied
        let denied = await Access.revalidateSystemAudioRecordingStatus(dependencies: fixture.dependencies)
        assertFalse(denied, "a subsequent denial replaces the prior grant")
        assertEqual(fixture.store.state, .denied, "record the revocation")
        assertEqual(fixture.probeStates, [.denied, .granted], "each completed revalidation uses the current cache")
        assertEqual(fixture.notifications, 2, "each completed fallback revalidation notifies consumers")
        assertEqual(fixture.activations, 0, "background revalidation does not activate the app")
    }

    for result: Result in [.indeterminate(.cancelled), .indeterminate(.prepareCapture), .indeterminate(.silentAudio)] {
        for initial: State in [.unknown, .granted] {
            await runSuite("System audio revalidation — \(result.diagnosticName) uses canonical evidence policy for \(initial)") {
                let fixture = SystemAudioDecisionFixture(initial: initial)
                fixture.probeResult = result
                let allowed = await Access.revalidateSystemAudioRecordingStatus(dependencies: fixture.dependencies)
                let expected = result == .indeterminate(.silentAudio)
                    || (initial == .granted && result != .indeterminate(.cancelled))
                assertEqual(allowed, expected, "revalidation must use the same evidence policy as a decision")
                assertEqual(fixture.store.state, initial, "inconclusive results preserve cache state")
                assertEqual(fixture.store.cacheChanges, 0, "do not write an inconclusive result")
                assertEqual(fixture.notifications, 1, "fallback completion notifies consumers")
            }
        }
    }

    for initial: State in [.unknown, .denied, .granted] {
        await runSuite("System audio revalidation — smoke mode returns injected \(initial) without external work") {
            let fixture = SystemAudioDecisionFixture(initial: initial, tcc: .authorized, smoke: true)
            let granted = await Access.revalidateSystemAudioRecordingStatus(dependencies: fixture.dependencies)
            assertEqual(granted, initial == .granted, "smoke mode uses only the injected historical state")
            assertEqual(fixture.store.preflights, 0, "smoke mode must not touch TCC")
            assertEqual(fixture.store.cacheChanges, 0, "smoke mode must not mutate the cache")
            assertEqual(fixture.notifications, 0, "smoke mode must not emit permission changes")
            fixture.assertNoPromptOrProbe()
        }
    }

    await runSuite("System audio decision — smoke refresh skips TCC but retains fallback policy") {
        let fixture = SystemAudioDecisionFixture(initial: .unknown, tcc: .denied, smoke: true)
        fixture.probeResult = .indeterminate(.prepareCapture)
        let decision = await Access.systemAudioRecordingAccessDecision(dependencies: fixture.dependencies)
        assertEqual(fixture.store.preflights, 0, "smoke refresh must not read TCC")
        assertEqual(fixture.store.requests, 0, "unavailable refresh must not request TCC")
        assertEqual(fixture.probeStates, [.unknown], "decision fallback remains distinct from smoke revalidation")
        assertEqual(decision.state, .unknown, "do not turn a skipped preflight into a denial")
        assertFalse(decision.canProceed, "retain existing unknown-transport-failure policy")
    }

    // Global revalidation singleflight is intentionally not given a runtime
    // claim here: no deterministic second-caller join witness is exposed.
    // Its existing implementation is retained and reviewed separately.
}

@MainActor
private final class SystemAudioDecisionFixture {
    typealias Access = TranscriptedPermissionAccess
    let store: SystemAudioDecisionMemory
    var probeResult: Access.SystemAudioPermissionProbeResult = .indeterminate(.prepareCapture)
    private(set) var probeStates: [Access.SystemAudioPermissionState] = []
    private(set) var activations = 0
    private(set) var notifications = 0

    init(
        initial: Access.SystemAudioPermissionState,
        tcc: SystemAudioCaptureTCCStatus = .unavailable,
        requestResult: Bool? = nil,
        smoke: Bool = false
    ) {
        store = SystemAudioDecisionMemory(state: initial, tcc: tcc, requestResult: requestResult, smoke: smoke)
    }

    var dependencies: Access.SystemAudioPermissionDependencies {
        let memory = store
        return Access.SystemAudioPermissionDependencies(
            cache: Access.SystemAudioPermissionCache(
                read: { memory.state },
                recordGrant: { memory.recordGrant($0) },
                clear: { memory.clear() }
            ),
            tcc: SystemAudioCaptureTCC(
                preflight: { memory.preflight() },
                request: { memory.request() }
            ),
            isSmokeMode: { memory.smoke },
            probe: { [self] state in
                probeStates.append(state)
                return probeResult
            },
            activateForPrompt: { [self] in activations += 1 },
            notifyChanged: { [self] in notifications += 1 }
        )
    }

    func assertNoPromptOrProbe() {
        assertEqual(store.requests, 0, "no request is needed")
        assertEqual(probeStates.count, 0, "no probe is needed")
        assertEqual(activations, 0, "no app activation is needed")
    }
}

// All mutable fields are behind one lock because the actual TCC abstraction
// accepts Sendable closures; no actor assumption or preference store is used.
private final class SystemAudioDecisionMemory: @unchecked Sendable {
    typealias State = TranscriptedPermissionAccess.SystemAudioPermissionState
    private let lock = NSLock()
    private var cached: State
    private var tccStatus: SystemAudioCaptureTCCStatus
    private let directAnswer: Bool?
    let smoke: Bool
    private var preflightCount = 0
    private var requestCount = 0
    private var statesAtRequest: [State] = []
    private var changes = 0

    init(state: State, tcc: SystemAudioCaptureTCCStatus, requestResult: Bool?, smoke: Bool) {
        cached = state
        tccStatus = tcc
        directAnswer = requestResult
        self.smoke = smoke
    }

    var state: State { lock.withLock { cached } }
    var preflights: Int { lock.withLock { preflightCount } }
    var requests: Int { lock.withLock { requestCount } }
    var requestStates: [State] { lock.withLock { statesAtRequest } }
    var cacheChanges: Int { lock.withLock { changes } }
    var tcc: SystemAudioCaptureTCCStatus {
        get { lock.withLock { tccStatus } }
        set { lock.withLock { tccStatus = newValue } }
    }

    func recordGrant(_ granted: Bool) {
        lock.withLock {
            cached = granted ? .granted : .denied
            changes += 1
        }
    }

    func clear() {
        lock.withLock {
            cached = .unknown
            changes += 1
        }
    }

    func preflight() -> SystemAudioCaptureTCCStatus {
        lock.withLock {
            preflightCount += 1
            return tccStatus
        }
    }

    func request() -> Bool? {
        lock.withLock {
            requestCount += 1
            statesAtRequest.append(cached)
            return directAnswer
        }
    }
}
