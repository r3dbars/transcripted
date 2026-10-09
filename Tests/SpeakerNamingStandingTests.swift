import Foundation

func testSpeakerNamingStanding() {
    func person(_ name: String?, confirmed: Int, disputes: Int = 0) -> SpeakerProfile {
        SpeakerProfile(
            id: UUID(), displayName: name, nameSource: name == nil ? nil : "user_manual",
            embedding: [], firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 0),
            callCount: confirmed, confidence: 0.5, disputeCount: disputes, confirmedMeetingCount: confirmed
        )
    }

    runSuite("Speakers shows no New / Learning / Auto dial for a voice with no name") {
        assertNil(SpeakerNamingStanding.of(person(nil, confirmed: 7), recentOutcomes: []))
        assertNil(SpeakerNamingStanding.of(person("   ", confirmed: 7), recentOutcomes: []), "a blank name is still unnamed")
    }

    runSuite("A named person is New, then Learning, then Auto at five confirmed meetings") {
        assertEqual(SpeakerNamingStanding.of(person("Maya", confirmed: 1), recentOutcomes: [])?.tier, .new)
        assertEqual(SpeakerNamingStanding.of(person("Maya", confirmed: 2), recentOutcomes: [])?.tier, .learning)
        let auto = SpeakerNamingStanding.of(person("Maya", confirmed: 5), recentOutcomes: [.autoAccepted, .confirmed])
        assertEqual(auto?.tier, .auto)
        assertEqual(auto?.isTrusted, true)
        assertEqual(auto?.confirmedMeetings, 5)
        assertEqual(auto?.requiredMeetings, 5, "Settings uses the standard bar, not a meeting's lineup bar")
    }

    runSuite("A recent correction or an open dispute keeps a well-confirmed person at Learning") {
        let corrected = SpeakerNamingStanding.of(person("Maya", confirmed: 8), recentOutcomes: [.autoAccepted, .corrected])
        assertEqual(corrected?.tier, .learning, "the newest verdict was a correction, so she isn't named silently")
        assertEqual(corrected?.isTrusted, false, "the dial's hover then says auto-naming is paused")
        let disputed = SpeakerNamingStanding.of(person("Maya", confirmed: 8, disputes: 1), recentOutcomes: [])
        assertEqual(disputed?.tier, .learning)
        assertEqual(disputed?.isTrusted, false)
        let reconfirmed = SpeakerNamingStanding.of(person("Maya", confirmed: 8), recentOutcomes: [.confirmed, .corrected])
        assertEqual(reconfirmed?.tier, .auto, "one confirmation after the correction earns Auto back")
    }
}
