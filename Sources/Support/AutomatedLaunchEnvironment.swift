import Foundation

/// Our own launch harnesses set one of these: build.sh's launch smoke, the
/// launch benchmark, the packaged first-run smoke, and the debug control CLI
/// (`TRANSCRIPTED_AUTOMATED_HARNESS=1`). The smokes open the app with a fresh
/// temp HOME; the debug CLI only moves app state into a container dir, so it
/// still shares the real UserDefaults domain. Anything that would otherwise treat the launch as a
/// real person's first run (analytics, crash reports, the setup resume step,
/// update checks, permission probes) checks here first.
enum AutomatedLaunchEnvironment {
    static let harnessKey = "TRANSCRIPTED_AUTOMATED_HARNESS"
    static let keys = [
        "TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT",
        "TRANSCRIPTED_FIRST_RUN_RELIABILITY_REPORT",
        harnessKey,
    ]

    static func isActive(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        // The generic harness key must be exactly "1", so a stray `=0` or a
        // leftover `launchctl setenv` can't quietly turn off updates and
        // crash reports in a shipped app.
        keys.contains { key in
            guard let value = environment[key] else { return false }
            return key == harnessKey ? value == "1" : true
        }
    }
}
