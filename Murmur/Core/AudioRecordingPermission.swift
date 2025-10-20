import SwiftUI
import Observation

let kMurmurSubsystem = "com.murmur.app"

/// Handles system audio recording permission (macOS 14.2+)
@available(macOS 14.2, *)
@Observable
final class AudioRecordingPermission {

    enum Status: String {
        case unknown
        case denied
        case authorized
    }

    private(set) var status: Status = .unknown

    init() {
        // For now, we'll use a simpler approach without TCC SPI
        // The permission will be requested when first attempting to capture system audio
        // This avoids using private API
        status = .unknown
    }

    func request() {
        // Permission will be requested automatically when system audio capture starts
        // macOS will show the native permission dialog
        print("ℹ️ System audio permission will be requested on first capture attempt")
        status = .unknown
    }

    func updateStatus(_ newStatus: Status) {
        status = newStatus
    }
}
