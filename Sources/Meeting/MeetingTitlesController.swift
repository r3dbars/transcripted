import Combine
import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// Settings > Meetings "Titles and summaries". Off by default: turning it on
/// downloads a 3.1 GB model.
enum MeetingTitlesPreferences {
    static let enabledKey = "meetingTitlesOnDeviceEnabled"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }
}

/// Owns the opt-in, the model download, the titles queue and its helper.
/// Transcript text, titles and summaries never leave this Mac and are never
/// logged; nothing here reports analytics.
@MainActor
final class MeetingTitlesController: ObservableObject {
    enum ModelStatus: Equatable {
        case notDownloaded
        case downloading(received: Int64, total: Int64)
        case ready
        case failed(MeetingTitlesModelFailure)
    }

    /// Where a save came from, as the meeting session knows it at the save.
    enum SaveOrigin: Equatable, Sendable {
        /// A live recording's pipeline save. A title it kept came with the
        /// recording (a calendar event's or a requested one).
        case recording
        /// An import's pipeline save: the title is the import's own name.
        case importedFile
        /// "Transcribe again" replaced the file.
        case transcribedAgain
        /// Anything else (a speaker review's save, a recovery).
        case other
    }

    nonisolated static let downloadSizeLabel = "3.1 GB download"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var modelStatus: ModelStatus
    @Published private(set) var activity: MeetingTitlesQueue.Activity = .idle

    /// True while a meeting is recording, a dictation is running, or a
    /// meeting is being transcribed. Set by the app at launch, which also
    /// calls `noteBusyStarted`/`noteBusyChanged` from the same published state.
    var busyProvider: @MainActor () -> Bool = { false }
    /// True while that meeting (file, capture id) has a speaker review
    /// waiting for answers. Set by the app at launch.
    var speakerReviewProvider: @MainActor (URL, UUID?) -> Bool = { _, _ in false }

    let store: MeetingTitlesModelStore
    private(set) var queue: MeetingTitlesQueue!
    private let host: any MeetingTitlesEngineHost
    private let defaults: UserDefaults
    private let meetingsDirectory: @Sendable () -> URL?
    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration = 0
    /// A download that was cancelled but may still be writing its last bytes.
    private var unwindingDownload: Task<Void, Never>?
    private var modelRemoval: Task<ModelCacheCleanupResult, Error>?
    private let removeModelFiles: @Sendable () throws -> ModelCacheCleanupResult
    private var backfillTask: Task<Void, Never>?
    private let onMeetingChanged: @MainActor (URL) -> Void
    private var retranscribeRules: [String: MeetingTitlesJob.TitleRule] = [:]
    private var launched = false
    private let notificationCenter: NotificationCenter
    private var libraryObserver: NSObjectProtocol?

    static let shared: MeetingTitlesController = {
        let store = MeetingTitlesModelStore()
        let server = MeetingTitlesLlamaServer(configuration: .bundled, openModel: { try store.openVerifiedModel() })
        return MeetingTitlesController(
            store: store,
            host: server,
            defaults: .standard,
            meetingsDirectory: { MeetingStoragePaths.transcriptsFolder },
            onMeetingChanged: { url in
                CaptureLibraryChangeBroadcaster.shared.noteArtifactsChanged(transcriptURLs: [url])
            }
        )
    }()

    init(
        store: MeetingTitlesModelStore,
        host: any MeetingTitlesEngineHost,
        defaults: UserDefaults,
        meetingsDirectory: @escaping @Sendable () -> URL?,
        onMeetingChanged: @escaping @MainActor (URL) -> Void = { _ in },
        notificationCenter: NotificationCenter = .default,
        removeModelFiles: (@Sendable () throws -> ModelCacheCleanupResult)? = nil,
        queueEnvironment: ((MeetingTitlesController) -> MeetingTitlesQueue.Environment)? = nil
    ) {
        self.onMeetingChanged = onMeetingChanged
        self.notificationCenter = notificationCenter
        self.removeModelFiles = removeModelFiles ?? { try ModelCacheInventory.removeMeetingTitlesModels() }
        self.store = store
        self.host = host
        self.defaults = defaults
        self.meetingsDirectory = meetingsDirectory
        self.isEnabled = MeetingTitlesPreferences.isEnabled(userDefaults: defaults)
        self.modelStatus = store.isInstalled ? .ready : .notDownloaded
        let environment = queueEnvironment?(self) ?? MeetingTitlesQueue.Environment(
            isEnabled: { [weak self] in self?.canRunJobs ?? false },
            isBusy: { [weak self] in self?.busyProvider() ?? false },
            isAwaitingSpeakerReview: { [weak self] url, captureID in
                self?.speakerReviewProvider(url, captureID) ?? false
            }
        )
        queue = MeetingTitlesQueue(host: host, environment: environment)
        queue.onActivityChange = { [weak self] activity in
            guard let self else { return }
            self.activity = activity
            // A model file that failed its check was deleted; say so.
            if activity == .engineUnavailable, !self.store.isInstalled {
                self.modelStatus = .failed(.checksumMismatch)
            }
        }
        queue.onJobFinished = { [weak self] job, result in
            // Home and Today re-read the row, so a new title shows while open.
            if result == .written { self?.onMeetingChanged(job.transcriptURL) }
        }
    }

    /// Jobs run only with the feature on and the model on disk (and not
    /// while Free up space is removing it).
    var canRunJobs: Bool { isEnabled && modelStatus == .ready && modelRemoval == nil }

    // MARK: - App lifecycle

    /// Called once at launch. Reaps a titles helper a crash left behind,
    /// then (feature on) resumes an interrupted download or rescans the
    /// meetings. Harness launches skip it.
    func launch() {
        guard !launched else { return }
        launched = true
        let host = self.host
        Task.detached(priority: .utility) { await host.reapOrphaned() }
        observeLibraryChanges()
        guard isEnabled else { return }
        if modelStatus == .ready {
            startBackfill()
        } else {
            startDownload()
        }
    }

    /// Synchronous helper stop for app termination.
    func shutDownNow() {
        downloadTask?.cancel()
        queue.cancelAll()
        (host as? MeetingTitlesLlamaServer)?.stopNow()
    }

    // MARK: - Settings

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        MeetingTitlesPreferences.setEnabled(enabled, userDefaults: defaults)
        if enabled {
            // Free up space is removing the model: it starts the download
            // (or the rescan) itself once it's done.
            guard modelRemoval == nil else { return }
            if modelStatus == .ready {
                startBackfill()
            } else {
                startDownload()
            }
        } else {
            if let downloadTask {
                downloadTask.cancel()
                unwindingDownload = downloadTask
            }
            downloadTask = nil
            backfillTask?.cancel()
            backfillTask = nil
            queue.cancelAll()
            if case .downloading = modelStatus { modelStatus = .notDownloaded }
            if case .failed = modelStatus { modelStatus = store.isInstalled ? .ready : .notDownloaded }
        }
    }

    /// "Try again": a failed download starts over (keeping what arrived);
    /// a model that couldn't start gets another go.
    func retry() {
        guard isEnabled else { return }
        if modelStatus == .ready {
            queue.wake()
        } else {
            startDownload()
        }
    }

    /// Storage > Free up space, only while the feature is off: removes the
    /// model folder. Serialized with the download: it first waits for a
    /// cancelled download to finish unwinding, and turning the feature on
    /// meanwhile starts the new download only once the removal is done.
    func removeModelWhileOff() async throws -> ModelCacheCleanupResult {
        guard !isEnabled, modelRemoval == nil, downloadTask == nil else { return .empty }
        let unwinding = unwindingDownload
        let remove = removeModelFiles
        let removal = Task { () throws -> ModelCacheCleanupResult in
            await unwinding?.value
            return try await Task.detached(priority: .utility) { try remove() }.value
        }
        modelRemoval = removal
        defer {
            modelRemoval = nil
            unwindingDownload = nil
            modelStatus = store.isInstalled ? .ready : .notDownloaded
            if isEnabled {
                if modelStatus == .ready { startBackfill() } else { startDownload() }
            }
        }
        return try await removal.value
    }

    var isRemovingModel: Bool { modelRemoval != nil }

    // MARK: - Busy

    /// A dictation, recording or transcription just started. Stops a running
    /// job at once and restarts the quiet period before the helper may load.
    func noteBusyStarted() {
        queue.noteBusyStarted()
    }

    /// One of the busy sources changed; `busyProvider` is read again.
    func noteBusyChanged() {
        queue.noteBusyChanged()
    }

    /// Observes state the app already publishes (true means that source just
    /// got busy). The subscriber only schedules work for the next main-actor
    /// turn, so it adds nothing to the dictation, capture or hotkey path that
    /// publishes the change; `@Published` also emits before the new value is
    /// stored, so `busyProvider` is read after the hop.
    func observeBusySignals(_ signals: [AnyPublisher<Bool, Never>]) {
        busySignalCancellables = signals.map { signal in
            signal.sink { [weak self] busy in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if busy { self.noteBusyStarted() }
                        self.noteBusyChanged()
                    }
                }
            }
        }
    }

    private var busySignalCancellables: [AnyCancellable] = []

    // MARK: - Meetings

    /// A meeting transcript was saved and restyled. `title` is the title the
    /// restyle settled on; `titleWasGenerated` is true only when the restyle
    /// made it from the app's rule in that pass.
    func noteSavedMeeting(
        at url: URL,
        title: String,
        titleWasGenerated: Bool = false,
        origin: SaveOrigin = .other
    ) {
        let retranscribed = retranscribeRules.removeValue(forKey: url.standardizedFileURL.path)
        guard canRunJobs else { return }
        let rule: MeetingTitlesJob.TitleRule
        if titleWasGenerated {
            rule = .appMade(title)
        } else {
            switch origin {
            case .recording: rule = .unknown
            case .importedFile: rule = .importNamed(title)
            case .transcribedAgain: rule = retranscribed ?? .fromFile
            case .other: rule = .fromFile
            }
        }
        queue.enqueue(MeetingTitlesJob(transcriptURL: url, titleRule: rule))
    }

    /// Before "Transcribe again" replaces a meeting's file (which drops its
    /// `ai_*` keys), remember whether the old file shows the app made the
    /// title. A rename doesn't depend on this: the replacement write itself
    /// carries `title_set_by_user`.
    func noteRetranscriptionRequested(transcriptURL: URL?) {
        guard let transcriptURL else { return }
        let key = transcriptURL.standardizedFileURL.path
        Task { @MainActor [weak self] in
            let rule = await Task.detached(priority: .utility) {
                Self.retranscriptionRule(at: transcriptURL)
            }.value
            self?.retranscribeRules[key] = rule
        }
    }

    /// `.appMade(title)` when the old file shows the app made the title,
    /// `.unknown` otherwise (keep the title).
    nonisolated static func retranscriptionRule(at url: URL) -> MeetingTitlesJob.TitleRule {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let values = TranscriptFrontmatter.values(in: raw) else { return .unknown }
        let decision = MeetingTitlesTitleOwnership.decide(values: values, rule: .fromFile) {
            MeetingTranscriptStyler.ruleTitle(forMeetingMarkdown: raw, fallbackURL: url)
        }
        if case .replaceable(let title) = decision { return .appMade(title) }
        return .unknown
    }

    /// Speaker names changing (a review answered, a rename or merge) makes a
    /// labeled meeting stale; its job notices and labels it once more.
    private func observeLibraryChanges() {
        guard libraryObserver == nil else { return }
        libraryObserver = notificationCenter.addObserver(
            forName: .meetingCaptureArtifactsDidChange, object: nil, queue: .main
        ) { [weak self] note in
            let ids = note.userInfo?[CaptureLibraryChange.affectedTranscriptIDsKey] as? [String] ?? []
            MainActor.assumeIsolated { self?.libraryChanged(ids: ids) }
        }
    }

    /// `ids` are transcript paths (`CaptureLibraryChange.id`); none means the
    /// whole library.
    func libraryChanged(ids: [String]) {
        guard canRunJobs else { return }
        guard !ids.isEmpty else {
            startBackfill()
            return
        }
        let jobs = ids
            .filter { $0.hasSuffix(".md") && !$0.hasSuffix(".summary.md") }
            .map { MeetingTitlesJob(transcriptURL: URL(fileURLWithPath: $0), titleRule: .fromFile) }
        queue.enqueueBackfill(jobs)
    }

    // MARK: - Download

    private func startDownload() {
        // A removal in progress starts the download itself once it's done.
        guard downloadTask == nil, modelRemoval == nil else { return }
        modelStatus = .downloading(received: store.partialBytes, total: store.asset.expectedBytes)
        let store = self.store
        let throttle = ProgressThrottle()
        let sink = ProgressSink(controller: self)
        downloadGeneration += 1
        let generation = downloadGeneration
        downloadTask = Task { [weak self] in
            let work = Task.detached(priority: .utility) { () -> Result<Void, MeetingTitlesModelFailure> in
                do {
                    try await store.download { received, total in
                        guard throttle.shouldPublish(received: received, total: total) else { return }
                        sink.publish(received: received, total: total)
                    }
                    return .success(())
                } catch let failure as MeetingTitlesModelFailure {
                    return .failure(failure)
                } catch is CancellationError {
                    return .failure(.offline)
                } catch {
                    return .failure(.installationFailed)
                }
            }
            let result = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard let self, self.downloadGeneration == generation else { return }
            self.downloadTask = nil
            guard !Task.isCancelled, self.isEnabled else { return }
            switch result {
            case .success:
                self.modelStatus = .ready
                self.startBackfill()
            case .failure(let failure):
                self.modelStatus = .failed(failure)
            }
        }
    }

    private func downloadProgressed(received: Int64, total: Int64) {
        guard case .downloading = modelStatus else { return }
        modelStatus = .downloading(received: received, total: total)
    }

    private final class ProgressSink: @unchecked Sendable {
        private weak var controller: MeetingTitlesController?

        init(controller: MeetingTitlesController) { self.controller = controller }

        func publish(received: Int64, total: Int64) {
            Task { @MainActor [weak controller] in
                controller?.downloadProgressed(received: received, total: total)
            }
        }
    }

    /// Publishes about every 0.25% so a 3.1 GB download doesn't flood main.
    private final class ProgressThrottle: @unchecked Sendable {
        private let lock = NSLock()
        private var last: Int64 = -1

        func shouldPublish(received: Int64, total: Int64) -> Bool {
            let step = max(total / 400, 1)
            return lock.withLock {
                guard received == total || last < 0 || received - last >= step else { return false }
                last = received
                return true
            }
        }
    }

    // MARK: - Backfill

    /// Rescans the meetings on every launch and every time the feature is
    /// turned on, so failed jobs, moved files and renamed speakers get
    /// another go.
    private func startBackfill() {
        guard canRunJobs, backfillTask == nil, let directory = meetingsDirectory() else { return }
        backfillTask = Task { [weak self] in
            let jobs = await Task.detached(priority: .utility) {
                Self.backfillJobs(in: directory)
            }.value
            guard let self else { return }
            self.backfillTask = nil
            guard !Task.isCancelled, self.canRunJobs else { return }
            self.queue.enqueueBackfill(jobs)
        }
    }

    /// Waits for a running rescan and the queue (tests).
    func waitUntilIdle() async {
        while let task = backfillTask { await task.value }
        await queue.waitUntilIdle()
    }

    /// Meetings in `directory` that need a label, newest first: no keys at
    /// this version, or (for a file changed since it was labeled) keys
    /// written from speaker names it no longer has. Only those changed files
    /// are read past the frontmatter, and only while the change is recent.
    nonisolated static func backfillJobs(
        in directory: URL,
        fileManager: FileManager = .default,
        now: Date = Date()
    ) -> [MeetingTitlesJob] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        var dated: [(URL, Date)] = []
        for url in urls where url.pathExtension == "md"
            && !url.deletingPathExtension().lastPathComponent.hasSuffix(".summary") {
            guard let resources = try? url.resourceValues(forKeys: Set(keys)),
                  resources.isRegularFile == true,
                  let document = try? TranscriptFrontmatter.readDocument(from: url),
                  document.values["capture_type"] == "meeting" else { continue }
            let values = document.values
            if MeetingTitlesFrontmatterWriter.isCurrentVersion(values: values) {
                let tooShort = MeetingTitlesFrontmatterWriter.NoSummaryStatus.tooShort.rawValue
                guard values[MeetingTitlesKeys.status] != tooShort,
                      changedSinceLabeled(values: values, modifiedAt: resources.contentModificationDate, now: now),
                      let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let speakers = MeetingTitlesSpeakers.fingerprint(of: MeetingTitlesTranscript.turns(fromMeetingMarkdown: raw))
                guard !MeetingTitlesFrontmatterWriter.isCurrent(values: values, speakers: speakers) else { continue }
            }
            let date = TranscriptFrontmatter.importedAt(values: values)
                ?? TranscriptFrontmatter.recordedAt(values: values)
                ?? .distantPast
            dated.append((url, date))
        }
        return dated
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.path > $1.0.path }
            .map { MeetingTitlesJob(transcriptURL: $0.0, titleRule: .fromFile) }
    }

    /// How long after a file last changed the rescan still reads it in full
    /// to compare speaker names.
    nonisolated static let relabelCheckWindow: TimeInterval = 30 * 24 * 60 * 60

    /// The label's own write lands within moments of
    /// `ai_summary_generated_at`; anything later (a speaker rename, a merge,
    /// a review's answers) may have changed the names. Other writes (a star,
    /// a rename, the audio path) bump the modified time too, and a name
    /// change made while the app runs is relabeled then and there, so this
    /// is only the catch-up for one the app quit before handling. It stops
    /// looking once the change is `relabelCheckWindow` old, so a library of
    /// old starred meetings isn't read in full on every launch.
    nonisolated static func changedSinceLabeled(
        values: [String: String],
        modifiedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard let modifiedAt,
              let raw = values[MeetingTitlesKeys.generatedAt],
              let stamp = ISO8601DateFormatter().date(from: raw) else { return true }
        guard modifiedAt.timeIntervalSince(stamp) > 5 else { return false }
        return now.timeIntervalSince(modifiedAt) <= relabelCheckWindow
    }
}
