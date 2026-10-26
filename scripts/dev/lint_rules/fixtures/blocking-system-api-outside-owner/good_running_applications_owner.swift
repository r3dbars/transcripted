// lint-fixture-path: Sources/Support/RunningApplicationsReader.swift
// The owner itself may read the list, on its serial queue.
import AppKit

enum RunningApplicationsReader {
    private static let readQueue = DispatchQueue(label: "fixture.running-applications")

    static func bundleIdentifiers() async -> Set<String> {
        await withCheckedContinuation { continuation in
            readQueue.async {
                continuation.resume(returning: Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)))
            }
        }
    }
}
