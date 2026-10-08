import Combine
import TranscriptedCore

/// Meeting owns the live Core Audio backend; Support owns the bounded request.
@available(macOS 26.0, *)
@MainActor
extension SystemAudioPermissionRequester {
    convenience init() {
        let capture = CoreAudioSystemAudioCapture()
        self.init(
            prepare: { try capture.prepare() },
            start: { receivedSignal in
                try capture.start { buffer in
                    receivedSignal(SystemAudioPermissionProbeClassifier.sampleEvidence(buffer))
                }
            },
            stop: { capture.stopSync() }
        )
        observeBackendErrors(capture.errorMessagePublisher)
    }
}
