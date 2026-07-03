import Foundation
import NaturalLanguage

/// Which retrieval strategy a search runs.
///
/// - `lexical`  — the original SQLite FTS5 path (exact/stemmed token match).
/// - `semantic` — vector cosine match only (paraphrase recall).
/// - `hybrid`   — both, fused with reciprocal-rank fusion. Strict superset of
///                lexical recall, so it never drops an FTS hit.
enum SearchMode: String, Codable, Sendable {
    case lexical
    case semantic
    case hybrid
}

/// Produces dense vector embeddings for short text spans (meeting utterances,
/// dictation entries).
///
/// Pluggable on purpose: today the shipping backend is Apple's built-in
/// `NaturalLanguage` sentence embedding — zero bundle size, no model download,
/// fully on-device. A bundled CoreML model (e.g. a quantized MiniLM) can replace
/// it later without touching the vector store or the search path, by conforming
/// a new type to this protocol and wiring it in `Main.swift`.
protocol EmbeddingProvider: Sendable {
    /// Stable identifier for the embedding space. Changing it invalidates every
    /// stored vector so they get re-embedded against the new model.
    var modelID: String { get }

    /// Vector dimensionality, or 0 when the backend is unavailable on this host.
    var dimension: Int { get }

    /// Whether the backend can actually produce vectors right now.
    var isAvailable: Bool { get }

    /// Embed one text span. Returns nil for empty/unembeddable input or when the
    /// backend is unavailable. Returned vectors are L2-normalized so a dot
    /// product equals cosine similarity.
    func embed(_ text: String) -> [Float]?
}

extension EmbeddingProvider {
    var isAvailable: Bool { dimension > 0 }
}

/// Default on-device backend: Apple's `NLEmbedding` sentence embedding.
///
/// Built into macOS (no bundled model, no download, negligible incremental app
/// size, modest RAM). `sentenceEmbedding(for:)` returns nil when the OS has no
/// model assets for the language (e.g. some headless/CI images) — in that case
/// `isAvailable` is false and the index simply skips semantic indexing, leaving
/// lexical search fully functional.
final class NLEmbeddingProvider: EmbeddingProvider, @unchecked Sendable {
    let modelID: String
    private let embedding: NLEmbedding?
    // NLEmbedding is not documented as thread-safe; serialize vector() calls.
    private let lock = NSLock()

    init(language: NLLanguage = .english) {
        let model = NLEmbedding.sentenceEmbedding(for: language)
        self.embedding = model
        self.modelID = "nl.sentence.\(language.rawValue).v1"
    }

    var dimension: Int { embedding?.dimension ?? 0 }
    var isAvailable: Bool { embedding != nil }

    func embed(_ text: String) -> [Float]? {
        guard let embedding else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        lock.lock()
        let raw = embedding.vector(for: trimmed)
        lock.unlock()
        guard let raw, !raw.isEmpty else { return nil }
        return VectorMath.normalized(raw.map { Float($0) })
    }
}

/// Small float-vector helpers shared by the provider and the vector store.
enum VectorMath {
    /// L2-normalize a vector. A zero vector is returned unchanged.
    static func normalized(_ v: [Float]) -> [Float] {
        var sum: Float = 0
        for x in v { sum += x * x }
        let norm = sum.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    /// Dot product. For L2-normalized inputs this equals cosine similarity.
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        let n = min(a.count, b.count)
        var sum: Float = 0
        var i = 0
        while i < n {
            sum += a[i] * b[i]
            i += 1
        }
        return sum
    }

    /// Pack a vector into a Float32 blob for SQLite storage.
    static func blob(from v: [Float]) -> Data {
        v.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Unpack a Float32 blob back into a vector.
    static func vector(from data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.stride
        guard count > 0 else { return [] }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self).prefix(count))
        }
    }
}
