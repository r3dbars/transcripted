// OverlayTokens.swift
// Design tokens for the floating overlay UI — pure AppKit, no SwiftUI

import AppKit

enum OverlayTokens {
    enum Palette {
        static let green = NSColor(red: 0.07, green: 0.94, blue: 0.58, alpha: 1.0) // #13EF95 mint green
        static let red = NSColor(calibratedRed: 1.00, green: 0.27, blue: 0.23, alpha: 1.0)
        static let blue = NSColor(calibratedRed: 0.4, green: 0.7, blue: 1.0, alpha: 1.0)
    }

    // Colors (semi-transparent for glassmorphism blur)
    static let panelBg       = NSColor.black.withAlphaComponent(0.82)
    static let panelStroke   = NSColor.white.withAlphaComponent(0.10)
    static let accentGreen   = Palette.green
    static let accentForeground = NSColor.black // Must remain readable on accentGreen.
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
    static let cornerRadius: CGFloat   = UIRadius.large
    static let controlCornerRadius: CGFloat = UIRadius.small
    static let contentPadding: CGFloat = 12

    // Header
    static let headerHeight: CGFloat = 32
    static let toolbarHeight: CGFloat = 28
    static let dividerHeight: CGFloat = 1

    // Waveform
    static let waveformBarWidth: CGFloat = 2
    static let waveformBarSpacing: CGFloat = 1
    static let waveformMirroredBarSpacing: CGFloat = 1.5
    static let waveformMinBarHeight: CGFloat = 2
    static let waveformMaxBarHeight: CGFloat = 14
    static let waveformBarCornerRadius: CGFloat = 1
    static let waveformSampleInterval: TimeInterval = 0.05
    static let waveformMirroredBarCount = 26
}
