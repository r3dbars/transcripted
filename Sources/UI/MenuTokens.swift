// MenuTokens.swift
// Design tokens for the menubar panel — NSColor primary, SwiftUI Color wrappers for onboarding

import AppKit
import SwiftUI

enum MenuTokens {
    // NSColor primaries — used by AppKit views
    static let statusGreenNS       = NSColor.systemGreen
    static let statusOrangeNS      = NSColor.systemOrange
    static let textPrimaryNS       = NSColor.labelColor
    static let textSecondaryNS     = NSColor.secondaryLabelColor
    static let textMutedNS         = NSColor.tertiaryLabelColor
    static let cardBackgroundNS    = NSColor.controlBackgroundColor
    static let cardBorderNS        = NSColor.gray.withAlphaComponent(0.12)
    static let pillBackgroundNS    = NSColor.controlBackgroundColor
    static let pillBorderNS        = NSColor.gray.withAlphaComponent(0.12)
    static let buttonBackgroundNS  = NSColor.controlBackgroundColor
    static let buttonBorderNS      = NSColor.gray.withAlphaComponent(0.10)

    // SwiftUI Color wrappers — used by onboarding SwiftUI views (Phase 3 removes these)
    static let statusGreen       = Color.green
    static let statusOrange      = Color.orange
    static let textSecondary     = Color.secondary
    static let textMuted         = Color(.tertiaryLabelColor)
    static let cardBackground    = Color(.controlBackgroundColor)
    static let cardBorder        = Color.gray.opacity(0.12)
    static let pillBackground    = Color(.controlBackgroundColor)
    static let pillBorder        = Color.gray.opacity(0.12)

    // Layout
    static let panelWidth: CGFloat       = 360
    static let panelHeight: CGFloat      = 304
    static let sectionSpacing: CGFloat   = 12
    static let innerPadding: CGFloat     = 12
    static let cardCornerRadius: CGFloat = 12
    static let cardPadding: CGFloat      = 12
    static let pillCornerRadius: CGFloat = 8
    static let statusDotSize: CGFloat    = 6
    static let compactStyleLines         = 4
}
