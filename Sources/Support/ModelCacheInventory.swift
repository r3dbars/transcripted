import Foundation

struct ModelCacheSnapshot: Equatable {
    let fluidAudioModelsBytes: Int64
    let transcriptedCacheBytes: Int64
    let whisperModelsBytes: Int64
    let staleFluidAudioModelBytes: Int64
    let staleFluidAudioModelNames: [String]

    var totalKnownBytes: Int64 {
        fluidAudioModelsBytes + transcriptedCacheBytes
    }

    var formattedTotalKnownSize: String {
        ModelCacheInventory.formattedByteCount(totalKnownBytes)
    }

    var formattedFluidAudioModelsSize: String {
        ModelCacheInventory.formattedByteCount(fluidAudioModelsBytes)
    }

    var formattedTranscriptedCacheSize: String {
        ModelCacheInventory.formattedByteCount(transcriptedCacheBytes)
    }

    var formattedWhisperModelsSize: String {
        ModelCacheInventory.formattedByteCount(whisperModelsBytes)
    }

    var formattedStaleFluidAudioModelSize: String {
        ModelCacheInventory.formattedByteCount(staleFluidAudioModelBytes)
    }

    func reclaimableBytes(includeWhisper: Bool) -> Int64 {
        staleFluidAudioModelBytes + (includeWhisper ? whisperModelsBytes : 0)
    }

    func formattedReclaimableSize(includeWhisper: Bool) -> String {
        ModelCacheInventory.formattedByteCount(reclaimableBytes(includeWhisper: includeWhisper))
    }

    var staleModelSummary: String {
        staleFluidAudioModelNames.isEmpty ? "none" : staleFluidAudioModelNames.joined(separator: ", ")
    }

    var diagnosticsFields: [String: String] {
        [
            "model_cache_total": formattedTotalKnownSize,
            "fluid_audio_models": formattedFluidAudioModelsSize,
            "transcripted_cache": formattedTranscriptedCacheSize,
            "whisper_models": formattedWhisperModelsSize,
            "known_stale_model_count": "\(staleFluidAudioModelNames.count)",
            "known_stale_model_size": formattedStaleFluidAudioModelSize,
            "known_stale_models": staleModelSummary,
        ]
    }
}

struct ModelCacheCleanupResult: Equatable {
    let removedBytes: Int64
    let removedNames: [String]

    static let empty = ModelCacheCleanupResult(removedBytes: 0, removedNames: [])

    func merging(_ other: ModelCacheCleanupResult) -> ModelCacheCleanupResult {
        ModelCacheCleanupResult(
            removedBytes: removedBytes + other.removedBytes,
            removedNames: removedNames + other.removedNames
        )
    }
}

enum ModelCacheInventory {
    static let knownStaleFluidAudioModelDirectories: Set<String> = [
        "parakeet-tdt-0.6b-v2",
        "parakeet-tdt-0.6b-v2-coreml",
        "parakeet-tdt-0.6b-v3",
    ]

    static func snapshot(
        fileManager: FileManager = .default,
        fluidAudioModelsDirectory: URL = defaultFluidAudioModelsDirectory(),
        transcriptedCacheDirectory: URL = defaultTranscriptedCacheDirectory(),
        whisperModelsDirectory: URL = defaultWhisperModelsDirectory()
    ) -> ModelCacheSnapshot {
        let staleEntries = knownStaleFluidAudioModelDirectories
            .sorted()
            .map { name in
                (name, fluidAudioModelsDirectory.appendingPathComponent(name, isDirectory: true))
            }
            .map { name, url in
                (name, directorySize(at: url, fileManager: fileManager))
            }
            .filter { _, bytes in bytes > 0 }

        return ModelCacheSnapshot(
            fluidAudioModelsBytes: directorySize(at: fluidAudioModelsDirectory, fileManager: fileManager),
            transcriptedCacheBytes: directorySize(at: transcriptedCacheDirectory, fileManager: fileManager),
            whisperModelsBytes: directorySize(at: whisperModelsDirectory, fileManager: fileManager),
            staleFluidAudioModelBytes: staleEntries.reduce(0) { $0 + $1.1 },
            staleFluidAudioModelNames: staleEntries.map(\.0)
        )
    }

    static func formattedByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }

    static func removeKnownStaleFluidAudioModels(
        fileManager: FileManager = .default,
        fluidAudioModelsDirectory: URL = defaultFluidAudioModelsDirectory()
    ) throws -> ModelCacheCleanupResult {
        let root = fluidAudioModelsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        var removedBytes: Int64 = 0
        var removedNames: [String] = []

        for name in knownStaleFluidAudioModelDirectories.sorted() {
            let candidate = root.appendingPathComponent(name, isDirectory: true)
                .standardizedFileURL
                .resolvingSymlinksInPath()

            guard candidate.path == root.appendingPathComponent(name, isDirectory: true).path,
                  candidate.path.hasPrefix(root.path + "/"),
                  fileManager.fileExists(atPath: candidate.path)
            else {
                continue
            }

            let bytes = directorySize(at: candidate, fileManager: fileManager)
            try fileManager.removeItem(at: candidate)
            removedBytes += bytes
            removedNames.append(name)
        }

        return ModelCacheCleanupResult(
            removedBytes: removedBytes,
            removedNames: removedNames
        )
    }

    static func removeWhisperModels(
        fileManager: FileManager = .default,
        whisperModelsDirectory: URL = defaultWhisperModelsDirectory()
    ) throws -> ModelCacheCleanupResult {
        let directory = whisperModelsDirectory.standardizedFileURL.resolvingSymlinksInPath()
        guard
            directory.lastPathComponent == "models",
            directory.deletingLastPathComponent().lastPathComponent == "whisperkit",
            fileManager.fileExists(atPath: directory.path)
        else {
            return ModelCacheCleanupResult(removedBytes: 0, removedNames: [])
        }

        let bytes = directorySize(at: directory, fileManager: fileManager)
        try fileManager.removeItem(at: directory)
        return ModelCacheCleanupResult(
            removedBytes: bytes,
            removedNames: ["Whisper cache"]
        )
    }

    static func removeReclaimableCaches(
        includeWhisper: Bool,
        fileManager: FileManager = .default,
        fluidAudioModelsDirectory: URL = defaultFluidAudioModelsDirectory(),
        whisperModelsDirectory: URL = defaultWhisperModelsDirectory()
    ) throws -> ModelCacheCleanupResult {
        let staleResult = try removeKnownStaleFluidAudioModels(
            fileManager: fileManager,
            fluidAudioModelsDirectory: fluidAudioModelsDirectory
        )

        guard includeWhisper else { return staleResult }

        let whisperResult = try removeWhisperModels(
            fileManager: fileManager,
            whisperModelsDirectory: whisperModelsDirectory
        )
        return staleResult.merging(whisperResult)
    }

    static func directorySize(at url: URL, fileManager: FileManager = .default) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return 0
        }

        if !isDirectory.boolValue {
            return fileSize(at: url)
        }

        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: []
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    private static func fileSize(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { return 0 }
        return Int64(values?.fileSize ?? 0)
    }

    private static func defaultFluidAudioModelsDirectory() -> URL {
        applicationSupportDirectory()
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    private static func defaultTranscriptedCacheDirectory() -> URL {
        FileManager.default.transcriptedAppSupportRootURL
            .appendingPathComponent("cache", isDirectory: true)
    }

    private static func defaultWhisperModelsDirectory() -> URL {
        defaultTranscriptedCacheDirectory()
            .appendingPathComponent("whisperkit", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    private static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Application Support", isDirectory: true)
    }
}
