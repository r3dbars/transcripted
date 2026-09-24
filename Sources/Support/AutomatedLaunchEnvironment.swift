import Foundation

/// Our own launch harnesses set one of these: build.sh's launch smoke, the
/// launch benchmark, and the packaged first-run smoke. Each opens the app with
/// a fresh temp HOME, so anything that would otherwise treat the launch as a
/// real person's first run (analytics, crash reports, the setup resume step,
/// update checks, permission probes) checks here first.
enum AutomatedLaunchEnvironment {
    static let keys = [
        "TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT",
        "TRANSCRIPTED_FIRST_RUN_RELIABILITY_REPORT",
    ]

    static func isActive(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        keys.contains { environment[$0] != nil }
    }
}
