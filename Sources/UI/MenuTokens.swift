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
    static let cardBorderNS        = NSColor.gray.withAlphaComponent(0.15)
    static let pillBackgroundNS    = NSColor.controlBackgroundColor
    static let pillBorderNS        = NSColor.gray.withAlphaComponent(0.15)

    // SwiftUI Color wrappers — used by onboarding SwiftUI views (Phase 3 removes these)
    static let statusGreen       = Color.green
    static let statusOrange      = Color.orange
    static let textSecondary     = Color.secondary
    static let textMuted         = Color(.tertiaryLabelColor)
    static let cardBackground    = Color(.controlBackgroundColor)
    static let cardBorder        = Color.gray.opacity(0.15)
    static let pillBackground    = Color(.controlBackgroundColor)
    static let pillBorder        = Color.gray.opacity(0.15)

    // Layout
    static let panelWidth: CGFloat       = 440
    static let panelHeight: CGFloat      = 520
    static let sectionSpacing: CGFloat   = 20
    static let innerPadding: CGFloat     = 20
    static let cardCornerRadius: CGFloat = 8
    static let cardPadding: CGFloat      = 12
    static let pillCornerRadius: CGFloat = 6
    static let statusDotSize: CGFloat    = 7
    static let compactStyleLines         = 4
}
