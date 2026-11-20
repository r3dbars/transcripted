// MenuTokens.swift
// Design tokens for the menubar popover.
//
// Colors are dynamic: they resolve per-appearance so the popover can follow
// the system light/dark setting instead of forcing dark. The dark variants
// keep the popover's original look; light variants mirror them on a light
// surface. NSTextField/contentTintColor users adapt automatically, but any
// color written into a CALayer must be re-resolved when the effective
// appearance changes — use `NSView.menuResolvedCGColor(_:)` for that and
// re-apply from `viewDidChangeEffectiveAppearance()`.

import AppKit

enum MenuTokens {
    // Almost every value here comes from `DesignTokens` (Sources/UI/Shared/DesignTokens.swift),
    // the one source shared with the main window and the island. These names
    // stay so the popover's AppKit views keep reading one place. The two
    // exceptions are the secondary and muted text greys below: the popover sits
    // on a translucent system material, where the main window's see-through
    // inks drop too far (about 3.7:1 and 2.1:1 in light mode), so it keeps
    // solid greys.

    // Surface — NSPopover's native material provides the background; only the
    // section divider is drawn by the popover itself.
    static let sectionDividerNS = DesignTokens.NS.hairline

    // Text + status. Green means live (recording, transcribing), never "ready".
    static let statusLiveNS = DesignTokens.NS.live
    static let statusReadyNS = DesignTokens.NS.ink3
    static let statusOrangeNS = DesignTokens.NS.attention
    /// The recording mark. Recording is live, so it is the same green.
    static let statusRecordingNS = DesignTokens.NS.live
    static let textPrimaryNS = DesignTokens.NS.ink
    static let textSecondaryNS = DesignTokens.dynamic(
        dark: NSColor(calibratedWhite: 0.74, alpha: 1.0),
        light: NSColor(calibratedWhite: 0.35, alpha: 1.0)
    )
    static let textMutedNS = DesignTokens.dynamic(
        dark: NSColor(calibratedWhite: 0.58, alpha: 1.0),
        light: NSColor(calibratedWhite: 0.50, alpha: 1.0)
    )

    // Rows
    static let flatRowHoverNS = DesignTokens.NS.fill
    static let flatRowPressedNS = DesignTokens.NS.fillStrong
    static let flatRowDisabledNS = DesignTokens.NS.fill
    /// Filled buttons (Record, Dictate, the update callout) are the primary
    /// look: an ink fill with paper text.
    static let buttonBackgroundNS = DesignTokens.NS.ink
    static let buttonTextNS = DesignTokens.NS.paper

    // Layout
    static let panelWidth: CGFloat = 304
    static let panelHeight: CGFloat = 480
    static let innerPadding: CGFloat = 10
    static let sectionSpacing: CGFloat = 7
    static let cardCornerRadius: CGFloat = DesignTokens.Radius.control
    static let minimumHitTargetSize: CGFloat = DesignTokens.minimumHitTarget
    static let compactActionRowHeight: CGFloat = 42
    static let utilityActionRowHeight: CGFloat = 40
    static let statusDotSize: CGFloat = 6

    // Type — the shared text roles (`TextRole`). See docs/ui-tokens.md.
    // Changing a menubar font means changing it once, here.
    @MainActor
    enum Font {
        static let rowTitlePrimary = TextRole.body.nsFont(weight: .medium)
        static let rowTitleUtility = TextRole.body.nsFont(weight: .regular)
        static let rowDetail = TextRole.small.nsFont()
        // Monospaced digits so the live recording timer doesn't jitter.
        static let rowTrailingPrimary = NSFont.monospacedDigitSystemFont(ofSize: TextRole.small.size, weight: .medium)
        static let rowTrailingUtility = NSFont.monospacedDigitSystemFont(ofSize: TextRole.small.size, weight: .regular)
        static let headerStatus = TextRole.meta.nsFont(weight: .medium)
        static let headerDetail = TextRole.small.nsFont()
    }
}

extension NSView {
    /// Resolves a (possibly dynamic) color against this view's effective
    /// appearance for CALayer use. `NSColor.cgColor` alone snapshots whatever
    /// appearance is current on the calling thread, which is wrong when
    /// layer colors are assigned outside of a draw pass.
    func menuResolvedCGColor(_ color: NSColor) -> CGColor {
        var resolved = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = color.cgColor
        }
        return resolved
    }
}
