// MenuTokens.swift
// Design tokens for the menubar popover.

import AppKit
import SwiftUI

enum MenuTokens {
    // Surface
    static let surfaceBackgroundNS = NSColor(calibratedWhite: 0.11, alpha: 0.98)
    static let surfaceStrokeNS = NSColor.white.withAlphaComponent(0.08)
    static let sectionDividerNS = NSColor.white.withAlphaComponent(0.08)

    // Text + status
    static let statusGreenNS = NSColor.systemGreen
    static let statusOrangeNS = NSColor.systemOrange
    static let textPrimaryNS = OverlayTokens.textPrimary
    static let textSecondaryNS = OverlayTokens.textSecondary
    static let textMutedNS = OverlayTokens.textMuted

    // Rows
    static let actionBackgroundNS = NSColor.white.withAlphaComponent(0.06)
    static let actionPressedNS = NSColor.white.withAlphaComponent(0.10)
    static let actionDisabledNS = NSColor.white.withAlphaComponent(0.03)
    static let actionBorderNS = NSColor.white.withAlphaComponent(0.08)
    static let badgeBackgroundNS = NSColor.white.withAlphaComponent(0.08)
    static let badgeBorderNS = NSColor.white.withAlphaComponent(0.12)
    static let recentHoverNS = NSColor.white.withAlphaComponent(0.05)
    static let failedBackgroundNS = NSColor.systemOrange.withAlphaComponent(0.14)
    static let failedBorderNS = NSColor.systemOrange.withAlphaComponent(0.24)

    // Compatibility aliases for existing AppKit controls still using the old names.
    static let cardBackgroundNS = actionBackgroundNS
    static let cardBorderNS = actionBorderNS
    static let pillBackgroundNS = badgeBackgroundNS
    static let pillBorderNS = badgeBorderNS
    static let buttonBackgroundNS = badgeBackgroundNS
    static let buttonBorderNS = badgeBorderNS

    // SwiftUI wrappers still used by onboarding
    static let statusGreen = Color.green
    static let statusOrange = Color.orange
    static let textSecondary = Color(MenuTokens.textSecondaryNS)
    static let textMuted = Color(MenuTokens.textMutedNS)
    static let cardBackground = Color(MenuTokens.surfaceBackgroundNS)
    static let cardBorder = Color(MenuTokens.surfaceStrokeNS)
    static let pillBackground = Color(MenuTokens.badgeBackgroundNS)
    static let pillBorder = Color(MenuTokens.badgeBorderNS)

    // Layout
    static let panelWidth: CGFloat = 360
    static let panelHeight: CGFloat = 384
    static let innerPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 14
    static let surfaceCornerRadius: CGFloat = 14
    static let cardCornerRadius: CGFloat = 12
    static let actionRowHeight: CGFloat = 50
    static let recentRowHeight: CGFloat = 40
    static let failedRowHeight: CGFloat = 42
    static let badgeHeight: CGFloat = 24
    static let statusDotSize: CGFloat = 6
    static let compactStyleLines = 4
}
