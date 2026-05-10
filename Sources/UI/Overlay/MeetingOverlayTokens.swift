// MeetingOverlayTokens.swift
// Design tokens for the meeting overlay. Keep these separate from the
// dictation overlay tokens because the meeting overlay is denser and darker.

import AppKit

@available(macOS 14.0, *)
enum MeetingOverlayTokens {
    // Slightly darker than OverlayTokens.panelBg so meeting capture remains
    // readable over video-call windows.
    static let panelBg       = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 0.92)
    static let panelStroke   = NSColor.white.withAlphaComponent(0.08)
    static let textPrimary   = NSColor(calibratedWhite: 0.98, alpha: 1.0)
    static let textSecondary = NSColor.white.withAlphaComponent(0.55)
    static let waveformMicTint = NSColor(calibratedRed: 0.84, green: 0.69, blue: 0.48, alpha: 1.0)
    static let waveformSystemTint = NSColor(calibratedRed: 0.57, green: 0.66, blue: 0.85, alpha: 1.0)
    static let dotIdle       = OverlayTokens.textMuted
    static let dotPrep       = OverlayTokens.textSecondary
    static let dotPrompt     = OverlayTokens.accentGreen
    static let dotRecording  = NSColor(calibratedRed: 1.00, green: 0.27, blue: 0.23, alpha: 1.0)
    static let dotSaved      = NSColor.systemGreen
    static let dotError      = NSColor.systemRed
    static let quietActionBg = NSColor.white.withAlphaComponent(0.08)
    static let quietActionBorder = NSColor.white.withAlphaComponent(0.14)
    static let quietActionTint = NSColor.white.withAlphaComponent(0.70)
    static let finishActionColor = NSColor.white.withAlphaComponent(0.16)
    static let finishActionBorder = NSColor.white.withAlphaComponent(0.24)
    static let finishActionForeground = NSColor.white.withAlphaComponent(0.92)

    static let panelWidth: CGFloat  = 360
    static let recordingPanelWidth: CGFloat = 292
    static let minimizedRecordingPanelWidth: CGFloat = 152
    static let panelHeight: CGFloat = 44
    static let minimizedRecordingPanelHeight: CGFloat = 36
    static let promptHeight: CGFloat = 88
    static let warmupHeight: CGFloat = 96
    static let errorHeight: CGFloat = 88
    static let cornerRadius: CGFloat = 22
    static let minimizedCornerRadius: CGFloat = 18
    static let dotSize: CGFloat     = 8
    static let padLeft: CGFloat     = 12
    static let padRight: CGFloat    = 8
    static let headerGap: CGFloat   = 8
    static let standardPad: CGFloat = 12
    static let standardCloseHeight: CGFloat = 22
    static let standardChevronSize: CGFloat = 16
    static let standardLevelBarHeight: CGFloat = 10
    static let standardLevelBarGap: CGFloat = 2
    static let minimizedPadLeft: CGFloat = 10
    static let minimizedGap: CGFloat = 7
    static let timerFontSize: CGFloat = 13
    static let cancelHeight: CGFloat = 24
    static let toggleHeight: CGFloat = 22
    static let stopHeight: CGFloat  = 28
    static let recordingWaveformWidth: CGFloat = 124
    static let recordingWaveformHeight: CGFloat = 22
    static let promptPad: CGFloat = 12
    static let promptButtonHeight: CGFloat = 24
    static let promptButtonGap: CGFloat = 8
    static let warmupPad: CGFloat = 16
    static let tooltipOffset: CGFloat = 8
    static let tooltipScreenInset: CGFloat = 6
    static let tooltipDelayNanoseconds: UInt64 = 80_000_000
}
