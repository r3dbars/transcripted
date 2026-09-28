import CoreGraphics

/// Layout for the menu bar header. The header has no title; it only takes
/// space when it has something to say: a status line (recording, making a
/// transcript, or warmup progress) and/or a shortcut warning.
enum MenuBarHeaderLayoutPolicy {
    static let warningTextHeight: CGFloat = 26
    static let statusRowHeight: CGFloat = 20
    static let progressTop: CGFloat = 20
    static let detailTop: CGFloat = 32
    static let nonReadyIntrinsicHeight: CGFloat = 56
    static let recordingIntrinsicHeight: CGFloat = statusRowHeight

    /// Where the warning starts: at the top when it is the only thing in the
    /// header, otherwise below the status line or the warmup block.
    static func warningTop(isReady: Bool, showsStatus: Bool) -> CGFloat {
        if !isReady { return nonReadyIntrinsicHeight + 4 }
        return showsStatus ? statusRowHeight + 2 : 2
    }

    static func intrinsicHeight(isReady: Bool, hasWarning: Bool, isRecording: Bool = false) -> CGFloat {
        if hasWarning {
            return warningTop(isReady: isReady, showsStatus: isRecording) + warningTextHeight + 2
        }
        if isReady {
            return isRecording ? recordingIntrinsicHeight : 0
        }
        return nonReadyIntrinsicHeight
    }
}
