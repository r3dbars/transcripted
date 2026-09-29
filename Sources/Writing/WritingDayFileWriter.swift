import AppKit
import Foundation

extension Notification.Name {
    /// Posted on the main thread after Save my writing appends to a day file.
    /// The object is the file's URL. Home and Today refresh on it.
    static let writingDayFileDidSave = Notification.Name("Transcripted.WritingDayFileDidSave")
}

/// Save my writing's host side: builds the `WritingDayFileRecorder` against
/// the capture library, closes idle entries on a timer, and flushes at quit.
/// Entries that close with nothing to scrub go on to Personal History through
/// `personalHistory`.
/// The recorder, composer and formatter live in `TranscriptedWriting/Runtime`
/// so they're tested under `swift test`; this owns only what needs AppKit or
/// the app's paths.
@MainActor
final class WritingDayFileWriter {
    /// How often an entry idle for 2 minutes is looked for.
    private static let idleSweepInterval: TimeInterval = 15

    /// `<capture-library>/writing`, from the storage-path helper that owns the
    /// capture-library folder names. The pure form doesn't create the folder;
    /// `WritingDayFileStore` creates it 0700 on first write.
    nonisolated static let defaultDirectory: @Sendable () -> URL = {
        FileManager.writingDirectory(in: FileManager.default.transcriptedCaptureLibraryDir)
    }

    let recorder: WritingDayFileRecorder
    /// Where cleared entries go to Personal History.
    let personalHistory: PersonalHistoryRelay
    private var idleTimer: Timer?
    /// Cleared at `stop()` so a rescrub still running stops between files.
    private let rescrubAllowed = RescrubFlag()

    /// `problemStarted` runs on the main actor once per write problem (see
    /// `WritingDayFileRecorder.lastWriteFailure`), with the error case only.
    init(
        directory: @escaping @Sendable () -> URL,
        preferences: @escaping @Sendable () -> WritingPreferences,
        personalHistory: any PersonalHistoryIngesting,
        problemStarted: @escaping @MainActor @Sendable (WritingDayFileStore.StoreError) -> Void = { _ in }
    ) {
        let names = WritingAppDisplayNames()
        let relay = PersonalHistoryRelay(personalHistory: personalHistory)
        self.personalHistory = relay
        recorder = WritingDayFileRecorder(
            directory: directory,
            gate: { WritingDayFileRecorder.Gate(preferences: preferences()) },
            appName: { names.name(for: $0) },
            didWrite: { url in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .writingDayFileDidSave, object: url)
                }
            },
            writeFailed: {
                DiagnosticsLog.shared.record("writing-day-file-write-failed")
            },
            writeProblemStarted: { error in
                Task { @MainActor in problemStarted(error) }
            },
            releaseToPersonalHistory: { relay.send($0) }
        )
    }

    /// The `WritingSecretScrubber.rulesVersion` the day files on disk were
    /// last scrubbed with.
    nonisolated static let scrubbedRulesVersionKey = "WritingDayFilesScrubbedRulesVersion"

    func start() {
        guard idleTimer == nil else { return }
        let recorder = recorder
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleSweepInterval, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { recorder.closeIdleEntries() }
        }
        rescrubOlderDayFilesIfNeeded()
    }

    /// Once per scrubber rules version: files written before the scrubber
    /// (or under older rules) get the current rules. Retried next launch if
    /// any file couldn't be read or written.
    private func rescrubOlderDayFilesIfNeeded() {
        let version = WritingSecretScrubber.rulesVersion
        guard UserDefaults.standard.integer(forKey: Self.scrubbedRulesVersionKey) < version else { return }
        let recorder = recorder
        let allowed = rescrubAllowed
        allowed.set(true)
        DispatchQueue.global(qos: .utility).async {
            let outcome = recorder.rescrubExistingDayFiles(shouldContinue: { allowed.value })
            DiagnosticsLog.shared.record(
                "writing-day-files-rescrubbed",
                metadata: [
                    "scanned": String(outcome.filesScanned),
                    "changed": String(outcome.filesChanged),
                    "failures": String(outcome.failures),
                ]
            )
            guard outcome.failures == 0 else { return }
            UserDefaults.standard.set(version, forKey: Self.scrubbedRulesVersionKey)
        }
    }

    /// The final flush. Synchronous on purpose: it runs from the app's quit.
    /// The open entry's day-file write finishes here; its Personal History
    /// batch is handed off and lands only if the app lives long enough.
    func stop() {
        rescrubAllowed.set(false)
        idleTimer?.invalidate()
        idleTimer = nil
        recorder.flush()
    }
}

/// A flag the rescrub reads from its background queue.
private final class RescrubFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool { lock.withLock { stored } }

    func set(_ newValue: Bool) {
        lock.withLock { stored = newValue }
    }
}

/// `Source app:` names. Asks the running app, then the installed bundle;
/// reads nothing else about the app.
private final class WritingAppDisplayNames: @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String] = [:]

    func name(for bundleIdentifier: String) -> String? {
        if let cached = lock.withLock({ names[bundleIdentifier] }) { return cached }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first?.localizedName
        let installed = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier).map {
            let name = FileManager.default.displayName(atPath: $0.path)
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        guard let resolved = running ?? installed, !resolved.isEmpty else { return nil }
        lock.withLock { names[bundleIdentifier] = resolved }
        return resolved
    }
}
