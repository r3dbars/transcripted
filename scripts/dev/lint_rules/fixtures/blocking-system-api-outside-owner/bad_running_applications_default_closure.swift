// lint-fixture-path: Sources/Support/CallAppMicrophoneSharingMonitor.swift
// Shape of fabac326f^: the default reader closure ran on main during launch,
// and is split across lines so a single-line grep misses it.
import AppKit

@MainActor
final class CallAppMicrophoneSharingMonitor {
    private let runningApplicationBundleIDs: () -> [String]

    init(
        runningApplicationBundleIDs: @escaping () -> [String] = {
            NSWorkspace.shared
                .runningApplications
                .compactMap(\.bundleIdentifier)
        }
    ) {
        self.runningApplicationBundleIDs = runningApplicationBundleIDs
    }
}
