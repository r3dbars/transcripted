#if TRANSCRIPTEDCLI_WITH_MEETING_IMPORT && canImport(TranscriptedCore)
import Foundation
import XCTest
import TranscriptedCore
@testable import transcripted_cli

/// Promises of `import-audio`'s diarization engine:
///   - `--diarization-engine app` (the default) picks the same engine the app
///     uses: Nemotron when nothing is set, the app's stored preference, or
///     `TRANSCRIPTED_DIARIZATION_BACKEND`;
///   - an explicit `nemotron` or `pyannote` wins over that;
///   - the bundle provider hands Nemotron its own folder, so a pyannote path
///     cannot make Nemotron fail-and-fall-back.
final class MeetingImportDiarizationTests: XCTestCase {
    func testAppChoiceDefaultsToTheAppNemotronEngine() throws {
        XCTAssertEqual(MeetingImportDiarization.hostDefault, .nemotron)
        XCTAssertEqual(
            try MeetingImportDiarization.backend(choice: "app", environment: [:], appDefaults: nil),
            .nemotron
        )
        XCTAssertEqual(
            MeetingImportDiarization.preferenceKey,
            DiarizationBackend.preferenceKey
        )
        XCTAssertEqual(
            MeetingImportDiarization.environmentKey,
            DiarizationBackend.environmentKey
        )
    }

    func testAppChoiceHonorsTheStoredPreferenceAndEnvironment() throws {
        let storedPyannote: [String: Any] = [MeetingImportDiarization.preferenceKey: "pyannote"]
        XCTAssertEqual(
            try MeetingImportDiarization.backend(choice: "app", environment: [:], appDefaults: storedPyannote),
            .pyannote
        )
        XCTAssertEqual(
            try MeetingImportDiarization.backend(
                choice: "app",
                environment: [MeetingImportDiarization.environmentKey: "NEMOTRON"],
                appDefaults: storedPyannote
            ),
            .nemotron,
            "env wins over the stored preference, like the app"
        )
        XCTAssertEqual(
            try MeetingImportDiarization.backend(
                choice: "app",
                environment: [MeetingImportDiarization.environmentKey: "garbage"],
                appDefaults: nil
            ),
            .nemotron,
            "garbage env falls through to the app default"
        )
    }

    func testExplicitEngineOverridesTheAppChoice() throws {
        let storedPyannote: [String: Any] = [MeetingImportDiarization.preferenceKey: "pyannote"]
        let envNemotron = [MeetingImportDiarization.environmentKey: "nemotron"]
        XCTAssertEqual(
            try MeetingImportDiarization.backend(
                choice: "pyannote", environment: envNemotron, appDefaults: [MeetingImportDiarization.preferenceKey: "nemotron"]
            ),
            .pyannote
        )
        XCTAssertEqual(
            try MeetingImportDiarization.backend(choice: "nemotron", environment: [:], appDefaults: storedPyannote),
            .nemotron
        )
    }

    func testUnknownEngineIsAClearErrorInsteadOfSilentNemotron() {
        XCTAssertThrowsError(
            try MeetingImportDiarization.backend(choice: "sortformer", environment: [:], appDefaults: nil)
        ) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(message.contains("sortformer"), message)
            XCTAssertFalse(message.contains("falling back"), message)
        }
    }

    func testBundleProviderDoesNotHandThePyannoteFolderToNemotron() {
        let pyannote = URL(fileURLWithPath: "/tmp/offline-diarizer-models")
        let nemotron = URL(fileURLWithPath: "/tmp/nemotron-diarizer-models")
        let provider = MeetingImportDiarization.bundleProvider(pyannote: pyannote, nemotron: nemotron)
        XCTAssertEqual(provider("offline-diarizer-models"), pyannote)
        XCTAssertEqual(provider("nemotron-diarizer-models"), nemotron)
        XCTAssertNil(provider("online-diarizer-models"))
        XCTAssertNil(provider("eres2net-embedding"))
        let online = URL(fileURLWithPath: "/tmp/online-diarizer-models")
        let withOnline = MeetingImportDiarization.bundleProvider(
            pyannote: pyannote, nemotron: nemotron, onlineWeSpeaker: online
        )
        XCTAssertEqual(withOnline("online-diarizer-models"), online)
    }

    func testBundledNemotronUsesTheFlatAppLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-nemotron-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("Relocated.app/Contents/Resources")
        let bundle = resources.appendingPathComponent("nemotron-diarizer-models", isDirectory: true)
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Nemotron3Diarizer_fast128.mlmodelc"),
            withIntermediateDirectories: true
        )
        try Data().write(to: bundle.appendingPathComponent("learnable_sil_emb.bin"))
        XCTAssertEqual(MeetingImportModels.bundledNemotronModels(in: [resources]), bundle)
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("learnable_sil_emb.bin"))
        XCTAssertNil(MeetingImportModels.bundledNemotronModels(in: [resources]))
    }

    func testBundleProviderReturnsNilWhenNemotronIsNotLocal() {
        let pyannote = URL(fileURLWithPath: "/tmp/offline-diarizer-models")
        let provider = MeetingImportDiarization.bundleProvider(pyannote: pyannote, nemotron: nil)
        XCTAssertEqual(provider("offline-diarizer-models"), pyannote)
        XCTAssertNil(provider("nemotron-diarizer-models"),
                     "nil means cache-or-download, not 'load Nemotron from the pyannote folder'")
    }

    func testCachedNemotronFindsTheFluidAudioMonolithicLayout() throws {
        XCTAssertEqual(
            MeetingImportModels.defaultNemotronCacheDirectory(
                homeDirectory: URL(fileURLWithPath: "/tmp/fake-home", isDirectory: true)
            ).path,
            "/tmp/fake-home/Library/Application Support/FluidAudio/Models/nemotron-3-diarization"
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-nemotron-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent(MeetingImportModels.nemotronCacheRelativePath, isDirectory: true)
        XCTAssertNil(MeetingImportModels.cachedNemotronModels(at: cache))

        try FileManager.default.createDirectory(
            at: cache.appendingPathComponent("monolithic/Nemotron3Diarizer_fast128.mlmodelc"),
            withIntermediateDirectories: true
        )
        XCTAssertNil(MeetingImportModels.cachedNemotronModels(at: cache), "model without silence is incomplete")
        try Data().write(to: cache.appendingPathComponent("learnable_sil_emb.bin"))
        XCTAssertNil(MeetingImportModels.cachedNemotronModels(at: cache), "model without FluidAudio marker is incomplete")
        try writeNemotronCacheMarker(at: cache)
        XCTAssertEqual(MeetingImportModels.cachedNemotronModels(at: cache), cache)

        let resolved = MeetingImportModels.resolveNemotronPaths(
            bundledResourceDirectories: [root.appendingPathComponent("empty-resources")],
            cacheDirectory: cache
        )
        XCTAssertNil(resolved.bundled, "cache is not a bundle directory")
        XCTAssertEqual(resolved.cache, cache)
    }

    func testCachedNemotronAlsoAcceptsAFlatCacheCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-nemotron-flat-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Nemotron3Diarizer_fast128.mlmodelc"),
            withIntermediateDirectories: true
        )
        try Data().write(to: root.appendingPathComponent("learnable_sil_emb.bin"))
        XCTAssertNil(MeetingImportModels.cachedNemotronModels(at: root), "flat cache still needs the FluidAudio marker")
        try writeNemotronCacheMarker(at: root)
        XCTAssertEqual(MeetingImportModels.cachedNemotronModels(at: root), root)
    }

    func testCachedNemotronFindsTheProvisionedVersionedLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-nemotron-v2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent(MeetingImportModels.nemotronCacheRelativePath, isDirectory: true)
        // Exact layout from scripts/release/provision-release-models.sh:
        //   monolithic/v2/Nemotron3Diarizer_fast128.mlmodelc
        //   learnable_sil_emb.bin
        //   .fluidaudio-nemotron3-weights
        try FileManager.default.createDirectory(
            at: cache.appendingPathComponent("monolithic/v2/Nemotron3Diarizer_fast128.mlmodelc", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertNil(MeetingImportModels.cachedNemotronModels(at: cache), "versioned model without silence is incomplete")
        try Data().write(to: cache.appendingPathComponent(MeetingImportModels.nemotronCacheSilenceName))
        XCTAssertNil(MeetingImportModels.cachedNemotronModels(at: cache), "provisioned model without marker is incomplete")
        try writeNemotronCacheMarker(at: cache, contents: "stale-version\n")
        XCTAssertNil(MeetingImportModels.cachedNemotronModels(at: cache), "wrong weights version is not local")
        try writeNemotronCacheMarker(at: cache)
        XCTAssertEqual(MeetingImportModels.cachedNemotronModels(at: cache), cache)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: cache.appendingPathComponent("monolithic/Nemotron3Diarizer_fast128.mlmodelc").path
            ),
            "the provisioned cache has no unversioned monolithic/ model"
        )
    }

    func testImportAudioModelsDirHonorsNemotronLikeDiarizeAndBatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-models-dir-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let modelsDir = root.appendingPathComponent("nemotron-models", isDirectory: true)
        try writeNemotronFixture(at: modelsDir)
        let found = MeetingImportModels.diarizationModelsFromDirectory(modelsDir)
        XCTAssertEqual(found.nemotron, modelsDir)
        XCTAssertNil(found.pyannote)

        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let paths = try MeetingImportModels.resolve(
            modelsDir: modelsDir.path,
            diarizationModelsDir: nil,
            noDownload: false,
            engineChoice: "nemotron",
            environment: [:],
            storedPreference: nil,
            bundledResourceDirectories: [empty],
            homeDirectory: empty
        )
        XCTAssertEqual(paths.nemotron?.path, modelsDir.path)
        XCTAssertTrue(paths.nemotronAvailable)
        XCTAssertNil(paths.diarization, "a Nemotron --models-dir does not invent pyannote")
    }

    func testNemotronDefaultPathFromFlagsThroughModelsAndJSON() throws {
        XCTAssertEqual(try ImportAudio.parse(["memo.wav"]).diarizationEngine, "app")
        XCTAssertEqual(try Diarize.parse(["memo.wav"]).diarizationEngine, "app")
        XCTAssertEqual(try Batch.parse(["clips"]).diarizationEngine, "app")
        XCTAssertEqual(
            try CLIDiarization.resolvedEngine(choice: "app", environment: [:], storedPreference: nil),
            "nemotron"
        )
        let runnable = try CLIDiarization.runnableEngine(
            choice: "app", environment: [:], storedPreference: nil, nemotronAvailable: true
        )
        XCTAssertEqual(runnable.engine, "nemotron")
        XCTAssertNil(runnable.fallbackNote)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-nemotron-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let modelsDir = root.appendingPathComponent("nemotron-models", isDirectory: true)
        try writeNemotronFixture(at: modelsDir)
        let empty = root.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let paths = try MeetingImportModels.resolve(
            modelsDir: modelsDir.path,
            diarizationModelsDir: nil,
            noDownload: false,
            engineChoice: "app",
            environment: [:],
            storedPreference: nil,
            bundledResourceDirectories: [empty],
            homeDirectory: empty
        )
        XCTAssertEqual(paths.nemotron?.path, modelsDir.path)
        XCTAssertTrue(paths.nemotronAvailable)
        XCTAssertNil(try MeetingImportModels.noDownloadError(
            parakeet: URL(fileURLWithPath: "/parakeet"),
            diarization: paths.diarization,
            nemotronAvailable: paths.nemotronAvailable,
            engineChoice: "app"
        ))

        let loaded = try CLIDiarization.acceptLoadedEngine(
            requested: "nemotron", actual: "nemotron", choice: "app"
        )
        XCTAssertEqual(loaded.engine, "nemotron")
        XCTAssertNil(loaded.fallbackNote)

        let data = try DiarizeOutputBuilder.encode(
            DiarizeFileOutput(
                audioFile: "memo.wav",
                segments: [],
                speakerCount: 0,
                processingSeconds: 0.1,
                timings: .missing,
                engine: loaded.engine
            )
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["engine"] as? String, "nemotron")
        let existingTopLevel: Set<String> = [
            "audioFile", "segments", "speakerCount", "processingSeconds", "timings"
        ]
        XCTAssertEqual(existingTopLevel.subtracting(object.keys), [])
        XCTAssertNotNil(object["timings"] as? [String: Any])
    }

    func testNoDownloadChecksOnlyTheSelectedEngineModels() throws {
        let parakeet = URL(fileURLWithPath: "/tmp/parakeet")
        let pyannote = URL(fileURLWithPath: "/tmp/pyannote")

        XCTAssertNil(try MeetingImportModels.noDownloadError(
            parakeet: parakeet, diarization: nil, nemotronAvailable: true,
            engineChoice: "nemotron"
        ), "Nemotron does not need pyannote")
        XCTAssertNotNil(try MeetingImportModels.noDownloadError(
            parakeet: parakeet, diarization: nil, nemotronAvailable: true,
            engineChoice: "pyannote"
        ), "pyannote still needs its own models")
        XCTAssertNil(try MeetingImportModels.noDownloadError(
            parakeet: parakeet, diarization: pyannote, nemotronAvailable: false,
            engineChoice: "pyannote"
        ), "pyannote does not need Nemotron")

        XCTAssertNotNil(try MeetingImportModels.noDownloadError(
            parakeet: parakeet, diarization: pyannote, nemotronAvailable: false,
            engineChoice: "nemotron"
        ), "explicit Nemotron cannot borrow pyannote")
        XCTAssertNil(try MeetingImportModels.noDownloadError(
            parakeet: parakeet, diarization: pyannote, nemotronAvailable: false,
            engineChoice: "app"
        ), "default app path may fall back to local pyannote")
        XCTAssertNil(try MeetingImportModels.noDownloadError(
            parakeet: parakeet, diarization: nil, nemotronAvailable: true,
            engineChoice: "app"
        ))

        let neither = try MeetingImportModels.noDownloadError(
            parakeet: parakeet, diarization: nil, nemotronAvailable: false,
            engineChoice: "app"
        )
        XCTAssertNotNil(neither)
        let missingParakeet = try MeetingImportModels.noDownloadError(
            parakeet: nil, diarization: pyannote, nemotronAvailable: true,
            engineChoice: "nemotron"
        )
        XCTAssertNotNil(missingParakeet)
        let message = String(describing: missingParakeet!)
        XCTAssertTrue(message.contains("Parakeet"), message)
        XCTAssertFalse(message.contains("AND offline"), message)
    }

    func testNoDownloadUsesTheResolvedAppEngineNotAlwaysNemotron() throws {
        let parakeet = URL(fileURLWithPath: "/tmp/parakeet")
        XCTAssertNotNil(try MeetingImportModels.noDownloadError(
            parakeet: parakeet, diarization: nil, nemotronAvailable: true,
            engineChoice: "app", storedPreference: "pyannote"
        ), "app + saved pyannote must require pyannote even when Nemotron is local")
        XCTAssertNil(try MeetingImportModels.noDownloadError(
            parakeet: parakeet, diarization: URL(fileURLWithPath: "/tmp/pyannote"),
            nemotronAvailable: false, engineChoice: "app", storedPreference: "pyannote"
        ))
        XCTAssertNil(try MeetingImportModels.noDownloadError(
            parakeet: parakeet, diarization: nil, nemotronAvailable: true,
            engineChoice: "app", storedPreference: nil
        ), "app with no saved preference still uses Nemotron")
    }

    func testNoDownloadBlocksPyannoteFallbackDownload() {
        XCTAssertFalse(
            DiarizationService.canLoadPyannote(hasLocalBundle: false, allowDownload: false)
        )
        XCTAssertTrue(
            DiarizationService.canLoadPyannote(hasLocalBundle: true, allowDownload: false)
        )
    }

    func testNoDownloadPassesCacheOnlyNemotronAsALocalBundle() throws {
        let cache = URL(fileURLWithPath: "/tmp/nemotron-3-diarization", isDirectory: true)
        let bundled = URL(fileURLWithPath: "/tmp/nemotron-diarizer-models", isDirectory: true)

        XCTAssertEqual(
            MeetingImportModels.localNemotronDirectoryForLoad(
                bundled: nil, cache: cache, allowDownload: false
            ),
            cache,
            "a downloaded cache is a local load directory under --no-download"
        )
        XCTAssertNil(
            MeetingImportModels.localNemotronDirectoryForLoad(
                bundled: nil, cache: cache, allowDownload: true
            ),
            "downloads still go through HuggingFace when allowed"
        )
        XCTAssertEqual(
            MeetingImportModels.localNemotronDirectoryForLoad(
                bundled: bundled, cache: cache, allowDownload: false
            ),
            bundled
        )

        let local = MeetingImportModels.localNemotronDirectoryForLoad(
            bundled: nil, cache: cache, allowDownload: false
        )
        let provider = MeetingImportDiarization.bundleProvider(pyannote: nil, nemotron: local)
        XCTAssertEqual(provider("nemotron-diarizer-models"), cache)
        XCTAssertFalse(
            DiarizationService.nemotronUsesHuggingFaceLoader(
                hasLocalBundle: local != nil, allowDownload: false
            ),
            "cache-only --no-download must not call loadFromHuggingFace"
        )
    }

    func testNoDownloadRequiresTheResolvedNemotronPreset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-nemotron-preset-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent(MeetingImportModels.nemotronCacheRelativePath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: cache.appendingPathComponent("monolithic/v2/Nemotron3Diarizer_fast128.mlmodelc", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data().write(to: cache.appendingPathComponent(MeetingImportModels.nemotronCacheSilenceName))
        try writeNemotronCacheMarker(at: cache)

        let fast32 = ["TRANSCRIPTED_NEMOTRON_PRESET": "fast32"]
        XCTAssertEqual(MeetingImportModels.cachedNemotronModels(at: cache), cache)
        XCTAssertNil(
            MeetingImportModels.cachedNemotronModels(at: cache, environment: fast32),
            "a fast128 cache is not enough for TRANSCRIPTED_NEMOTRON_PRESET=fast32"
        )
        XCTAssertNil(MeetingImportModels.bundledNemotronModels(in: [root], environment: fast32))

        let parakeet = URL(fileURLWithPath: "/tmp/parakeet")
        XCTAssertNotNil(try MeetingImportModels.noDownloadError(
            parakeet: parakeet, diarization: nil,
            nemotronAvailable: MeetingImportModels.cachedNemotronModels(at: cache, environment: fast32) != nil,
            engineChoice: "nemotron", environment: fast32
        ), "--no-download must not treat a fast128 cache as the selected fast32 preset")

        try FileManager.default.createDirectory(
            at: cache.appendingPathComponent("monolithic/v2/Nemotron3Diarizer_fast32.mlmodelc", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(MeetingImportModels.cachedNemotronModels(at: cache, environment: fast32), cache)
        XCTAssertNil(try MeetingImportModels.noDownloadError(
            parakeet: parakeet, diarization: nil,
            nemotronAvailable: true, engineChoice: "nemotron", environment: fast32
        ))
    }

    func testCachedNemotronFindsTheSplitPresetLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cli-nemotron-split-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = root.appendingPathComponent(MeetingImportModels.nemotronCacheRelativePath, isDirectory: true)
        let published = cache.appendingPathComponent(
            "split/Nemotron3Diarizer_c128_split_w8a8.mlmodelc", isDirectory: true
        )
        try FileManager.default.createDirectory(at: published, withIntermediateDirectories: true)
        try Data().write(to: cache.appendingPathComponent(MeetingImportModels.nemotronCacheSilenceName))
        try writeNemotronCacheMarker(at: cache)
        XCTAssertNil(
            MeetingImportModels.cachedNemotronModels(at: cache, preset: "c128-split-w8a8"),
            "split preset without pre_encode_proj_t.bin is incomplete"
        )
        try Data().write(to: cache.appendingPathComponent(DiarizationBackend.nemotronProjectionFileName))
        XCTAssertEqual(
            MeetingImportModels.cachedNemotronModels(at: cache, preset: "c128-split-w8a8"),
            cache
        )

        try FileManager.default.createDirectory(
            at: cache.appendingPathComponent(
                "split/Nemotron3Diarizer_c128-split-w8a8.mlmodelc", isDirectory: true
            ),
            withIntermediateDirectories: true
        )
        try FileManager.default.removeItem(at: published)
        XCTAssertNil(
            MeetingImportModels.cachedNemotronModels(at: cache, preset: "c128-split-w8a8"),
            "the published cache uses Nemotron3Diarizer_c128_split_w8a8, not the hyphenated preset string"
        )

        try FileManager.default.createDirectory(
            at: cache.appendingPathComponent("split/Nemotron3Diarizer_s32_split_w8a8.mlmodelc", isDirectory: true),
            withIntermediateDirectories: true
        )
        XCTAssertEqual(
            MeetingImportModels.cachedNemotronModels(at: cache, preset: "fast32-split-w8a8"),
            cache,
            "fast32-split-w8a8 is published as s32_split_w8a8"
        )
        XCTAssertNil(
            MeetingImportModels.cachedNemotronModels(at: cache, preset: "fast128"),
            "a split cache is not the default fast128 layout"
        )
    }

    func testNoDownloadRequiresWeSpeakerAssetsWhenNemotronHasNoInjectedEmbedder() {
        XCTAssertNotNil(MeetingImportModels.noDownloadWeSpeakerError(
            engine: "nemotron", hasInjectedEmbedder: false,
            hasOfflineWeSpeaker: false, usesOnlineWeSpeaker: false, hasOnlineWeSpeaker: false
        ), "wespeaker + nemotron needs local FBank/Embedding")
        XCTAssertNil(MeetingImportModels.noDownloadWeSpeakerError(
            engine: "nemotron", hasInjectedEmbedder: false,
            hasOfflineWeSpeaker: true, usesOnlineWeSpeaker: false, hasOnlineWeSpeaker: false
        ))
        XCTAssertNil(MeetingImportModels.noDownloadWeSpeakerError(
            engine: "nemotron", hasInjectedEmbedder: true,
            hasOfflineWeSpeaker: false, usesOnlineWeSpeaker: false, hasOnlineWeSpeaker: false
        ), "an injected ReDimNet2 voiceprint does not need pyannote WeSpeaker")
        XCTAssertNil(MeetingImportModels.noDownloadWeSpeakerError(
            engine: "pyannote", hasInjectedEmbedder: false,
            hasOfflineWeSpeaker: false, usesOnlineWeSpeaker: false, hasOnlineWeSpeaker: false
        ))
    }

    func testNoDownloadBlocksOnlineWeSpeakerDownload() {
        XCTAssertNotNil(MeetingImportModels.noDownloadWeSpeakerError(
            engine: "nemotron", hasInjectedEmbedder: false,
            hasOfflineWeSpeaker: true, usesOnlineWeSpeaker: true, hasOnlineWeSpeaker: false
        ), "lab online WeSpeaker cannot download under --no-download")
        XCTAssertNil(MeetingImportModels.noDownloadWeSpeakerError(
            engine: "nemotron", hasInjectedEmbedder: false,
            hasOfflineWeSpeaker: false, usesOnlineWeSpeaker: true, hasOnlineWeSpeaker: true
        ))
        XCTAssertFalse(
            DiarizationService.canLoadWeSpeakerFallback(hasLocalBundle: false, allowDownload: false)
        )
    }

    private func writeNemotronFixture(at directory: URL, preset: String = "fast128") throws {
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(DiarizationBackend.nemotronModelFileName(preset: preset)),
            withIntermediateDirectories: true
        )
        try Data().write(to: directory.appendingPathComponent(MeetingImportModels.nemotronCacheSilenceName))
    }

    private func writeNemotronCacheMarker(
        at directory: URL,
        contents: String = DiarizationBackend.nemotronCacheWeightsVersion + "\n"
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contents.utf8).write(
            to: directory.appendingPathComponent(MeetingImportModels.nemotronCacheMarkerName)
        )
    }
}
#endif
