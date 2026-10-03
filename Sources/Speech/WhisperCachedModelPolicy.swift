// WhisperCachedModelPolicy.swift
// Decides whether a Whisper load can skip WhisperKit.download and use the model
// folder already on disk. Transcripted writes its own completion manifest after
// a download AND a load both succeed, and trusts the cache only when that
// manifest still matches the files on disk exactly (same repo, variant,
// revision, and every recorded file present at the same byte size).
//
// Without this, every Whisper load asked Hugging Face for the file list first
// (2 API calls + ~22 HEADs), and offline loads failed outright.
// Don't read the hub's private `.cache/huggingface` metadata as the signal: it
// only lists files that finished, not the full repo listing.

import Foundation

struct WhisperCachedModelManifest: Codable, Equatable {
    static let currentSchema = 1

    var schema: Int
    var repo: String
    var variant: String
    /// Changes with each app build, so the first load after an update takes
    /// the full download path once and picks up upstream refreshes.
    var revision: String
    /// The model folder, relative to the download base.
    var modelFolder: String
    /// Every regular file in the model folder: relative path -> byte size.
    var files: [String: Int64]
}

enum WhisperCachedModelDecision: Equatable {
    case useCached(relativeFolder: String)
    case download
}

enum WhisperCachedModelPolicy {
    static func decodeManifest(_ data: Data?) -> WhisperCachedModelManifest? {
        guard let data else { return nil }
        return try? JSONDecoder().decode(WhisperCachedModelManifest.self, from: data)
    }

    static func isSafeRelativeFolder(_ folder: String) -> Bool {
        guard !folder.isEmpty, !folder.hasPrefix("/") else { return false }
        let components = folder.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// `filesOnDisk` is the regular-file listing (relative path -> size) of the
    /// folder the manifest names. Extra files on disk are fine; a missing or
    /// resized recorded file is not.
    static func decide(
        manifestData: Data?,
        repo: String,
        variant: String,
        revision: String,
        filesOnDisk: [String: Int64]
    ) -> WhisperCachedModelDecision {
        guard
            let manifest = decodeManifest(manifestData),
            manifest.schema == WhisperCachedModelManifest.currentSchema,
            manifest.repo == repo,
            manifest.variant == variant,
            manifest.revision == revision,
            isSafeRelativeFolder(manifest.modelFolder),
            !manifest.files.isEmpty
        else { return .download }

        for (path, size) in manifest.files where filesOnDisk[path] != size {
            return .download
        }
        return .useCached(relativeFolder: manifest.modelFolder)
    }
}

/// File I/O around the policy. Every call is synchronous and meant to run off
/// the main actor (see `WhisperCachedModelLoad`).
enum WhisperCachedModelStore {
    /// Lives inside `<downloadBase>/models`, the folder model-cache cleanup
    /// deletes, so removing the Whisper cache removes the manifest with it.
    static func manifestURL(downloadBase: URL, variant: String) -> URL {
        let safeVariant = variant.replacingOccurrences(of: "/", with: "_")
        return downloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(".transcripted", isDirectory: true)
            .appendingPathComponent("whisper-\(safeVariant).json", isDirectory: false)
    }

    /// Regular files under `folder`, keyed by path relative to it.
    static func regularFileSizes(in folder: URL, fileManager: FileManager = .default) -> [String: Int64] {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        var sizes: [String: Int64] = [:]
        for case let url as URL in enumerator {
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                values.isRegularFile == true
            else { continue }
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            sizes[String(path.dropFirst(rootPath.count))] = Int64(values.fileSize ?? 0)
        }
        return sizes
    }

    static func relativeFolder(_ folder: URL, under downloadBase: URL) -> String? {
        let base = downloadBase.resolvingSymlinksInPath().standardizedFileURL.path
        let basePrefix = base.hasSuffix("/") ? base : base + "/"
        let path = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard path.hasPrefix(basePrefix) else { return nil }
        let relative = String(path.dropFirst(basePrefix.count))
        return WhisperCachedModelPolicy.isSafeRelativeFolder(relative) ? relative : nil
    }

    /// The cached model folder when the manifest still matches the disk exactly.
    static func cachedModelFolder(
        downloadBase: URL,
        repo: String,
        variant: String,
        revision: String,
        fileManager: FileManager = .default
    ) -> URL? {
        let data = try? Data(contentsOf: manifestURL(downloadBase: downloadBase, variant: variant))
        guard
            let manifest = WhisperCachedModelPolicy.decodeManifest(data),
            WhisperCachedModelPolicy.isSafeRelativeFolder(manifest.modelFolder)
        else { return nil }

        let folder = downloadBase.appendingPathComponent(manifest.modelFolder, isDirectory: true)
        let decision = WhisperCachedModelPolicy.decide(
            manifestData: data,
            repo: repo,
            variant: variant,
            revision: revision,
            filesOnDisk: regularFileSizes(in: folder, fileManager: fileManager)
        )
        guard case .useCached = decision else { return nil }
        return folder
    }

    /// Records a model folder that just downloaded and loaded successfully.
    /// Does nothing for a folder outside the download base or an empty folder.
    static func recordCompletedLoad(
        downloadBase: URL,
        repo: String,
        variant: String,
        revision: String,
        modelFolder: URL,
        fileManager: FileManager = .default
    ) throws {
        guard let relative = relativeFolder(modelFolder, under: downloadBase) else { return }
        let files = regularFileSizes(in: modelFolder, fileManager: fileManager)
        guard !files.isEmpty else { return }
        let manifest = WhisperCachedModelManifest(
            schema: WhisperCachedModelManifest.currentSchema,
            repo: repo,
            variant: variant,
            revision: revision,
            modelFolder: relative,
            files: files
        )
        let url = manifestURL(downloadBase: downloadBase, variant: variant)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(manifest).write(to: url, options: .atomic)
    }

    static func removeManifest(downloadBase: URL, variant: String, fileManager: FileManager = .default) {
        let url = manifestURL(downloadBase: downloadBase, variant: variant)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try? fileManager.removeItem(at: url)
    }
}

/// The load sequence with the cached fast path, behind closures so it can be
/// tested without WhisperKit. The caller still checks its generation and
/// unloads a pipe that arrives after it was superseded.
@MainActor
enum WhisperCachedModelLoad {
    struct Outcome<Pipe> {
        let pipe: Pipe
        let modelFolder: URL
        let usedCache: Bool
    }

    /// - Returns: nil when `isCurrent` turned false before a load finished.
    static func run<Pipe>(
        downloadBase: URL,
        repo: String,
        variant: String,
        revision: String,
        isCurrent: () -> Bool,
        willLoad: (_ folder: URL, _ cached: Bool) -> Void,
        download: () async throws -> URL,
        load: (URL) async throws -> Pipe
    ) async throws -> Outcome<Pipe>? {
        let cachedFolder = await Task.detached(priority: .userInitiated) {
            WhisperCachedModelStore.cachedModelFolder(
                downloadBase: downloadBase,
                repo: repo,
                variant: variant,
                revision: revision
            )
        }.value
        guard isCurrent(), !Task.isCancelled else { return nil }

        if let cachedFolder {
            willLoad(cachedFolder, true)
            do {
                let pipe = try await load(cachedFolder)
                return Outcome(pipe: pipe, modelFolder: cachedFolder, usedCache: true)
            } catch {
                if error is CancellationError || Task.isCancelled || !isCurrent() { throw error }
                // A corrupt or partial cache heals the same way it did before
                // the fast path: fall through to download-then-load, once.
            }
        }

        // Any manifest left at this point is stale or untrusted. Clear it
        // before the download so a half-finished refresh never looks complete.
        await Task.detached(priority: .userInitiated) {
            WhisperCachedModelStore.removeManifest(downloadBase: downloadBase, variant: variant)
        }.value
        guard isCurrent(), !Task.isCancelled else { return nil }

        let folder = try await download()
        guard isCurrent(), !Task.isCancelled else { return nil }
        willLoad(folder, false)
        let pipe = try await load(folder)

        await Task.detached(priority: .utility) {
            try? WhisperCachedModelStore.recordCompletedLoad(
                downloadBase: downloadBase,
                repo: repo,
                variant: variant,
                revision: revision,
                modelFolder: folder
            )
        }.value
        return Outcome(pipe: pipe, modelFolder: folder, usedCache: false)
    }
}
