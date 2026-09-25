#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation
import Security

/// Owner-only unix socket between Tilde and its input method. Completion
/// context remains memory-only; explicit Personal History batches are routed
/// to the app-owned encrypted store.
final class GhostBrainServerHost: @unchecked Sendable {
    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
            .appendingPathComponent(TildeProductProfile.current.supportDirectoryName)
            .appendingPathComponent("ghost.sock")
            .path
    }

    private let runtime: LlamaServerProcessHost
    private let engine: LlamaCompletionEngine
    private let personalHistory: any PersonalHistoryIngesting
    /// Fired whenever a completion request reaches the socket — a bare
    /// timestamp pulse, never the request's content. Screen Memory's
    /// typing-pause trigger uses this as its "is a completion session
    /// active" signal; this file otherwise knows nothing about Screen
    /// Memory and never sees a `ScreenSnapshot`.
    private let onCompletionActivity: (@Sendable () -> Void)?
    /// Content-free field lifecycle pulses from the IME. The app turns
    /// these into Screen Memory capture triggers; no document text is
    /// carried by this callback.
    private let onScreenMemoryEvent: (@Sendable (ScreenMemoryInputEvent) -> Void)?
    /// Screen Memory plan Phase 2 PR 2b: resolves the current request's
    /// scene, already settings-gated by whoever constructs this host (see
    /// `AppDelegate`). `nil` — no provider, or the provider itself returning
    /// `nil` — means exactly today's (no-context) completion behavior; this
    /// file never inspects capture state itself.
    private let sceneProvider: (@Sendable (
        String?, String, String?, TypingTargetIdentity?
    ) async -> ScreenScene.Scene?)?
    /// Resolves the exact current field/window. Production fails closed when
    /// it cannot prove this identity; tests and proof hosts may omit it.
    private let targetProvider: (@Sendable (String?, String?) -> TypingTargetIdentity?)?
    /// 2026-08-16 owner directive: Screen Recording permission is required
    /// for Tilde to suggest at all, not merely to enrich suggestions with
    /// screen context. `nil` means "always allowed" (release-proof mode and
    /// tests that don't care about this gate); `AppDelegate` wires the real
    /// closure to `ScreenMemoryStatus.evaluate(...).allowsSuggestions` (Core,
    /// pure, tested — the same decision `StatusMenuHost`'s status line
    /// reads, so the menu and the actual suggestion behavior can never
    /// disagree), read fresh on every request so a permission revoked or a
    /// toggle flipped mid-session takes effect on the very next completion,
    /// and a permission granted mid-session resumes suggestions on the next
    /// completion too — no restart, no cached state to go stale.
    private let suggestionsGate: (@Sendable () -> Bool)?
    /// "Personal suggestions (experimental)" (`docs/plans/road-to-paid.md`
    /// Phase 3). Read fresh on every completion request, same shape and
    /// contract as `suggestionsGate`: `nil` means "always off" (release-
    /// proof mode and tests that don't care about this feature), so
    /// existing call sites are unaffected by this feature's addition.
    private let personalSuggestionsGate: (@Sendable () -> Bool)?
    /// The read-only lookup into `PersonalHistoryController`'s live trained
    /// model (see its `personalNextWordPrediction` doc comment). Takes the
    /// already-extracted tail words and the request's app bundle
    /// identifier — per-app exclusions are checked on the other end of this
    /// closure, inside the controller, using the exact same
    /// `personalHistoryExcludedApps` list capture already enforces (the
    /// covenant). `nil` means "no personal serving available" (release-
    /// proof mode and tests).
    private let personalNextWordProvider: (@Sendable ([String], String?) async -> PersonalNextWordPrediction?)?
    private let productProfile: TildeProductProfile
    /// The whole behaviour the app serves, stamped on every response line
    /// so the keyboard runs the same interaction policy and every outcome
    /// event names the configuration that produced it.
    private let configuration: TildeEffectiveConfiguration
    private let queue = DispatchQueue(label: "com.justinbetker.draft.ghost-brain-server")
    private var listenerFD: Int32 = -1
    private var lockFD: Int32 = -1
    private var source: DispatchSourceRead?
    private var ownsSocket = false

    init(
        runtime: LlamaServerProcessHost,
        personalHistory: any PersonalHistoryIngesting,
        sceneProvider: (@Sendable (
            String?, String, String?, TypingTargetIdentity?
        ) async -> ScreenScene.Scene?)? = nil,
        targetProvider: (@Sendable (String?, String?) -> TypingTargetIdentity?)? = nil,
        onCompletionActivity: (@Sendable () -> Void)? = nil,
        onScreenMemoryEvent: (@Sendable (ScreenMemoryInputEvent) -> Void)? = nil,
        suggestionsGate: (@Sendable () -> Bool)? = nil,
        personalSuggestionsGate: (@Sendable () -> Bool)? = nil,
        personalNextWordProvider: (@Sendable ([String], String?) async -> PersonalNextWordPrediction?)? = nil,
        configuration: TildeEffectiveConfiguration? = nil,
        productProfile: TildeProductProfile = TildeModelSelection.completionProfile(
            for: TildeProductProfile.current,
            productionChoice: TildeModelSelection.choice(for: TildeProductProfile.current)
        )
    ) {
        self.runtime = runtime
        self.productProfile = productProfile
        self.configuration = configuration ?? TildeEffectiveConfiguration.resolve(
            build: .current,
            completionProfile: productProfile,
            modelIdentifier: "unspecified"
        )
        self.engine = LlamaCompletionEngine(baseURL: runtime.baseURL, productProfile: productProfile)
        self.personalHistory = personalHistory
        self.sceneProvider = sceneProvider
        self.targetProvider = targetProvider
        self.onCompletionActivity = onCompletionActivity
        self.onScreenMemoryEvent = onScreenMemoryEvent
        self.suggestionsGate = suggestionsGate
        self.personalSuggestionsGate = personalSuggestionsGate
        self.personalNextWordProvider = personalNextWordProvider
    }

    func start() -> Bool {
        queue.sync { bindAndListen() }
    }

    func stop() {
        queue.sync {
            source?.cancel()
            source = nil
            if listenerFD >= 0 { close(listenerFD) }
            listenerFD = -1
            if ownsSocket { unlink(Self.socketPath) }
            ownsSocket = false
            if lockFD >= 0 {
                flock(lockFD, LOCK_UN)
                close(lockFD)
            }
            lockFD = -1
        }
    }

    private func bindAndListen() -> Bool {
        let directory = (Self.socketPath as NSString).deletingLastPathComponent
        guard Self.secureSocketDirectory(directory) else {
            DiagnosticsLog.shared.record("ghost-socket-unavailable", metadata: ["reason": "directory"])
            return false
        }
        let lockPath = directory + "/runtime.lock"
        let lockFD = open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        var lockInfo = stat()
        guard lockFD >= 0,
              fcntl(lockFD, F_SETFD, FD_CLOEXEC) == 0,
              fchmod(lockFD, S_IRUSR | S_IWUSR) == 0,
              fstat(lockFD, &lockInfo) == 0,
              lockInfo.st_mode & S_IFMT == S_IFREG,
              lockInfo.st_uid == getuid(),
              lockInfo.st_mode & 0o777 == 0o600,
              flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD) }
            DiagnosticsLog.shared.record("ghost-socket-unavailable", metadata: ["reason": "already-running"])
            return false
        }
        self.lockFD = lockFD
        unlink(Self.socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            if fd >= 0 { close(fd) }
            releaseLock()
            return false
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathOK = Self.socketPath.withCString { path in
            withUnsafeMutableBytes(of: &address.sun_path) { bytes -> Bool in
                guard strlen(path) < bytes.count else { return false }
                bytes.baseAddress!.assumingMemoryBound(to: CChar.self)
                    .update(from: path, count: strlen(path) + 1)
                return true
            }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = pathOK && withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 }
        }
        guard bound, listen(fd, 8) == 0, chmod(Self.socketPath, 0o600) == 0,
              Self.isOwnerOnlySocket(Self.socketPath) else {
            close(fd)
            unlink(Self.socketPath)
            releaseLock()
            return false
        }
        listenerFD = fd
        ownsSocket = true
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptOne() }
        source.resume()
        self.source = source
        return true
    }

    private func releaseLock() {
        if lockFD >= 0 {
            flock(lockFD, LOCK_UN)
            close(lockFD)
        }
        lockFD = -1
    }

    private func acceptOne() {
        let connection = accept(listenerFD, nil, nil)
        guard connection >= 0 else { return }
        guard fcntl(connection, F_SETFD, FD_CLOEXEC) == 0 else {
            close(connection)
            return
        }
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigpipe: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))

        // Clock starts here, not inside the task: the wait for a cooperative
        // pool slot is part of accept-to-parsed, and under load it is exactly
        // the tail this measurement exists to expose. Monotonic, so a clock
        // step cannot fabricate a 0ms sample for the percentiles.
        let acceptedAt = ProcessInfo.processInfo.systemUptime
        Task.detached(priority: .userInitiated) { [weak self] in
            defer { close(connection) }
            guard let self else { return }
            guard Self.authorizedPeer(connection) else {
                _ = Self.write(.unavailable, to: connection)
                return
            }
            guard case let .success(request) = Self.readRequest(
                connection,
                allowingPunctuation: self.configuration.interaction.requestsAfterPunctuation,
                allowingMidWord: self.configuration.interaction.requestsMidWordContinuation
            ) else {
                _ = Self.write(.invalidRequest, to: connection)
                return
            }
            // `authorizedPeer` resolves two full code-signing identities (the
            // peer's and our own) per accepted connection; that plus the wire
            // read is the most expensive fixed cost on the request path, and it
            // runs before `ghost-request-timing` starts counting. Its own event
            // rather than a second field on that one: a second timing field
            // would re-key the existing series and hand its whole-request
            // budget to this segment alone, leaving the sum unbudgeted.
            DiagnosticsLog.shared.record("ghost-handshake-timing", metadata: [
                "handshakeMilliseconds": String(Self.milliseconds(since: acceptedAt)),
            ])
            if case let .personalHistory(events) = request {
                let accepted = await self.personalHistory.ingest(events)
                _ = Self.write(accepted ? .recorded : .error, to: connection)
                return
            }
            if case let .screenMemory(event) = request {
                self.onScreenMemoryEvent?(event)
                _ = Self.write(.recorded, to: connection)
                return
            }
            guard case let .completion(completionRequest) = request else { return }
            // "P99 at every section" (2026-08-18): request total, parse to
            // response write. `defer` — not a single emit call at the
            // bottom of the closure — so every early return below (runtime
            // not ready, suggestions gate silence, sensitive-scene silence,
            // plus the normal completed path) still reports its own
            // duration, the same way `defer { close(connection) }` above
            // already guarantees cleanup on every exit.
            let requestStartedAt = Date()
            defer {
                DiagnosticsLog.shared.record("ghost-request-timing", metadata: [
                    "requestMilliseconds": String(Self.milliseconds(from: requestStartedAt, to: Date())),
                ])
            }
            self.onCompletionActivity?()
            let opportunityID = completionRequest.opportunityID
            guard await self.runtime.isReadyForCompletion() else {
                _ = self.writeStamped(
                    GhostBrainResponse.unavailable.stamped(
                        opportunityID: opportunityID, reason: .runtimeUnavailable, generated: false
                    ),
                    to: connection
                )
                return
            }
            // All-or-nothing gate (2026-08-16 owner directive): `.silence`,
            // never `.unavailable` — `.unavailable` tells the IME the brain
            // itself is missing and to try to summon it back
            // (`GhostInputController.summonBrainIfNeeded`), which is wrong
            // here: the app and model are fully up, Tilde is simply
            // withholding a suggestion by policy. `.silence` is the same
            // "nothing to show this time" outcome an ordinary empty
            // completion already produces, so the IME does nothing special
            // and nothing gets logged as a failure.
            guard self.suggestionsGate?() ?? true else {
                _ = self.writeStamped(.silence(reason: .suggestionsPaused, opportunityID: opportunityID), to: connection)
                return
            }

            let expectedTarget = self.targetProvider?(
                completionRequest.app,
                completionRequest.fieldSessionIdentifier
            )
            if self.targetProvider != nil, expectedTarget == nil {
                _ = self.writeStamped(.silence(reason: .fieldTargetLost, opportunityID: opportunityID), to: connection)
                return
            }
            let targetIsCurrent: @Sendable () -> Bool = { [targetProvider = self.targetProvider] in
                guard let targetProvider else { return true }
                return targetProvider(
                    completionRequest.app,
                    completionRequest.fieldSessionIdentifier
                ) == expectedTarget
            }

            // Read-only and fast (an actor property read, not a capture) —
            // resolved before the completion Task starts so the request
            // that follows already carries whatever context exists.
            let scene = await self.sceneProvider?(
                completionRequest.app,
                completionRequest.context,
                completionRequest.fieldSessionIdentifier,
                expectedTarget
            )
            guard targetIsCurrent() else {
                _ = self.writeStamped(.silence(reason: .fieldTargetLost, opportunityID: opportunityID), to: connection)
                return
            }

            // Trust-critical fix (2026-08-16, build 2705 dogfood): a grief
            // conversation produced a garbled-relationship suggestion and,
            // worse, a lateness cliché overpowering visible grief context.
            // Small models cannot reliably do relationship reasoning or
            // grief register, so when the current scene is emotionally
            // sensitive Tilde stays silent rather than guesses — same
            // `.silence` outcome (never `.unavailable`) as the permission
            // gate above, so the IME treats it as an ordinary empty
            // completion. Count-only diagnostic: never the matched category
            // or any scene text, only that suppression happened.
            if SensitiveScenePolicy.isSensitive(scene: scene) {
                _ = self.writeStamped(.silence(reason: .sensitiveScene, opportunityID: opportunityID), to: connection)
                DiagnosticsLog.shared.record("suggestion-suppressed", metadata: ["reason": "sensitive-scene"])
                return
            }
            if let reason = SceneSuggestionPolicy.suppressionReason(
                scene: scene,
                textBeforeCursor: completionRequest.context,
                options: self.productProfile.sceneSuggestionOptions
            ) {
                _ = self.writeStamped(
                    .silence(reason: SuggestionDecisionReason(scene: reason), opportunityID: opportunityID),
                    to: connection
                )
                DiagnosticsLog.shared.record(
                    "suggestion-suppressed",
                    metadata: ["reason": reason.rawValue]
                )
                return
            }

            // Read fresh, before either task starts, so the personal lookup
            // (if any) runs CONCURRENTLY with the llama call, not after it —
            // "never lengthen latency" (docs/plans/road-to-paid.md Phase 3).
            let personalSuggestionsEnabled = self.personalSuggestionsGate?() ?? false
            // The register the generator composes with: the same pure
            // function of the same scene and host the engine applies, sent
            // back on every response line so the outcome ledger records
            // what actually ran instead of re-deriving a register from the
            // host bundle (which calls a Screen-Memory chat reply in a
            // browser "prose").
            let register = ContinuationRegister.following(
                scene: scene,
                hostBundleIdentifier: completionRequest.app
            )
            // The provider resolves the race itself when it finishes, so every
            // waiter (the streaming gate, the terminal await) registers with
            // the race and can be released by its own deadline; nothing is
            // ever left blocked on the provider's task.
            let personalRace: PersonalLookupRace? = {
                guard personalSuggestionsEnabled, let provider = self.personalNextWordProvider else {
                    return nil
                }
                let tailWords = Self.personalTailWords(fromContext: completionRequest.context)
                guard !tailWords.isEmpty else { return nil }
                return PersonalLookupRace()
            }()
            let personalPredictionTask: Task<Void, Never>? = personalRace.map { race in
                let tailWords = Self.personalTailWords(fromContext: completionRequest.context)
                let provider = self.personalNextWordProvider!
                return Task { race.resolve(await provider(tailWords, completionRequest.app)) }
            }
            // Stream stable complete-word prefixes to peers that asked for
            // them. A personal prediction may replace the base ghost's first
            // word, so when one is actually racing the sink holds the first
            // prefix for a bounded window rather than giving up streaming
            // for the whole request (see `PartialResponseSink`).
            let configuration = self.configuration
            let midWordContext = RawContinuationPrompt.endsMidWord(completionRequest.context)
            let partials = PartialResponseSink(
                enabled: completionRequest.supportsStreamingResponses,
                holdingForPersonal: personalPredictionTask != nil,
                register: register,
                midWordContext: midWordContext,
                opportunityID: opportunityID,
                holdDeadlineNanoseconds: Self.personalStreamHoldNanoseconds,
                targetIsCurrent: targetIsCurrent,
                write: { response in
                    Self.write(response.stamped(configuration: configuration), to: connection)
                }
            )
            let completion = Task {
                try await self.engine.decide(
                    textBeforeCursor: completionRequest.context,
                    appBundleIdentifier: completionRequest.app,
                    scene: scene,
                    onPartialSuggestion: { partials.send($0, firstStableWordMilliseconds: $1) }
                )
            }
            partials.onWriteFailure = { completion.cancel() }
            // The gate must learn the answer as soon as it exists rather than
            // after generation finishes; its waiter is released by the same
            // deadline the terminal await uses.
            // Its clock is the request's, not the 250 ms terminal deadline: a
            // late answer that still precedes a slow model's first partial
            // must reach the gate. The waiter leaves the race when this task
            // is cancelled at the end of the request.
            let personalObserver: Task<Void, Never>? = personalRace.map { race in
                Task { [weak partials] in
                    if case let .predicted(prediction) = await race.value(
                        deadlineNanoseconds: Self.personalObserverCeilingNanoseconds
                    ) {
                        partials?.resolvePersonal(prediction)
                    }
                }
            }
            let disconnect = DispatchSource.makeReadSource(
                fileDescriptor: connection,
                queue: .global(qos: .userInitiated)
            )
            disconnect.setEventHandler {
                var byte: UInt8 = 0
                let count = recv(connection, &byte, 1, MSG_PEEK | MSG_DONTWAIT)
                if count == 0 || (count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR) {
                    completion.cancel()
                    personalPredictionTask?.cancel()
                }
            }
            disconnect.resume()
            let result = await completion.result
            // No partial may be written from here on: the terminal line is
            // next, and a held prefix flushed after it would land inside or
            // behind the answer it is supposed to precede.
            partials.finish()
            let personalPrediction: PersonalNextWordPrediction?
            switch result {
            case .success:
                personalPrediction = await Self.awaitPersonalPrediction(personalRace)
            case .failure:
                // This result is about to become an error/timeout response
                // and the personal prediction would be discarded either
                // way — don't let a slow personal lookup hold up writing it.
                personalPredictionTask?.cancel()
                personalPrediction = nil
            }
            personalObserver?.cancel()
            // Whatever the terminal wait decided, the provider's work is over:
            // a lookup that missed its deadline must not queue behind the
            // next request's on the shared actor.
            personalPredictionTask?.cancel()
            if personalSuggestionsEnabled, completionRequest.supportsStreamingResponses {
                DiagnosticsLog.shared.record(
                    "personal-stream-hold",
                    metadata: partials.holdDiagnostics()
                )
            }
            await withCheckedContinuation { continuation in
                disconnect.setCancelHandler { continuation.resume() }
                disconnect.cancel()
            }
            guard !completion.isCancelled else { return }
            guard targetIsCurrent() else {
                _ = self.writeStamped(.silence(reason: .fieldTargetLost, opportunityID: opportunityID), to: connection)
                return
            }

            let response: GhostBrainResponse
            let servedMetadata: [String: String]?
            var source: PersonalSuggestionSource?
            switch result {
            case let .success(decision):
                let baseText = decision.suggestion.map {
                    Self.servedText($0.visibleText, midWord: midWordContext)
                } ?? ""
                var text = baseText
                if personalSuggestionsEnabled {
                    // `streamedPrefix` is the grow-only promise: a prefix
                    // already on screen is never replaced, so a personal
                    // answer that arrives after the stream opened loses to
                    // the base ghost the writer is reading.
                    let applied = PersonalSuggestionPolicy.finalSuggestion(
                        baseGhost: baseText,
                        personalPrediction: personalPrediction,
                        streamedPrefix: partials.didStream
                    )
                    text = applied.text
                    source = applied.source
                }
                // The receipt names the engine's reason when nothing is
                // served; a base candidate the personal layer emptied is
                // an empty output, not a policy verdict the engine reached.
                let reason: SuggestionDecisionReason = text.isEmpty
                    ? (decision.suggestion == nil ? decision.reason : .emptyOutput)
                    : .shown
                response = GhostBrainResponse.suggestion(
                    text,
                    register: register,
                    source: TextFreeCandidateSource(personal: source)
                ).stamped(
                    opportunityID: opportunityID,
                    reason: reason,
                    generated: decision.generated,
                    generatorMilliseconds: decision.generatorMilliseconds,
                    firstStableWordMilliseconds: decision.firstStableWordMilliseconds
                )
                servedMetadata = text.isEmpty ? nil : Self.servedMetadata(
                    app: completionRequest.app,
                    text: text,
                    source: source
                )
            case let .failure(error):
                self.runtime.reportCompletionFailure()
                let timedOut = (error as? URLError)?.code == .timedOut
                response = (timedOut ? GhostBrainResponse.timeout : .error).stamped(
                    opportunityID: opportunityID,
                    reason: timedOut ? .timeout : .protocolError,
                    generated: false
                )
                servedMetadata = nil
            }
            if self.writeStamped(response, to: connection), let servedMetadata {
                DiagnosticsLog.shared.record("suggestion-served", metadata: servedMetadata)
                if let source {
                    PersonalSuggestionStats.record(source: source)
                }
            }
        }
    }

    /// The personal model must only ever see finished words. Mid-word
    /// requests (cursor inside a word, no trailing whitespace) now do reach
    /// here — `acceptsCompletionContext` lets them through whenever the
    /// served interaction policy turns mid-word continuation on — and this
    /// guard is what keeps personal serving word-boundary only regardless:
    /// a partial word fed to the model as a finished tail word could
    /// resolve to a confident prediction that gets glued onto the very word
    /// still being typed (e.g. "tomo" + "tomorrow" → "tomotomorrow"). The
    /// base model has a prompt shape for a partial word
    /// (`RawContinuationPrompt.partialWordToComplete`); the personal
    /// next-word path has none, so it declines. `internal`, not `private`,
    /// so it is directly testable.
    static func personalTailWords(fromContext context: String) -> [String] {
        guard RawContinuationPrompt.endsAtWordBoundary(context) else { return [] }
        return PersonalSuggestionPolicy.tailWords(fromContext: context)
    }

    /// The most a ready base ghost may be held up by a still-running
    /// personal-history lookup. `PersonalHistoryController` is a single
    /// actor shared with ingest/training work, so it can be busy; this
    /// keeps that from ever lengthening a request past a short, fixed
    /// budget — past the deadline the base ghost serves alone (`.base`
    /// source), exactly as if personal suggestions had produced nothing.
    private static let personalPredictionDeadlineNanoseconds: UInt64 = 250_000_000

    /// The most the FIRST streamed prefix may be held while the personal
    /// lookup races (`PartialResponseSink`). Deliberately far shorter than
    /// the 250ms terminal deadline above: that budget protects a finished
    /// answer nobody is looking at yet, this one delays a ghost the writer
    /// would otherwise already be reading. The lookup it waits on is one
    /// read of an in-memory table behind a shared actor — sub-millisecond
    /// unless that actor is busy with ingest or training — so tens of
    /// milliseconds covers the ordinary case, and anything slower simply
    /// streams and lets the terminal line honour the base ghost.
    ///
    /// Not an `InteractionPolicy`/`DecisionPolicy` knob: it is inert unless
    /// the owner-visible "Personal suggestions (experimental)" toggle is on,
    /// so putting it in the configuration digest would re-key all three
    /// shipped digests for a number no default configuration can reach.
    static let personalStreamHoldNanoseconds: UInt64 = 60_000_000

    /// The streaming observer's ceiling: generous, because it is bounded by
    /// the request's own lifetime (the observer is cancelled when the
    /// terminal line is written) and exists only so an abandoned race can
    /// never hold a waiter forever.
    static let personalObserverCeilingNanoseconds: UInt64 = 30_000_000_000

    /// One arm of the 250ms race actually decided the request; the other
    /// resolving too (or not at all) is irrelevant to the outcome. A plain
    /// `PersonalNextWordPrediction??` cannot tell "the model resolved with
    /// nothing" apart from "the deadline fired first" — both read as `nil`
    /// — so the race itself has to report which branch won, not just the
    /// value it produced.
    enum PersonalLookupRaceResult {
        case predicted(PersonalNextWordPrediction?)
        case timedOut
    }

    /// `now`/`diagnostics` are injectable for testability, same pattern as
    /// `ScreenCaptureService`'s clock/diagnostics closures — production call
    /// sites take the defaults (`Date.init`, `DiagnosticsLog.shared.record`)
    /// unchanged. Internal, not private, so `waitedMilliseconds`/`outcome`
    /// can be proven directly without a live socket.
    static func awaitPersonalPrediction(
        _ race: PersonalLookupRace?,
        now: @Sendable () -> Date = Date.init,
        diagnostics: @Sendable (String, [String: String]) -> Void = { event, metadata in
            DiagnosticsLog.shared.record(event, metadata: metadata)
        }
    ) async -> PersonalNextWordPrediction? {
        guard let race else {
            // No provider, the gate was off, or the context had no tail
            // words — no race ever ran, so `waitedMilliseconds` is exactly
            // 0, not "however long the caller happened to take to get here".
            diagnostics("personal-lookup-timing", ["waitedMilliseconds": "0", "outcome": "disabled"])
            return nil
        }
        let waitStartedAt = now()
        let raceResult = await race.value(deadlineNanoseconds: personalPredictionDeadlineNanoseconds)
        let waitedMilliseconds = milliseconds(from: waitStartedAt, to: now())
        let prediction: PersonalNextWordPrediction?
        let outcome: String
        switch raceResult {
        case let .predicted(value):
            prediction = value
            outcome = "resolved"
        case .timedOut:
            prediction = nil
            outcome = "timeout"
        }
        diagnostics("personal-lookup-timing", [
            "waitedMilliseconds": String(waitedMilliseconds),
            "outcome": outcome,
        ])
        return prediction
    }

    /// What goes on the wire for a cleaned suggestion. At a word or
    /// punctuation boundary the leading whitespace is stripped and the
    /// keyboard restores the separator it needs; inside a word a leading
    /// space is the answer's meaning — "start a new word" rather than
    /// "finish this one" — and stripping it glued the ghost onto the
    /// writer's last letter ("thebest"). `internal` for tests.
    static func servedText(_ visibleText: String, midWord: Bool) -> String {
        midWord ? visibleText : String(visibleText.drop(while: \Character.isWhitespace))
    }

    /// The personal lookup as a race every interested party can join and
    /// leave on its own clock. The provider resolves it once when it
    /// finishes; each waiter registers a continuation and a deadline, and
    /// is resumed by whichever comes first — the answer, or its own
    /// deadline. A waiter that times out is removed, so a slow provider
    /// leaves nothing suspended behind it. `internal` for tests.
    final class PersonalLookupRace: @unchecked Sendable {
        private let lock = NSLock()
        private var result: PersonalLookupRaceResult?
        private var waiters: [UUID: CheckedContinuation<PersonalLookupRaceResult, Never>] = [:]

        init() {}

        /// The provider's one answer. Later calls are ignored.
        func resolve(_ prediction: PersonalNextWordPrediction?) {
            let released: [CheckedContinuation<PersonalLookupRaceResult, Never>] = lock.withLock {
                guard result == nil else { return [] }
                result = .predicted(prediction)
                defer { waiters.removeAll() }
                return Array(waiters.values)
            }
            for waiter in released { waiter.resume(returning: .predicted(prediction)) }
        }

        /// Resumes with the answer, or `.timedOut` at the deadline or when
        /// the waiting task is cancelled — either way the waiter is removed.
        func value(deadlineNanoseconds: UInt64) async -> PersonalLookupRaceResult {
            let ticket = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let immediate: PersonalLookupRaceResult? = lock.withLock {
                        if let result { return result }
                        waiters[ticket] = continuation
                        return nil
                    }
                    if let immediate {
                        continuation.resume(returning: immediate)
                        return
                    }
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: deadlineNanoseconds)
                        self?.timeOut(ticket)
                    }
                }
            } onCancel: {
                timeOut(ticket)
            }
        }

        private func timeOut(_ ticket: UUID) {
            let waiter: CheckedContinuation<PersonalLookupRaceResult, Never>? = lock.withLock {
                waiters.removeValue(forKey: ticket)
            }
            waiter?.resume(returning: .timedOut)
        }
    }

    /// Whole milliseconds between two instants, floored at zero — same
    /// rounding/floor behavior as `ScreenCaptureService.milliseconds`,
    /// duplicated here rather than shared because the two types have no
    /// common module to host it in without a bigger refactor than this
    /// change warrants. Internal, not private, so the rounding is directly
    /// testable.
    static func milliseconds(from start: Date, to end: Date) -> Int {
        max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    /// Monotonic counterpart, for spans timed with `systemUptime`.
    static func milliseconds(since start: TimeInterval) -> Int {
        max(0, Int(((ProcessInfo.processInfo.systemUptime - start) * 1_000).rounded()))
    }

    /// Adds `source` only when the "Personal suggestions (experimental)"
    /// toggle was actually consulted this request — toggle-off behavior
    /// stays byte-identical to before this feature existed, no `source`
    /// key appears at all.
    private static func servedMetadata(
        app: String?,
        text: String,
        source: PersonalSuggestionSource?
    ) -> [String: String] {
        var metadata = [
            "app": app ?? "unknown",
            "chars": String(text.count),
        ]
        if let source { metadata["source"] = source.rawValue }
        return metadata
    }

    private enum ValidatedRequest {
        case completion(GhostBrainRequest)
        case personalHistory([PersonalHistoryEvent])
        case screenMemory(ScreenMemoryInputEvent)
    }

    /// Where a completion request is allowed to have left the caret.
    ///
    /// A word boundary always, request punctuation when the served
    /// interaction policy allows it, and — only when that policy turns
    /// mid-word continuation on — a context that ends inside a word the
    /// writer has already typed at least
    /// `RawContinuationPrompt.minimumMidWordPartialLetters` letters of. The
    /// wire is the boundary where the two processes could disagree, so the
    /// check is made against the same served policy the keyboard adopted,
    /// not against this build's own bundle. `internal` for tests: the socket
    /// itself is not unit-testable, this predicate is.
    static func acceptsCompletionContext(
        _ context: String,
        allowingPunctuation: Bool,
        allowingMidWord: Bool
    ) -> Bool {
        RawContinuationPrompt.requestBoundary(
            in: context,
            allowingPunctuation: allowingPunctuation,
            allowingMidWord: allowingMidWord
        ) != nil
    }

    private static func readRequest(
        _ fd: Int32,
        allowingPunctuation: Bool,
        allowingMidWord: Bool
    ) -> Result<ValidatedRequest, Error> {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while data.count < GhostBrainRequest.maximumWireBytes {
            let count = Darwin.read(
                fd,
                &buffer,
                min(buffer.count, GhostBrainRequest.maximumWireBytes - data.count)
            )
            guard count > 0 else { return .failure(WireError.invalid) }
            data.append(contentsOf: buffer[0..<count])
            guard let newline = data.firstIndex(of: 0x0A) else { continue }
            data = data.prefix(upTo: newline)
            guard let request = try? JSONDecoder().decode(GhostBrainRequest.self, from: data),
                  request.v == GhostBrainRequest.version else {
                return .failure(WireError.invalid)
            }
            if let events = request.personalHistoryEvents {
                guard request.context.isEmpty, request.app == nil,
                      request.screenMemoryEvent == nil,
                      request.fieldSessionIdentifier == nil,
                      request.experimentArm == nil,
                      PersonalHistoryEvent.validBatch(events) else {
                    return .failure(WireError.invalid)
                }
                return .success(.personalHistory(events))
            }
            if let event = request.screenMemoryEvent {
                guard request.context.isEmpty, request.app == nil,
                      request.personalHistoryEvents == nil,
                      request.fieldSessionIdentifier == nil,
                      request.experimentArm == nil,
                      UUID(uuidString: event.sessionIdentifier) != nil else {
                    return .failure(WireError.invalid)
                }
                return .success(.screenMemory(event))
            }
            guard !request.context.isEmpty,
                  request.screenMemoryEvent == nil,
                  request.context.count <= 3_000,
                  Self.acceptsCompletionContext(
                      request.context,
                      allowingPunctuation: allowingPunctuation,
                      allowingMidWord: allowingMidWord
                  ),
                  request.fieldSessionIdentifier.map({ UUID(uuidString: $0) != nil }) ?? true,
                  (request.app?.count ?? 0) <= 512 else {
                return .failure(WireError.invalid)
            }
            return .success(.completion(request))
        }
        return .failure(WireError.invalid)
    }

    private enum WireError: Error { case invalid }

    /// Serializes partial writes from the engine's stream loop. A failed
    /// write means the input method is gone or wedged; the sink then cancels
    /// inference instead of letting the helper run for nobody.
    ///
    /// It is also the streaming gate for "Personal suggestions
    /// (experimental)". A personal answer may replace the base ghost's first
    /// word, and the keyboard grows a visible ghost rather than rewriting it
    /// — which is why this sink used to be constructed disabled outright
    /// whenever the toggle was on, silently costing every request its
    /// word-by-word ghost. Instead the sink now holds the FIRST stable
    /// prefix, and only that one, for a short bounded window while the
    /// personal lookup races:
    ///
    /// - a replacement that wins inside the window closes the stream and the
    ///   request answers with one final line (nothing was shown, so nothing
    ///   is rewritten);
    /// - a base or agreed answer, or an expired window, releases the held
    ///   prefix and streaming continues exactly as it does with the toggle
    ///   off;
    /// - once anything has been written the terminal line honours the base
    ///   ghost (`PersonalSuggestionPolicy.finalSuggestion`), so a late
    ///   personal answer can never rewrite what the writer is reading.
    ///
    /// Internal, not private, so the state machine is provable without a
    /// live socket: `write` is injected, and `expireHold` is the window
    /// firing.
    final class PartialResponseSink: @unchecked Sendable {
        /// One event per request, fixed vocabulary, no candidate text.
        enum HoldOutcome: String, CaseIterable {
            /// Streamed with nothing ever held — no personal lookup ran, or it
            /// answered before the first prefix. (The diagnostic is recorded
            /// only for streaming peers, so there is no "unstreamed" case.)
            case notHeld = "not-held"
            /// A prefix was held and the personal answer released it in time.
            case streamed
            /// A prefix was held until the window expired, then released.
            case expired
            /// A personal replacement won while holding; final-only.
            case finalOnly = "final-only"
            /// The request ended while the prefix was still held: the writer
            /// got no streamed ghost because the personal lookup never
            /// answered in time. The one outcome that costs the writer.
            case heldUntilEnd = "held-until-end"
        }

        private enum GateState { case streaming, holding, closed }

        private let enabled: Bool
        private let register: ContinuationRegister
        private let midWordContext: Bool
        private let opportunityID: String?
        private var firstStableWordMilliseconds: Int?
        private let holdDeadlineNanoseconds: UInt64
        private let targetIsCurrent: @Sendable () -> Bool
        private let write: @Sendable (GhostBrainResponse) -> Bool
        private let lock = NSLock()
        private var state: GateState
        private var failed = false
        private var failureHandler: (() -> Void)?
        private var heldPartial: String?
        private var holdStartedAt: Date?
        private var heldMilliseconds = 0
        private var wroteAnything = false
        private var personalLookup: PersonalLookupState
        private var outcome: HoldOutcome
        private var expiryTimer: Task<Void, Never>?

        init(
            enabled: Bool,
            holdingForPersonal: Bool,
            register: ContinuationRegister,
            midWordContext: Bool = false,
            opportunityID: String? = nil,
            holdDeadlineNanoseconds: UInt64,
            targetIsCurrent: @escaping @Sendable () -> Bool,
            write: @escaping @Sendable (GhostBrainResponse) -> Bool
        ) {
            self.enabled = enabled
            self.register = register
            self.midWordContext = midWordContext
            self.opportunityID = opportunityID
            self.holdDeadlineNanoseconds = holdDeadlineNanoseconds
            self.targetIsCurrent = targetIsCurrent
            self.write = write
            let holding = enabled && holdingForPersonal
            state = holding ? .holding : .streaming
            personalLookup = holding ? .pending : .resolved(nil)
            outcome = .notHeld
        }

        var onWriteFailure: (() -> Void)? {
            get { lock.withLock { failureHandler } }
            set { lock.withLock { failureHandler = newValue } }
        }

        /// Whether any prefix reached the keyboard. The terminal line must
        /// honour the base ghost whenever this is true.
        var didStream: Bool { lock.withLock { wroteAnything } }

        func send(_ partial: CompletionSuggestion, firstStableWordMilliseconds: Int? = nil) {
            guard enabled else { return }
            lock.withLock {
                if self.firstStableWordMilliseconds == nil { self.firstStableWordMilliseconds = firstStableWordMilliseconds }
            }
            guard targetIsCurrent() else {
                lock.withLock {
                    guard !failed else { return }
                    failed = true
                    failureHandler?()
                }
                return
            }
            let text = GhostBrainServerHost.servedText(partial.visibleText, midWord: midWordContext)
            guard !text.isEmpty else { return }
            lock.lock()
            defer { lock.unlock() }
            guard !failed, state != .closed else { return }
            if state == .holding {
                heldPartial = text
                applyDecisionLocked()
                return
            }
            writeLocked(text)
        }

        /// The personal lookup answered. Called at most once per request,
        /// from the observer that shares the lookup task with
        /// `awaitPersonalPrediction`.
        func resolvePersonal(_ prediction: PersonalNextWordPrediction?) {
            lock.lock()
            defer { lock.unlock() }
            personalLookup = .resolved(prediction)
            guard state == .holding else { return }
            applyDecisionLocked()
        }

        /// The bounded hold window elapsed: release the prefix and stream.
        /// A personal answer that lands after this can no longer replace it.
        func expireHold() {
            lock.lock()
            defer { lock.unlock() }
            guard state == .holding else { return }
            releaseLocked(outcome: .expired)
        }

        /// No further partials may be written for this request. Taken before
        /// the terminal line is written so a held prefix can never be
        /// flushed into the middle of it.
        func finish() {
            let timer: Task<Void, Never>? = lock.withLock {
                if state == .holding {
                    stopHoldClockLocked()
                    if heldPartial != nil { outcome = .heldUntilEnd }
                }
                state = .closed
                heldPartial = nil
                let timer = expiryTimer
                expiryTimer = nil
                return timer
            }
            timer?.cancel()
        }

        /// The request's one hold event. Fixed words and a duration only.
        func holdDiagnostics() -> [String: String] {
            lock.withLock {
                ["outcome": outcome.rawValue, "heldMilliseconds": String(heldMilliseconds)]
            }
        }

        private func applyDecisionLocked() {
            switch PersonalSuggestionPolicy.streamDecision(
                basePrefix: heldPartial,
                personalLookup: personalLookup
            ) {
            case .hold:
                startHoldClockLocked()
            case .stream:
                releaseLocked(outcome: holdStartedAt == nil ? .notHeld : .streamed)
            case .finalOnly:
                stopHoldClockLocked()
                state = .closed
                heldPartial = nil
                outcome = .finalOnly
            }
        }

        private func releaseLocked(outcome released: HoldOutcome) {
            stopHoldClockLocked()
            state = .streaming
            outcome = released
            if let heldPartial {
                self.heldPartial = nil
                writeLocked(heldPartial)
            }
        }

        /// Only a prefix that actually exists starts the clock — a personal
        /// lookup still running while the generator has produced nothing has
        /// delayed no ghost, and must not be reported as if it had.
        private func startHoldClockLocked() {
            guard heldPartial != nil, holdStartedAt == nil, expiryTimer == nil else { return }
            holdStartedAt = Date()
            expiryTimer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.holdDeadlineNanoseconds ?? 0)
                guard !Task.isCancelled else { return }
                self?.expireHold()
            }
        }

        private func stopHoldClockLocked() {
            if let holdStartedAt {
                heldMilliseconds = GhostBrainServerHost.milliseconds(from: holdStartedAt, to: Date())
                self.holdStartedAt = nil
            }
            expiryTimer?.cancel()
            expiryTimer = nil
        }

        private func writeLocked(_ text: String) {
            guard !failed else { return }
            if write(GhostBrainResponse.partial(
                text,
                register: register,
                opportunityID: opportunityID,
                firstStableWordMilliseconds: firstStableWordMilliseconds
            )) {
                wroteAnything = true
            } else {
                failed = true
                DiagnosticsLog.shared.record("ghost-partial-write-failed", metadata: [:])
                failureHandler?()
            }
        }
    }

    /// Every completion-path line carries the configuration stamp.
    private func writeStamped(_ response: GhostBrainResponse, to fd: Int32) -> Bool {
        Self.write(response.stamped(configuration: configuration), to: fd)
    }

    private static func write(_ response: GhostBrainResponse, to fd: Int32) -> Bool {
        guard var data = try? JSONEncoder().encode(response) else { return false }
        data.append(0x0A)
        var offset = 0
        return data.withUnsafeBytes { bytes in
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                guard count > 0 else {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
    }

    private static func authorizedPeer(_ fd: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { return false }
#if DEBUG
        if Bundle.main.bundleIdentifier != TildeProductProfile.current.appBundleIdentifier {
            return ProcessInfo.processInfo.environment["TRANSCRIPTED_WRITING_ALLOW_UNSIGNED_LOCAL_PEER"] == "1"
        }
#else
        guard Bundle.main.bundleIdentifier == TildeProductProfile.current.appBundleIdentifier else { return false }
#endif
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return false }
        guard let peer = cachedIdentity(pid: pid),
              peer.identifier == TildeProductProfile.current.inputMethodBundleIdentifier,
              let own = cachedIdentity(pid: getpid()) else { return false }
#if DEBUG
        if let ownTeam = own.team, let peerTeam = peer.team {
            return ownTeam == peerTeam
        }
        return own.team == nil
            && peer.team == nil
            && ProcessInfo.processInfo.environment["TRANSCRIPTED_WRITING_ALLOW_UNSIGNED_LOCAL_PEER"] == "1"
#else
        guard let ownTeam = own.team, let peerTeam = peer.team else { return false }
        return ownTeam == peerTeam
#endif
    }

    /// `authorizedPeer` resolved two Security-framework identities (the
    /// keyboard's and our own) per accepted connection — the cost the
    /// `ghost-handshake-timing` budget exists to watch. A live process
    /// instance cannot change its code, so each answer is remembered per
    /// (pid, kernel start time); see `ProcessPeerIdentityCache`. When the
    /// start time cannot be read the identity is resolved uncached, as before.
    private static let identityCache = ProcessPeerIdentityCache<CodeSigningIdentity>()

    private static func cachedIdentity(pid: pid_t) -> CodeSigningIdentity? {
        identityCache.identity(for: processKey(pid: pid)) { identity(pid: pid) }
    }

    private static func processKey(pid: pid_t) -> ProcessIdentityKey? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return ProcessIdentityKey(
            pid: pid,
            startedAtSeconds: Int64(info.pbi_start_tvsec),
            startedAtMicroseconds: Int64(info.pbi_start_tvusec)
        )
    }

    private static func identity(pid: pid_t) -> CodeSigningIdentity? {
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            [kSecGuestAttributePid: pid] as CFDictionary,
            [],
            &code
        ) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let values = information as? [CFString: Any],
              let identifier = values[kSecCodeInfoIdentifier] as? String else { return nil }
        return CodeSigningIdentity(
            identifier: identifier,
            team: values[kSecCodeInfoTeamIdentifier] as? String
        )
    }

    private static func secureSocketDirectory(_ path: String) -> Bool {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        } catch {
            return false
        }
        var info = stat()
        guard lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(),
              chmod(path, 0o700) == 0,
              lstat(path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(),
              info.st_mode & 0o777 == 0o700 else { return false }
        return true
    }

    private static func isOwnerOnlySocket(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
            && info.st_mode & S_IFMT == S_IFSOCK
            && info.st_uid == getuid()
            && info.st_mode & 0o777 == 0o600
    }

}
