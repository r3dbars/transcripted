import Foundation

/// Resolves a directory containing a named bundle of ML models for offline use.
///
/// `DiarizationService` (and future STT services) ask the provider for directories like
/// `"sortformer-models"` or `"offline-diarizer-models"`. The provider returns the URL
/// to that directory if it exists on disk, or `nil` to signal "not bundled, please
/// download from HuggingFace instead".
///
/// The standalone Transcripted app supplies a provider backed by `Bundle.main.resourcePath`
/// because its diarization models are copied into the app bundle at build time. Embedders
/// (e.g. the app in this repo) can supply a custom provider that points at a shared models cache
/// in Application Support, a sideloaded directory, or just return `nil` to force downloads.
public typealias ModelBundleProvider = @Sendable (String) -> URL?

/// Default `ModelBundleProvider` that looks inside `Bundle.main.resourcePath`.
/// Returns `nil` when running inside a library context where `Bundle.main` is the host
/// process (e.g. `xctest`, `swift build`) and doesn't contain the expected models.
public let defaultModelBundleProvider: ModelBundleProvider = { directory in
    guard let resourcePath = Bundle.main.resourcePath else { return nil }
    let path = URL(fileURLWithPath: resourcePath).appendingPathComponent(directory)
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    return path
}
