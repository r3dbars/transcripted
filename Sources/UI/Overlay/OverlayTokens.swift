// OverlayTokens.swift
// Design tokens for the floating overlay UI — pure AppKit, no SwiftUI

import AppKit

enum OverlayTokens {
    // Adaptive colors for a lighter, more native floating control.
    static let compactGlassTint  = NSColor.windowBackgroundColor.withAlphaComponent(0.18)
    static let expandedGlassTint = NSColor.windowBackgroundColor.withAlphaComponent(0.24)
    static let panelStroke       = NSColor.separatorColor.withAlphaComponent(0.38)
    static let contentCardTint   = NSColor.controlBackgroundColor.withAlphaComponent(0.46)
    static let contentCardStroke = NSColor.separatorColor.withAlphaComponent(0.24)
    static let accentColor       = NSColor.controlAccentColor
    static let accentGreen       = accentColor
    static let successColor      = NSColor.systemGreen
    static let warningColor      = NSColor.systemOrange
    static let textPrimary       = NSColor.labelColor
    static let textSecondary     = NSColor.secondaryLabelColor
    static let textMuted         = NSColor.tertiaryLabelColor

    // Diff colors
    static let diffDeleteText    = NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0)
    static let diffDeleteBg      = NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 0.15)
    static let diffDeleteBorder  = NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 0.5)
    static let diffInsertText    = NSColor(red: 0.3, green: 0.9, blue: 0.5, alpha: 1.0)
    static let diffInsertBg      = NSColor(red: 0.3, green: 0.9, blue: 0.5, alpha: 0.15)
    static let diffReplaceText   = NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1.0)
    static let diffReplaceBorder = NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 0.5)

    // Layout
    static let panelWidth: CGFloat         = 360
    static let panelCompactWidth: CGFloat  = 304
    static let panelCompactHeight: CGFloat = 48
    static let panelLoadingHeight: CGFloat = 138
    static let panelMinHeight: CGFloat     = 140
    static let panelActionErrorHeight: CGFloat = 156
    static let panelMaxHeight: CGFloat     = 340
    static let compactCornerRadius: CGFloat = 18
    static let expandedCornerRadius: CGFloat = 20
    static let cornerRadius: CGFloat = expandedCornerRadius
    static let contentCardCornerRadius: CGFloat = 16
    static let panelChromeInset: CGFloat = 10
    static let contentPadding: CGFloat = 14
    static let contentGap: CGFloat = 8

    // Header
    static let headerHeight: CGFloat = 36
    static let toolbarHeight: CGFloat = 28
    static let dividerHeight: CGFloat = 1
}
