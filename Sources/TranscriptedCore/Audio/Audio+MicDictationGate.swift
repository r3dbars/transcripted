import Foundation
@preconcurrency import AVFoundation
import Synchronization

/// Borrowed-dictation mic gate.
///
/// When the user dictates during a meeting, dictation borrows the meeting's
/// mic stream through `onMicPCMBuffer`. Without a gate, those same words also
/// land in the saved mic WAV and the live meeting preview, so the meeting
/// transcript repeats the dictation. While the gate is on, `handleMicBuffer`
/// hands the real samples to `onMicPCMBuffer` only and gives the file and the
/// live preview silence of the same length, so the mic track stays aligned
/// with system audio. System audio is never gated.
///
/// It's checked per buffer, like a mute. The meter, silence tracking, signal
/// peaks and watchdog keep reading the real mic, so being gated never looks
/// like a dead or silent mic.
extension Audio {
    /// On while a borrowed-mic dictation claim is live. Safe from any thread;
    /// the mic buffer handler reads it once per buffer.
    public var isMicGatedForBorrowedDictation: Bool {
        get { micDictationGate.load(ordering: .acquiring) }
        set { micDictationGate.store(newValue, ordering: .releasing) }
    }

    /// A zero-filled buffer with the same format and frame count as `buffer`.
    /// Only built while gated, on the same handler thread that already copies
    /// each buffer; never the CoreAudio IOProc itself.
    func silentCopy(matching buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let silent = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        silent.frameLength = buffer.frameLength
        zeroSamples(of: silent)
        return silent
    }

    /// Zeroes an owned buffer in place. Never call it on the borrowed tap
    /// buffer; only on a copy this handler made.
    func zeroSamples(of buffer: AVAudioPCMBuffer) {
        for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            if let data = audioBuffer.mData {
                memset(data, 0, Int(audioBuffer.mDataByteSize))
            }
        }
    }
}
