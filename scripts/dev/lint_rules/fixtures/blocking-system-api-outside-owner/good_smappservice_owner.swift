// lint-fixture-path: Sources/Support/LaunchAtLoginController.swift
// The owner itself may call SMAppService, on its status queue.
import ServiceManagement

enum LaunchAtLoginController {
    private nonisolated static let statusQueue = DispatchQueue(label: "fixture.launch-at-login-status")

    nonisolated static func readState() async -> Bool {
        await withCheckedContinuation { continuation in
            statusQueue.async {
                continuation.resume(returning: SMAppService.mainApp.status == .enabled)
            }
        }
    }
}
