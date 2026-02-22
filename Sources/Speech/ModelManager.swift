// ModelManager.swift
// Locates the Whisper GGML model file.
// Checks app bundle first (production), then Application Support (development).

import Foundation

@MainActor
class ModelManager: ObservableObject {
    @Published var isModelAvailable = false

    private static let modelFileName = "ggml-large-v3-turbo-q5_0"
    private static let modelExtension = "bin"

    var modelPath: String? {
        // 1. Check app bundle (bundled in Contents/Resources/models/)
        if let bundled = Bundle.main.path(
            forResource: Self.modelFileName,
            ofType: Self.modelExtension,
            inDirectory: "models"
        ) {
            return bundled
        }

        // 2. Fall back to Application Support (dev builds / pre-downloaded)
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let path = appSupport
            .appendingPathComponent("Draft", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("\(Self.modelFileName).\(Self.modelExtension)")
            .path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    init() {
        isModelAvailable = modelPath != nil
    }
}
