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
    /// On a display without a notch the island swells out of a small nub
    /// at the top edge.
    static let edgeNubWidth: CGFloat = 72
    /// The window the island springs inside while it is up. It is sized once
    /// when the island appears (and only grows if an island needs more), so
    /// the window never resizes under a moving shape.
    static let envelopeMinimumSize = CGSize(width: 720, height: 380)
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
            x: halfPoint(screen.frame.midX - edgeNubWidth / 2),
            y: screen.frame.maxY - 2,
            width: edgeNubWidth,
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

// MARK: - Shape and motion

extension NotchIslandGeometry {
    /// Corner radius of the shape the island grows from and shrinks into.
    static func collapsedRadius(screen: NotchIslandScreenInfo) -> CGFloat {
        screen.hasNotch ? 10 : 2
    }

    /// Top-centered window that holds every rect given plus `margin` of
    /// room for a spring's overshoot, at least `envelopeMinimumSize`, and
    /// never wider than the screen.
    static func envelope(screen: NotchIslandScreenInfo, containing rects: [CGRect], margin: CGFloat) -> CGRect {
        let midX = screen.frame.midX
        var half = envelopeMinimumSize.width / 2
        var height = envelopeMinimumSize.height
        for rect in rects {
            half = max(half, max(midX - rect.minX, rect.maxX - midX) + margin)
            height = max(height, screen.frame.maxY - rect.minY + margin)
        }
        half = min(half.rounded(.up), screen.frame.width / 2)
        height = min(height.rounded(.up), screen.frame.height)
        return CGRect(x: midX - half, y: screen.frame.maxY - height, width: 2 * half, height: height)
    }
}

/// How the island moves: springs on the system's render server, so a busy
/// main thread (the mic starting up) can't make it stutter.
enum NotchIslandMotion {
    struct Spring: Equatable {
        var stiffness: CGFloat
        var damping: CGFloat

        /// SwiftUI-style response (seconds per oscillation) and damping
        /// ratio (1 = no overshoot) as Core Animation spring constants.
        static func response(_ response: CGFloat, dampingRatio: CGFloat) -> Spring {
            let omega = 2 * CGFloat.pi / response
            return Spring(stiffness: omega * omega, damping: 2 * dampingRatio * omega)
        }

        var dampingRatio: CGFloat { damping / (2 * stiffness.squareRoot()) }

        /// Progress from 0 to 1 (past 1 while it overshoots) after `time`
        /// seconds, starting at rest. Mirrors CASpringAnimation with mass 1.
        func progress(at time: CGFloat) -> CGFloat {
            guard time > 0 else { return 0 }
            let omega = stiffness.squareRoot()
            let zeta = dampingRatio
            if zeta < 1 {
                let omegaD = omega * (1 - zeta * zeta).squareRoot()
                let decay = exp(-zeta * omega * time)
                return 1 - decay * (cos(omegaD * time) + zeta * omega / omegaD * sin(omegaD * time))
            }
            return 1 - exp(-omega * time) * (1 + omega * time)
        }
    }

    /// Growing out of the notch and between states: quick, with a small
    /// Dynamic Island overshoot.
    static let grow = Spring.response(0.34, dampingRatio: 0.74)
    /// Swelling out of the top edge of a display without a notch: a touch
    /// softer, so it pours out instead of snapping.
    static let growFromEdge = Spring.response(0.42, dampingRatio: 0.8)
    /// Pulling back into the notch: quick and without a bounce.
    static let shrink = Spring.response(0.26, dampingRatio: 1)
    static let contentFadeIn: Double = 0.12
    static let contentFadeOut: Double = 0.08
    /// Content blurs in while the shape uncovers it (about the first fifth
    /// of a second), then is fully sharp.
    static let blurRadius: CGFloat = 6
    static let blurInDuration: Double = 0.2
    /// Room around the island while it springs, so an overshoot isn't
    /// cut off by the window's edge.
    static let springMargin: CGFloat = 14
}
