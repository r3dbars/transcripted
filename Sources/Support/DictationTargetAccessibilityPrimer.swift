// DictationTargetAccessibilityPrimer.swift
// Asks an Auto Enter app to build its Accessibility tree, so paste-back can
// prove a paste there and Auto Enter can press Return.
//
// Electron and Chromium apps keep their web content out of Accessibility until
// an assistive client asks for it. Without that tree a paste into them can only
// end as `.likelyPasted`, which never authorizes Auto Enter. Setting
// `AXManualAccessibility` on the app element is Electron's documented switch
// for third-party assistive apps. It stays on for the life of that process.
// Apps that don't know the attribute answer kAXErrorAttributeUnsupported and
// change nothing (checked against Finder and System Settings on macOS 26).
//
// Only apps on the Auto Enter allow-list get it, and only while Auto Enter is
// on: a full Chromium tree costs the target app CPU on every page change. It
// also tells the app an assistive client is running, and VS Code-family
// editors answer that by switching to their screen-reader mode, so they never
// get it.
//
// It's set at dictation start, not at paste: a tree still being built while
// paste-back reads the focus could make a landed paste look refuted, or turn
// tree-building change events into a false confirmation.

import ApplicationServices
import Foundation

enum DictationTargetAccessibilityPrimerPolicy {
    static let manualAccessibilityAttribute = "AXManualAccessibility"

    /// Editors that turn on screen-reader mode when an app sets the attribute
    /// (`editor.accessibilitySupport: auto`): VS Code, Insiders, VSCodium,
    /// Cursor and Windsurf.
    static let screenReaderModeEditors: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.vscodium",
        "com.todesktop.230313mzl4w4u92",
        "com.exafunction.windsurf",
    ]

    static func shouldPrime(
        autoEnterEnabled: Bool,
        bundleIdentifier: String?,
        allowedBundleIDs: Set<String>
    ) -> Bool {
        guard autoEnterEnabled,
              let bundleIdentifier,
              !screenReaderModeEditors.contains(bundleIdentifier) else { return false }
        return allowedBundleIDs.contains(bundleIdentifier)
    }

    /// The app answered, so asking again won't change anything. Only "didn't
    /// answer in time" and "Accessibility is off" are worth another try on a
    /// later take.
    static func shouldRetryLater(after result: AXError) -> Bool {
        switch result {
        case .cannotComplete, .apiDisabled:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class DictationTargetAccessibilityPrimer {
    typealias EnableManualAccessibility = @Sendable (pid_t) -> AXError

    /// The set runs off the main actor, so this bounds a background wait on a
    /// busy app, not a dictation start.
    nonisolated private static let messagingTimeout: Float = 0.25

    private let enableManualAccessibility: EnableManualAccessibility
    private let ownProcessIdentifier: pid_t
    private var requestedProcessIdentifiers: Set<pid_t> = []

    init(
        enableManualAccessibility: @escaping EnableManualAccessibility = { DictationTargetAccessibilityPrimer.liveEnableManualAccessibility($0) },
        ownProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier
    ) {
        self.enableManualAccessibility = enableManualAccessibility
        self.ownProcessIdentifier = ownProcessIdentifier
    }

    /// Asks the target to expose its Accessibility tree, once per process.
    /// Returns the background request so tests can wait on it, or nil when
    /// nothing was asked. Never blocks the caller on the target app.
    @discardableResult
    func prime(
        _ target: DictationPasteTarget?,
        autoEnterEnabled: Bool,
        allowedBundleIDs: Set<String>
    ) -> Task<Void, Never>? {
        guard let processIdentifier = target?.processIdentifier,
              processIdentifier > 0,
              processIdentifier != ownProcessIdentifier,
              DictationTargetAccessibilityPrimerPolicy.shouldPrime(
                  autoEnterEnabled: autoEnterEnabled,
                  bundleIdentifier: target?.bundleIdentifier,
                  allowedBundleIDs: allowedBundleIDs
              ),
              requestedProcessIdentifiers.insert(processIdentifier).inserted else {
            return nil
        }

        let enable = enableManualAccessibility
        return Task.detached(priority: .utility) { [weak self] in
            let result = enable(processIdentifier)
            guard DictationTargetAccessibilityPrimerPolicy.shouldRetryLater(after: result) else { return }
            await self?.forget(processIdentifier)
        }
    }

    private func forget(_ processIdentifier: pid_t) {
        requestedProcessIdentifiers.remove(processIdentifier)
    }

    nonisolated static func liveEnableManualAccessibility(_ processIdentifier: pid_t) -> AXError {
        let application = AXUIElementCreateApplication(processIdentifier)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        return AXUIElementSetAttributeValue(
            application,
            DictationTargetAccessibilityPrimerPolicy.manualAccessibilityAttribute as CFString,
            kCFBooleanTrue
        )
    }
}
