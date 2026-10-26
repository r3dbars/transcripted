// lint-fixture-path: Sources/Meeting/MeetingPromptDetector.swift
// Shape of cb900ba2a^ MeetingPromptDetector: a main-actor scan read the
// running apps (and their bundle IDs) directly.
import AppKit

@MainActor
final class MeetingPromptDetector {
    func scanCandidateApps() -> Set<String> {
        let runningApplications = NSWorkspace.shared.runningApplications
        let runningBundleIDs = Set(runningApplications.compactMap(\.bundleIdentifier))
        return runningBundleIDs
    }
}
