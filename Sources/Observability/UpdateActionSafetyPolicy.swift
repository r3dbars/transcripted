import Foundation

enum UpdateActionSafetyState: Equatable {
    case unknown
    case readyToCheck
    case checking
    case noUpdateAvailable
    case updateAvailable
    case downloading
    case readyToInstall
}

/// Why an update click can't reach Sparkle's window right now.
enum UpdateClickProblem: Equatable {
    /// No valid HTTPS feed and signing key (a local or tampered build).
    case updaterNotConfigured
    /// Sparkle is mid-session without an update on screen, or never started.
    /// It would ignore the call and show nothing.
    case updaterBusy
}

enum UpdateClickRoute: Equatable {
    /// A downloaded update is staged: install it and relaunch.
    case installImmediately
    /// Sparkle holds this update in its open session (a quiet reminder, or a
    /// downloaded update waiting on its window). Bring that window forward.
    case showHeldUpdate
    /// No session is open: start Sparkle's own check, which shows its window.
    case startUserCheck
    /// Sparkle is still reading the feed. The click runs when that ends.
    case waitForFeedRead
    /// Sparkle would silently ignore the click, so say why instead.
    case explain(UpdateClickProblem)
}

/// Decides what a click on the update item does. Every route either opens
/// Sparkle's window, installs, or shows a message. Issue #1830: on 1.1.61 a
/// click during a quiet reminder went down a guarded path Sparkle ignores
/// while its session is open, so nothing happened.
///
/// Mirrors the early returns in Sparkle 2.9.1 `-[SPUUpdater checkForUpdates]`:
/// with a session open it only acts when an update (or permission prompt) is
/// on screen, and it does nothing before the updater has started. Mid-session,
/// Sparkle turns `canCheckForUpdates` back on exactly when its driver has shown
/// an update, so that also counts as held. It covers an Install window the
/// person opened that slipped behind other windows, which the quiet-reminder
/// flag alone misses.
enum UpdateClickRoutingPolicy {
    static func route(
        state: UpdateActionSafetyState,
        hasConfiguredFeed: Bool,
        hasImmediateInstallHandler: Bool,
        sessionInProgress: Bool,
        isSparkleHoldingUpdate: Bool,
        canCheckForUpdates: Bool
    ) -> UpdateClickRoute {
        guard hasConfiguredFeed else { return .explain(.updaterNotConfigured) }

        if state == .readyToInstall, hasImmediateInstallHandler {
            return .installImmediately
        }

        if sessionInProgress {
            if isSparkleHoldingUpdate || canCheckForUpdates { return .showHeldUpdate }
            if state == .updateAvailable { return .waitForFeedRead }
            return .explain(.updaterBusy)
        }

        return canCheckForUpdates ? .startUserCheck : .explain(.updaterBusy)
    }

    static let downloadPageURL = URL(string: "https://github.com/r3dbars/transcripted/releases/latest")!

    static func message(for problem: UpdateClickProblem) -> (title: String, detail: String) {
        let manual = "You can get the latest version from the download page, or run "
            + "brew upgrade --cask transcripted if you installed with Homebrew."
        switch problem {
        case .updaterNotConfigured:
            return ("This copy of Transcripted can't update itself", manual)
        case .updaterBusy:
            return (
                "The updater is still busy",
                "Try again in a minute. " + manual
            )
        }
    }
}

/// Decides when an update should ask for the person's attention: the orange
/// menu bar badge and the settings sidebar footer badge.
///
/// A found update that Sparkle is about to download on its own stays quiet,
/// because the next visible step is "Restart to Update". Everything else that
/// needs a click (an update Sparkle will not fetch by itself, or a downloaded
/// one waiting for a restart) shows the badge right away, so people who never
/// open the menu still learn an update exists.
enum UpdateAttentionPolicy {
    static func needsUserAction(
        state: UpdateActionSafetyState,
        availableUpdateDownloadsAutomatically: Bool
    ) -> Bool {
        switch state {
        case .readyToInstall:
            return true
        case .updateAvailable:
            return !availableUpdateDownloadsAutomatically
        case .unknown, .readyToCheck, .checking, .noUpdateAvailable, .downloading:
            return false
        }
    }
}

/// Decides whether Sparkle's background check should wait. Only matters when
/// automatic downloads are on: that check is what starts a ~500 MB download,
/// so it waits while the Mac is busy recording or transcribing, and while the
/// network is expensive (a phone hotspot) or constrained (Low Data Mode).
/// With automatic downloads off the check only fetches a few KB and runs.
/// Checks the person starts are never deferred.
enum BackgroundUpdateDeferralPolicy {
    enum Reason: String, Equatable {
        case busy
        case costlyNetwork = "costly_network"
    }

    static func deferralReason(
        isBackgroundCheck: Bool,
        automaticDownloadsEnabled: Bool,
        isBusy: Bool,
        isOnCostlyNetwork: Bool
    ) -> Reason? {
        guard isBackgroundCheck, automaticDownloadsEnabled else { return nil }
        if isBusy { return .busy }
        if isOnCostlyNetwork { return .costlyNetwork }
        return nil
    }
}

/// Why an update action is waiting. The update row used to just grey out
/// while the orange badge kept asking, so the row now says what it waits on.
enum UpdateBlockedReason: Equatable {
    case recording
    case transcribing
    case speakerReview

    /// Recording wins over transcribing, which wins over a waiting speaker review.
    static func current(
        isRecording: Bool,
        isTranscribing: Bool,
        isSpeakerReviewPending: Bool
    ) -> UpdateBlockedReason? {
        if isRecording { return .recording }
        if isTranscribing { return .transcribing }
        if isSpeakerReviewPending { return .speakerReview }
        return nil
    }
}

enum UpdateActionSafetyPolicy {
    static let activeCaptureHelp = "Finish the current recording or processing work before checking for updates."

    /// A short line for the disabled update row, or nil when nothing blocks it.
    static func blockedDetail(
        state: UpdateActionSafetyState,
        reason: UpdateBlockedReason?
    ) -> String? {
        guard let reason, requiresIdleCapture(for: state) else { return nil }
        switch reason {
        case .recording:
            return "After this recording finishes"
        case .transcribing:
            return "After transcribing finishes"
        case .speakerReview:
            return "Finish naming speakers first"
        }
    }

    static func canRunUserAction(
        state: UpdateActionSafetyState,
        sparkleCanRunUserAction: Bool,
        availableUpdateDownloadsAutomatically: Bool,
        isCaptureActive: Bool
    ) -> Bool {
        guard sparkleCanRunUserAction else { return false }
        if state == .updateAvailable && availableUpdateDownloadsAutomatically {
            return false
        }
        if isCaptureActive && requiresIdleCapture(for: state) {
            return false
        }
        return true
    }

    static func captureSafetyHelp(
        state: UpdateActionSafetyState,
        isCaptureActive: Bool
    ) -> String? {
        guard isCaptureActive && requiresIdleCapture(for: state) else { return nil }
        return activeCaptureHelp
    }

    static func requiresIdleCapture(for state: UpdateActionSafetyState) -> Bool {
        switch state {
        case .unknown, .readyToCheck, .noUpdateAvailable, .updateAvailable, .readyToInstall:
            return true
        case .checking, .downloading:
            return false
        }
    }
}
