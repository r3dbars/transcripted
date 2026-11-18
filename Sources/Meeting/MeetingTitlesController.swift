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

    nonisolated static let downloadSizeLabel = "3.1 GB download"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var modelStatus: ModelStatus
    @Published private(set) var activity: MeetingTitlesQueue.Activity = .idle

    /// True while a meeting is recording, a dictation is running, or a
    /// meeting is being transcribed. Set by `MeetingSessionController`.
    var busyProvider: @MainActor () -> Bool = { false }

    let store: MeetingTitlesModelStore
    private(set) var queue: MeetingTitlesQueue!
    private let host: any MeetingTitlesEngineHost
    private let defaults: UserDefaults
    private let meetingsDirectory: @Sendable () -> URL?
    private var downloadTask: Task<Void, Never>?
    private var downloadGeneration = 0
    private var backfillTask: Task<Void, Never>?
    private let onMeetingChanged: @MainActor (URL) -> Void
    private var retranscribeRules: [String: MeetingTitlesJob.TitleRule] = [:]
    private var launched = false

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
        queueEnvironment: ((MeetingTitlesController) -> MeetingTitlesQueue.Environment)? = nil
    ) {
        self.onMeetingChanged = onMeetingChanged
        self.store = store
        self.host = host
        self.defaults = defaults
        self.meetingsDirectory = meetingsDirectory
        self.isEnabled = MeetingTitlesPreferences.isEnabled(userDefaults: defaults)
        self.modelStatus = store.isInstalled ? .ready : .notDownloaded
        let environment = queueEnvironment?(self) ?? MeetingTitlesQueue.Environment(
            isEnabled: { [weak self] in self?.canRunJobs ?? false },
            isBusy: { [weak self] in self?.busyProvider() ?? false }
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

    /// Jobs run only with the feature on and the model on disk.
    var canRunJobs: Bool { isEnabled && modelStatus == .ready }

    // MARK: - App lifecycle

    /// Called once at launch. Reaps a titles helper a crash left behind,
    /// then (feature on) resumes an interrupted download or rescans the
    /// meetings. Harness launches skip it.
    func launch() {
        guard !launched else { return }
        launched = true
        let host = self.host
        Task.detached(priority: .utility) { await host.reapOrphaned() }
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
            if modelStatus == .ready {
                startBackfill()
            } else {
                startDownload()
            }
        } else {
            downloadTask?.cancel()
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

    /// The model was removed from Storage > Free up space (only offered while
    /// the feature is off).
    func noteModelRemoved() {
        modelStatus = store.isInstalled ? .ready : .notDownloaded
    }

    // MARK: - Meetings

    /// A meeting transcript was saved and restyled: a new recording, an
    /// imported file, or "Transcribe again". `title` is the title the restyle
    /// settled on; `titleWasGenerated` is true only when the restyle made it
    /// from the app's rule in that pass. That, an import's own name, or what
    /// "Transcribe again" learned from the old file is positive evidence;
    /// without any, the job decides from the file.
    func noteSavedMeeting(at url: URL, title: String, titleWasGenerated: Bool = false) {
        guard canRunJobs else { return }
        let key = url.standardizedFileURL.path
        let rule: MeetingTitlesJob.TitleRule
        if let retranscribed = retranscribeRules.removeValue(forKey: key) {
            rule = retranscribed
        } else if titleWasGenerated {
            rule = .appMade(title)
        } else if takeImportedTitle(title) {
            rule = .appMade(title)
        } else {
            rule = .fromFile
        }
        queue.enqueue(MeetingTitlesJob(transcriptURL: url, titleRule: rule))
    }

    /// An imported file was queued for transcription under `title`, the name
    /// the import derived from the file. Its first save carries that title.
    func noteImportQueued(title: String) {
        let key = MeetingTitlesKeys.normalizedTitle(title)
        guard !key.isEmpty else { return }
        pendingImportTitles[key, default: 0] += 1
    }

    private var pendingImportTitles: [String: Int] = [:]

    private func takeImportedTitle(_ title: String) -> Bool {
        let key = MeetingTitlesKeys.normalizedTitle(title)
        guard let count = pendingImportTitles[key], count > 0 else { return false }
        pendingImportTitles[key] = count > 1 ? count - 1 : nil
        return true
    }

    /// Before "Transcribe again" replaces a meeting's file (which drops its
    /// `ai_*` keys and `title_set_by_user`), remember what the old file says
    /// about its title.
    func noteRetranscriptionRequested(transcriptURL: URL?) {
        guard let transcriptURL, isEnabled else { return }
        let key = transcriptURL.standardizedFileURL.path
        Task { @MainActor [weak self] in
            let rule = await Task.detached(priority: .utility) {
                Self.retranscriptionRule(at: transcriptURL)
            }.value
            self?.retranscribeRules[key] = rule
        }
    }

    /// `.userSet` when the old file carried the rename mark (it is carried
    /// over), `.appMade(title)` when the old file shows the app made the
    /// title, `.unknown` otherwise (keep the title, mark nothing).
    nonisolated static func retranscriptionRule(at url: URL) -> MeetingTitlesJob.TitleRule {
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let values = TranscriptFrontmatter.values(in: raw) else { return .unknown }
        if values[MeetingTitlesKeys.titleSetByUser] == "true" { return .userSet }
        switch MeetingTitlesTitleOwnership.decide(values: values, rule: .fromFile) {
        case .replaceable(let title): return .appMade(title)
        case .keep, .noTitle: return .unknown
        }
    }

    // MARK: - Download

    private func startDownload() {
        guard downloadTask == nil else { return }
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
    /// turned on: a frontmatter-only read that skips files already at the
    /// current version, so failed jobs and moved files get another go.
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

    /// Meetings in `directory` without this version's keys, newest first.
    nonisolated static func backfillJobs(in directory: URL, fileManager: FileManager = .default) -> [MeetingTitlesJob] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        var dated: [(URL, Date)] = []
        for url in urls where url.pathExtension == "md"
            && !url.deletingPathExtension().lastPathComponent.hasSuffix(".summary") {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let document = try? TranscriptFrontmatter.readDocument(from: url),
                  document.values["capture_type"] == "meeting",
                  !MeetingTitlesFrontmatterWriter.isCurrent(values: document.values) else { continue }
            let date = TranscriptFrontmatter.importedAt(values: document.values)
                ?? TranscriptFrontmatter.recordedAt(values: document.values)
                ?? .distantPast
            dated.append((url, date))
        }
        return dated
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.path > $1.0.path }
            .map { MeetingTitlesJob(transcriptURL: $0.0, titleRule: .fromFile) }
    }
}
