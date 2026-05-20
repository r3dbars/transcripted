import CoreGraphics

enum MenuBarHeaderLayoutPolicy {
    static let warningTextHeight: CGFloat = 26
    static let readyWarningTop: CGFloat = 44
    static let nonReadyWarningTop: CGFloat = 82
    static let readyWarningIntrinsicHeight: CGFloat = 74
    static let nonReadyWarningIntrinsicHeight: CGFloat = 110
    static let nonReadyIntrinsicHeight: CGFloat = 78

    static func warningTop(isReady: Bool) -> CGFloat {
        isReady ? readyWarningTop : nonReadyWarningTop
    }

    static func intrinsicHeight(isReady: Bool, hasWarning: Bool) -> CGFloat {
        if isReady {
            return hasWarning ? readyWarningIntrinsicHeight : 0
        }
        return hasWarning ? nonReadyWarningIntrinsicHeight : nonReadyIntrinsicHeight
    }
}
