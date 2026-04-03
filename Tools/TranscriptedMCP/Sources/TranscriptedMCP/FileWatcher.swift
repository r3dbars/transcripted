import Foundation

final class FileWatcher: @unchecked Sendable {
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var pendingScan: DispatchWorkItem?
    private let directory: URL
    private let onChange: (URL) -> Void
    private var knownModTimes: [String: TimeInterval] = [:]
    private let watchQueue = DispatchQueue(label: "com.transcripted.mcp.watcher", qos: .utility)

    init(directory: URL, onChange: @escaping (URL) -> Void) {
        self.directory = directory
        self.onChange = onChange
    }

    func start() {
        startDirectoryWatcher()
        startReconciliationTimer()
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
            self?.scanForChanges()
        }
        timer.resume()
        self.timer = timer
    }

    private func scanForChanges() {
        let files = TranscriptLoader.enumerateSidecars(in: directory)

        for (url, modDate) in files {
            let filename = url.deletingPathExtension().lastPathComponent
            if knownModTimes[filename] != modDate {
                knownModTimes[filename] = modDate
                onChange(url)
            }
        }
    }
}
