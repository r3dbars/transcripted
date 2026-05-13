import Foundation

func testModelCacheInventory() {
    runSuite("ModelCacheInventory totals model cache directories") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCacheInventoryTests-\(UUID().uuidString)", isDirectory: true)
        let fluid = root.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        let transcriptedCache = root.appendingPathComponent("Transcripted/cache", isDirectory: true)
        let whisper = transcriptedCache.appendingPathComponent("whisperkit/models", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        writeTestFile(fluid.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml/Encoder.mlmodelc/data.bin"), bytes: 11)
        writeTestFile(fluid.appendingPathComponent("parakeet-tdt-0.6b-v3/Encoder.mlmodelc/data.bin"), bytes: 17)
        writeTestFile(whisper.appendingPathComponent("openai_whisper-large-v3-v20240930_turbo_632MB/model.bin"), bytes: 23)

        let snapshot = ModelCacheInventory.snapshot(
            fluidAudioModelsDirectory: fluid,
            transcriptedCacheDirectory: transcriptedCache,
            whisperModelsDirectory: whisper
        )

        assertEqual(snapshot.fluidAudioModelsBytes, 28, "FluidAudio total should include active and known stale model files")
        assertEqual(snapshot.transcriptedCacheBytes, 23, "Transcripted cache should include Whisper model files")
        assertEqual(snapshot.whisperModelsBytes, 23, "Whisper total should be broken out separately")
        assertEqual(snapshot.staleFluidAudioModelBytes, 17, "known stale Parakeet v3 non-CoreML cache should be counted")
        assertEqual(snapshot.staleFluidAudioModelNames, ["parakeet-tdt-0.6b-v3"], "known stale model names should be stable and sorted")
        assertEqual(snapshot.reclaimableBytes(includeWhisper: false), 17, "reclaimable total without Whisper should include stale models only")
        assertEqual(snapshot.reclaimableBytes(includeWhisper: true), 40, "reclaimable total with Whisper should include stale and optional Whisper models")
    }

    runSuite("ModelCacheInventory active Parakeet cache requires complete CoreML files") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCacheInventoryTests-\(UUID().uuidString)", isDirectory: true)
        let fluid = root.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        let active = fluid.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        assertNil(
            ModelCacheInventory.activeParakeetModelDirectory(fluidAudioModelsDirectory: fluid),
            "missing active Parakeet cache should not be treated as cached"
        )

        writeTestFile(active.appendingPathComponent("Encoder.mlmodelc/coremldata.bin"), bytes: 11)
        writeTestFile(active.appendingPathComponent("JointDecision.mlmodelc/coremldata.bin"), bytes: 11)
        writeTestFile(active.appendingPathComponent("Decoder.mlmodelc/coremldata.bin"), bytes: 11)
        writeTestFile(active.appendingPathComponent("Preprocessor.mlmodelc/coremldata.bin"), bytes: 11)
        writeTestFile(active.appendingPathComponent("config.json"), bytes: 2)
        writeTestFile(active.appendingPathComponent("parakeet_v3_vocab.json"), bytes: 2)
        writeTestFile(active.appendingPathComponent("parakeet_vocab.json"), bytes: 2)

        assertEqual(
            ModelCacheInventory.activeParakeetModelDirectory(fluidAudioModelsDirectory: fluid)?.path,
            active.standardizedFileURL.path,
            "complete active Parakeet cache should be reusable without showing a new download"
        )
    }

    runSuite("ModelCacheInventory diagnostics avoid raw paths") {
        let snapshot = ModelCacheSnapshot(
            fluidAudioModelsBytes: 10,
            transcriptedCacheBytes: 20,
            whisperModelsBytes: 5,
            staleFluidAudioModelBytes: 7,
            staleFluidAudioModelNames: ["parakeet-tdt-0.6b-v2-coreml"]
        )

        let fields = snapshot.diagnosticsFields

        assertEqual(fields["known_stale_model_count"], "1", "diagnostics should expose stale model count")
        assertEqual(fields["known_stale_models"], "parakeet-tdt-0.6b-v2-coreml", "diagnostics should name coarse model folders only")
        assertFalse(
            fields.values.contains { $0.contains("/Users/") || $0.contains("Application Support") },
            "model cache diagnostics should not include raw local paths"
        )
    }

    runSuite("ModelCacheInventory cleanup removes only known stale FluidAudio models") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCacheInventoryTests-\(UUID().uuidString)", isDirectory: true)
        let fluid = root.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let active = fluid.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml/Encoder.mlmodelc/data.bin")
        let stale = fluid.appendingPathComponent("parakeet-tdt-0.6b-v3/Encoder.mlmodelc/data.bin")
        let unknown = fluid.appendingPathComponent("some-other-model/model.bin")
        writeTestFile(active, bytes: 11)
        writeTestFile(stale, bytes: 17)
        writeTestFile(unknown, bytes: 19)

        let result = try? ModelCacheInventory.removeKnownStaleFluidAudioModels(
            fluidAudioModelsDirectory: fluid
        )

        assertEqual(result?.removedBytes, 17, "cleanup should report the stale directory size")
        assertEqual(result?.removedNames, ["parakeet-tdt-0.6b-v3"], "cleanup should name removed stale directories")
        assertTrue(FileManager.default.fileExists(atPath: active.path), "active CoreML Parakeet should stay")
        assertFalse(FileManager.default.fileExists(atPath: stale.path), "known stale Parakeet cache should be removed")
        assertTrue(FileManager.default.fileExists(atPath: unknown.path), "unknown model directories should not be touched")
    }

    runSuite("ModelCacheInventory cleanup removes only the Whisper models directory") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCacheInventoryTests-\(UUID().uuidString)", isDirectory: true)
        let whisperRoot = root.appendingPathComponent("cache/whisperkit", isDirectory: true)
        let whisperModels = whisperRoot.appendingPathComponent("models", isDirectory: true)
        let unrelatedCacheFile = whisperRoot.appendingPathComponent("state.json", isDirectory: false)
        defer { try? FileManager.default.removeItem(at: root) }

        writeTestFile(whisperModels.appendingPathComponent("openai_whisper-large-v3-v20240930_626MB/model.bin"), bytes: 31)
        writeTestFile(unrelatedCacheFile, bytes: 11)

        let result = try? ModelCacheInventory.removeWhisperModels(
            transcriptedCacheDirectory: root.appendingPathComponent("cache", isDirectory: true),
            whisperModelsDirectory: whisperModels
        )

        assertEqual(result?.removedBytes, 31, "cleanup should report the Whisper models directory size")
        assertEqual(result?.removedNames, ["Whisper cache"], "cleanup should name the removed cache")
        assertFalse(FileManager.default.fileExists(atPath: whisperModels.path), "Whisper models directory should be removed")
        assertTrue(FileManager.default.fileExists(atPath: unrelatedCacheFile.path), "non-model Whisper cache files should stay")
    }

    runSuite("ModelCacheInventory combined cleanup removes stale models and optional Whisper") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCacheInventoryTests-\(UUID().uuidString)", isDirectory: true)
        let fluid = root.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        let whisperRoot = root.appendingPathComponent("cache/whisperkit", isDirectory: true)
        let whisperModels = whisperRoot.appendingPathComponent("models", isDirectory: true)
        let active = fluid.appendingPathComponent("parakeet-tdt-0.6b-v3-coreml/Encoder.mlmodelc/data.bin")
        let stale = fluid.appendingPathComponent("parakeet-tdt-0.6b-v3/Encoder.mlmodelc/data.bin")
        let whisper = whisperModels.appendingPathComponent("openai_whisper-large-v3-v20240930_626MB/model.bin")
        defer { try? FileManager.default.removeItem(at: root) }

        writeTestFile(active, bytes: 11)
        writeTestFile(stale, bytes: 17)
        writeTestFile(whisper, bytes: 23)

        let result = try? ModelCacheInventory.removeReclaimableCaches(
            includeWhisper: true,
            fluidAudioModelsDirectory: fluid,
            transcriptedCacheDirectory: root.appendingPathComponent("cache", isDirectory: true),
            whisperModelsDirectory: whisperModels
        )

        assertEqual(result?.removedBytes, 40, "combined cleanup should report stale plus Whisper model bytes")
        assertEqual(result?.removedNames, ["parakeet-tdt-0.6b-v3", "Whisper cache"], "combined cleanup should name every removed cache")
        assertTrue(FileManager.default.fileExists(atPath: active.path), "combined cleanup should keep active Parakeet")
        assertFalse(FileManager.default.fileExists(atPath: stale.path), "combined cleanup should remove stale Parakeet")
        assertFalse(FileManager.default.fileExists(atPath: whisperModels.path), "combined cleanup should remove optional Whisper models")
    }

    runSuite("ModelCacheInventory combined cleanup can preserve Whisper") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCacheInventoryTests-\(UUID().uuidString)", isDirectory: true)
        let fluid = root.appendingPathComponent("FluidAudio/Models", isDirectory: true)
        let whisperModels = root.appendingPathComponent("cache/whisperkit/models", isDirectory: true)
        let stale = fluid.appendingPathComponent("parakeet-tdt-0.6b-v3/Encoder.mlmodelc/data.bin")
        let whisper = whisperModels.appendingPathComponent("openai_whisper-large-v3-v20240930_626MB/model.bin")
        defer { try? FileManager.default.removeItem(at: root) }

        writeTestFile(stale, bytes: 17)
        writeTestFile(whisper, bytes: 23)

        let result = try? ModelCacheInventory.removeReclaimableCaches(
            includeWhisper: false,
            fluidAudioModelsDirectory: fluid,
            whisperModelsDirectory: whisperModels
        )

        assertEqual(result?.removedBytes, 17, "combined cleanup should remove only stale models when Whisper is excluded")
        assertEqual(result?.removedNames, ["parakeet-tdt-0.6b-v3"], "combined cleanup should not name preserved Whisper")
        assertFalse(FileManager.default.fileExists(atPath: stale.path), "stale Parakeet should be removed")
        assertTrue(FileManager.default.fileExists(atPath: whisper.path), "Whisper should stay when excluded")
    }

    runSuite("ModelCacheInventory cleanup refuses non-Whisper model paths") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCacheInventoryTests-\(UUID().uuidString)", isDirectory: true)
        let nonWhisperModels = root.appendingPathComponent("other/models", isDirectory: true)
        let modelFile = nonWhisperModels.appendingPathComponent("model.bin")
        defer { try? FileManager.default.removeItem(at: root) }

        writeTestFile(modelFile, bytes: 31)

        let result = try? ModelCacheInventory.removeWhisperModels(
            transcriptedCacheDirectory: root.appendingPathComponent("cache", isDirectory: true),
            whisperModelsDirectory: nonWhisperModels
        )

        assertEqual(result?.removedBytes, 0, "cleanup should refuse model folders outside whisperkit")
        assertTrue(FileManager.default.fileExists(atPath: modelFile.path), "non-Whisper model paths should stay untouched")
    }

    runSuite("ModelCacheInventory cleanup refuses Whisper symlink escapes") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCacheInventoryTests-\(UUID().uuidString)", isDirectory: true)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        let cacheWhisperKit = cache.appendingPathComponent("whisperkit", isDirectory: true)
        let outsideWhisperKit = root.appendingPathComponent("outside/whisperkit", isDirectory: true)
        let outsideModelFile = outsideWhisperKit
            .appendingPathComponent("models/openai_whisper-large-v3-v20240930_626MB/model.bin")
        let symlinkedWhisperModels = cacheWhisperKit.appendingPathComponent("models", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        writeTestFile(outsideModelFile, bytes: 31)
        try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(
            at: cacheWhisperKit,
            withDestinationURL: outsideWhisperKit
        )

        let result = try? ModelCacheInventory.removeWhisperModels(
            transcriptedCacheDirectory: cache,
            whisperModelsDirectory: symlinkedWhisperModels
        )

        assertEqual(result?.removedBytes, 0, "cleanup should refuse symlinked Whisper cache paths")
        assertTrue(FileManager.default.fileExists(atPath: outsideModelFile.path), "symlink targets outside the app cache must stay untouched")
        assertTrue(FileManager.default.fileExists(atPath: cacheWhisperKit.path), "cleanup should not remove the symlink escape")
    }

    runSuite("ModelCacheInventory cleanup refuses symlinked cache roots") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCacheInventoryTests-\(UUID().uuidString)", isDirectory: true)
        let cacheLink = root.appendingPathComponent("cache", isDirectory: true)
        let outsideCache = root.appendingPathComponent("outside-cache", isDirectory: true)
        let outsideModelFile = outsideCache
            .appendingPathComponent("whisperkit/models/openai_whisper-large-v3-v20240930_626MB/model.bin")
        let symlinkedWhisperModels = cacheLink.appendingPathComponent("whisperkit/models", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        writeTestFile(outsideModelFile, bytes: 31)
        try? FileManager.default.createSymbolicLink(
            at: cacheLink,
            withDestinationURL: outsideCache
        )

        let result = try? ModelCacheInventory.removeWhisperModels(
            transcriptedCacheDirectory: cacheLink,
            whisperModelsDirectory: symlinkedWhisperModels
        )

        assertEqual(result?.removedBytes, 0, "cleanup should refuse a symlinked Transcripted cache root")
        assertTrue(FileManager.default.fileExists(atPath: outsideModelFile.path), "symlinked cache targets outside the app cache must stay untouched")
        assertTrue(FileManager.default.fileExists(atPath: cacheLink.path), "cleanup should not remove the cache-root symlink")
    }
}

private func writeTestFile(_ url: URL, bytes: Int) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 1, count: bytes))
}
