// LocalVisionExtractor.swift
// Replaces AnthropicAPI.extractStructuredContext() with fully local Apple Vision OCR.
// Extracts text from screenshot and returns it as raw conversation context —
// the drafting model interprets it directly (no separate parsing LLM).

import Foundation
import Vision
import AppKit

enum LocalVisionExtractor {

    /// Extract conversation context from a screenshot using Apple Vision OCR only (no LLM).
    /// Returns raw OCR text as the conversation field — the drafting model interprets it directly.
    static func extractContext(imageData: Data) async throws -> CapturedContext {
        let ocrText = try await performOCR(imageData: imageData)

        guard !ocrText.isEmpty else {
            return CapturedContext.parse(from: "")
        }

        // Truncate long OCR: keep header (app chrome) + recent messages
        let trimmedOCR: String
        if ocrText.count > DraftConstants.ocrMaxCharacters {
            let header = String(ocrText.prefix(DraftConstants.ocrHeaderCharacters))
            let recent = String(ocrText.suffix(DraftConstants.ocrRecentCharacters))
            trimmedOCR = header + "\n...\n" + recent
        } else {
            trimmedOCR = ocrText
        }

        // Build a CapturedContext with raw OCR as the conversation.
        // Platform/formality detection happens via PlatformFormatter from the source app.
        var context = CapturedContext()
        context.conversation = trimmedOCR
        return context
    }

    // MARK: - Apple Vision OCR

    private static func performOCR(imageData: Data) async throws -> String {
        guard let image = NSImage(data: imageData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
        }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                // Sort by vertical position (top to bottom) then left to right
                let sorted = observations.sorted { a, b in
                    let ay = 1.0 - a.boundingBox.origin.y  // VN uses bottom-left origin
                    let by = 1.0 - b.boundingBox.origin.y
                    if abs(ay - by) < 0.01 { // Same line
                        return a.boundingBox.origin.x < b.boundingBox.origin.x
                    }
                    return ay < by
                }
                let lines = sorted.compactMap { obs in
                    obs.topCandidates(1).first?.string
                }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
