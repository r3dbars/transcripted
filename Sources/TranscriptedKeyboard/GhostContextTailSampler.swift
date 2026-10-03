#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Cocoa

/// Remembers the host's text before the caret from one suggestion request to
/// the next, and says when it changed wholesale (a different thread opened
/// in the same field) so Screen Memory can recapture.
///
/// It samples host text only, never the keyboard's own typed fallback: a
/// field that can't report its text has no thread to switch, and the
/// fallback is ours, not the host's. It runs after the key callback has
/// returned (from `updateSuggestion`), not inside it.
struct GhostContextTailSampler {
    let limit: Int
    private(set) var lastTail = ""

    init(limit: Int) {
        self.limit = limit
    }

    /// Records `hostText` as the latest sample and returns whether it is a
    /// wholesale change from the previous one. `nil` (secure input, no caret,
    /// a selection) stores an empty sample and never reports.
    mutating func record(_ hostText: String?) -> Bool {
        guard var text = hostText, !text.isEmpty else {
            lastTail = ""
            return false
        }
        // IMK hands back bridged NSStrings. Grapheme walks over a bridged
        // string with any non-ASCII text cost ~1.2 ms at 3,000 chars;
        // the same walk over native UTF-8 is a few microseconds. Same
        // characters, same answer.
        text.makeContiguousUTF8()
        let tail = String(text.suffix(limit))
        defer { lastTail = tail }
        return ContextResetDetector.isReset(previous: lastTail, current: tail)
    }
}

/// Whether a host needs the calm (Chromium/Electron) marked-text reveal,
/// shared by every input session in the keyboard process.
///
/// Chromium browsers are known by bundle prefix with no lookup. Anything else
/// costs a LaunchServices query plus a file stat the first time, so the
/// answer is cached until an app launches or quits (a reinstall can turn an
/// app into or out of Electron). Main thread only, like the controller.
final class GhostCalmRevealCache {
    static let shared = GhostCalmRevealCache(
        lookupHasElectronFramework: GhostCalmRevealCache.hasElectronFramework(bundleIdentifier:),
        observesWorkspace: true
    )

    private let lookupHasElectronFramework: (String) -> Bool
    private var answers = [String: Bool]()
    private var observers = [NSObjectProtocol]()

    init(lookupHasElectronFramework: @escaping (String) -> Bool, observesWorkspace: Bool = false) {
        self.lookupHasElectronFramework = lookupHasElectronFramework
        guard observesWorkspace else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            // Clear everything rather than reading the notification's app:
            // no bundle-identifier read on main for an unrelated launch.
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.invalidate()
            })
        }
    }

    deinit {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func usesCalmReveal(for bundleIdentifier: String) -> Bool {
        guard !bundleIdentifier.isEmpty else { return false }
        // Same answer `requiresCalmMarkedText` gives with any framework flag.
        if SuggestionRevealDelayPolicy.requiresCalmMarkedText(
            bundleIdentifier: bundleIdentifier,
            hasElectronFramework: false
        ) {
            return true
        }
        if let cached = answers[bundleIdentifier] { return cached }
        let calm = SuggestionRevealDelayPolicy.requiresCalmMarkedText(
            bundleIdentifier: bundleIdentifier,
            hasElectronFramework: lookupHasElectronFramework(bundleIdentifier)
        )
        answers[bundleIdentifier] = calm
        return calm
    }

    func invalidate() {
        answers.removeAll()
    }

    static func hasElectronFramework(bundleIdentifier: String) -> Bool {
        let electronFramework = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleIdentifier)
            .first?.bundleURL?
            .appendingPathComponent("Contents/Frameworks/Electron Framework.framework")
        return electronFramework.map {
            FileManager.default.fileExists(atPath: $0.path)
        } ?? false
    }
}
