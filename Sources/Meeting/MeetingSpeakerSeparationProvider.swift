import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// Builds the per-meeting speaker-separation provider the task manager calls.
///
/// The diarization backend is read on every call, which the pipeline makes after
/// the diarizer's models load, never once at launch. If Nemotron fails to load,
/// pyannote diarizes the meeting and must get pyannote's separation settings,
/// not Nemotron's.
enum MeetingSpeakerSeparationProvider {
    static func make<Options: Sendable>(
        activeBackend: @escaping @Sendable () async -> DiarizationBackend,
        resolve: @escaping @Sendable (_ backend: DiarizationBackend, _ recordingDate: Date?) async -> Options
    ) -> @Sendable (_ recordingDate: Date?) async -> Options? {
        { recordingDate in
            await resolve(await activeBackend(), recordingDate)
        }
    }
}
