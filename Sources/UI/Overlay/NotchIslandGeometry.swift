// NotchIslandGeometry.swift
// Where the notch island sits and how big it is. Every width comes from what
// the wings hold, so nothing is ever clipped:
// - On a MacBook with a notch the island is centered on the notch and both
//   wings are as wide as the wider one, so the camera stays in the middle.
// - On a display without a notch there is no fake notch: the island hangs
//   from the top edge only while something is happening, as small as its
//   content allows.
// A drop-down makes the island at least `dropWidth` wide. Pure geometry
// (no AppKit) so the fast tests can check both display kinds.

import CoreGraphics

struct NotchIslandScreenInfo: Equatable {
    /// The screen's frame in global (Cocoa) coordinates.
    var frame: CGRect
    /// Width of the camera housing, or nil on a display without a notch.
    var notchWidth: CGFloat?
    /// Height of the wing row: the notch height, or a tab height elsewhere.
    var rowHeight: CGFloat

    var hasNotch: Bool { notchWidth != nil }
}

enum NotchIslandGeometry {
    /// Outer 14 plus inner 10 points around each wing's content.
    static let wingPadding: CGFloat = 24
    /// A notch wing never shrinks below this, so a lone dot still reads.
    static let minimumWing: CGFloat = 44
    static let minimumTabWidth: CGFloat = 96
    static let tabRowHeight: CGFloat = 32
    static let dropWidth: CGFloat = 460
    static let dropTopGap: CGFloat = 2
    static let screenMargin: CGFloat = 8
    static let restingCornerRadius: CGFloat = 16
    static let dropCornerRadius: CGFloat = 26

    /// Rounds up to a 4-point step so a timer ticking from 9:59 to 10:00
    /// does not nudge the island.
    static func snap(_ value: CGFloat) -> CGFloat {
        (value / 4).rounded(.up) * 4
    }

    /// The wing width (content plus padding) for one side, or 0 when empty.
    static func wingWidth(content: CGFloat) -> CGFloat {
        content > 0 ? content + wingPadding : 0
    }

    static func islandSize(
        screen: NotchIslandScreenInfo,
        leftContent: CGFloat,
        rightContent: CGFloat,
        dropHeight: CGFloat?
    ) -> CGSize {
        let left = wingWidth(content: leftContent)
        let right = wingWidth(content: rightContent)
        var width: CGFloat
        if let notchWidth = screen.notchWidth {
            let wing = snap(max(left, right, minimumWing))
            width = notchWidth + 2 * wing
        } else {
            width = max(minimumTabWidth, snap(left + right))
        }
        var height = screen.rowHeight
        if let dropHeight {
            width = max(width, dropWidth)
            height += dropTopGap + dropHeight
        }
        width = min(width, screen.frame.width - 2 * screenMargin)
        return CGSize(width: width, height: height)
    }

    /// Top-attached and horizontally centered on the screen (the notch is
    /// always centered).
    static func frame(screen: NotchIslandScreenInfo, size: CGSize) -> CGRect {
        CGRect(
            x: halfPoint(screen.frame.midX - size.width / 2),
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
        )
    }

    /// Where the island grows from and shrinks back to: the notch itself, or a
    /// sliver at the top edge of a display without one.
    static func collapsedFrame(screen: NotchIslandScreenInfo) -> CGRect {
        if let notchWidth = screen.notchWidth {
            return CGRect(
                x: halfPoint(screen.frame.midX - notchWidth / 2),
                y: screen.frame.maxY - screen.rowHeight,
                width: notchWidth,
                height: screen.rowHeight
            )
        }
        return CGRect(
            x: halfPoint(screen.frame.midX - minimumTabWidth / 2),
            y: screen.frame.maxY - 2,
            width: minimumTabWidth,
            height: 2
        )
    }

    /// Notches are an odd number of points wide, so whole-point rounding
    /// would leave the camera half a point off center; a half point is a
    /// whole pixel on the Retina panels that have one.
    static func halfPoint(_ value: CGFloat) -> CGFloat {
        (value * 2).rounded() / 2
    }

    static func cornerRadius(hasDrop: Bool, rowHeight: CGFloat) -> CGFloat {
        hasDrop ? dropCornerRadius : min(restingCornerRadius, rowHeight / 2)
    }

    /// The notch from the screen's safe-area insets and the two unobscured
    /// top areas either side of the camera. Takes plain numbers so tests can
    /// describe any Mac.
    static func screenInfo(
        frame: CGRect,
        safeAreaTop: CGFloat,
        leftAuxiliaryWidth: CGFloat?,
        rightAuxiliaryWidth: CGFloat?
    ) -> NotchIslandScreenInfo {
        if safeAreaTop > 0,
           let leftAuxiliaryWidth,
           let rightAuxiliaryWidth {
            let notchWidth = frame.width - leftAuxiliaryWidth - rightAuxiliaryWidth
            if notchWidth >= 40 {
                return NotchIslandScreenInfo(
                    frame: frame,
                    notchWidth: notchWidth,
                    rowHeight: max(safeAreaTop, 24)
                )
            }
        }
        return NotchIslandScreenInfo(frame: frame, notchWidth: nil, rowHeight: tabRowHeight)
    }
}
