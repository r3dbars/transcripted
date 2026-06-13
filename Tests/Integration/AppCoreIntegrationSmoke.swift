// AppCoreIntegrationSmoke.swift
// Verifies that TranscriptedCore links cleanly against the app's bundled deps-libs and
// that the pieces MeetingSessionController wires up can be constructed.
//
// Does NOT construct MeetingSessionController itself — that type lives inside
// the app target and depends on app-internal ParakeetEngine. Instead
// we exercise the Core surface that Meeting code touches (CoreStoragePaths,
// DiarizationService, SpeakerDatabase, FailedTranscriptionManager, Audio,
// TranscriptionTaskManager, AppServices), so any breakage in the bundled
// Core-in-libDraftDeps.a shows up here rather than at app launch time.

import Foundation
import TranscriptedCore

private enum SmokeLifetime {
    static var audio: Audio?
}

@MainActor
func runSmoke() async -> Int32 {
    print("[smoke] CoreStoragePaths default…")
    let tmpRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptedMeetingSmoke-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: tmpRoot, withIntermediateDirectories: true)

    let paths = CoreStoragePaths(
        transcripts: tmpRoot.appendingPathComponent("transcripts", isDirectory: true),
        speakerDB: tmpRoot.appendingPathComponent("speakers.sqlite"),
        statsDB: tmpRoot.appendingPathComponent("stats.sqlite"),
        failedQueue: tmpRoot.appendingPathComponent("failed.json"),
        speakerClips: tmpRoot.appendingPathComponent("clips", isDirectory: true),
        audioCaptures: tmpRoot.appendingPathComponent("captures", isDirectory: true),
        logs: tmpRoot.appendingPathComponent("logs", isDirectory: true)
    )
    print("[smoke]   transcripts: \(paths.transcripts.path)")

    print("[smoke] AudioResampler…")
    let sixteenK: [Float] = (0..<1600).map { Float($0) / 1600.0 }
    let resampled = AudioResampler.resample(sixteenK, from: 48000, to: 16000)
    guard !resampled.isEmpty else {
        print("[smoke] FAIL: AudioResampler returned empty output")
        return 1
    }

    print("[smoke] Audio(paths:) lightweight init…")
    SmokeLifetime.audio = Audio(paths: paths)

    // NOTE: Live Audio start()/monitoring and DiarizationService() are still
    // intentionally skipped. Starting capture touches OS-managed devices and
    // permissions the smoke binary does not own, while DiarizationService
    // still reaches for CoreML bundles we cannot download from a standalone
    // tool.

    print("[smoke] DiarizationService type reachable…")
    let _: DiarizationService.Type = DiarizationService.self

    print("[smoke] SpeakerDatabase(path:)…")
    let speakerDB = SpeakerDatabase(path: paths.speakerDB.path)

    // Behavioral round-trip: inserting an embedding (pure SQLite, no CoreML or audio
    // device) should mint a profile that getSpeaker(id:) can read back, and it should
    // show up in the all-speakers listing.
    let insertedSpeaker = speakerDB.addOrUpdateSpeaker(embedding: Array(repeating: 0.1, count: 256))
    guard let fetchedSpeaker = speakerDB.getSpeaker(id: insertedSpeaker.id),
          fetchedSpeaker.id == insertedSpeaker.id else {
        print("[smoke] FAIL: SpeakerDatabase did not read back the inserted speaker")
        return 1
    }
    guard speakerDB.allSpeakers().contains(where: { $0.id == insertedSpeaker.id }) else {
        print("[smoke] FAIL: SpeakerDatabase all-speakers listing dropped the inserted speaker")
        return 1
    }

    print("[smoke] FailedTranscriptionManager(paths:)…")
    let failed = FailedTranscriptionManager(paths: paths)

    // Behavioral round-trip: enqueue a failed transcription whose audio path lives under
    // the sandboxed captures root, then confirm the in-memory queue count reflects the add.
    // Needs no CoreML or audio device — the manager only validates path containment and
    // persists JSON. The add-then-read-count API shape mirrors TranscriptedE2ESmoke.swift.
    try? FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
    let smokeMicURL = paths.audioCaptures.appendingPathComponent("smoke-mic.wav")
    let didEnqueueFailed = failed.addFailedTranscription(
        micAudioURL: smokeMicURL,
        systemAudioURL: nil,
        errorMessage: "Smoke fixture failure",
        meetingTitle: "Smoke Meeting"
    )
    guard didEnqueueFailed, failed.count == 1 else {
        print("[smoke] FAIL: FailedTranscriptionManager did not enqueue the failed transcription (persisted=\(didEnqueueFailed) count=\(failed.count))")
        return 1
    }

    print("[smoke] AppServices(...) DI container…")
    // NOTE: AppServices wants a concrete SpeechToTextEngine. The smoke binary
    // cannot see the app's MeetingSTTAdapter (the app module isn't importable from
    // a standalone tool), so we skip the full AppServices construction and
    // instead verify TranscriptionTaskManager's init signature compiles with
    // the protocol-typed service surface.
    _ = { (
        stt: any SpeechToTextEngine,
        diar: any DiarizationEngine
    ) -> TranscriptionTaskManager in
        TranscriptionTaskManager(
            failedTranscriptionManager: failed,
            speechToText: stt,
            diarization: diar,
            speakerStore: speakerDB
        )
    }

    // Clean up the tmp root we created.
    try? FileManager.default.removeItem(at: tmpRoot)

    print("[smoke] OK — TranscriptedCore is reachable from the app's dependency chain")
    return 0
}

@main
struct Main {
    static func main() async {
        let code = await runSmoke()
        exit(code)
    }
}
