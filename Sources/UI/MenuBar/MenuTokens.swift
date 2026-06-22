// MenuTokens.swift
// Design tokens for the menubar popover.

import AppKit
import SwiftUI

enum MenuTokens {
    // Surface
    static let surfaceBackgroundNS = NSColor(calibratedWhite: 0.11, alpha: 0.98)
    static let surfaceStrokeNS = NSColor.white.withAlphaComponent(0.08)
    static let sectionDividerNS = NSColor.white.withAlphaComponent(0.12)

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
    static let flatRowHoverNS = NSColor.white.withAlphaComponent(0.075)
    static let flatRowPressedNS = NSColor.white.withAlphaComponent(0.12)
    static let flatRowDisabledNS = NSColor.white.withAlphaComponent(0.02)
    static let badgeBackgroundNS = NSColor.white.withAlphaComponent(0.08)
    static let badgeBorderNS = NSColor.white.withAlphaComponent(0.12)
    static let symbolBackgroundNS = NSColor.white.withAlphaComponent(0.05)
    static let symbolBorderNS = NSColor.white.withAlphaComponent(0.08)
    static let secondaryButtonBackgroundNS = NSColor.white.withAlphaComponent(0.02)
    static let secondaryButtonHoverNS = NSColor.white.withAlphaComponent(0.07)
    static let secondaryButtonPressedNS = NSColor.white.withAlphaComponent(0.10)
    static let secondaryButtonBorderNS = NSColor.white.withAlphaComponent(0.10)
    static let accentButtonBackgroundNS = NSColor.systemBlue.withAlphaComponent(0.16)
    static let accentButtonHoverNS = NSColor.systemBlue.withAlphaComponent(0.22)
    static let accentButtonPressedNS = NSColor.systemBlue.withAlphaComponent(0.28)
    static let accentButtonBorderNS = NSColor.systemBlue.withAlphaComponent(0.34)
    static let savedBackgroundNS = NSColor.systemGreen.withAlphaComponent(0.14)
    static let savedBorderNS = NSColor.systemGreen.withAlphaComponent(0.24)

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
    static let textPrimary = Color(MenuTokens.textPrimaryNS)
    static let textSecondary = Color(MenuTokens.textSecondaryNS)
    static let textMuted = Color(MenuTokens.textMutedNS)
    static let cardBackground = Color(MenuTokens.surfaceBackgroundNS)
    static let cardBorder = Color(MenuTokens.surfaceStrokeNS)
    static let pillBackground = Color(MenuTokens.badgeBackgroundNS)
    static let pillBorder = Color(MenuTokens.badgeBorderNS)
    static let savedBackground = Color(MenuTokens.savedBackgroundNS)
    static let savedBorder = Color(MenuTokens.savedBorderNS)

    // Layout
    static let panelWidth: CGFloat = 304
    static let panelHeight: CGFloat = 480
    static let onboardingWindowWidth: CGFloat = 720
    static let onboardingWindowHeight: CGFloat = 740
    static let innerPadding: CGFloat = 10
    static let sectionSpacing: CGFloat = 7
    static let surfaceCornerRadius: CGFloat = 14
    static let cardCornerRadius: CGFloat = 8
    static let minimumHitTargetSize: CGFloat = 40
    static let compactActionRowHeight: CGFloat = 42
    static let utilityActionRowHeight: CGFloat = 40
    static let actionRowHeight: CGFloat = 46
    static let savedRowHeight: CGFloat = 54
    static let badgeHeight: CGFloat = 22
    static let secondaryButtonSize: CGFloat = 32
    static let secondaryButtonCornerRadius: CGFloat = 10
    static let secondaryButtonIconPointSize: CGFloat = 11
    static let symbolWellSize: CGFloat = 26
    static let statusDotSize: CGFloat = 6
    static let compactStyleLines = 4
}
