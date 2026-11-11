import Foundation
@preconcurrency import AVFoundation

struct AudioRecordingArtifactFacts {
    let languageSelection: TranscriptionLanguageSelection
    let micOnlyByChoice: Bool
}
typealias AudioArtifactOwner = RecordingArtifactOwnership<AudioRecordingArtifactFacts, MeetingRecordingJournalStore, MeetingRecordingJournalSession>
typealias AudioArtifactContext = RecordingArtifactContext<AudioRecordingArtifactFacts, MeetingRecordingJournalStore, MeetingRecordingJournalSession>
typealias AudioArtifactTicket = RecordingArtifactStopTicket<AudioRecordingArtifactFacts, MeetingRecordingJournalStore, MeetingRecordingJournalSession>
typealias AudioArtifactDispatcher = JournalCommandDispatcher<AudioRecordingArtifactFacts, MeetingRecordingJournalStore, MeetingRecordingJournalSession>
typealias AudioMicArtifactTransactions = MicArtifactTransactions<AVAudioFile, MicPCMWriteContext, AudioRecordingArtifactFacts, MeetingRecordingJournalStore, MeetingRecordingJournalSession>
typealias AudioArtifactCompletion = RecordingArtifactCompletion<AudioRecordingArtifactFacts, MeetingRecordingJournalStore, MeetingRecordingJournalSession>

extension Audio {
    func configureArtifactOwnership() {
        // Initialize these plain owners before capture callbacks can escape.
        // The factories construct closures; they do not create files/devices.
        _ = recordingArtifactOwner
        _ = micArtifactTransactions
        _ = recordingArtifactCompletion
    }
    func compatibilityArtifactContext() -> AudioArtifactContext {
        if let context = recordingArtifactOwner.currentContext() { return context }
        return recordingArtifactOwner.adoptCurrentGeneration(facts: currentArtifactFacts(), endpoint: initialRecordingJournal)
    }
    func currentArtifactFacts() -> AudioRecordingArtifactFacts {
        AudioRecordingArtifactFacts(languageSelection: languageSelectionForCurrentRecording,
                                    micOnlyByChoice: !currentRecordingCapturesSystemAudio)
    }
    func makeRecordingArtifactDispatcher() -> AudioArtifactDispatcher {
        AudioArtifactDispatcher(queue: initialRecordingJournal.artifactQueue, applications: JournalApplications(
            recordSegments: { $0.endpoint.recordSegmentsOnQueue($1, session: $0.token) },
            recordSystemURL: { $0.endpoint.recordSystemURLOnQueue($1, session: $0.token) },
            clearSystemURL: { $0.endpoint.recordSystemURLOnQueue(nil, session: $0.token) },
            markStopping: { $0.endpoint.markStoppingOnQueue(session: $0.token) },
            markFinalized: { $0.endpoint.markFinalizedOnQueue(finalMicURL: $1, session: $0.token, endingSession: $2) },
            snapshotOwnedDiscard: { $0.endpoint.snapshotForOwnedDiscardOnQueue(session: $0.token) },
            finishOwnedDiscard: { $0.endpoint.finishOwnedDiscardOnQueue(session: $0.token, cleanupSucceeded: $1) },
            releaseRecovery: { $0.endpoint.releaseRecoveryOnQueue(session: $0.token) }
        ))
    }
    func makeMicArtifactTransactions() -> AudioMicArtifactTransactions {
        let root = paths.audioCaptures
        let files = FileActions<AVAudioFile,MicPCMWriteContext>(allocateURL: { role in
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let timestamp = DateFormattingHelper.formatFilenamePrecise(Date())
            let suffix: String
            switch role { case .initial: suffix = "mic"; case .recovery: suffix = "mic_recovery" }
            let url = root.appendingPathComponent("meeting_\(timestamp)_\(suffix).wav")
            if case .initial = role {
                let journal = root.appendingPathComponent(url.deletingPathExtension().lastPathComponent + MeetingRecordingJournalStore.filenameSuffix)
                guard !FileManager.default.fileExists(atPath: url.path), !FileManager.default.fileExists(atPath: journal.path) else {
                    throw MeetingRecordingJournalStartError.alreadyExists
                }
            }
            return url
        }, createWriter: { url, prepared in
            try AVAudioFile(forWriting: url, settings: prepared.monoFormat.settings,
                            commonFormat: prepared.monoFormat.commonFormat, interleaved: prepared.monoFormat.isInterleaved)
        }, closeWriter: { $0.close() }, restrictPermissions: {
            FileManager.default.restrictToOwnerOnly(atPath: $0.path)
        }, removeFile: { url in
            guard url.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
                  url.lastPathComponent.hasPrefix("meeting_"),
                  url.lastPathComponent.hasSuffix("_mic.wav") || url.lastPathComponent.hasSuffix("_mic_recovery.wav") else {
                throw CocoaError(.fileWriteNoPermission)
            }
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        })
        return AudioMicArtifactTransactions(queue: micAudioFileQueue, writerOwnership: micAudioFileOwnership,
            owner: recordingArtifactOwner, files: files, journal: JournalBegin(begin: { endpoint, url, facts in
                try endpoint.begin(primaryMicURL: url, languageSelection: facts.languageSelection, micOnlyByChoice: facts.micOnlyByChoice)
            }))
    }
    func makeRecordingArtifactCompletion() -> AudioArtifactCompletion {
        AudioArtifactCompletion(owner: recordingArtifactOwner, journal: recordingArtifactDispatcher,
            files: TerminalFileActions(merge: { [weak self] snapshot in
                self?.finalizeMicRecording(primaryURL: snapshot.primaryURL, segments: snapshot.segments)
            }, safeCleanup: { MeetingRecordingJournalStore.safelyDiscardOwnedInventory($0) }),
            workQueue: .global(qos: .utility), callbackQueue: .main)
    }
    func artifactContext(for generation: UInt64) -> AudioArtifactContext? {
        guard let context = recordingArtifactOwner.currentContext(), context.captureGeneration == generation else { return nil }
        return context
    }
    func completeArtifactStop(_ ticket: AudioArtifactTicket, systemTimeline: RecordedSystemAudioTimeline?) {
        // This value belongs to the captured stopped attempt, never a current
        // context lookup. Keep the existing UI-before-callback ordering.
        let edges = CompletionEdges(beforeDelivery: { output in
            if self.recordingSessionGeneration == output.stopGeneration {
                self.inFlightStopGeneration = nil
                self.micAudioFileURL = output.micURL
            }
        }, timeline: { output in
            self.onRecordingCompleteWithTimeline?(output.stopGeneration, output.micURL, output.systemURL,
                                                  output.disposition, systemTimeline)
        }, generation: { output in
            self.onRecordingCompleteWithGeneration?(output.stopGeneration, output.micURL, output.systemURL, output.disposition)
        }, legacy: { mic, system in self.onRecordingComplete?(mic, system) })
        recordingArtifactCompletion.afterOwnedArtifactsDrained(ticket, callbacks: edges)
    }
}
