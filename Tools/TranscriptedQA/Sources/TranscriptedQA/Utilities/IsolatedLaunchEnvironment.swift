import Foundation

// Account isolation is enforced before launch; this also marks the child as
// automated so the app suppresses first-run, update and telemetry side effects.
func applyIsolatedLaunchEnvironment(_ environment: inout [String: String], isolatedHome: URL) {
    environment["TRANSCRIPTED_AUTOMATED_HARNESS"] = "1"
    environment["HOME"] = isolatedHome.path
    environment["CFFIXED_USER_HOME"] = isolatedHome.path
    environment.removeValue(forKey: "__CFBundleIdentifier")
    environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
    environment["TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS"] = "1"
    environment["TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD"] = "1"
}
