// OverlayTokens.swift
// Design tokens for the floating overlay UI — pure AppKit, no SwiftUI

import AppKit

enum OverlayTokens {
    // Colors (semi-transparent for glassmorphism blur)
    static let panelBg       = NSColor.black.withAlphaComponent(0.82)
    static let panelStroke   = NSColor.white.withAlphaComponent(0.10)
    static let accentGreen   = NSColor(red: 0.07, green: 0.94, blue: 0.58, alpha: 1.0) // #13EF95 mint green
    static let textPrimary   = NSColor.white
    static let textSecondary = NSColor(white: 0.74, alpha: 1.0)
    static let textMuted     = NSColor(white: 0.58, alpha: 1.0)

    // Diff colors
    static let diffDeleteText    = NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 1.0)
    static let diffDeleteBg      = NSColor(red: 1.0, green: 0.3, blue: 0.3, alpha: 0.15)
    static let diffDeleteBorder  = NSColor(red: 1.0, green: 0.4, blue: 0.4, alpha: 0.5)
    static let diffInsertText    = NSColor(red: 0.3, green: 0.9, blue: 0.5, alpha: 1.0)
    static let diffInsertBg      = NSColor(red: 0.3, green: 0.9, blue: 0.5, alpha: 0.15)
    static let diffReplaceText   = NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 1.0)
    static let diffReplaceBorder = NSColor(red: 0.4, green: 0.7, blue: 1.0, alpha: 0.5)

    // Layout
    static let recordingPillWidth: CGFloat  = 260
    static let recordingPillHeight: CGFloat = 48
    static let panelWidth: CGFloat         = 360
    static let panelCompactWidth: CGFloat  = recordingPillWidth
    static let panelCompactHeight: CGFloat = recordingPillHeight   // header bar only, no content area
    static let panelLoadingHeight: CGFloat = 100
    static let panelMinHeight: CGFloat     = 92
    static let panelActionErrorHeight: CGFloat = 122
    static let panelMaxHeight: CGFloat     = 340
    static let cornerRadius: CGFloat   = 12
    static let contentPadding: CGFloat = 12

    // Header
    static let headerHeight: CGFloat = 32
    static let toolbarHeight: CGFloat = 28
    static let dividerHeight: CGFloat = 1
}
