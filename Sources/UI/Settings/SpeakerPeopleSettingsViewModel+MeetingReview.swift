import SwiftUI
import TranscriptedCore

/// The Speakers page's "Who spoke?" cards, one saved meeting at a time: what
/// Done, Undo and Skip save (what a card asks is `+WhoSpokeInput.swift`). Done waits `SpeakerMeetingReviewPolicy.undoSeconds`
/// before saving so Undo can bring the card back as it was; leaving the page
/// or finishing the next card saves it at once. The saves are the page's own
/// (`saveReviewName`, `joinReviewVoice`, `markReviewVoiceAsMe`, `delete`), so a
/// voice named here comes out the same as one named anywhere else on the page.
extension SpeakerPeopleSettingsViewModel {
    /// Changes whenever what a card asks could change: a saved person added,
    /// renamed or removed, their progress, or which voices match whom. A card
    /// nobody has touched yet is rebuilt with the new names and guesses.
    var whoSpokeInputSignature: Int {
        var hasher = Hasher()
        for profile in profiles {
            guard let name = profile.displayName, !name.isEmpty else { continue }
            hasher.combine(profile.id)
            hasher.combine(name)
            if let standing = namingStanding(for: profile) {
                hasher.combine(standing.confirmedMeetings)
                hasher.combine(standing.requiredMeetings)
                hasher.combine(standing.isTrusted)
            }
        }
        for candidate in duplicateCandidates where candidate.reason.includesVoiceMatch {
            hasher.combine(candidate.id)
            hasher.combine(candidate.voiceSimilarity)
        }
        return hasher.finalize()
    }

    /// Everyone with a name, for "People Transcripted knows · 14".
    var knownPeopleCount: Int {
        profiles.filter { $0.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }.count
    }

    // MARK: Meetings page

    func voicesToName(forTranscript transcriptURL: URL) -> Int {
        meetingNamingByTranscriptPath[transcriptURL.standardizedFileURL.path]?.voicesToName ?? 0
    }

    /// The Meetings page's "Who spoke?": put that meeting's card on top.
    func focusMeeting(transcriptURL: URL?) {
        let key = transcriptURL.flatMap { meetingNamingByTranscriptPath[$0.standardizedFileURL.path]?.callKey }
        meetingReview.focus(key)
    }

    /// Saved people with a real name, so a merge can keep that name when the
    /// typed field is blank.
    private func meetingReviewExistingNames() -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: profiles.compactMap { profile in
            guard let name = SpeakerMeetingReviewPolicy.usableName(profile.displayName) else { return nil }
            return (profile.id, name)
        })
    }

    // MARK: Done, Undo, Skip

    /// Done on the top card. Its answers wait out Undo, then save. A card
    /// still waiting on Undo saves now.
    func finishMeeting(_ call: SpeakerPendingMeetingGroup, updates: [SpeakerReviewUpdate]) {
        // A second Done (or a Skip) on a card already finished, e.g. a click
        // while it animates away, must not save it twice.
        guard !meetingReview.heldOutCallKeys.contains(call.id) else { return }
        meetingSaveError = nil
        let steps = SpeakerMeetingReviewPolicy.steps(for: updates, existingNames: meetingReviewExistingNames())
        let finished = SpeakerMeetingReviewState.Finished(
            callKey: call.id,
            title: call.meetingTitle,
            names: steps.compactMap(\.savedName),
            personIDs: steps.compactMap { step in
                if case .join(_, let personID, _) = step { return personID }
                return step.savedName == nil ? nil : step.voiceID
            },
            token: UUID()
        )
        pendingMeetingSaves[finished.token] = (call, steps)
        if let previous = meetingReview.finish(finished) {
            saveMeeting(token: previous.token, callKey: previous.callKey)
        }
        meetingSaveTask?.cancel()
        let token = finished.token
        meetingSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(SpeakerMeetingReviewPolicy.undoSeconds))
            guard !Task.isCancelled else { return }
            self?.saveFinishedMeetingNow(token: token)
        }
    }

    /// Undo on "Weekly sync is done": nothing was saved; the card comes back.
    func undoFinishedMeeting() {
        guard let token = meetingReview.finished?.token, meetingReview.undo(token: token) != nil else { return }
        meetingSaveTask?.cancel()
        meetingSaveTask = nil
        pendingMeetingSaves[token] = nil
    }

    /// The finished card saves now: its Undo ran out, or the page closed.
    func saveFinishedMeetingNow(token: UUID? = nil) {
        guard let finished = meetingReview.finished, token == nil || token == finished.token,
              meetingReview.startSaving(token: finished.token) != nil else { return }
        meetingSaveTask?.cancel()
        meetingSaveTask = nil
        saveMeeting(token: finished.token, callKey: finished.callKey)
    }

    /// Skip: what was answered saves now, and the meeting stops asking.
    /// Its other voices move to Not named yet. If an answer doesn't save, the
    /// meeting isn't skipped: its card comes back with a note.
    func skipMeeting(_ call: SpeakerPendingMeetingGroup, updates: [SpeakerReviewUpdate]) {
        guard !meetingReview.heldOutCallKeys.contains(call.id) else { return }
        meetingSaveError = nil
        let steps = SpeakerMeetingReviewPolicy.steps(for: updates, existingNames: meetingReviewExistingNames())
        meetingReview.skipped(callKey: call.id)
        enqueueMeetingSave { [weak self] done in
            guard let self else { return done() }
            self.runMeetingSteps(steps, on: call) { [weak self] failed in
                defer { done() }
                guard let self else { return }
                if failed > 0 {
                    self.meetingReview.skipFailed(callKey: call.id)
                    self.meetingSaveError = SpeakerMeetingReviewPolicy.saveFailedLine(meetingTitle: call.meetingTitle, failed: failed)
                } else {
                    self.skipCall(call)
                    self.meetingReview.saved(callKey: call.id)
                }
            }
        }
    }

    private func saveMeeting(token: UUID, callKey: String) {
        guard let pending = pendingMeetingSaves.removeValue(forKey: token) else {
            meetingReview.saved(callKey: callKey)
            return
        }
        let answered = Set(pending.steps.map(\.voiceID))
        let leftOver = pending.call.voices.contains { !answered.contains($0.id) }
        enqueueMeetingSave { [weak self] done in
            guard let self else { return done() }
            self.runMeetingSteps(pending.steps, on: pending.call) { [weak self] failed in
                defer { done() }
                guard let self else { return }
                if failed > 0 {
                    self.meetingSaveError = SpeakerMeetingReviewPolicy.saveFailedLine(meetingTitle: pending.call.meetingTitle, failed: failed)
                }
                // Voices left unanswered (or not saved) wait behind the other meetings.
                if leftOver || failed > 0 { self.sendCallToBack(pending.call) }
                self.meetingReview.saved(callKey: callKey)
                self.meetingReview.resetProgressIfIdle(meetingsLeft: self.reviewStack.calls.count)
            }
        }
    }

    /// Quit: a card waiting on Undo saves now, and Quit waits (up to
    /// `terminationWaitSeconds`) for every meeting save to land.
    static func finishMeetingSavesForTermination() async {
        await live?.finishMeetingSaves()
    }

    func finishMeetingSaves() async {
        saveFinishedMeetingNow()
        // Edits made while people move to a new voice model wait for it to
        // finish; Quit doesn't.
        guard !isMovingPeopleToNewVoiceModel, isRunningMeetingSave || !waitingMeetingSaves.isEmpty else { return }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(SpeakerMeetingReviewPolicy.terminationWaitSeconds))
            self?.resumeMeetingSaveWaiters()
        }
        await withCheckedContinuation { meetingSavesIdleWaiters.append($0) }
    }

    private func resumeMeetingSaveWaiters() {
        let waiters = meetingSavesIdleWaiters
        meetingSavesIdleWaiters = []
        waiters.forEach { $0.resume() }
    }

    /// Runs one meeting's saves after every meeting saved before it.
    private func enqueueMeetingSave(_ save: @escaping (@escaping @MainActor () -> Void) -> Void) {
        waitingMeetingSaves.append(save)
        runNextMeetingSave()
    }

    private func runNextMeetingSave() {
        guard !isRunningMeetingSave else { return }
        guard !waitingMeetingSaves.isEmpty else {
            resumeMeetingSaveWaiters()
            return
        }
        isRunningMeetingSave = true
        let save = waitingMeetingSaves.removeFirst()
        save { [weak self] in
            self?.isRunningMeetingSave = false
            self?.runNextMeetingSave()
        }
    }

    /// Runs the saves one after another, so each sees the snapshot the one
    /// before it left. A save that fails leaves that voice in the queue; the
    /// completion gets how many failed.
    private func runMeetingSteps(
        _ steps: [SpeakerMeetingReviewPolicy.Step],
        on call: SpeakerPendingMeetingGroup,
        failed: Int = 0,
        completion: @escaping @MainActor (_ failed: Int) -> Void
    ) {
        guard let step = steps.first else {
            completion(failed)
            return
        }
        let rest = Array(steps.dropFirst())
        let next: @MainActor (_ didSave: Bool) -> Void = { [weak self] didSave in
            guard let self else { return }
            self.runMeetingSteps(rest, on: call, failed: failed + (didSave ? 0 : 1), completion: completion)
        }
        guard let item = call.voices.first(where: { $0.id == step.voiceID })?.representative else {
            next(false)
            return
        }
        let landed: @MainActor (SpeakerReviewNamedVoice?) -> Void = { [weak self] voice in
            if let voice, !voice.isNewPerson { self?.celebrate(voice.personID) }
            next(voice != nil)
        }
        switch step {
        case .name(_, let name):
            saveReviewName(item, to: name, completion: landed)
        case .join(_, let personID, let name):
            if let person = profiles.first(where: { $0.id == personID }) {
                joinReviewVoice(item, into: person, completion: landed)
            } else if let fallback = SpeakerMeetingReviewPolicy.fallbackNameAfterMissingJoin(name) {
                saveReviewName(item, to: fallback, completion: landed)
            } else {
                next(false)
            }
        case .markAsMe:
            markReviewVoiceAsMe(item, completion: landed)
        case .notAPerson:
            delete(profile: item.profile) { didDelete in MainActor.assumeIsolated { next(didDelete) } }
        }
    }
}
