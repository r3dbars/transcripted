import SwiftUI

// MARK: - Heat Map Colors (5-Step Gradient)

extension Color {
    static let heatMapLevel0 = Color(hex: "#2A2A2A")
    static let heatMapLevel1 = Color(hex: "#4A2F2F")
    static let heatMapLevel2 = Color(hex: "#7A3D3D")
    static let heatMapLevel3 = Color(hex: "#AA4545")
    static let heatMapLevel4 = Color.recordingCoral

    // Legacy aliases
    static let heatMapEmpty = heatMapLevel0
    static let heatMapLight = heatMapLevel1
    static let heatMapMedium = heatMapLevel2
    static let heatMapHigh = heatMapLevel3
    static let heatMapMax = heatMapLevel4
}
