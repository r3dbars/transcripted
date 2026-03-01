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
    static let panelWidth: CGFloat         = 480
    static let panelCompactHeight: CGFloat = 52   // header bar only, no content area
    static let panelMinHeight: CGFloat     = 160
    static let panelMaxHeight: CGFloat     = 340
    static let cornerRadius: CGFloat   = 16
    static let contentPadding: CGFloat = 16
}

// Design tokens for the menubar panel (SuperWhisper-inspired minimal aesthetic)
enum MenuTokens {
    // Colors — system-adaptive, no hardcoded purple
    static let statusGreen       = Color.green
    static let statusOrange      = Color.orange
    static let textSecondary     = Color.secondary
    static let textMuted         = Color(.tertiaryLabelColor)
    static let cardBackground    = Color(.controlBackgroundColor)
    static let cardBorder        = Color.gray.opacity(0.15)
    static let userBubbleBg      = Color.primary.opacity(0.06)
    static let assistantBubbleBg = Color(.controlBackgroundColor)
    static let pillBackground    = Color(.controlBackgroundColor)
    static let pillBorder        = Color.gray.opacity(0.15)
    static let sendButton        = Color.primary.opacity(0.7)

    // Layout
    static let panelWidth: CGFloat       = 440
    static let panelHeight: CGFloat      = 520
    static let sectionSpacing: CGFloat   = 20
    static let innerPadding: CGFloat     = 20
    static let cardCornerRadius: CGFloat = 8
    static let cardPadding: CGFloat      = 12
    static let bubbleCornerRadius: CGFloat = 10
    static let pillCornerRadius: CGFloat = 6
    static let statusDotSize: CGFloat    = 7
    static let compactStyleLines         = 4
}
