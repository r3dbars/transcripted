import AppKit
import Darwin
import Foundation

final class SingleInstanceGuard {
    enum AcquisitionResult: Equatable {
        case acquired
        case alreadyRunning
    }

    static let reopenNotificationName = Notification.Name("com.transcripted.single-instance.reopen")

    private let lockURL: URL
    private var lockFileDescriptor: Int32 = -1

    init(lockURL: URL = FileManager.default.transcriptedAppInstanceLockURL) {
        self.lockURL = lockURL
    }

    deinit {
        release()
    }

    func acquire() -> AcquisitionResult {
        if lockFileDescriptor >= 0 {
            return .acquired
        }

        do {
            try FileManager.default.createPrivateDirectory(at: lockURL.deletingLastPathComponent())
        } catch {
            fputs("SINGLE_INSTANCE | failed to prepare lock directory: \(error.localizedDescription)\n", stderr)
            return .acquired
        }

        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )

        guard descriptor >= 0 else {
            fputs("SINGLE_INSTANCE | failed to open lock file: errno \(errno)\n", stderr)
            return .acquired
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            return .alreadyRunning
        }

        FileManager.default.restrictFileToOwnerOnly(at: lockURL)
        lockFileDescriptor = descriptor
        return .acquired
    }

    func release() {
        guard lockFileDescriptor >= 0 else { return }
        flock(lockFileDescriptor, LOCK_UN)
        Darwin.close(lockFileDescriptor)
        lockFileDescriptor = -1
    }

    static func requestExistingInstanceToPresent() {
        DistributedNotificationCenter.default().postNotificationName(
            reopenNotificationName,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    @MainActor
    static func activateExistingInstance(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        currentProcessID: pid_t = getpid()
    ) {
        guard let bundleIdentifier else { return }

        let existing = NSWorkspace.shared.runningApplications.first { application in
            application.processIdentifier != currentProcessID
                && application.bundleIdentifier == bundleIdentifier
        }
        if #available(macOS 14.0, *) {
            existing?.activate()
        } else {
            existing?.activate(options: [.activateIgnoringOtherApps])
        }
    }
}

extension FileManager {
    var transcriptedAppInstanceLockURL: URL {
        transcriptedAppSupportDir.appendingPathComponent("transcripted.instance.lock", isDirectory: false)
    }
}
