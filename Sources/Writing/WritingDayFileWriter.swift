import AppKit
import Foundation

extension Notification.Name {
    /// Posted on the main thread after Save my writing appends to a day file.
    /// The object is the file's URL. Home and Today refresh on it.
    static let writingDayFileDidSave = Notification.Name("Transcripted.WritingDayFileDidSave")
}

/// Save my writing's host side: builds the `WritingDayFileRecorder` against
/// the capture library, closes idle entries on a timer, and flushes at quit.
/// The recorder, composer and formatter live in `TranscriptedWriting/Runtime`
/// so they're tested under `swift test`; this owns only what needs AppKit or
/// the app's paths.
@MainActor
final class WritingDayFileWriter {
    /// How often an entry idle for 2 minutes is looked for.
    private static let idleSweepInterval: TimeInterval = 15

    /// `<capture-library>/writing`. The storage-path helper that will own
    /// this lands separately; until then it's the dictations folder's sibling.
    nonisolated static let defaultDirectory: @Sendable () -> URL = {
        FileManager.default.transcriptedCaptureLibraryDir
            .appendingPathComponent(WritingDayFileStore.folderName, isDirectory: true)
    }

    let recorder: WritingDayFileRecorder
    private var idleTimer: Timer?

    init(directory: @escaping @Sendable () -> URL, preferences: @escaping @Sendable () -> WritingPreferences) {
        let names = WritingAppDisplayNames()
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
            }
        )
    }

    func start() {
        guard idleTimer == nil else { return }
        let recorder = recorder
        idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleSweepInterval, repeats: true) { _ in
            DispatchQueue.global(qos: .utility).async { recorder.closeIdleEntries() }
        }
    }

    /// The final flush. Synchronous on purpose: it runs from the app's quit.
    func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
        recorder.flush()
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
