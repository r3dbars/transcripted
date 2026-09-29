import Foundation
import Testing
@testable import TranscriptedWritingCore

/// The labelled corpus in `Tests/Fixtures/writing-secret-corpus.json` is the
/// scrubber's measured bar: every secret not marked `knownMiss` is gone, and
/// every ordinary text not marked `knownFalsePositive` comes back byte for
/// byte. `scripts/dev/measure-writing-scrubber.sh` reports the same corpus
/// with the known misses and false positives counted, plus a sweep over the
/// repo's own docs, code, scripts and commit messages.
@Suite("Writing secret scrubber corpus")
struct WritingSecretCorpusTests {
    struct Corpus: Decodable {
        let secrets: [SecretCase]
        let ordinary: [OrdinaryCase]
    }

    struct SecretCase: Decodable, CustomTestStringConvertible {
        let category: String
        let name: String
        let app: String
        let context: [String]
        let text: String
        let secrets: [String]
        let knownMiss: Bool
        var testDescription: String { "\(category): \(name)" }
    }

    struct OrdinaryCase: Decodable, CustomTestStringConvertible {
        let category: String
        let name: String
        let app: String
        let context: [String]
        let text: String
        let knownFalsePositive: Bool
        var testDescription: String { "\(category): \(name)" }
    }

    static let corpus: Corpus = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Core
            .deletingLastPathComponent() // TranscriptedWritingTests
            .deletingLastPathComponent() // Tests
            .appendingPathComponent("Fixtures/writing-secret-corpus.json")
        guard let data = try? Data(contentsOf: url),
              let corpus = try? JSONDecoder().decode(Corpus.self, from: data) else {
            return Corpus(secrets: [], ordinary: [])
        }
        return corpus
    }()

    @Test("The corpus loads and has both secrets and ordinary writing")
    func corpusLoads() {
        #expect(Self.corpus.secrets.count >= 50)
        #expect(Self.corpus.ordinary.count >= 20)
    }

    @Test("Every secret in the corpus is removed", arguments: corpus.secrets.filter { !$0.knownMiss })
    func secretRemoved(_ item: SecretCase) {
        let result = WritingSecretScrubber.scrub(item.text, appBundleIdentifier: item.app, precedingLines: item.context)
        for secret in item.secrets {
            #expect(!result.clean.contains(secret), "\(item.name): a secret survived")
        }
        #expect(!result.kinds.isEmpty)
        for line in item.context {
            #expect(!result.clean.contains(line) || item.text.contains(line), "\(item.name): context leaked")
        }
    }

    @Test("Every ordinary text in the corpus comes back unchanged", arguments: corpus.ordinary.filter { !$0.knownFalsePositive })
    func ordinaryKept(_ item: OrdinaryCase) {
        let result = WritingSecretScrubber.scrub(item.text, appBundleIdentifier: item.app, precedingLines: item.context)
        #expect(result.clean == item.text)
        #expect(result.kinds.isEmpty)
    }
}
