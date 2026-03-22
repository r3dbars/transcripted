import SwiftUI

// MARK: - Animation Timing

struct AnimationTiming {
    static let quick: Double = 0.15
    static let standard: Double = 0.25
    static let smooth: Double = 0.35
    static let elaborate: Double = 0.5
    static let long: Double = 0.8
}

// MARK: - Spring Presets

extension Animation {
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.8)
    static let smooth = Animation.spring(response: 0.5, dampingFraction: 0.85)
    static let bouncy = Animation.spring(response: 0.5, dampingFraction: 0.6)
    static let gentle = Animation.spring(response: 0.7, dampingFraction: 0.9)
    static let elegant = Animation.spring(response: 0.5, dampingFraction: 0.92)
    static let refined = Animation.spring(response: 0.45, dampingFraction: 0.95)

    // MARK: - Laws of UX Animation Presets
    static let lawsBase = Animation.easeInOut(duration: 0.3)
    static let lawsTap = Animation.spring(response: 0.15, dampingFraction: 0.8)
    static let lawsSuccess = Animation.spring(response: 0.4, dampingFraction: 0.5)
    static let lawsStateChange = Animation.spring(response: 0.35, dampingFraction: 0.85)
    static let lawsCardHover = Animation.spring(response: 0.3, dampingFraction: 0.8)
    static let lawsPanelExpand = Animation.spring(response: 0.25, dampingFraction: 0.85)
    static let lawsPanelCollapse = Animation.spring(response: 0.15, dampingFraction: 0.9)

    // MARK: - Pill Morphing Presets
    static let pillMorph = Animation.spring(response: 0.3, dampingFraction: 0.8)
    static let trayExpand = Animation.spring(response: PillAnimationTiming.trayDuration, dampingFraction: 0.85)
    static let pillContentFade = Animation.easeInOut(duration: PillAnimationTiming.contentFade)
}

// MARK: - Pill Dimensions

struct PillDimensions {
    static let idleWidth: CGFloat = 40
    static let idleHeight: CGFloat = 20
    static let idleExpandedWidth: CGFloat = 120
    static let idleExpandedHeight: CGFloat = 28
    static let recordingWidth: CGFloat = 160
    static let recordingHeight: CGFloat = 36
    static let savedWidth: CGFloat = 260
    static let savedHeight: CGFloat = 56
    static let trayWidth: CGFloat = 280
    static let trayMaxHeight: CGFloat = 300
    static let dockPadding: CGFloat = 8
    static let defaultDockHeight: CGFloat = 70
}

// MARK: - Pill Animation Timing

struct PillAnimationTiming {
    static let morphDuration: Double = 0.175
    static let cooldownDuration: Double = 0.175
    static let contentFade: Double = 0.1
    static let celebrationDuration: Double = 2.0
    static let trayDuration: Double = 0.2
    static let toastDuration: Double = 8.0
    static let stateTransitionDuration: Double = 0.2
    static let settleDelay: Double = 0.2
}
