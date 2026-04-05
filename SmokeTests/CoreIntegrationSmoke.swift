// CoreIntegrationSmoke.swift
// Verifies that TranscriptedCore links cleanly against Draft's deps-libs and
// that the pieces MeetingSessionController wires up can be constructed.
//
// Does NOT construct MeetingSessionController itself — that type lives inside
// the Draft app target and depends on Draft-internal ParakeetEngine. Instead
// we exercise the Core surface that Meeting code touches (CoreStoragePaths,
// DiarizationService, SpeakerDatabase, FailedTranscriptionManager, Audio,
// TranscriptionTaskManager, AppServices), so any breakage in the bundled
// Core-in-libDraftDeps.a shows up here rather than at Draft launch time.

import Foundation
import TranscriptedCore

@MainActor
func runSmoke() async -> Int32 {
    print("[smoke] CoreStoragePaths default…")
    let tmpRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("DraftMeetingSmoke-\(UUID().uuidString)")
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

    // NOTE: Audio(paths:) and DiarizationService() are intentionally skipped.
    // Audio.setup() opens AVAudioEngine and blocks waiting for mic permissions
    // the smoke binary has no entitlements for; DiarizationService touches
    // CoreML bundles we cannot download from a standalone tool. Their
    // construction is exercised implicitly by the Draft app launch path
    // (bash build.sh), which this script runs alongside.

    print("[smoke] DiarizationService type reachable…")
    let _: DiarizationService.Type = DiarizationService.self

    print("[smoke] SpeakerDatabase(path:)…")
    let speakerDB = SpeakerDatabase(path: paths.speakerDB.path)
    _ = speakerDB

    print("[smoke] FailedTranscriptionManager(paths:)…")
    let failed = FailedTranscriptionManager(paths: paths)

    print("[smoke] AppServices(...) DI container…")
    // NOTE: AppServices wants a concrete SpeechToTextEngine. The smoke binary
    // cannot see Draft's MeetingSTTAdapter (Draft module isn't importable from
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

    print("[smoke] OK — TranscriptedCore is reachable from Draft's dep chain")
    return 0
}

@main
struct Main {
    static func main() async {
        let code = await runSmoke()
        exit(code)
    }
}
