#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import AppKit
import Foundation

extension Notification.Name {
    /// Posted on the main thread after opt-in writing capture appends to a day
    /// file. The object is the file's URL. Home and Today refresh on it.
    static let writingDayFileDidSave = Notification.Name("Transcripted.WritingDayFileDidSave")
}

/// Host side of opt-in writing capture: builds `WritingDayFileRecorder`
/// against `<capture-library>/writing`, closes idle entries on a timer,
/// rescrubs older day files when scrubber rules advance, and flushes at quit.
@MainActor
final class WritingDayFileWriter {
    private static let idleSweepInterval: TimeInterval = 15
    private static let idleSweepTolerance: TimeInterval = 3

    nonisolated static let defaultDirectory: @Sendable () -> URL = {
        FileManager.writingDirectory(in: FileManager.default.transcriptedCaptureLibraryDir)
    }

    nonisolated static let defaultPendingDirectory: @Sendable () -> URL = {
        FileManager.default.transcriptedAppSupportRootURL
            .appendingPathComponent("writing", isDirectory: true)
            .appendingPathComponent("Pending Entries", isDirectory: true)
    }

    let recorder: WritingDayFileRecorder
    private var idleTimer: Timer?
    private let rescrubAllowed = RescrubFlag()

    init(
        directory: @escaping @Sendable () -> URL,
        pendingDirectory: @escaping @Sendable () -> URL,
        preferences: @escaping @Sendable () -> WritingPreferences,
        problemStarted: @escaping @MainActor @Sendable (WritingDayFileStore.StoreError) -> Void = { _ in }
    ) {
        let names = WritingAppDisplayNames()
        recorder = WritingDayFileRecorder(
            directory: directory,
            pendingDirectory: pendingDirectory,
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
            }
        )
    }

    nonisolated static let scrubbedRulesVersionKey = "WritingDayFilesScrubbedRulesVersion"

    func start() {
        guard idleTimer == nil else { return }
        let recorder = recorder
        let timer = Timer.scheduledTimer(withTimeInterval: Self.idleSweepInterval, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { recorder.closeIdleEntries() }
        }
        timer.tolerance = Self.idleSweepTolerance
        idleTimer = timer
        DispatchQueue.global(qos: .utility).async { recorder.closeIdleEntries() }
        rescrubOlderDayFilesIfNeeded()
    }

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
                    "skipped": String(outcome.skipped),
                ]
            )
            guard outcome.failures == 0 else { return }
            UserDefaults.standard.set(version, forKey: Self.scrubbedRulesVersionKey)
        }
    }

    @discardableResult
    func stop() -> Bool {
        guard recorder.flush() else { return false }
        rescrubAllowed.set(false)
        idleTimer?.invalidate()
        idleTimer = nil
        return true
    }
}

private final class RescrubFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool { lock.withLock { stored } }

    func set(_ newValue: Bool) {
        lock.withLock { stored = newValue }
    }
}

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
