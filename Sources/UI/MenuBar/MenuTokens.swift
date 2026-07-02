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
    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    // Surface — NSPopover's native material provides the background; only the
    // section divider is drawn by the popover itself.
    static let sectionDividerNS = dynamic(
        dark: NSColor.white.withAlphaComponent(0.12),
        light: NSColor.black.withAlphaComponent(0.12)
    )

    // Text + status
    static let statusGreenNS = NSColor.systemGreen
    static let statusOrangeNS = NSColor.systemOrange
    static let statusRedNS = NSColor.systemRed
    static let textPrimaryNS = dynamic(
        dark: NSColor.white,
        light: NSColor(calibratedWhite: 0.10, alpha: 1.0)
    )
    static let textSecondaryNS = dynamic(
        dark: NSColor(calibratedWhite: 0.74, alpha: 1.0),
        light: NSColor(calibratedWhite: 0.35, alpha: 1.0)
    )
    static let textMutedNS = dynamic(
        dark: NSColor(calibratedWhite: 0.58, alpha: 1.0),
        light: NSColor(calibratedWhite: 0.50, alpha: 1.0)
    )

    // Rows
    static let flatRowHoverNS = dynamic(
        dark: NSColor.white.withAlphaComponent(0.075),
        light: NSColor.black.withAlphaComponent(0.06)
    )
    static let flatRowPressedNS = dynamic(
        dark: NSColor.white.withAlphaComponent(0.12),
        light: NSColor.black.withAlphaComponent(0.10)
    )
    static let flatRowDisabledNS = dynamic(
        dark: NSColor.white.withAlphaComponent(0.02),
        light: NSColor.black.withAlphaComponent(0.02)
    )
    static let buttonBackgroundNS = dynamic(
        dark: NSColor.white.withAlphaComponent(0.08),
        light: NSColor.black.withAlphaComponent(0.06)
    )

    // Layout
    static let panelWidth: CGFloat = 304
    static let panelHeight: CGFloat = 480
    static let innerPadding: CGFloat = 10
    static let sectionSpacing: CGFloat = 7
    static let cardCornerRadius: CGFloat = 8
    static let minimumHitTargetSize: CGFloat = 40
    static let compactActionRowHeight: CGFloat = 42
    static let utilityActionRowHeight: CGFloat = 40
    static let statusDotSize: CGFloat = 6
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
