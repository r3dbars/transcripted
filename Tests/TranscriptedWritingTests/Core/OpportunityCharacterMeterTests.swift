import Foundation
import Testing
@testable import TranscriptedWritingCore

@Suite("Opportunity character meter")
struct OpportunityCharacterMeterTests {
    @Test("A long document with ten ghosts counts its authored characters once, not its body ten times")
    func longDocumentDenominatorIsAuthoredCharacters() {
        // The old denominator: the bounded context at each show.
        let documentBody = String(repeating: "x", count: 2_000)
        var oldDenominator = 0
        var meter = OpportunityCharacterMeter()
        var newDenominator = 0
        for _ in 0..<10 {
            for _ in 0..<5 { meter.noteTyped() }
            oldDenominator += documentBody.count
            newDenominator += meter.takeForOpportunity()
        }
        #expect(oldDenominator == 20_000)
        #expect(newDenominator == 50)
    }

    @Test("Accepted characters are authored writing and count toward the next ghost")
    func acceptedCharactersCount() {
        var meter = OpportunityCharacterMeter()
        meter.noteTyped(characters: 3)
        meter.noteAccepted(characters: 7)
        #expect(meter.takeForOpportunity() == 10)
        #expect(meter.authoredSinceLastOpportunity == 0)
    }

    @Test("A ghost with nothing authored since the last one is still one opportunity")
    func floorIsOne() {
        var meter = OpportunityCharacterMeter()
        #expect(meter.takeForOpportunity() == 1)
        meter.noteTyped(characters: -4)
        #expect(meter.takeForOpportunity() == 1)
    }

    @Test("A segment close drops the unattributed tail instead of charging it to the next ghost")
    func resetDropsTail() {
        var meter = OpportunityCharacterMeter()
        meter.noteTyped(characters: 40)
        meter.reset()
        #expect(meter.takeForOpportunity() == 1)
    }
}
