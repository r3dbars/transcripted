// MenuTokens.swift
// Design tokens for the menubar popover.

import AppKit
import SwiftUI

enum MenuTokens {
    enum Fonts {
        static let headerTitle = NSFont.systemFont(ofSize: 15.5, weight: .semibold)
        static let headerStatus = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        static let headerDetail = NSFont.systemFont(ofSize: 10)
        static let modelStatus = NSFont.systemFont(ofSize: 11, weight: .medium)
        static let caption = NSFont.systemFont(ofSize: 10)
        static let primaryShortcutTitle = NSFont.systemFont(ofSize: 12, weight: .semibold)
        static let primaryShortcutSubtitle = NSFont.systemFont(ofSize: 10)
        static let shortcutBadge = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        static let primaryRowTitle = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        static let utilityRowTitle = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        static let rowDetail = NSFont.systemFont(ofSize: 10)
        static let primaryRowTrailing = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        static let utilityRowTrailing = NSFont.systemFont(ofSize: 10, weight: .medium)
        static let secondaryButtonLabel = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
    }

    // Surface
    static let surfaceBackgroundNS = NSColor.windowBackgroundColor.withAlphaComponent(0.98)
    static let surfaceStrokeNS = NSColor.separatorColor
    static let sectionDividerNS = NSColor.separatorColor

    // Text + status
    static let statusGreenNS = NSColor.systemGreen
    static let statusOrangeNS = NSColor.systemOrange
    static let textPrimaryNS = NSColor.labelColor
    static let textSecondaryNS = NSColor.secondaryLabelColor
    static let textMutedNS = NSColor.tertiaryLabelColor
    static let selectedTextPrimaryNS = NSColor.alternateSelectedControlTextColor
    static let selectedTextSecondaryNS = NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.78)
    static let selectedTextMutedNS = NSColor.alternateSelectedControlTextColor.withAlphaComponent(0.82)

    // Rows
    static let actionBackgroundNS = NSColor.controlBackgroundColor.withAlphaComponent(0.82)
    static let actionPressedNS = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.16)
    static let actionDisabledNS = NSColor.controlBackgroundColor.withAlphaComponent(0.42)
    static let actionBorderNS = NSColor.separatorColor
    static let flatRowHoverNS = NSColor.selectedContentBackgroundColor
    static let flatRowPressedNS = NSColor.controlAccentColor
    static let flatRowDisabledNS = NSColor.controlBackgroundColor.withAlphaComponent(0.42)
    static let badgeBackgroundNS = NSColor.labelColor.withAlphaComponent(0.08)
    static let badgeBorderNS = NSColor.separatorColor
    static let symbolBackgroundNS = NSColor.labelColor.withAlphaComponent(0.06)
    static let symbolBorderNS = NSColor.separatorColor
    static let secondaryButtonBackgroundNS = NSColor.controlBackgroundColor.withAlphaComponent(0.72)
    static let secondaryButtonHoverNS = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.12)
    static let secondaryButtonPressedNS = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.20)
    static let secondaryButtonBorderNS = NSColor.separatorColor
    static let accentButtonBackgroundNS = NSColor.controlAccentColor.withAlphaComponent(0.16)
    static let accentButtonHoverNS = NSColor.controlAccentColor.withAlphaComponent(0.22)
    static let accentButtonPressedNS = NSColor.controlAccentColor.withAlphaComponent(0.28)
    static let accentButtonBorderNS = NSColor.controlAccentColor.withAlphaComponent(0.34)
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

    // Timings
    static let copyFeedbackDurationNanoseconds: UInt64 = 1_500_000_000
    static let compactCopyFeedbackDurationNanoseconds: UInt64 = 1_200_000_000

    // Layout
    static let panelWidth: CGFloat = 304
    static let panelHeight: CGFloat = 320
    static let onboardingWindowWidth: CGFloat = 720
    static let onboardingWindowHeight: CGFloat = 740
    static let innerPadding: CGFloat = UISpacing.compact
    static let sectionSpacing: CGFloat = UISpacing.tight
    static let surfaceCornerRadius: CGFloat = UIRadius.xlarge
    static let cardCornerRadius: CGFloat = UIRadius.small
    static let primaryActionCornerRadius: CGFloat = UIRadius.large
    static let compactActionRowHeight: CGFloat = 30
    static let actionRowHeight: CGFloat = 46
    static let actionRowGap: CGFloat = UISpacing.micro
    static let secondaryActionGap: CGFloat = UISpacing.sm
    static let savedRowHeight: CGFloat = 54
    static let badgeHeight: CGFloat = 22
    static let primaryActionPadding: CGFloat = UISpacing.relaxed
    static let primaryActionTextGap: CGFloat = UISpacing.compact
    static let primaryActionVerticalInset: CGFloat = UISpacing.sm
    static let secondaryButtonSize: CGFloat = 28
    static let secondaryButtonCornerRadius: CGFloat = UIRadius.small
    static let secondaryButtonIconPointSize: CGFloat = 11
    static let symbolWellSize: CGFloat = 26
    static let modelStatusPadding: CGFloat = UISpacing.sm
    static let footerLabelGap: CGFloat = UISpacing.compact
    static let statusDotSize: CGFloat = 6
    static let compactStyleLines = 4
}
