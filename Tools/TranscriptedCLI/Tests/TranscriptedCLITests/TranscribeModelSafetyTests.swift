#if TRANSCRIPTEDCLI_WITH_TRANSCRIPTION && canImport(FluidAudio)
import FluidAudio
import Foundation
import XCTest
@testable import transcripted_cli

final class TranscribeModelSafetyTests: XCTestCase {
    func testCorruptBundledModelsFailWithoutDeletingTheirBytes() async throws {
        for compiledDirectories in [false, true] {
            try await assertCorruptModelsPreserved(explicitDirectory: false, compiledDirectories: compiledDirectories)
        }
    }

    func testExplicitModelDirectoryKeepsItsExistingPreservationBehavior() async throws {
        for compiledDirectories in [false, true] {
            try await assertCorruptModelsPreserved(explicitDirectory: true, compiledDirectories: compiledDirectories)
        }
    }

    private func assertCorruptModelsPreserved(explicitDirectory: Bool, compiledDirectories: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("parakeet-tdt-0.6b-v3")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Complete layout but invalid Core ML contents: existence checks pass,
        // then the real loader throws. None of these fixture bytes may be lost.
        let names = ["Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc", "Preprocessor.mlmodelc", "parakeet_vocab.json", "parakeet_v3_vocab.json"]
        let bytes = Data("deliberately invalid fixture".utf8)
        let byteLocations = try names.map { name -> URL in
            let url = directory.appendingPathComponent(name)
            if compiledDirectories, name.hasSuffix(".mlmodelc") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                return url.appendingPathComponent("invalid-coreml.bin")
            }
            return url
        }
        for location in byteLocations { try bytes.write(to: location) }
        XCTAssertTrue(AsrModels.modelsExist(at: directory))
        let originalOfflineMode = ModelHub.offlineMode
        defer { ModelHub.offlineMode = originalOfflineMode }
        for wasOffline in [false, true] {
            ModelHub.offlineMode = wasOffline
            do {
                _ = try await TranscribeModelResolver.loadManager(
                    modelsDir: explicitDirectory ? directory.path : nil,
                    allowDownload: false,
                    log: { _ in },
                    bundledDirectories: explicitDirectory ? [] : [directory]
                )
                XCTFail("Corrupt models must report a load failure")
            } catch {
                XCTAssertEqual(ModelHub.offlineMode, wasOffline, "Restore the caller's mode after a load failure")
            }
            for location in byteLocations {
                XCTAssertEqual(try Data(contentsOf: location), bytes, "Failed load must preserve \(location.lastPathComponent)")
            }
        }
    }
}
#endif
