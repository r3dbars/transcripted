@preconcurrency import CoreML
import FluidAudio
import Foundation
import TranscriptedCore

/// Loads a script-installed Parakeet model (Parakeet Ultra) straight from its
/// folder with the same per-model compute units FluidAudio uses for v3.
/// Unlike `AsrModels.load`, there is no recovery path: a broken install
/// throws `ParakeetLocalModelError.loadFailed` and stays on disk untouched,
/// and nothing is ever downloaded.
enum ParakeetLocalModelLoader {
    static func load(from directory: URL, encoderComputeUnits: MLComputeUnits?) async throws -> AsrModels {
        do {
            // Core ML compiles for the Neural Engine synchronously; keep it off
            // the caller's actor.
            return try await Task.detached(priority: .userInitiated) {
                try loadModels(from: directory, encoderComputeUnits: encoderComputeUnits)
            }.value
        } catch {
            AppLogger.transcription.warning("PARAKEET | local model files didn't load: \(error.localizedDescription)")
            throw ParakeetLocalModelError.loadFailed
        }
    }

    private static func loadModels(from directory: URL, encoderComputeUnits: MLComputeUnits?) throws -> AsrModels {
        let configuration = AsrModels.defaultConfiguration()
        // Preprocessor ops run on the CPU in FluidAudio too; the rest default
        // to the configuration's CPU + Neural Engine.
        let preprocessor = try model(ParakeetLocalModelPolicy.preprocessorFileName, in: directory, computeUnits: .cpuOnly)
        let encoder = try model(
            ParakeetLocalModelPolicy.encoderFileName,
            in: directory,
            computeUnits: encoderComputeUnits ?? configuration.computeUnits
        )
        let decoder = try model(ParakeetLocalModelPolicy.decoderFileName, in: directory, computeUnits: configuration.computeUnits)
        let joint = try model(ParakeetLocalModelPolicy.jointFileName, in: directory, computeUnits: configuration.computeUnits)
        let vocabulary = try ParakeetLocalModelPolicy.parseVocabulary(
            Data(contentsOf: directory.appendingPathComponent(ParakeetLocalModelPolicy.vocabularyFileName))
        )
        return AsrModels(
            encoder: encoder,
            preprocessor: preprocessor,
            decoder: decoder,
            joint: joint,
            configuration: configuration,
            vocabulary: vocabulary,
            version: .v3
        )
    }

    private static func model(_ fileName: String, in directory: URL, computeUnits: MLComputeUnits) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        configuration.allowLowPrecisionAccumulationOnGPU = true
        return try MLModel(
            contentsOf: directory.appendingPathComponent(fileName, isDirectory: true),
            configuration: configuration
        )
    }
}
