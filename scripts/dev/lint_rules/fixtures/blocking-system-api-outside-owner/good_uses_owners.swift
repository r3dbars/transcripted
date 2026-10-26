// lint-fixture-path: Sources/Meeting/MeetingPromptDetector.swift
// The fixed shapes: go through the owners. Mentions in comments and strings,
// and cheap non-blocking reads, don't count.
import AppKit
import EventKit

@MainActor
final class MeetingPromptDetector {
    // Don't read NSWorkspace.shared.runningApplications or build EKEventStore() here.
    private let note = "SMAppService.mainApp.register() runs on the status queue"

    func scanCandidateApps() async -> Set<String> {
        await RunningApplicationsReader.bundleIdentifiers()
    }

    func refreshLoginItem() async -> Bool {
        await LaunchAtLoginController.readState().isEnabled
    }

    func calendarAllowed() -> Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    func isRunning(_ bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    func frontmost() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
