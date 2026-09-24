// Old names for `CallAppMicrophoneSharingMonitor`, kept so branches written
// before the rename (the pinned Mac-mic recorder and the Faster Bluetooth
// removal) still build after merging. Delete once nothing uses them.

typealias ZoomMicrophoneSharingMonitor = CallAppMicrophoneSharingMonitor

extension CallAppMicrophoneSharingMonitor {
    /// True while any listed desktop call app is open, not only Zoom.
    var isZoomRunning: Bool { isCallAppRunning }
}
