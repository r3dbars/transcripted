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
    static let flatRowHoverNS = NSColor.white.withAlphaComponent(0.075)
    static let flatRowPressedNS = NSColor.white.withAlphaComponent(0.12)
    static let flatRowDisabledNS = NSColor.white.withAlphaComponent(0.02)
    static let buttonBackgroundNS = NSColor.white.withAlphaComponent(0.08)

    // SwiftUI wrappers still used by onboarding
    static let statusGreen = Color.green
    static let statusOrange = Color.orange
    static let textPrimary = Color(MenuTokens.textPrimaryNS)
    static let textSecondary = Color(MenuTokens.textSecondaryNS)
    static let textMuted = Color(MenuTokens.textMutedNS)

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
    static let statusDotSize: CGFloat = 6
}
