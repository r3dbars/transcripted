import Foundation
#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Seam for the sentence-embedding model behind semantic search.
///
/// Production uses Apple's on-device `NLEmbedding` sentence model (ships with
/// macOS — no download, no bundled weights, nothing leaves the machine). Tests
/// inject a deterministic provider so retrieval mechanics can be proven without
/// depending on model availability or exact vector values.
protocol SemanticTextEmbedding {
    /// False when the underlying model cannot be loaded; the index then skips
    /// semantic rows entirely and the tool reports itself unavailable.
    var isAvailable: Bool { get }
    /// Vector length this provider produces. Stored rows whose blob length
    /// disagrees with the active provider are skipped at query time.
    var dimension: Int { get }
    /// L2-normalized embedding, or nil when the text cannot be embedded.
    func normalizedVector(for text: String) -> [Float]?
}

/// Apple NaturalLanguage sentence embedding (English). `available` is false on
/// systems where the model asset is missing; the index then skips semantic
/// rows and the tool reports itself unavailable instead of failing indexing.
struct AppleSentenceEmbedding: SemanticTextEmbedding {
    #if canImport(NaturalLanguage)
    private let embedding: NLEmbedding?

    init() {
        self.embedding = NLEmbedding.sentenceEmbedding(for: .english)
    }

    var isAvailable: Bool { embedding != nil }
    var dimension: Int { embedding?.dimension ?? 0 }

    func normalizedVector(for text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let raw = embedding?.vector(for: trimmed) else { return nil }
        return SemanticVectorCodec.normalize(raw.map(Float.init))
    }
    #else
    var isAvailable: Bool { false }
    var dimension: Int { 0 }
    func normalizedVector(for text: String) -> [Float]? { nil }
    #endif
}

/// Packs normalized Float32 vectors into SQLite blobs. Written and read on the
/// same machine, so native byte order is fine.
enum SemanticVectorCodec {
    static func normalize(_ vector: [Float]) -> [Float]? {
        let magnitude = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard magnitude.isFinite, magnitude > 0 else { return nil }
        return vector.map { $0 / magnitude }
    }

    static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data) -> [Float] {
        guard data.count % MemoryLayout<Float>.size == 0 else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Dot product of two same-length normalized vectors == cosine similarity.
    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var total: Float = 0
        for index in lhs.indices {
            total += lhs[index] * rhs[index]
        }
        return total
    }
}

/// Groups consecutive utterances into embedding-sized chunks. One vector per
/// utterance is wasteful and one per meeting is useless; a few sentences of
/// context per vector is where sentence embeddings retrieve best.
enum SemanticChunker {
    static let maxChunkCharacters = 400

    static func chunks(from texts: [String], maxCharacters: Int = maxChunkCharacters) -> [String] {
        var chunks: [String] = []
        var current = ""

        for raw in texts {
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            if current.isEmpty {
                current = text
            } else if current.count + text.count + 1 <= maxCharacters {
                current += " " + text
            } else {
                chunks.append(current)
                current = text
            }

            // A single oversized utterance still becomes its own chunk, capped
            // so one rambling monologue can't dominate the embedding budget.
            if current.count > maxCharacters {
                chunks.append(String(current.prefix(maxCharacters)))
                current = ""
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }
}
