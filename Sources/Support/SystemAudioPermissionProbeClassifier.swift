import AppKit
import AVFoundation
import ApplicationServices
import CoreAudio
import Combine
import EventKit
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

enum SystemAudioPermissionSampleEvidence: Sendable {
    case noValidFrames
    case silentFrames
    case signal
}

enum SystemAudioPermissionProbeClassifier {
    typealias ProbeResult = TranscriptedPermissionAccess.SystemAudioPermissionProbeResult
    typealias ProbeStage = TranscriptedPermissionAccess.SystemAudioPermissionProbeStage

    static func containsAudioSignal(_ buffer: AVAudioPCMBuffer) -> Bool {
        if case .signal = sampleEvidence(buffer) { return true }
        return false
    }

    static func sampleEvidence(_ buffer: AVAudioPCMBuffer) -> SystemAudioPermissionSampleEvidence {
        guard buffer.frameLength > 0, buffer.format.commonFormat == .pcmFormatFloat32 else { return .noValidFrames }
        var hasFiniteSample = false
        var hasInvalidSample = false
        for channel in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
            guard let data = channel.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            for index in 0..<(Int(channel.mDataByteSize) / MemoryLayout<Float>.size) {
                if samples[index].isFinite {
                    hasFiniteSample = true
                    if samples[index] != 0 { return .signal }
                } else {
                    hasInvalidSample = true
                }
            }
        }
        return hasFiniteSample && !hasInvalidSample ? .silentFrames : .noValidFrames
    }

    static func result(for error: Error, stage: ProbeStage) -> ProbeResult {
        // Core Audio's public errors do not distinguish a TCC denial from
        // other device-access failures. In particular '!hog' is not specific
        // to the user's recording grant. Do not persist these as a revocation.
        return .indeterminate(stage)
    }

}
