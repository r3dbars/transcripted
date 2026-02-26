// OverlayTokens.swift
// Design tokens for the floating overlay UI

import SwiftUI

enum OverlayTokens {
    // Colors (semi-transparent for glassmorphism blur)
    static let panelBg       = Color.black.opacity(0.58)                   // translucent for blur
    static let accentGreen   = Color(red: 0.07, green: 0.94, blue: 0.58)  // #13EF95  mint green
    static let textPrimary   = Color.white
    static let textSecondary = Color(white: 0.55)                          // gray labels
    static let textMuted     = Color(white: 0.35)                          // placeholder

    // Layout
    static let panelWidth: CGFloat     = 480
    static let panelMinHeight: CGFloat = 160
    static let panelMaxHeight: CGFloat = 340
    static let cornerRadius: CGFloat   = 16
    static let contentPadding: CGFloat = 16
}
