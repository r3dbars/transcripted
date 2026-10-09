// VoicePrintStyle.swift
// What makes each saved person's voice print theirs: a palette color and the
// angle of the gap in each of the print's five concentric rings, like the gates
// of a combination lock. Every print shares the same radii, thickness and gap
// size; only the gap angles and the color differ. Both come from the person's
// saved ID, so the same person looks the same in the island review and in
// Settings › Speakers, on every launch.
//
// Ported exactly from the approved mockup generator (cyrb-style string hash plus
// mulberry32), so the app draws the print the design showed. Foundation-only so
// the fast tests can compile it.

import Foundation

struct VoicePrintStyle: Equatable {
    struct PaletteColor: Equatable {
        let name: String
        /// 0xRRGGBB on dark surfaces (the island, dark Settings).
        let dark: UInt32
        /// 0xRRGGBB on light surfaces, darker so a thin stroke still reads on white.
        let light: UInt32
    }

    /// Eight soft hues at about the same brightness, so nobody looks more
    /// important. No pure red or green: those read as error and success.
    static let palette: [PaletteColor] = [
        PaletteColor(name: "Lavender", dark: 0xB9A3FF, light: 0x7A5CF0),
        PaletteColor(name: "Periwinkle", dark: 0x8FA8FF, light: 0x4C66E6),
        PaletteColor(name: "Sky", dark: 0x6EC7FF, light: 0x0E8AD0),
        PaletteColor(name: "Lagoon", dark: 0x4FD8D0, light: 0x0E9E95),
        PaletteColor(name: "Butter", dark: 0xF5D46E, light: 0xB58A00),
        PaletteColor(name: "Apricot", dark: 0xFFB26E, light: 0xD2700F),
        PaletteColor(name: "Coral", dark: 0xFF8C82, light: 0xD9483C),
        PaletteColor(name: "Rose", dark: 0xFF86C2, light: 0xD23F8A),
    ]

    /// Ring radii in a 42-point design box, innermost first. One ring per
    /// confirmed meeting, up to `SpeakerNamingTierPresentation.segmentCount`.
    static let ringRadii: [Double] = [8, 10.9, 13.8, 16.7, 19.6]
    /// Share of each ring left open.
    static let gapFraction: Double = 0.2
    static let designSize: Double = 42

    /// Preferred palette index from the ID (before per-call de-duplication).
    let preferredColorIndex: Int
    /// Center of each ring's gap in degrees, measured clockwise on screen from
    /// 3 o'clock (the +x axis, y pointing down, as in the mockup's SVG),
    /// innermost first. Multiples of 15; neighbouring rings at least 45 apart.
    let gapAngles: [Double]

    init(id: UUID) {
        self.init(seedString: id.uuidString.lowercased())
    }

    init(seedString: String) {
        let next = Self.random(seed: Self.seed(of: seedString))
        preferredColorIndex = min(Self.palette.count - 1, Int(next() * Double(Self.palette.count)))
        var angles: [Double] = []
        var previous: Double?
        for _ in Self.ringRadii {
            var angle = (next() * 23).rounded() * 15
            while let previous, Self.angularDistance(angle, previous) < 45 {
                angle = (angle + 60).truncatingRemainder(dividingBy: 360)
            }
            angles.append(angle)
            previous = angle
        }
        gapAngles = angles
    }

    /// Colors for everyone on one call: each keeps their preferred color unless
    /// someone earlier in `ids` already has it, then takes the next free one.
    /// With more people than colors, colors repeat in the same order.
    static func colorIndices(for ids: [UUID]) -> [UUID: Int] {
        var used: Set<Int> = []
        var result: [UUID: Int] = [:]
        for id in ids where result[id] == nil {
            var index = VoicePrintStyle(id: id).preferredColorIndex
            if used.count < palette.count {
                while used.contains(index) { index = (index + 1) % palette.count }
            }
            used.insert(index)
            result[id] = index
        }
        return result
    }

    static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(d, 360 - d)
    }

    // MARK: - Same hash and PRNG as the mockup (JavaScript Math.imul semantics)

    static func seed(of string: String) -> UInt32 {
        let units = Array(string.utf16)
        var h: UInt32 = 1_779_033_703 ^ UInt32(truncatingIfNeeded: units.count)
        for unit in units {
            h = (h ^ UInt32(unit)) &* 3_432_918_353
            h = (h << 13) | (h >> 19)
        }
        return h
    }

    static func random(seed: UInt32) -> () -> Double {
        var a = seed
        return {
            a = a &+ 0x6D2B_79F5
            var t = (a ^ (a >> 15)) &* (1 | a)
            t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
            return Double(t ^ (t >> 14)) / 4_294_967_296
        }
    }
}
