import Foundation
import Testing
@testable import TranscriptedWritingCore

@Suite("Candidate source and the production event contract")
struct TextFreeCandidateSourceTests {
    @Test("The app's arbitration outcome maps onto the fixed source vocabulary")
    func personalArbitrationMapsToSource() {
        #expect(TextFreeCandidateSource(personal: nil) == .baseModel)
        #expect(TextFreeCandidateSource(personal: .base) == .baseModel)
        #expect(TextFreeCandidateSource(personal: .personal) == .personal)
        #expect(TextFreeCandidateSource(personal: .agreed) == .basePersonalAgreement)
    }

    @Test("A shown ghost's event names its source and never the legacy bucket")
    func opportunityEventCarriesSource() throws {
        for source in TextFreeCandidateSource.allCases where source != .unknownLegacy {
            let opportunity = LiveOnlineOpportunity(
                shownAt: Date(timeIntervalSince1970: 1_000),
                sessionDigestSHA256: TextFreeOnlineEvent.sessionDigest(sessionIdentifier: "s"),
                appCategory: "chat",
                register: "chat",
                boundary: "word-boundary",
                safeOpportunity: true,
                candidateCharacters: 4,
                candidateWordCount: 1,
                candidateSource: source,
                opportunityCharacters: 12
            )
            let event = try opportunity.eventWithoutAcceptedSpan()
            #expect(event.candidateSourceBucket == source.rawValue)
            #expect(event.opportunityCharacters == 12)
        }
    }

    @Test("The production event writes exactly its declared keys")
    func encodedKeysMatchAllowedKeys() throws {
        // A shown ghost carries every key but the reason; a silent
        // opportunity carries the reason. Together they are the contract.
        let shown = try sampleEvent()
        let shownLine = try TextFreeOnlineEvent.encodeJSONL(shown)
        let shownObject = try #require(JSONSerialization.jsonObject(with: shownLine) as? [String: Any])
        #expect(Set(shownObject.keys) == TextFreeOnlineEvent.allowedKeys.subtracting(["guardReason"]))
        #expect(try TextFreeOnlineEvent.decodeProductionLine(shownLine.dropLast()) == shown)

        let silent = try TextFreeOnlineEvent.silent(
            id: UUID(),
            occurredAt: Date(timeIntervalSince1970: 1_000),
            sessionDigestSHA256: TextFreeOnlineEvent.sessionDigest(sessionIdentifier: "s"),
            variant: "champion",
            appCategory: "prose",
            register: "prose",
            boundary: "word-boundary",
            reason: .emptyOutput,
            generated: false,
            deadlineMissed: false,
            generatorMilliseconds: 90,
            firstStableWordMilliseconds: 60,
            nextActionMilliseconds: 300,
            opportunityCharacters: 4,
            configurationDigestSHA256: String(repeating: "b", count: 64)
        )
        let silentLine = try TextFreeOnlineEvent.encodeJSONL(silent)
        let silentObject = try #require(JSONSerialization.jsonObject(with: silentLine) as? [String: Any])
        #expect(Set(silentObject.keys) == TextFreeOnlineEvent.allowedKeys.subtracting(["settledVisibleMilliseconds"]))
        #expect(Set(shownObject.keys).union(silentObject.keys) == TextFreeOnlineEvent.allowedKeys)
    }

    @Test("A live line carrying a Lab-only field is refused by name")
    func labOnlyKeyIsRefused() throws {
        let line = try TextFreeOnlineEvent.encodeJSONL(try sampleEvent())
        var object = try #require(JSONSerialization.jsonObject(with: line) as? [String: Any])
        object["cacheHit"] = true
        let data = try JSONSerialization.data(withJSONObject: object)
        #expect(throws: TextFreeOnlineEventError.unexpectedKey("cacheHit")) {
            try TextFreeOnlineEvent.decodeProductionLine(data)
        }
    }

    /// Every field set, including the optional timings, so the encoded key
    /// set is the full contract rather than a subset of it.
    private func sampleEvent() throws -> TextFreeOnlineEvent {
        var opportunity = LiveOnlineOpportunity(
            shownAt: Date(timeIntervalSince1970: 1_000),
            sessionDigestSHA256: TextFreeOnlineEvent.sessionDigest(sessionIdentifier: "s"),
            appCategory: "prose",
            register: "prose",
            boundary: "mid-word",
            safeOpportunity: true,
            candidateCharacters: 3,
            candidateWordCount: 1,
            candidateSource: .dictionary,
            opportunityCharacters: 8,
            generatorMilliseconds: 110,
            firstStableWordMilliseconds: 70,
            configurationDigestSHA256: String(repeating: "a", count: 64)
        )
        opportunity.noteTyped(at: Date(timeIntervalSince1970: 1_000.5))
        return try opportunity.eventWithoutAcceptedSpan()
    }
}

/// `boundary` on a live event answers "where was the caret", and the flight
/// recorder's two 9B-preview trials — requests after punctuation and requests
/// mid-word — must not land on the same answer.
@Suite("Text-free cursor boundary")
struct TextFreeCursorBoundaryTests {
    @Test("Only letters are mid-word")
    func onlyLettersAreMidWord() {
        #expect(TextFreeCursorBoundary.from(precedingCharacter: "i") == .midWord)
        #expect(TextFreeCursorBoundary.from(precedingCharacter: " ") == .wordBoundary)
        #expect(TextFreeCursorBoundary.from(precedingCharacter: "\n") == .wordBoundary)
        #expect(TextFreeCursorBoundary.from(precedingCharacter: nil) == .wordBoundary)
    }

    @Test("A finished clause is a boundary, not a word the writer is inside")
    func clausePunctuationIsABoundary() {
        #expect(TextFreeCursorBoundary.from(precedingCharacter: ".") == .sentenceBoundary)
        #expect(TextFreeCursorBoundary.from(precedingCharacter: "!") == .sentenceBoundary)
        #expect(TextFreeCursorBoundary.from(precedingCharacter: "?") == .sentenceBoundary)
        for mark in RawContinuationPrompt.requestPunctuation where !".!?".contains(mark) {
            #expect(TextFreeCursorBoundary.from(precedingCharacter: mark) == .wordBoundary)
        }
    }
}
