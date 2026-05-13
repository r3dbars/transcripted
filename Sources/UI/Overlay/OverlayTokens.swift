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

    // Layout
    static let panelWidth: CGFloat         = 360
    static let panelCompactWidth: CGFloat  = 276
    static let panelCompactHeight: CGFloat = 42   // header bar only, no content area
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
    static let preferredWaveformWidth: CGFloat = 124

    // Status + surfaces
    static let warningColor = NSColor.systemOrange
    static let dividerColor = NSColor.white.withAlphaComponent(0.06)
}
