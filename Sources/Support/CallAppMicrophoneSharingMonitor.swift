import AppKit
import Combine
import Foundation

enum MicrophoneSharingPolicy {
    /// Desktop call apps that run their own voice processing on the mic.
    /// Apple voice processing in Transcripted fights them for the shared mic
    /// (Zoom lost the user's voice) and makes their call audio quieter, so
    /// while one is open Transcripted stays on software autogain.
    ///
    /// Exact ids, not family prefixes, so lookalike apps never match.
    /// Browsers stay out on purpose: a Safari or Firefox call is the case
    /// Boost Mic exists for. Chat apps that only sometimes call (Slack,
    /// Discord) stay out too, since they are open all day and would take
    /// Boost away from browser calls; Boost is per meeting and opt-in there.
    static let callAppBundleIDs: Set<String> = [
        "us.zoom.xos",
        "com.microsoft.teams",
        "com.microsoft.teams2",
        "com.cisco.webexmeetingsapp",
        "com.webex.meetingmanager",
        "Cisco-Systems.Spark",
        "com.apple.FaceTime",
    ]

    static func requiresSharedMicrophone(runningApplicationBundleIDs: [String]) -> Bool {
        runningApplicationBundleIDs.contains(where: callAppBundleIDs.contains)
    }

    static func runningCallApps(runningApplicationBundleIDs: [String]) -> Set<String> {
        Set(runningApplicationBundleIDs.filter(callAppBundleIDs.contains))
    }

    /// Processes that hold the mic for a call app's call. Some call apps take
    /// the mic from a helper, not the app itself: Zoom's meeting host, and
    /// Apple's call daemon for FaceTime and iPhone calls on the Mac.
    static let callMicrophoneProcessBundleIDs: Set<String> = callAppBundleIDs.union([
        "us.zoom.CptHost",
        "com.apple.avconferenced",
    ])

    /// True when a call app (or one of its helpers, `id.suffix`) is holding
    /// the mic input right now. Just having Teams or Zoom open all day is not
    /// enough to take Boost Mic away from a browser call.
    static func isCallAppUsingMicrophone(micInputBundleIDs: Set<String>) -> Bool {
        micInputBundleIDs.contains { bundleID in
            callMicrophoneProcessBundleIDs.contains { id in
                bundleID == id || bundleID.hasPrefix(id + ".")
            }
        }
    }
}

/// App presence is intentional: a call app can start using its automatic
/// microphone after Transcripted starts recording. Waiting for input activity
/// is too late to avoid joining its voice-processing graph. No microphone is
/// opened here.
@MainActor
final class CallAppMicrophoneSharingMonitor: ObservableObject {
    static let shared = CallAppMicrophoneSharingMonitor()

    @Published private(set) var isCallAppRunning = false
    /// Which listed call apps are open. Lets owners notice a second call app
    /// launching while the first is already open.
    @Published private(set) var runningCallAppBundleIDs: Set<String> = []
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
        let apps = MicrophoneSharingPolicy.runningCallApps(
            runningApplicationBundleIDs: runningApplicationBundleIDs()
        )
        if runningCallAppBundleIDs != apps { runningCallAppBundleIDs = apps }
        let running = !apps.isEmpty
        if isCallAppRunning != running { isCallAppRunning = running }
    }

    isolated deinit {
        observers.forEach(notificationCenter.removeObserver)
    }
}
