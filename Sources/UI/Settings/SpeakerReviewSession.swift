import Foundation

/// Presentation for one visit to Speakers review. The queue remains owned by
/// the model; a completed card stays here until Next, Later, Skip or Close.
struct SpeakerReviewSession {
    private(set) var isOpen = false
    private(set) var heldCall: SpeakerPendingMeetingGroup?
    private(set) var visitToken = UUID()
    private(set) var namedVoices: [String: [SpeakerReviewNamedVoice]] = [:]

    func currentCall(in calls: [SpeakerPendingMeetingGroup]) -> SpeakerPendingMeetingGroup? {
        heldCall ?? calls.first
    }

    func callCount(in calls: [SpeakerPendingMeetingGroup]) -> Int {
        let heldIsExtra = heldCall.map { held in !calls.contains { $0.id == held.id } } ?? false
        return calls.count + (heldIsExtra ? 1 : 0)
    }

    func namedVoices(on call: SpeakerPendingMeetingGroup) -> [SpeakerReviewNamedVoice] {
        namedVoices[call.id] ?? []
    }

    /// Use the refreshed queue and exclude saves already shown on this card.
    func pendingVoices(on call: SpeakerPendingMeetingGroup, in calls: [SpeakerPendingMeetingGroup]) -> [SpeakerPendingVoiceGroup] {
        let named = Set(namedVoices(on: call).map(\.voiceID))
        let voices = calls.first { $0.id == call.id }?.voices ?? []
        return voices.filter { !named.contains($0.id) }
    }

    mutating func open() { isOpen = true }

    /// The disk save may finish after leaving. Its completion belongs only
    /// to the visit that submitted it, even if the same call is reopened.
    @discardableResult
    mutating func record(_ voice: SpeakerReviewNamedVoice, on call: SpeakerPendingMeetingGroup, visit submittedToken: UUID) -> Bool {
        guard isOpen, submittedToken == visitToken else { return false }
        heldCall = call
        namedVoices[call.id, default: []].append(voice)
        return true
    }

    mutating func leave(_ call: SpeakerPendingMeetingGroup) {
        visitToken = UUID()
        if heldCall?.id == call.id { heldCall = nil }
        namedVoices[call.id] = nil
    }

    mutating func finish(_ call: SpeakerPendingMeetingGroup, total: Int) {
        leave(call)
        if total <= 1 { isOpen = false }
    }

    mutating func close() {
        visitToken = UUID()
        isOpen = false
        heldCall = nil
        namedVoices = [:]
    }
}
