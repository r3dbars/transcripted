import Foundation

// Promise: a Whisper load skips the Hugging Face check only when Transcripted's
// own manifest still matches the model files on disk exactly; anything else
// (including the real partial folder shape seen on a dev Mac) downloads. A
// cached load that fails heals by downloading exactly once.
// Synthetic: no real WhisperKit, network, or CoreML load is exercised here.

private let whisperRepo = "argmaxinc/whisperkit-coreml"
private let turboVariant = "openai_whisper-large-v3-v20240930_turbo_632MB"
private let turboFolder = "models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo_632MB"

// The complete turbo variant as WhisperKit lays it out (sizes from a real cache).
private let completeTurboFiles: [String: Int64] = [
    "AudioEncoder.mlmodelc/analytics/coremldata.bin": 243,
    "AudioEncoder.mlmodelc/coremldata.bin": 348,
    "AudioEncoder.mlmodelc/metadata.json": 1974,
    "AudioEncoder.mlmodelc/model.mil": 7_589_739,
    "AudioEncoder.mlmodelc/weights/weight.bin": 421_968_768,
    "MelSpectrogram.mlmodelc/coremldata.bin": 329,
    "MelSpectrogram.mlmodelc/model.mil": 10143,
    "MelSpectrogram.mlmodelc/weights/weight.bin": 373_376,
    "TextDecoder.mlmodelc/coremldata.bin": 633,
    "TextDecoder.mlmodelc/model.mil": 217_177,
    "TextDecoder.mlmodelc/weights/weight.bin": 203_199_860,
    "config.json": 1149,
    "generation_config.json": 2767,
]

private func manifestData(
    repo: String = whisperRepo,
    variant: String = turboVariant,
    revision: String = "1.1.70-170",
    folder: String = turboFolder,
    files: [String: Int64] = completeTurboFiles
) -> Data {
    let manifest = WhisperCachedModelManifest(
        schema: WhisperCachedModelManifest.currentSchema,
        repo: repo,
        variant: variant,
        revision: revision,
        modelFolder: folder,
        files: files
    )
    return (try? JSONEncoder().encode(manifest)) ?? Data()
}

private func decideTurbo(_ data: Data?, disk: [String: Int64], revision: String = "1.1.70-170") -> WhisperCachedModelDecision {
    WhisperCachedModelPolicy.decide(
        manifestData: data,
        repo: whisperRepo,
        variant: turboVariant,
        revision: revision,
        filesOnDisk: disk
    )
}

private func makeTempBase() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("whisper-cached-model-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeModelFolder(base: URL, sizes: [String: Int]) -> URL {
    let folder = base.appendingPathComponent(turboFolder, isDirectory: true)
    for (path, size) in sizes {
        let file = folder.appendingPathComponent(path)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(repeating: 7, count: size).write(to: file)
    }
    return folder
}

private let smallModelFiles: [String: Int] = [
    "AudioEncoder.mlmodelc/coremldata.bin": 34,
    "AudioEncoder.mlmodelc/weights/weight.bin": 400,
    "TextDecoder.mlmodelc/weights/weight.bin": 200,
    "config.json": 11,
]

private struct FakeLoadError: Error {}

@MainActor
func testWhisperCachedModelPolicy() async {
    runSuite("Whisper cache — a matching manifest uses the cached folder") {
        assertEqual(
            decideTurbo(manifestData(), disk: completeTurboFiles),
            .useCached(relativeFolder: turboFolder)
        )
        var withExtra = completeTurboFiles
        withExtra["notes.txt"] = 5
        assertEqual(
            decideTurbo(manifestData(), disk: withExtra),
            .useCached(relativeFolder: turboFolder),
            "an extra file on disk doesn't invalidate a complete set"
        )
    }

    runSuite("Whisper cache — anything short of an exact match downloads") {
        var partial = completeTurboFiles
        partial.removeValue(forKey: "AudioEncoder.mlmodelc/coremldata.bin")
        assertEqual(decideTurbo(manifestData(), disk: partial), .download, "partial folder (no AudioEncoder coremldata.bin)")

        var resized = completeTurboFiles
        resized["TextDecoder.mlmodelc/weights/weight.bin"] = 1_000
        assertEqual(decideTurbo(manifestData(), disk: resized), .download, "size mismatch on weights")

        assertEqual(decideTurbo(manifestData(variant: "openai_whisper-large-v3-v20240930_626MB"), disk: completeTurboFiles), .download, "other variant")
        assertEqual(decideTurbo(manifestData(repo: "someone/else"), disk: completeTurboFiles), .download, "other repo")
        assertEqual(decideTurbo(manifestData(), disk: completeTurboFiles, revision: "1.1.71-171"), .download, "new app build")
        assertEqual(decideTurbo(nil, disk: completeTurboFiles), .download, "no manifest")
        assertEqual(decideTurbo(Data("not json".utf8), disk: completeTurboFiles), .download, "garbage manifest")
        assertEqual(decideTurbo(manifestData(files: [:]), disk: completeTurboFiles), .download, "empty manifest")
        assertEqual(decideTurbo(manifestData(folder: "../elsewhere"), disk: completeTurboFiles), .download, "folder escaping the base")
        assertEqual(decideTurbo(manifestData(folder: "/abs/path"), disk: completeTurboFiles), .download, "absolute folder")
    }

    runSuite("Whisper cache — a recorded folder round-trips, and a truncated file breaks the match") {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = writeModelFolder(base: base, sizes: smallModelFiles)

        assertNil(WhisperCachedModelStore.cachedModelFolder(downloadBase: base, repo: whisperRepo, variant: turboVariant, revision: "r1"), "nothing recorded yet")

        try? WhisperCachedModelStore.recordCompletedLoad(downloadBase: base, repo: whisperRepo, variant: turboVariant, revision: "r1", modelFolder: folder)
        let cached = WhisperCachedModelStore.cachedModelFolder(downloadBase: base, repo: whisperRepo, variant: turboVariant, revision: "r1")
        assertEqual(cached?.resolvingSymlinksInPath().standardizedFileURL.path, folder.resolvingSymlinksInPath().standardizedFileURL.path)
        assertNil(WhisperCachedModelStore.cachedModelFolder(downloadBase: base, repo: whisperRepo, variant: turboVariant, revision: "r2"), "other build")

        try? Data(repeating: 1, count: 3).write(to: folder.appendingPathComponent("TextDecoder.mlmodelc/weights/weight.bin"))
        assertNil(WhisperCachedModelStore.cachedModelFolder(downloadBase: base, repo: whisperRepo, variant: turboVariant, revision: "r1"), "truncated weights")

        // Removing the models folder (what model-cache cleanup deletes) removes the manifest too.
        try? FileManager.default.removeItem(at: base.appendingPathComponent("models"))
        assertFalse(FileManager.default.fileExists(atPath: WhisperCachedModelStore.manifestURL(downloadBase: base, variant: turboVariant).path))
    }

    await runSuite("Whisper load — first load downloads and records; the next skips the download") {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        var downloads = 0
        var loads: [Bool] = []

        let first = try? await WhisperCachedModelLoad.run(
            downloadBase: base, repo: whisperRepo, variant: turboVariant, revision: "r1",
            isCurrent: { true },
            willLoad: { _, cached in loads.append(cached) },
            download: { downloads += 1; return writeModelFolder(base: base, sizes: smallModelFiles) },
            load: { folder in folder.lastPathComponent }
        )
        assertEqual(first?.usedCache, false)
        assertEqual(downloads, 1)

        let second = try? await WhisperCachedModelLoad.run(
            downloadBase: base, repo: whisperRepo, variant: turboVariant, revision: "r1",
            isCurrent: { true },
            willLoad: { _, cached in loads.append(cached) },
            download: { downloads += 1; return writeModelFolder(base: base, sizes: smallModelFiles) },
            load: { folder in folder.lastPathComponent }
        )
        assertEqual(second?.usedCache, true)
        assertEqual(second?.pipe, turboVariant)
        assertEqual(downloads, 1, "a successful cached load never calls the downloader")
        assertEqual(loads, [false, true])
    }

    await runSuite("Whisper load — a failed cached load downloads exactly once, then re-records") {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = writeModelFolder(base: base, sizes: smallModelFiles)
        try? WhisperCachedModelStore.recordCompletedLoad(downloadBase: base, repo: whisperRepo, variant: turboVariant, revision: "r1", modelFolder: folder)

        var downloads = 0
        var loadAttempts = 0
        let outcome = try? await WhisperCachedModelLoad.run(
            downloadBase: base, repo: whisperRepo, variant: turboVariant, revision: "r1",
            isCurrent: { true },
            willLoad: { _, _ in },
            download: { downloads += 1; return folder },
            load: { _ -> String in
                loadAttempts += 1
                if loadAttempts == 1 { throw FakeLoadError() }
                return "loaded"
            }
        )
        assertEqual(outcome?.pipe, "loaded")
        assertEqual(outcome?.usedCache, false)
        assertEqual(downloads, 1)
        assertEqual(loadAttempts, 2)
        assertNotNil(
            WhisperCachedModelStore.cachedModelFolder(downloadBase: base, repo: whisperRepo, variant: turboVariant, revision: "r1"),
            "the manifest is rewritten after the healed load"
        )
    }

    await runSuite("Whisper load — a failed download surfaces the error and leaves no manifest") {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        var threw = false
        do {
            _ = try await WhisperCachedModelLoad.run(
                downloadBase: base, repo: whisperRepo, variant: turboVariant, revision: "r1",
                isCurrent: { true },
                willLoad: { _, _ in },
                download: { throw FakeLoadError() },
                load: { _ in "never" }
            )
        } catch {
            threw = true
        }
        assertTrue(threw)
        assertFalse(FileManager.default.fileExists(atPath: WhisperCachedModelStore.manifestURL(downloadBase: base, variant: turboVariant).path))
    }

    await runSuite("Whisper load — a superseded load stops before downloading") {
        let base = makeTempBase()
        defer { try? FileManager.default.removeItem(at: base) }
        var downloads = 0
        let outcome = try? await WhisperCachedModelLoad.run(
            downloadBase: base, repo: whisperRepo, variant: turboVariant, revision: "r1",
            isCurrent: { false },
            willLoad: { _, _ in },
            download: { downloads += 1; return base },
            load: { _ in "never" }
        )
        assertNil(outcome)
        assertEqual(downloads, 0)
    }
}
