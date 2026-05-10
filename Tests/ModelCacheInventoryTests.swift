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

        let result = try? ModelCacheInventory.removeWhisperModels(whisperModelsDirectory: whisperModels)

        assertEqual(result?.removedBytes, 31, "cleanup should report the Whisper models directory size")
        assertEqual(result?.removedNames, ["Whisper cache"], "cleanup should name the removed cache")
        assertFalse(FileManager.default.fileExists(atPath: whisperModels.path), "Whisper models directory should be removed")
        assertTrue(FileManager.default.fileExists(atPath: unrelatedCacheFile.path), "non-model Whisper cache files should stay")
    }

    runSuite("ModelCacheInventory cleanup refuses non-Whisper model paths") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelCacheInventoryTests-\(UUID().uuidString)", isDirectory: true)
        let nonWhisperModels = root.appendingPathComponent("other/models", isDirectory: true)
        let modelFile = nonWhisperModels.appendingPathComponent("model.bin")
        defer { try? FileManager.default.removeItem(at: root) }

        writeTestFile(modelFile, bytes: 31)

        let result = try? ModelCacheInventory.removeWhisperModels(whisperModelsDirectory: nonWhisperModels)

        assertEqual(result?.removedBytes, 0, "cleanup should refuse model folders outside whisperkit")
        assertTrue(FileManager.default.fileExists(atPath: modelFile.path), "non-Whisper model paths should stay untouched")
    }
}

private func writeTestFile(_ url: URL, bytes: Int) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 1, count: bytes))
}
