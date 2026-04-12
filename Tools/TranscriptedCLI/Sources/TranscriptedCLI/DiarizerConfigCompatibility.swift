#if TRANSCRIPTEDCLI_WITH_DIARIZATION
import FluidAudio

extension OfflineDiarizerConfig {
    /// TranscriptedCLI previously relied on a FluidAudio helper that applied
    /// explicit speaker-count bounds to the default diarizer config. The
    /// current FluidAudio surface no longer exposes that helper, so keep the
    /// CLI call sites compiling with a compatibility no-op until bounded
    /// speaker-count tuning returns in the upstream API.
    func applyingSpeakerBounds(min: Int?, max: Int?) -> OfflineDiarizerConfig {
        _ = min
        _ = max
        return self
    }
}
#endif
