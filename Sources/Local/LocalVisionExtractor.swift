// LocalVisionExtractor.swift
// Replaces AnthropicAPI.extractStructuredContext() with fully local pipeline:
// 1. Apple Vision OCR extracts text from screenshot
// 2. Small LLM (0.8B) parses OCR text into CapturedContext fields

import Foundation
import Vision
import AppKit

enum LocalVisionExtractor {

    /// Extract structured conversation context from a screenshot using local OCR + LLM.
    static func extractContext(imageData: Data, engine: LlamaEngine, systemPrompt: String) async throws -> CapturedContext {
        // Step 1: OCR — extract all text from the screenshot
        let ocrText = try await performOCR(imageData: imageData)

        guard !ocrText.isEmpty else {
            return CapturedContext.parse(from: "")
        }

        // Step 2: LLM — parse OCR text into structured fields
        let userMessage = "Parse the following OCR text from a screenshot into the structured format described. Output ONLY the labeled sections.\n\nOCR TEXT:\n\(ocrText)"

        let rawText = try await engine.complete(
            prompt: userMessage,
            systemPrompt: systemPrompt,
            maxTokens: DraftConstants.visionMaxTokens,
            temperature: 0.1  // Low temp for structured extraction
        )

        return CapturedContext.parse(from: rawText)
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
