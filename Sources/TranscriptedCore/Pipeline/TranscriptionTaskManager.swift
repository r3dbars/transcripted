import Foundation
import AVFoundation

// MARK: - Transcription Task Queue & Orchestration
// Extensions in: SpeakerNamingCoordinator.swift, TranscriptionPipelineRunner.swift,
// TranscriptionTaskManager+Start.swift, +FailureClassification.swift,
// +FailedAudioRetention.swift, +OrphanedRecordingRecovery.swift, +Retry.swift,
// +CleanupPaths.swift
// Types in: DisplayStatus.swift (DisplayStatus enum, TranscriptionTask struct)

@available(macOS 14.0, *)
@MainActor
public class TranscriptionTaskManager: ObservableObject {
    struct ActiveTaskAudio {
        let micURL: URL?
        let systemURL: URL?
        let meetingTitle: String?
        let recordingDate: Date?
        let importedRecoverySession: (any ImportedTranscriptionRecoverySession)?
        let splitLocalSpeakers: Bool
        let languageSelection: TranscriptionLanguageSelection
        let micOnlyByChoice: Bool
    }

    /// Every task tracked by this manager is in exactly one of these states by
    /// construction. This replaced four collections that used to be updated in
    /// lockstep, keyed by the same `UUID`, with fragile ordering requirements
    /// (`activeTaskAudio`, `preservedTaskIdsForShutdown`,
    /// `intentionallyCancelledTaskIds`, `committedTranscriptTaskIds`). See the
    /// combination-analysis in the PR description for how each case was derived
    /// from the reachable combinations of those four collections.
    ///
    /// `activeTasks: [UUID: Task<Void, Never>]` (the actual concurrency handle)
    /// stays a separate stored property rather than folding into this enum: it
    /// is directly poked by several test files (`manager.activeTasks[id] =
    /// sentinel`, `.removeValue(forKey:)`) as an occupancy-guard test seam, so
    /// collapsing it here would mean rewriting those direct pokes for no
    /// behavior change. `TaskLifecycleState` is looked up by the same `UUID`
    /// used as an `activeTasks` key; every key that appears in `activeTasks`
    /// should have a corresponding entry here, but the reverse is not always
    /// true (see `.preservedForShutdown`).
    private enum TaskLifecycleState {
        /// Running normally: not yet committed, cancelled, or preserved.
        /// `audio` is `nil` for saved-audio-retranscription and failed-row
        /// retry tasks, which reuse already-retained source files and were
        /// never entered into the old `activeTaskAudio` map either.
        case active(audio: ActiveTaskAudio?)

        /// `markTaskTranscriptCommitted(taskId:)` ran while the task was still
        /// occupying `activeTasks` (finishing speaker-naming / scratch-cleanup
        /// work after the transcript already saved). `audio` mirrors whatever
        /// the task started with — imported jobs still need
        /// `importedRecoverySession` after commit.
        case committed(audio: ActiveTaskAudio?)

        /// `cancelAll()` marked this task's outcome as intentionally
        /// cancelled. Audio (if any) was already synchronously discarded or
        /// handed to a retry row by `cancelAll()` before this state was entered.
        case cancelling

        /// `cancelAll()` raced a task whose side effects had *already*
        /// committed — reachable, not merely theoretical, because `cancelAll()`
        /// unconditionally marks every `activeTasks` key cancelled without
        /// checking commit state first. The marker is transient: the next
        /// `finishCancelledTaskIfNeeded` call collapses this back to
        /// `.committed` (dropping the cancel marker) so the task's own success
        /// path still runs and its outcome is preserved.
        case cancellingCommitted

        /// `preserveActiveTranscriptionsForShutdown()` already synchronously
        /// persisted this task's audio into the failed queue and evicted it
        /// from `activeTasks` and the occupancy counters. Only this marker
        /// remains so the still-running (uncooperative CoreML) task body can
        /// recognize its own outcome should be suppressed when it eventually
        /// returns. Deliberately has no associated `Task<Void, Never>` — by
        /// the time this case exists, `activeTasks` no longer has an entry for
        /// this id.
        ///
        /// `wasCommitted` carries forward whatever `isCommitted` was true at the
        /// moment of preservation. This is required, not decorative: on the old
        /// five-collection code, `committedTranscriptTaskIds` and
        /// `preservedTaskIdsForShutdown` were independent `Set`s, so a task that
        /// committed *before* shutdown kept its committed membership even after
        /// `cancelAll()` later wiped `preservedTaskIdsForShutdown` with its own
        /// unconditional `.removeAll()` — `finishCancelledTaskIfNeeded` would
        /// still see `committedTranscriptTaskIds.contains(taskId) == true` and
        /// give the committed outcome precedence over the task's own
        /// `CancellationError`. Collapsing to a payload-less `.preservedForShutdown`
        /// would silently lose that precedence the moment `cancelAll()` clears the
        /// marker. See `cancelAll()`'s handling of this case.
        case preservedForShutdown(wasCommitted: Bool)

        var audio: ActiveTaskAudio? {
            switch self {
            case .active(let audio), .committed(let audio):
                return audio
            case .cancelling, .cancellingCommitted, .preservedForShutdown:
                return nil
            }
        }

        var isCommitted: Bool {
            switch self {
            case .committed, .cancellingCommitted:
                return true
            case .preservedForShutdown(let wasCommitted):
                return wasCommitted
            case .active, .cancelling:
                return false
            }
        }

        var isCancelling: Bool {
            switch self {
            case .cancelling, .cancellingCommitted:
                return true
            case .active, .committed, .preservedForShutdown:
                return false
            }
        }
    }

    @Published public var activeCount: Int = 0
    @Published public var justCompleted: Bool = false
    @Published public var displayStatus: DisplayStatus = .idle
    @Published public var backgroundTaskCount: Int = 0
    @Published public var speakerNamingRequest: SpeakerNamingRequest? = nil
    @Published public var lastSavedTranscriptURL: URL? = nil
    @Published public private(set) var lastSavedTranscriptTaskId: UUID? = nil
    /// Where the most recent saved transcript's job spent its time; nil when
    /// the save did not come from a timed pipeline run.
    public private(set) var lastPipelineTimings: MeetingPipelineTimings.Snapshot? = nil
    @Published public var lastSavedTitle: String? = nil
    @Published public var lastSavedDuration: String? = nil
    @Published public var lastSavedSpeakerCount: Int? = nil
    @Published public private(set) var lastFailureDiagnosticMessage: String? = nil
    @Published public private(set) var lastFailureErrorKind: PipelineErrorKind? = nil
    /// Coarse reason for the latest speaker review save failure. Set before the
    /// matching failed `displayStatus` so status observers can read it in their sink.
    @Published public private(set) var lastSpeakerFinalizationFailure: SpeakerFinalizationFailure? = nil

    var lastSavedTranscriptId: UUID?
    private var savedTranscriptTaskIdsByTranscriptId: [UUID: UUID] = [:]
    private var savedTranscriptTaskIdsByURL: [URL: UUID] = [:]
    var activeTasks: [UUID: Task<Void, Never>] = [:]
    /// Single source of truth for everything the old `activeTaskAudio` /
    /// `preservedTaskIdsForShutdown` / `intentionallyCancelledTaskIds` /
    /// `committedTranscriptTaskIds` collections tracked. See
    /// `TaskLifecycleState` for the combination analysis.
    private var tasks: [UUID: TaskLifecycleState] = [:]
    var pendingSpeakerNamingRequests: [SpeakerNamingRequest] = []
    var deferredSpeakerNamingRequests: [UUID: SpeakerNamingRequest] = [:]
    let speakerNamingRequestOwnership = SpeakerNamingRequestOwnership()
    let speakerReviewProfileProtection = SpeakerReviewProfileProtection()
    public let transcription: Transcription

    public let failedTranscriptionManager: FailedTranscriptionManager
    public let statsStore: (any StatsStore)?
    let retainedAudioDirectory: URL?
    let retainedAudioDirectoryProvider: (() -> URL?)?
    let transcriptFormatOptionsProvider: (() -> TranscriptFormatOptions)?
    let cleanupDirectories: [URL]
    /// Audio the app layer has spoken for but that Core cannot see on its own.
    /// Today that is meeting jobs sitting in the app's transcription queue:
    /// they have no entry in `tasks` until they actually start, so orphan
    /// recovery would otherwise archive and unlink audio a queued job is about
    /// to open. Set by the app layer; nil in Core-only contexts and tests.
    public var reservedAudioURLsProvider: (() -> [URL])?
    /// Speaker-lab hook: receives each live meeting's Phase 1 result (exact
    /// utterance times, channels, diarizer and saved-speaker IDs) before speaker
    /// classification, so `Tools/SpeakerEvalHarness` can score naming rows
    /// against a simulated answer key. The app never sets it.
    public var pipelineResultObserver: (@Sendable (TranscriptionResult) -> Void)?
    /// Per-meeting speaker separation for the call channel (SpeakerSeparation.swift).
    /// The app sets this to turn on "split generously, then merge smartly" and to pass
    /// a speaker cap from the calendar invite. Called once per transcription run with
    /// the meeting's recording date, or nil for an imported file (whose date can't
    /// name a meeting); nil (the default) keeps the shipped behavior.
    public var speakerSeparationProvider: (@Sendable (_ recordingDate: Date?) async -> SpeakerSeparationOptions?)?
    /// Lineup naming: who is expected in this meeting (the calendar invite, else the
    /// people heard most recently). When a voice's best match is on the lineup, silent
    /// naming uses `SpeakerNamingPolicy.InviteeBars` instead of the stricter default
    /// bars. The app sets this only when the feature is on; nil keeps today's behavior.
    /// Called once per transcription run with the meeting's recording date; imported
    /// files never call it (their date can't name a meeting).
    public var lineupNamingProvider: (@Sendable (_ recordingDate: Date?) async -> SpeakerNamingPolicy.LineupRequest?)?
    /// True when the speaker review lists voices that were named on their own
    /// (the Notch island's "who was on the call"). Only then does the pipeline
    /// cut a clip for each recognized voice and queue a review for a meeting
    /// where everyone was recognized. Nil or false (the review window, Core-only
    /// contexts, tests) finishes such a meeting at once, as before.
    public var reviewListsRecognizedVoicesProvider: (@MainActor () -> Bool)?

    /// Scratch-directory mic placeholders minted for system-only failures,
    /// keyed by task. When the archive pass later mints a second placeholder
    /// inside the retained-audio directory and repoints the row, the scratch
    /// one is orphaned — no sweeper matches its uuid-suffixed name — so it is
    /// tracked here and retired once the repoint is durable.
    var scratchMicPlaceholderURLsByTaskId: [UUID: URL] = [:]
    var orphanedRecordingRecoveryTask: Task<Int, Never>?
    var orphanedRecordingRecoveryRequestGeneration: UInt64 = 0
    /// Deterministic task-start delay point for recovery scheduler tests.
    var orphanedRecordingRecoveryTaskCreatedObserver: (() -> Void)?
    /// Deterministic pause point for recovery interleaving tests.
    var orphanedRecordingRecoveryPassObserver: (() -> Void)?
    /// Time source for recovery deadlines, rescan waits, and liveness checks.
    /// Read once per recovery owner; tests swap in a virtual clock.
    var orphanedRecordingRecoveryClock = OrphanedRecordingRecoveryClock.live

    /// Embedder-supplied notifier for transcript-saved and failure events. Optional — when
    /// `nil`, notification hooks become no-ops, which keeps Core usable from headless contexts
    /// (tests, CLI tools) and embedders that prefer their own in-app presentation.
    public let notifier: TranscriptNotifier?

    public var hasPreservableActiveTranscriptionAudio: Bool {
        tasks.values.contains { state in
            guard let audio = state.audio else { return false }
            return audio.micURL != nil || audio.systemURL != nil
        }
    }

    /// Active pipeline work that should keep quit confirmation enabled.
    ///
    /// Saved-audio retranscriptions and failed-row retries use already-retained
    /// source files, so they intentionally do not enter `activeTaskAudio`. They
    /// still need the background-work quit warning while inference is running.
    /// Conversely, `cancelAll()` leaves non-cooperative model work in
    /// `activeTasks` for single-flight occupancy, but marks it intentionally
    /// cancelled after discarding or handing off any owned scratch audio. That cancelled
    /// occupancy must not revive a misleading save-audio prompt.
    public var hasActiveTranscriptionWorkRequiringQuitConfirmation: Bool {
        activeTasks.keys.contains { !(tasks[$0]?.isCancelling ?? false) }
    }

    public init(
        failedTranscriptionManager: FailedTranscriptionManager,
        speechToText: any SpeechToTextEngine,
        diarization: any DiarizationEngine,
        speakerStore: any SpeakerStore,
        speakerClipsDirectory: URL = CoreStoragePaths.default.speakerClips,
        cleanupDirectories: [URL]? = nil,
        retainedAudioDirectory: URL? = nil,
        retainedAudioDirectoryProvider: (() -> URL?)? = nil,
        transcriptFormatOptionsProvider: (() -> TranscriptFormatOptions)? = nil,
        statsStore: (any StatsStore)? = nil,
        notifier: TranscriptNotifier? = nil
    ) {
        self.failedTranscriptionManager = failedTranscriptionManager
        self.statsStore = statsStore
        self.notifier = notifier
        self.retainedAudioDirectory = retainedAudioDirectory
        self.retainedAudioDirectoryProvider = retainedAudioDirectoryProvider
        self.transcriptFormatOptionsProvider = transcriptFormatOptionsProvider
        self.cleanupDirectories = (cleanupDirectories ?? [speakerClipsDirectory])
            .map(Self.canonicalDirectoryURL)
        self.transcription = Transcription(
            speechToText: speechToText,
            diarization: diarization,
            speakerStore: speakerStore,
            speakerClipsDirectory: speakerClipsDirectory
        )
    }

    func publishFailure(_ failure: FailurePresentation) {
        publishFailure(
            displayMessage: failure.displayMessage,
            diagnosticMessage: failure.diagnosticMessage,
            errorKind: failure.errorKind
        )
    }

    func publishFailure(
        displayMessage: String,
        diagnosticMessage: String,
        errorKind: PipelineErrorKind? = nil,
        speakerFinalizationFailure: SpeakerFinalizationFailure? = nil
    ) {
        lastFailureDiagnosticMessage = diagnosticMessage
        lastFailureErrorKind = errorKind
        lastSpeakerFinalizationFailure = speakerFinalizationFailure
        displayStatus = .failed(message: displayMessage)
    }

    /// Publishes a speaker review save failure. The display message doubles as
    /// the diagnostic so an older pipeline failure's diagnostic can never be
    /// mistaken for this one.
    func publishSpeakerFinalizationFailure(
        displayMessage: String,
        failure: SpeakerFinalizationFailure?
    ) {
        publishFailure(
            displayMessage: displayMessage,
            diagnosticMessage: displayMessage,
            speakerFinalizationFailure: failure
        )
    }

    /// Speaker review saved. Clears the previous failure's diagnostics so a later
    /// status observer never reads a stale failure reason.
    func publishSpeakerNamesSaved() {
        publishNonFailureStatus(.transcriptSaved)
    }

    /// A save that lands on an already-published transcript keeps its status, but the
    /// previous save's failure details no longer describe it. Leaves them alone while a
    /// failure is still showing, which may belong to another meeting.
    func clearSpeakerFinalizationFailure() {
        if case .failed = displayStatus { return }
        lastFailureDiagnosticMessage = nil
        lastFailureErrorKind = nil
        lastSpeakerFinalizationFailure = nil
    }

    func publishNonFailureStatus(_ status: DisplayStatus) {
        lastFailureDiagnosticMessage = nil
        lastFailureErrorKind = nil
        lastSpeakerFinalizationFailure = nil
        displayStatus = status
    }

    func publishTranscriptSaved(
        from transcriptURL: URL,
        taskId: UUID? = nil,
        timings: MeetingPipelineTimings.Snapshot? = nil
    ) {
        // Set before the status publishes so a host reading it on
        // `.transcriptSaved` sees this save's timings, never a previous one's.
        lastPipelineTimings = timings
        populateSavedMetadata(from: transcriptURL, taskId: taskId)
        publishNonFailureStatus(.transcriptSaved)
        scheduleStatusReset(delay: 4)
    }

    // MARK: - Task Completion & Cleanup

    func handleTaskCompletion(taskId: UUID) {
        activeTasks.removeValue(forKey: taskId)
        tasks.removeValue(forKey: taskId)
        activeCount = max(0, activeCount - 1)
        backgroundTaskCount = max(0, backgroundTaskCount - 1)

        AppLogger.pipeline.info("Task cleaned up", ["taskId": "\(taskId)", "remaining": "\(activeCount)", "backgroundTasks": "\(backgroundTaskCount)"])

        if activeCount == 0 {
            justCompleted = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.justCompleted = false
            }
        }
    }

    func canCommitTaskSideEffects(taskId: UUID) -> Bool {
        activeTasks[taskId] != nil && !(tasks[taskId]?.isCancelling ?? false)
    }

    /// Enters `taskId` into the lifecycle map as a running task. The start and
    /// retry flows live in other files; `tasks` stays private to this one.
    func beginTaskLifecycle(taskId: UUID, audio: ActiveTaskAudio?) {
        tasks[taskId] = .active(audio: audio)
    }

    /// Drops `taskId` from the lifecycle map (failed-row retry cleanup).
    func forgetTaskLifecycle(taskId: UUID) {
        tasks.removeValue(forKey: taskId)
    }

    /// Standardized paths of the scratch audio that lifecycle-tracked tasks own,
    /// for orphaned-recording recovery.
    func lifecycleOwnedAudioPaths() -> [String] {
        tasks.values
            .compactMap(\.audio)
            .flatMap { [$0.micURL, $0.systemURL] }
            .compactMap { $0?.standardizedFileURL.path }
    }

    func markTaskTranscriptCommitted(taskId: UUID) {
        let audio = tasks[taskId]?.audio
        tasks[taskId] = .committed(audio: audio)
        audio?.importedRecoverySession?.transcriptCommitConfirmed()
        // The imported journal remains through scratch cleanup. The separate
        // live-recording journal can retire once the transcript is durable.
        if let audio {
            MeetingRecordingJournalStore.removeJournal(
                micAudioURL: audio.micURL,
                systemAudioURL: audio.systemURL,
                allowedRoots: cleanupDirectories
            )
        }
    }

    /// `preserveActiveTranscriptionsForShutdown()` already synchronously handled this
    /// task's outcome and evicted it from `activeTasks`/counters — only the
    /// `.preservedForShutdown` marker remains. Consuming it (checking membership and
    /// removing in one step, mirroring the old `Set.remove(_:) != nil`) must happen
    /// before `finishCancelledTaskIfNeeded`, which has no special case for this marker.
    func consumePreservedForShutdownMarker(taskId: UUID) -> Bool {
        guard case .preservedForShutdown = tasks[taskId] else { return false }
        tasks.removeValue(forKey: taskId)
        return true
    }

    func finishCancelledTaskIfNeeded(taskId: UUID, error: Error? = nil) -> Bool {
        if tasks[taskId]?.isCommitted ?? false {
            // Committed wins over a later cancel-request: drop the transient
            // cancel marker (a `.cancellingCommitted` collapses back to plain
            // `.committed`) and let the caller's normal success path run.
            if case .cancellingCommitted = tasks[taskId] {
                tasks[taskId] = .committed(audio: nil)
            }
            AppLogger.pipeline.info("Preserving committed transcription task outcome after cancellation", [
                "taskId": "\(taskId)"
            ])
            return false
        }

        guard (tasks[taskId]?.isCancelling ?? false) || error is CancellationError else {
            return false
        }

        let hadActiveTask = activeTasks.removeValue(forKey: taskId) != nil
        tasks.removeValue(forKey: taskId)
        if hadActiveTask {
            activeCount = max(0, activeCount - 1)
            backgroundTaskCount = max(0, backgroundTaskCount - 1)
        }
        if activeCount == 0 {
            publishNonFailureStatus(.idle)
        }

        AppLogger.pipeline.info("Suppressed cancelled transcription task outcome", [
            "taskId": "\(taskId)",
            "remaining": "\(activeCount)",
            "backgroundTasks": "\(backgroundTaskCount)"
        ])
        return true
    }

    /// Cancels every running job. With `recordedAudioRetryMessage`, a recorded
    /// meeting that hasn't saved its transcript keeps its audio as a retry row
    /// with that message, the way queued meetings are kept; without it (and
    /// for imported audio, whose scratch copy is all that's removed) the
    /// cancelled job's scratch audio is deleted.
    public func cancelAll(recordedAudioRetryMessage: String? = nil) {
        for (taskId, task) in activeTasks {
            // Read commit state before overwriting it below: `cancelAll()` unconditionally
            // marks every occupied task cancelled, even one that already committed its
            // transcript — that combination is real (see `.cancellingCommitted`), not a bug.
            let wasCommitted = tasks[taskId]?.isCommitted ?? false
            task.cancel()
            if let audio = tasks[taskId]?.audio,
               let recordedAudioRetryMessage,
               audio.importedRecoverySession == nil,
               !wasCommitted {
                // Same hand-off as quitting mid-transcription: the retry row owns
                // the audio from here, so the task no longer does.
                addFailedTranscriptionRetainingAvailableAudio(
                    micAudioURL: audio.micURL,
                    systemAudioURL: audio.systemURL,
                    errorMessage: recordedAudioRetryMessage,
                    taskId: taskId,
                    meetingTitle: audio.meetingTitle,
                    recordingDate: audio.recordingDate,
                    splitLocalSpeakers: audio.splitLocalSpeakers,
                    languageSelection: audio.languageSelection,
                    micOnlyByChoice: audio.micOnlyByChoice
                )
            } else if let audio = tasks[taskId]?.audio {
                if audio.importedRecoverySession?.prepareForScratchCleanup() != false {
                    let removedMic = removeManagedCleanupFile(audio.micURL, label: "cancelled live mic scratch")
                    let removedSystem = removeManagedCleanupFile(audio.systemURL, label: "cancelled live system scratch")
                    if removedMic && removedSystem {
                        audio.importedRecoverySession?.scratchCleanupConfirmed()
                    }
                }
            }
            tasks[taskId] = wasCommitted ? .cancellingCommitted : .cancelling
            AppLogger.pipeline.info("Cancelled task", ["taskId": "\(taskId)"])
        }
        // Keep cancelled tasks in the occupancy map and counters until their task bodies exit.
        // CoreML calls are not guaranteed to observe cancellation immediately; clearing
        // these signals here would let a new pipeline enter the same single-instance models.
        // Audio ownership is cleared above because cancellation discarded it or a retry row owns it;
        // finishCancelledTaskIfNeeded removes each task from the occupancy map on exit.
        //
        // Also drop any detached `.preservedForShutdown` markers left over from a previous
        // preserveActiveTranscriptionsForShutdown() call whose task still hasn't returned —
        // mirrors the old unconditional `preservedTaskIdsForShutdown.removeAll()`. But the old
        // code's `committedTranscriptTaskIds` was a *separate* Set that this blanket clear never
        // touched, so a task that had already committed before it was preserved must keep that
        // fact alive here too (downgrading to plain `.committed`) instead of disappearing —
        // otherwise a later `CancellationError` from its still-running body would incorrectly
        // suppress an outcome that already committed for real. See `.preservedForShutdown`'s doc.
        let preservedShutdownMarkers = tasks.compactMap { taskId, state -> (UUID, Bool)? in
            guard case .preservedForShutdown(let wasCommitted) = state else { return nil }
            return (taskId, wasCommitted)
        }
        for (taskId, wasCommitted) in preservedShutdownMarkers {
            tasks[taskId] = wasCommitted ? .committed(audio: nil) : nil
        }
        publishNonFailureStatus(.idle)
    }

    @discardableResult
    public func preserveActiveTranscriptionsForShutdown(errorMessage: String) -> Int {
        let activeAudio: [UUID: ActiveTaskAudio] = tasks.reduce(into: [:]) { result, entry in
            if let audio = entry.value.audio {
                result[entry.key] = audio
            }
        }
        guard !activeAudio.isEmpty else { return 0 }

        for (taskId, task) in activeTasks {
            task.cancel()
            AppLogger.pipeline.warning("Preserving active transcription audio during shutdown", [
                "taskId": taskId.uuidString
            ])
        }

        activeTasks.removeAll()
        // Only the audio-bearing entries get a `.preservedForShutdown` marker (matching
        // the old code, which only ever inserted `activeTaskAudio` keys into
        // `preservedTaskIdsForShutdown`). Audio-less retranscription/retry entries are left
        // untouched here — their task bodies will notice `task.cancel()` above via
        // `error is CancellationError` in `finishCancelledTaskIfNeeded` once they return,
        // exactly as before. Capture whether each task had already committed *before*
        // overwriting its state — the old code's `committedTranscriptTaskIds` was a separate
        // Set that this transition never touched, so that fact must ride along explicitly now.
        for taskId in activeAudio.keys {
            let wasCommitted = tasks[taskId]?.isCommitted ?? false
            tasks[taskId] = .preservedForShutdown(wasCommitted: wasCommitted)
        }
        activeCount = 0
        backgroundTaskCount = 0
        publishNonFailureStatus(.idle)

        var preservedCount = 0
        for (taskId, audio) in activeAudio {
            let didPersist = addFailedTranscriptionRetainingAvailableAudio(
                micAudioURL: audio.micURL,
                systemAudioURL: audio.systemURL,
                errorMessage: errorMessage,
                taskId: taskId,
                meetingTitle: audio.meetingTitle,
                recordingDate: audio.recordingDate,
                splitLocalSpeakers: audio.splitLocalSpeakers,
                languageSelection: audio.languageSelection,
                micOnlyByChoice: audio.micOnlyByChoice
            )
            if didPersist {
                preservedCount += 1
                audio.importedRecoverySession?.failedQueueHandoffConfirmed()
            }
        }
        return preservedCount
    }

    /// Populate saved transcript metadata from the file's YAML frontmatter.
    /// Reads the YAML frontmatter in bounded chunks so larger metadata blocks
    /// (many speakers, gap events, etc.) still parse without reading the whole file.
    func populateSavedMetadata(from url: URL, taskId: UUID? = nil) {
        let previousTaskId = lastSavedTranscriptTaskId
        let previousURL = lastSavedTranscriptURL
        let previousTranscriptId = lastSavedTranscriptId
        let canonicalURL = Self.canonicalSavedTranscriptURL(url)

        lastSavedTranscriptTaskId = taskId
            ?? savedTranscriptTaskIdsByURL[canonicalURL]
            ?? (previousURL.map(Self.canonicalSavedTranscriptURL) == canonicalURL ? previousTaskId : nil)
        lastSavedTranscriptURL = url
        lastSavedTranscriptId = nil
        let name = url.deletingPathExtension().lastPathComponent
        lastSavedTitle = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        guard let values = try? TranscriptFrontmatter.readValues(from: url) else {
            rememberSavedTranscriptOwner(taskId: lastSavedTranscriptTaskId, url: canonicalURL, transcriptId: nil)
            return
        }

        if let transcriptId = values["transcript_id"] {
            let parsedTranscriptId = UUID(uuidString: transcriptId)
            lastSavedTranscriptId = parsedTranscriptId
            if taskId == nil, let parsedTranscriptId {
                if let knownTaskId = savedTranscriptTaskIdsByTranscriptId[parsedTranscriptId] {
                    lastSavedTranscriptTaskId = knownTaskId
                } else if lastSavedTranscriptTaskId == nil,
                          previousTranscriptId == parsedTranscriptId {
                    lastSavedTranscriptTaskId = previousTaskId
                }
            }
        }
        rememberSavedTranscriptOwner(
            taskId: lastSavedTranscriptTaskId,
            url: canonicalURL,
            transcriptId: lastSavedTranscriptId
        )
        if let title = values["title"] {
            lastSavedTitle = title
        }
        lastSavedDuration = values["duration"]
        lastSavedSpeakerCount = (Int(values["mic_speakers"] ?? "") ?? 0)
            + (Int(values["system_speakers"] ?? "") ?? 0)
    }

    private static func canonicalSavedTranscriptURL(_ url: URL) -> URL {
        url.standardizedFileURL
    }

    private func rememberSavedTranscriptOwner(taskId: UUID?, url: URL, transcriptId: UUID?) {
        guard let taskId else { return }
        savedTranscriptTaskIdsByURL[url] = taskId
        if let transcriptId {
            savedTranscriptTaskIdsByTranscriptId[transcriptId] = taskId
        }
    }

    func scheduleStatusReset(delay: TimeInterval = 3) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            // A pending speaker review used to keep a `.failed` status alive
            // indefinitely: the review sheet is its own surface, and a
            // completed review republishes only when nothing was published
            // yet, so the failed card (Home "Needs attention") had no way out
            // once a second meeting's failure landed behind a pending review.
            switch self.displayStatus {
            case .transcriptSaved, .failed, .discardedAccidentalStart:
                self.publishNonFailureStatus(.idle)
            default:
                break
            }
        }
    }

    func confirmImportedTranscriptionScratchCleanup(taskId: UUID) {
        tasks[taskId]?.audio?.importedRecoverySession?.scratchCleanupConfirmed()
    }

    func prepareImportedTranscriptionScratchCleanup(taskId: UUID) -> Bool {
        tasks[taskId]?.audio?.importedRecoverySession?.prepareForScratchCleanup() ?? true
    }

    func importedRecoverySession(taskId: UUID) -> (any ImportedTranscriptionRecoverySession)? {
        tasks[taskId]?.audio?.importedRecoverySession
    }
}
