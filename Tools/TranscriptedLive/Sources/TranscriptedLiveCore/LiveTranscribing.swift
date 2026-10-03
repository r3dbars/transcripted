import Foundation

/// What LiveRunner needs from one speaker's transcriber. `StreamTranscriber` is
/// the real one; tests pass fakes so the watch loop runs without the models.
protocol LiveTranscribing: Sendable {
    var speaker: String { get }
    func load() async throws
    func feed(_ samples: [Float], sampleRate: Double, startSeconds: Double) async throws -> [LiveUtterance]
    func partialText() async -> String
    func flush(atSeconds seconds: Double) async throws -> [LiveUtterance]
}

extension StreamTranscriber: LiveTranscribing {}
