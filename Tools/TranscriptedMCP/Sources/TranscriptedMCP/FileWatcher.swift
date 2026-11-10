import Foundation

final class FileWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var pendingScan: DispatchWorkItem?
    private let directory: URL
    private let onChange: () -> Void
    /// Runs on every timer tick after the change scan, even when nothing
    /// changed, for retries that must not wait for a file write.
    private let onPeriodicTick: (() -> Void)?
    private var knownModTimes: [String: TimeInterval] = [:]
    private let watchQueue = DispatchQueue(label: "com.transcripted.mcp.watcher", qos: .utility)

    init(directory: URL, onPeriodicTick: (() -> Void)? = nil, onChange: @escaping () -> Void) {
        self.directory = directory
        self.onPeriodicTick = onPeriodicTick
        self.onChange = onChange
        knownModTimes = Self.modificationTimes(in: directory)
    }

    func start() {
        startDirectoryWatcher()
        startReconciliationTimer()
        // Catch writes made during initial indexing or before the source was
        // installed. An unchanged snapshot does not trigger another reconcile.
        watchQueue.async { [weak self] in self?.scanForChanges() }
    }

    func stop() {
        source?.cancel()
        source = nil
        timer?.cancel()
        timer = nil
    }

    private func startDirectoryWatcher() {
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            log("Failed to open directory fd for watching, relying on reconciliation timer only")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: watchQueue
        )
        source.setEventHandler { [weak self] in
            // Debounce: cancel previous pending scan, wait 500ms for writes to settle
            self?.pendingScan?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.scanForChanges()
            }
            self?.pendingScan = work
            self?.watchQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        self.source = source
    }

    private func startReconciliationTimer() {
        let timer = DispatchSource.makeTimerSource(queue: watchQueue)
        timer.schedule(deadline: .now() + 300, repeating: 300) // 5 minutes
        timer.setEventHandler { [weak self] in
            self?.periodicTick()
        }
        timer.resume()
        self.timer = timer
    }

    func periodicTick() {
        scanForChanges()
        onPeriodicTick?()
    }

    func scanForChanges() {
        let currentModTimes = Self.modificationTimes(in: directory)
        guard currentModTimes != knownModTimes else { return }
        knownModTimes = currentModTimes
        onChange()
    }

    private static func modificationTimes(in directory: URL) -> [String: TimeInterval] {
        let files = TranscriptLoader.enumerateArtifacts(in: directory)
        var currentModTimes: [String: TimeInterval] = [:]

        for file in files {
            let filename = file.url.deletingPathExtension().lastPathComponent
            let modDate = file.modDate
            currentModTimes[filename] = modDate
        }

        return currentModTimes
    }
}
