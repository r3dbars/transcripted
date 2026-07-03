import CoreGraphics

enum MenuBarHeaderLayoutPolicy {
    static let warningTextHeight: CGFloat = 26
    static let readyWarningTop: CGFloat = 44
    static let nonReadyWarningTop: CGFloat = 82
    static let readyWarningIntrinsicHeight: CGFloat = 74
    static let nonReadyWarningIntrinsicHeight: CGFloat = 110
    static let nonReadyIntrinsicHeight: CGFloat = 78
    static let recordingIntrinsicHeight: CGFloat = 20

    static func warningTop(isReady: Bool) -> CGFloat {
        isReady ? readyWarningTop : nonReadyWarningTop
    }

    /// The header only takes space when it has something to say: warmup
    /// progress, a hotkey warning, or an active meeting recording. A ready,
    /// quiet, idle popover shows no header at all.
    static func intrinsicHeight(isReady: Bool, hasWarning: Bool, isRecording: Bool = false) -> CGFloat {
        if isReady {
            if hasWarning {
                return readyWarningIntrinsicHeight
            }
            return isRecording ? recordingIntrinsicHeight : 0
        }
        return hasWarning ? nonReadyWarningIntrinsicHeight : nonReadyIntrinsicHeight
    }
}
