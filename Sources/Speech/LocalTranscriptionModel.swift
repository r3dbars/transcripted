import Foundation

enum LocalTranscriptionModel: String, CaseIterable {
    case parakeetTdtV3 = "parakeet_tdt_v3"
    case parakeetTdtV2 = "parakeet_tdt_v2"

    var displayName: String {
        switch self {
        case .parakeetTdtV3:
            return "Parakeet TDT V3"
        case .parakeetTdtV2:
            return "Parakeet TDT V2"
        }
    }

    var pickerLabel: String {
        switch self {
        case .parakeetTdtV3:
            return "Parakeet TDT V3 (Recommended)"
        case .parakeetTdtV2:
            return "Parakeet TDT V2"
        }
    }

    var selectionSummary: String {
        switch self {
        case .parakeetTdtV3:
            return "Recommended. Multilingual and the best fit for mixed-language dictation or meetings."
        case .parakeetTdtV2:
            return "English-only. Best if you want the strongest English recall and do not need multilingual transcription."
        }
    }

    fileprivate var bundleDirectoryCandidates: [String] {
        switch self {
        case .parakeetTdtV3:
            return [
                "parakeet-tdt-0.6b-v3-coreml",
                "parakeet-tdt-0.6b-v3"
            ]
        case .parakeetTdtV2:
            return [
                "parakeet-tdt-0.6b-v2-coreml",
                "parakeet-tdt-0.6b-v2"
            ]
        }
    }

    fileprivate var bundleCheckFile: String {
        "Encoder.mlmodelc"
    }

}

enum LocalTranscriptionModelAvailabilitySource {
    case bundled
    case cached
    case downloadRequired

    var statusTitle: String {
        switch self {
        case .bundled:
            return "Bundled with this build"
        case .cached:
            return "Already on this Mac"
        case .downloadRequired:
            return "One-time download needed"
        }
    }
}

struct LocalTranscriptionModelAvailability {
    let source: LocalTranscriptionModelAvailabilitySource
    let directoryURL: URL?

    func statusDetail(for model: LocalTranscriptionModel) -> String {
        switch source {
        case .bundled:
            return "\(model.displayName) is already inside this app build, so setup does not need a network download."
        case .cached:
            return "\(model.displayName) is already stored on this Mac and can load without downloading it again."
        case .downloadRequired:
            return "\(model.displayName) is not bundled or cached yet, so Transcripted will download it the first time you use it."
        }
    }

    var networkDetail: String {
        "Network is only used when the selected model is missing. Transcripted then downloads from huggingface.co with hf-mirror.com as a fallback, and keeps the model on this Mac after setup."
    }
}

enum LocalTranscriptionModelResolver {
    static func availability(
        for model: LocalTranscriptionModel,
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        resourceRootURL: URL? = nil,
        applicationSupportURL: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) -> LocalTranscriptionModelAvailability {
        if let bundled = bundledURL(
            for: model,
            fileManager: fileManager,
            bundle: bundle,
            resourceRootURL: resourceRootURL
        ) {
            return LocalTranscriptionModelAvailability(source: .bundled, directoryURL: bundled)
        }

        if let cached = cachedURL(for: model, fileManager: fileManager, applicationSupportURL: applicationSupportURL) {
            return LocalTranscriptionModelAvailability(source: .cached, directoryURL: cached)
        }

        return LocalTranscriptionModelAvailability(source: .downloadRequired, directoryURL: nil)
    }

    static func bundledURL(
        for model: LocalTranscriptionModel,
        fileManager: FileManager = .default,
        bundle: Bundle = .main,
        resourceRootURL: URL? = nil
    ) -> URL? {
        guard let resourceURL = resourceRootURL ?? bundle.resourceURL else { return nil }

        return firstExistingModelDirectory(
            root: resourceURL.appendingPathComponent("parakeet-models", isDirectory: true),
            candidates: model.bundleDirectoryCandidates,
            checkFile: model.bundleCheckFile,
            fileManager: fileManager
        )
    }

    static func cachedURL(
        for model: LocalTranscriptionModel,
        fileManager: FileManager = .default,
        applicationSupportURL: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) -> URL? {
        guard let cacheRoot = cacheRootURL(applicationSupportURL: applicationSupportURL) else { return nil }

        return firstExistingModelDirectory(
            root: cacheRoot,
            candidates: model.bundleDirectoryCandidates,
            checkFile: model.bundleCheckFile,
            fileManager: fileManager
        )
    }

    static func cacheRootURL(
        applicationSupportURL: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    ) -> URL? {
        applicationSupportURL?.appendingPathComponent("FluidAudio/Models", isDirectory: true)
    }

    private static func firstExistingModelDirectory(
        root: URL,
        candidates: [String],
        checkFile: String,
        fileManager: FileManager
    ) -> URL? {
        for candidate in candidates {
            let directory = root.appendingPathComponent(candidate, isDirectory: true)
            let marker = directory.appendingPathComponent(checkFile)
            if fileManager.fileExists(atPath: marker.path) {
                return directory
            }
        }

        return nil
    }
}

enum LocalTranscriptionModelPreferences {
    static let selectedModelKey = "selectedLocalTranscriptionModel"

    static func selectedModel(userDefaults: UserDefaults = .standard) -> LocalTranscriptionModel {
        guard let rawValue = userDefaults.string(forKey: selectedModelKey),
              let model = LocalTranscriptionModel(rawValue: rawValue) else {
            return .parakeetTdtV3
        }

        return model
    }

    static func setSelectedModel(_ model: LocalTranscriptionModel, userDefaults: UserDefaults = .standard) {
        userDefaults.set(model.rawValue, forKey: selectedModelKey)
    }
}
