import Foundation

/// Decides whether a capture should read the whole display or only the
/// frontmost window. Pure and deterministic so the trade-off is testable.
///
/// Live data (2026-08-23, 25h, 1,963 captures): window captures produced a
/// usable scene 98% of the time; full-display captures were 74% of volume
/// and 84% of OCR time but produced a usable scene only 33% of the time.
/// So the window is the default, and the display is read only when the
/// window itself has no conversation to reply to — that is when
/// `referenceSnippets` from other windows can help — and the last display
/// read is too old for `ScreenScene`'s staleness window anyway.
public enum CaptureKindPolicy {
    public enum Kind: Equatable, Sendable {
        case window
        case fullDisplay
    }

    /// - Parameters:
    ///   - forcedFullDisplay: the caller has its own reason (e.g. no
    ///     layer-0 window could be identified).
    ///   - lastWindowSceneHadConversation: what the most recent window
    ///     capture classified to; `nil` when no window capture exists yet.
    ///   - secondsSinceLastFullDisplay: `nil` when the display was never read.
    ///   - stalenessCapSeconds: `ScreenScene.defaultStalenessCapSeconds`.
    public static func kind(
        forcedFullDisplay: Bool,
        lastWindowSceneHadConversation: Bool?,
        secondsSinceLastFullDisplay: TimeInterval?,
        stalenessCapSeconds: TimeInterval
    ) -> Kind {
        if forcedFullDisplay { return .fullDisplay }
        // A window we have never read is the cheapest, most useful read.
        guard let hadConversation = lastWindowSceneHadConversation else { return .window }
        if hadConversation { return .window }
        guard let age = secondsSinceLastFullDisplay else { return .fullDisplay }
        return age >= stalenessCapSeconds ? .fullDisplay : .window
    }
}
