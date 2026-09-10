import AppKit
import Combine
import Foundation

enum MicrophoneSharingPolicy {
    static func requiresSharedMicrophone(runningApplicationBundleIDs: [String]) -> Bool {
        runningApplicationBundleIDs.contains("us.zoom.xos")
    }
}

/// App presence is intentional: Zoom can start using its automatic microphone
/// after Transcripted starts recording. Waiting for input activity is too late
/// to avoid joining its voice-processing graph. No microphone is opened here.
@MainActor
final class ZoomMicrophoneSharingMonitor: ObservableObject {
    static let shared = ZoomMicrophoneSharingMonitor()

    @Published private(set) var isZoomRunning = false
    private let notificationCenter: NotificationCenter
    private let runningApplicationBundleIDs: () -> [String]
    private var observers: [NSObjectProtocol] = []

    init(
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        runningApplicationBundleIDs: @escaping () -> [String] = {
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        }
    ) {
        self.notificationCenter = notificationCenter
        self.runningApplicationBundleIDs = runningApplicationBundleIDs
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        let running = MicrophoneSharingPolicy.requiresSharedMicrophone(
            runningApplicationBundleIDs: runningApplicationBundleIDs()
        )
        if isZoomRunning != running { isZoomRunning = running }
    }

    isolated deinit {
        observers.forEach(notificationCenter.removeObserver)
    }
}
