// VoicePrintGeometry.swift
// Where everything in a voice print sits and which color it takes, in the
// 42-point design box of the approved mockup (Prints.dc.html): the five ring
// arcs with their gaps, the center well with its play or pause glyph, the
// colors for a number of lit rings on a dark or light surface, the glow, and
// the VoiceOver label. Angles are degrees clockwise on screen from 3 o'clock
// and y points down, as in the mockup's SVG.
//
// Foundation-only so the fast tests can check it. VoicePrintView (UI/Overlay)
// draws from it; the shape and color per person come from VoicePrintStyle.

import Foundation

/// The kind of surface a print sits on: the island and dark Settings are
/// `.dark`, light Settings is `.light`.
enum VoicePrintTone: Equatable {
    case dark
    case light
}

/// A plain sRGB color with alpha, each 0...1.
struct VoicePrintRGBA: Equatable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// From 0xRRGGBB, as the palette stores it.
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    static func white(_ alpha: Double) -> VoicePrintRGBA { VoicePrintRGBA(red: 1, green: 1, blue: 1, alpha: alpha) }
    static func black(_ alpha: Double) -> VoicePrintRGBA { VoicePrintRGBA(red: 0, green: 0, blue: 0, alpha: alpha) }
}

enum VoicePrintGeometry {
    struct Point: Equatable {
        let x: Double
        let y: Double
    }

    struct Rect: Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    /// One ring: an arc drawn clockwise on screen from `startAngle` to
    /// `endAngle`, so the part left open is centered on the person's gap angle.
    struct Arc: Equatable {
        let radius: Double
        /// Where the stroke starts, 0..<360: just after the gap.
        let startAngle: Double
        /// `startAngle` plus the arc's sweep; may run past 360.
        let endAngle: Double

        /// The middle of the open part, 0..<360.
        var gapCenter: Double { VoicePrintGeometry.normalized(startAngle - VoicePrintGeometry.gapHalfAngle) }
    }

    static let designSize = VoicePrintStyle.designSize
    static let center = Point(x: VoicePrintStyle.designSize / 2, y: VoicePrintStyle.designSize / 2)
    static let ringCount = VoicePrintStyle.ringRadii.count
    /// Ring stroke, design points, round caps.
    static let strokeWidth = 1.8
    /// The filled circle behind the play / pause glyph.
    static let wellRadius = 5.4
    /// Half of each ring's gap, in degrees (36 for a 20% gap).
    static let gapHalfAngle = VoicePrintStyle.gapFraction * 180
    /// How far each ring's stroke runs, in degrees (288 for a 20% gap).
    static let arcSweep = 360 * (1 - VoicePrintStyle.gapFraction)
    /// Play: a triangle pointing right, as in the mockup.
    static let playTriangle = [Point(x: 19.4, y: 18), Point(x: 24.4, y: 21), Point(x: 19.4, y: 24)]
    /// Pause, while the clip plays: two bars.
    static let pauseBars = [
        Rect(x: 18.3, y: 18.2, width: 1.8, height: 5.6),
        Rect(x: 21.9, y: 18.2, width: 1.8, height: 5.6),
    ]
    /// The print grows a little under the pointer and dips while pressed,
    /// easing over `hoverDuration` (CSS `ease`).
    static let hoverScale = 1.06
    static let pressedScale = 0.95
    static let hoverDuration = 0.15
    /// A complete print's glow: a drop shadow in the person's color with this
    /// CSS blur, in design points. Core Animation's shadowRadius is half of it.
    static let glowBlur = 7.0

    /// Points per design point for a print `diameter` points wide.
    static func scale(forDiameter diameter: Double) -> Double {
        diameter / designSize
    }

    /// The five arcs, innermost first, each with its gap centered on the
    /// style's gap angle for that ring.
    static func arcs(for style: VoicePrintStyle) -> [Arc] {
        zip(VoicePrintStyle.ringRadii, style.gapAngles).map { radius, gapAngle in
            let start = normalized(gapAngle + gapHalfAngle)
            return Arc(radius: radius, startAngle: start, endAngle: start + arcSweep)
        }
    }

    /// The point `radius` from the center at `angle` (clockwise on screen
    /// from 3 o'clock), in the y-down design box.
    static func point(angle: Double, radius: Double) -> Point {
        let radians = angle * .pi / 180
        return Point(x: center.x + radius * cos(radians), y: center.y + radius * sin(radians))
    }

    static func normalized(_ angle: Double) -> Double {
        let remainder = angle.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    /// `litRings` held to 0...5.
    static func clampedLitRings(_ litRings: Int) -> Int {
        min(max(litRings, 0), ringCount)
    }
}

/// The print's colors. Lit rings take the person's palette color (the light
/// variant on light surfaces); the rest stay a faint neutral.
enum VoicePrintInk {
    /// The person's color, by palette index (wrapped into the palette).
    static func personColor(colorIndex: Int, tone: VoicePrintTone) -> VoicePrintRGBA {
        let palette = VoicePrintStyle.palette
        let entry = palette[((colorIndex % palette.count) + palette.count) % palette.count]
        return VoicePrintRGBA(hex: tone == .dark ? entry.dark : entry.light)
    }

    /// A ring not earned yet.
    static func unlitRing(tone: VoicePrintTone) -> VoicePrintRGBA {
        tone == .dark ? .white(0.14) : .black(0.12)
    }

    /// Stroke color per ring, innermost first: the first `litRings` in the
    /// person's color.
    static func ringColors(colorIndex: Int, litRings: Int, tone: VoicePrintTone) -> [VoicePrintRGBA] {
        let lit = VoicePrintGeometry.clampedLitRings(litRings)
        let person = personColor(colorIndex: colorIndex, tone: tone)
        let unlit = unlitRing(tone: tone)
        return (0..<VoicePrintGeometry.ringCount).map { $0 < lit ? person : unlit }
    }

    /// The center well, a little brighter while the clip plays. On light
    /// surfaces it's dark, so the white glyph still reads (palette mockup).
    static func well(tone: VoicePrintTone, isPlaying: Bool) -> VoicePrintRGBA {
        switch tone {
        case .dark: return .white(isPlaying ? 0.22 : 0.10)
        case .light: return .black(isPlaying ? 0.62 : 0.45)
        }
    }

    static let glyph = VoicePrintRGBA.white(1)

    /// A complete print's glow strength (#RRGGBB88 in the mockup).
    static let completeGlowOpacity = Double(0x88) / 255

    /// Glow behind the print: only a complete print glows, and only on dark
    /// surfaces. Light Settings shows complete prints without it, as the
    /// palette mockup does.
    static func glowOpacity(litRings: Int, tone: VoicePrintTone) -> Double {
        guard tone == .dark, VoicePrintGeometry.clampedLitRings(litRings) == VoicePrintGeometry.ringCount else { return 0 }
        return completeGlowOpacity
    }

    /// Cascade squares on rings not earned yet: white on dark, black on light
    /// (each square carries its own opacity).
    static func unlitSquare(tone: VoicePrintTone) -> VoicePrintRGBA {
        tone == .dark ? .white(1) : .black(1)
    }

    /// The color a twinkling square flashes to.
    static let twinkle = VoicePrintRGBA.white(1)
}

enum VoicePrintCopy {
    /// VoiceOver label for the print, which is a button: "Play Priya's clip",
    /// or "Pause" while it plays.
    static func accessibilityLabel(name: String?, isPlaying: Bool) -> String {
        if isPlaying { return "Pause" }
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return "Play this voice"
        }
        return "Play \(name)'s clip"
    }
}
