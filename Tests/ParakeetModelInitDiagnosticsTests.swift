import AVFoundation
import Foundation

func testParakeetModelInitDiagnostics() {
    runSuite("ParakeetModelInitDiagnostics.failureContext captures safe initialization details") {
        let context = ParakeetModelInitDiagnostics.failureContext(
            stage: .downloadModels,
            loadSource: .download,
            bundledModelPresent: false,
            microphoneStatus: .denied
        )

        assertEqual(context["failure_stage"], "download_models", "failure stage should explain where initialization stopped")
        assertEqual(context["load_source"], "download", "load source should distinguish bundle from runtime download")
        assertEqual(context["model_bundle_present"], "false", "bundle presence should be explicit for packaging/debugging issues")
        assertEqual(context["mic_status"], "denied", "microphone status should be preserved in a sanitized form")
    }
}
