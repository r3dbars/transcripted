#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import CoreGraphics
import Vision

/// Runs on-device Vision OCR over a native-resolution captured frame. The
/// measured `.fast` configuration below preserves each candidate's
/// confidence so downstream freshness/evidence decisions do not flatten
/// uncertain OCR into certain text.
enum ScreenTextRecognizer {
    struct RecognizedBlock: Equatable, Sendable {
        let text: String
        /// Top-left-origin, normalized to the full image — already flipped
        /// from Vision's native bottom-left convention so every consumer
        /// downstream of this type shares one coordinate convention.
        let boundingBox: NormalizedDisplayRect
        let confidence: Double
    }

    enum RecognitionError: Error {
        case requestFailed
    }

    /// Runs Vision at utility priority so OCR never competes with the
    /// completion request it is meant to inform (2026-08-23: a capture
    /// overlapped 52% of ghost requests and added ~45ms to their p99).
    static func recognize(image: CGImage) async throws -> [RecognizedBlock] {
        try await Task.detached(priority: .utility) {
            try await recognizeNow(image: image)
        }.value
    }

    private static func recognizeNow(image: CGImage) async throws -> [RecognizedBlock] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(throwing: RecognitionError.requestFailed)
                    return
                }
                let blocks = observations.compactMap { observation -> RecognizedBlock? in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return RecognizedBlock(
                        text: candidate.string,
                        boundingBox: Self.topLeftNormalized(observation.boundingBox),
                        confidence: Double(candidate.confidence)
                    )
                }
                continuation.resume(returning: blocks)
            }
            // `.fast` without language correction, at native capture
            // resolution. Measured 2026-08-23 on synthetic iMessage / Slack /
            // Mail / desktop frames with exact ground truth: 9-15x faster
            // than `.accurate` + correction with equal or better word recall
            // and line exactness — correction rewrote wrapped UI text into
            // non-literal wording. `.fast` degrades sharply on downscaled
            // input, so the capture paths must keep passing full-resolution
            // pixels; lower resolution is not the lever here.
            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Vision reports `boundingBox` normalized with origin bottom-left; the
    /// rest of Screen Memory (window frames, `NormalizedDisplayRect`) standardizes
    /// on top-left, matching Quartz/ScreenCaptureKit's global-coordinate
    /// convention. Flip once, here, so nothing downstream has to remember
    /// which convention it is holding.
    private static func topLeftNormalized(_ box: CGRect) -> NormalizedDisplayRect {
        NormalizedDisplayRect(
            x: box.origin.x,
            y: 1.0 - box.origin.y - box.height,
            width: box.width,
            height: box.height
        )
    }
}
