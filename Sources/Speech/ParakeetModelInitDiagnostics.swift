import AVFoundation
import Foundation

enum ParakeetModelInitStage: String, Equatable {
    case authorizationRequest = "authorization_request"
    case bundleLoad = "bundle_load"
    case downloadModels = "download_models"
    case managerInitialize = "manager_initialize"
}

enum ParakeetModelLoadSource: String, Equatable {
    case unresolved
    case bundle
    case download
}

enum ParakeetModelInitDiagnostics {
    static func failureContext(
        stage: ParakeetModelInitStage,
        loadSource: ParakeetModelLoadSource,
        bundledModelPresent: Bool,
        microphoneStatus: AVAuthorizationStatus
    ) -> [String: String] {
        [
            "failure_stage": stage.rawValue,
            "load_source": loadSource.rawValue,
            "model_bundle_present": bundledModelPresent ? "true" : "false",
            "mic_status": diagnosticName(for: microphoneStatus),
        ]
    }

    private static func diagnosticName(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "not_determined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        @unknown default:
            return "unknown"
        }
    }
}
