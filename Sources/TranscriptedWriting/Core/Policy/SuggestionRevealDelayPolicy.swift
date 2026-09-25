/// Keeps native editors fast while giving Chromium/Electron marked text enough
/// time to avoid moving the visible caret between keystrokes.
public enum SuggestionRevealDelayPolicy {
    public struct Schedule: Equatable, Sendable {
        public let inferenceDelayNanoseconds: UInt64
        public let revealDelayNanoseconds: UInt64

        public init(inferenceDelayNanoseconds: UInt64, revealDelayNanoseconds: UInt64) {
            self.inferenceDelayNanoseconds = inferenceDelayNanoseconds
            self.revealDelayNanoseconds = revealDelayNanoseconds
        }
    }

    private static let chromiumBundlePrefixes = [
        "com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser",
        "company.thebrowser.Browser", "com.openai.atlas", "com.vivaldi.Vivaldi",
        "com.operasoftware.Opera",
    ]

    public static func requiresCalmMarkedText(
        bundleIdentifier: String,
        hasElectronFramework: Bool
    ) -> Bool {
        hasElectronFramework
            || chromiumBundlePrefixes.contains(where: bundleIdentifier.hasPrefix)
    }

    /// How long a Chromium/Electron host is given after a keystroke before
    /// marked text is set. The production pair is the measured floor that
    /// stopped visible caret ping-pong. The preview pair is the owner's
    /// 2026-09-02 trial: in the daily-driver apps (all Electron) this floor
    /// was the largest fixed delay left on every ghost, and chained
    /// requests had already run at the shorter value without jitter.
    public struct CalmDelays: Equatable, Sendable {
        public let postSpaceNanoseconds: UInt64
        public let midWordNanoseconds: UInt64

        public init(postSpaceNanoseconds: UInt64, midWordNanoseconds: UInt64) {
            self.postSpaceNanoseconds = postSpaceNanoseconds
            self.midWordNanoseconds = midWordNanoseconds
        }

        public static let production = CalmDelays(postSpaceNanoseconds: 200_000_000, midWordNanoseconds: 120_000_000)
        public static let preview = CalmDelays(postSpaceNanoseconds: 120_000_000, midWordNanoseconds: 80_000_000)
    }

    /// `chained` marks a request issued by an accept rather than a
    /// keystroke: no key is being processed, so the shorter mid-word wait is
    /// enough to keep a Chromium caret still, and every millisecond here is
    /// dead air between one Tab and the next ghost.
    public static func nanoseconds(
        afterUserTyped grapheme: String,
        calmMarkedText: Bool,
        chained: Bool = false,
        calm: CalmDelays = .production
    ) -> UInt64 {
        let short = chained || grapheme.last?.isLetter == true
        if calmMarkedText {
            return short ? calm.midWordNanoseconds : calm.postSpaceNanoseconds
        }
        return short ? 10_000_000 : 50_000_000
    }

    /// Model work always begins with the keystroke. Chromium/Electron only
    /// defer presentation, so their caret-stability workaround does not add
    /// 120–200ms to inference latency.
    public static func schedule(
        afterUserTyped grapheme: String,
        calmMarkedText: Bool,
        chained: Bool = false,
        calm: CalmDelays = .production
    ) -> Schedule {
        Schedule(
            inferenceDelayNanoseconds: 0,
            revealDelayNanoseconds: nanoseconds(
                afterUserTyped: grapheme,
                calmMarkedText: calmMarkedText,
                chained: chained,
                calm: calm
            )
        )
    }
}
