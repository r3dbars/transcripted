import Foundation

/// Plain-words copy for Settings-page action failures (beta setup, model-cache
/// cleanup, launch-at-login, capture-library migration).
///
/// Foundation-pure so the strings can be pinned by fast tests and can never
/// regress to a raw `error.localizedDescription` dump. Each message says what
/// happened and the one thing to try; the raw error is offered separately behind
/// "Copy Details", never shown inline. Plain words, no jargon, no exclamation
/// marks — the repo voice convention. Mirrors `HomeActionFailureCopy` and
/// `AgentSetupFailureCopy`.
enum SettingsActionFailureCopy {
    /// Title for the reveal affordance that copies the raw error to the clipboard.
    static let detailsTitle = "Copy Details"

    static let betaLiveSidecar =
        "Transcripted couldn't prepare the live meeting sidecar. Try turning it on again."

    static func localSummary(providerTitle: String) -> String {
        "\(providerTitle) setup didn't finish. Check your connection and free disk space, then try again."
    }

    static let modelCacheRemoval =
        "Transcripted couldn't remove those model files. Check that no capture is running, then try again."

    static let launchAtLogin =
        "Transcripted couldn't change the launch-at-login setting. Try again."

    static func captureLibraryMigration(currentLibraryPath: String) -> String {
        "The copy stopped before it finished. Your captures are still in \(currentLibraryPath) and the library was not switched. Try again."
    }
}
