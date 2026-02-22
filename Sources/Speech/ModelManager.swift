// ModelManager.swift
// Downloads and locates the Whisper GGML model file.
// Model: large-v3-turbo-q5_0 (~1.5GB) from HuggingFace.

import Foundation

@MainActor
class ModelManager: ObservableObject {
    @Published var isModelAvailable = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0  // 0.0–1.0
    @Published var downloadError: String?

    private static let modelFileName = "ggml-large-v3-turbo-q5_0.bin"
    private static let downloadURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!

    private let modelsDir: URL
    private var activeDownload: URLSessionDownloadTask?
    private var progressObservation: NSKeyValueObservation?

    var modelPath: String? {
        let path = modelsDir.appendingPathComponent(Self.modelFileName).path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        modelsDir = appSupport
            .appendingPathComponent("Draft", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)

        try? FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)
        isModelAvailable = modelPath != nil
    }

    func downloadModel() {
        guard !isDownloading else { return }
        isDownloading = true
        downloadProgress = 0
        downloadError = nil

        let destination = modelsDir.appendingPathComponent(Self.modelFileName)
        let task = URLSession.shared.downloadTask(with: Self.downloadURL) { [weak self] tempURL, response, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.progressObservation = nil

                if let error = error {
                    if (error as NSError).code == NSURLErrorCancelled {
                        // User cancelled — clean up silently
                    } else {
                        self.downloadError = error.localizedDescription
                        print("❌ MODEL | download failed: \(error.localizedDescription)")
                    }
                    self.isDownloading = false
                    self.downloadProgress = 0
                    return
                }

                guard let tempURL = tempURL else {
                    self.downloadError = "No file received"
                    self.isDownloading = false
                    self.downloadProgress = 0
                    return
                }

                do {
                    // Move temp file → final destination
                    if FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.removeItem(at: destination)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    self.downloadProgress = 1.0
                    self.isModelAvailable = true
                    print("✅ MODEL | download complete → \(destination.path)")
                } catch {
                    self.downloadError = "Failed to save: \(error.localizedDescription)"
                    print("❌ MODEL | save failed: \(error.localizedDescription)")
                }
                self.isDownloading = false
            }
        }

        // Observe fractionCompleted for real-time progress updates
        progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { @MainActor [weak self] in
                self?.downloadProgress = progress.fractionCompleted
            }
        }

        activeDownload = task
        task.resume()
        print("⬇️ MODEL | download started from \(Self.downloadURL)")
    }

    func cancelDownload() {
        activeDownload?.cancel()
        activeDownload = nil
        progressObservation = nil
        isDownloading = false
        downloadProgress = 0
        downloadError = nil
    }
}
