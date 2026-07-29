import Foundation

enum TranscriptionModelRuntime: Hashable {
    case parakeet
    case whisper
    case nemotron
}

extension TranscriptionModelChoice {
    var runtime: TranscriptionModelRuntime {
        switch self {
        case .parakeetTDTv3:
            return .parakeet
        case .whisperLargeV3Turbo, .whisperLargeV3:
            return .whisper
        case .nemotronStreaming:
            return .nemotron
        }
    }
}

struct TranscriptionModelWarmupLease: Equatable {
    let model: TranscriptionModelChoice
    let generation: UInt64
}

struct TranscriptionModelForegroundClaim: Equatable {
    let model: TranscriptionModelChoice
    let obsoleteBackgroundModel: TranscriptionModelChoice?
}

/// Tracks whether model work is disposable background warmup or protected by
/// active dictation/meeting/import use. The generation prevents an older
/// canceled warmup from clearing a newer warmup for the same model.
struct TranscriptionModelWarmupOwnership {
    private(set) var backgroundLease: TranscriptionModelWarmupLease?
    private var foregroundUseCounts: [TranscriptionModelChoice: Int] = [:]
    private var nextGeneration: UInt64 = 0

    func hasForegroundUse(of model: TranscriptionModelChoice) -> Bool {
        foregroundUseCounts[model, default: 0] > 0
    }

    func hasForegroundUse(on runtime: TranscriptionModelRuntime) -> Bool {
        foregroundUseCounts.contains { entry in
            entry.value > 0 && entry.key.runtime == runtime
        }
    }

    func foregroundModel(
        on runtime: TranscriptionModelRuntime
    ) -> TranscriptionModelChoice? {
        foregroundUseCounts.first { entry in
            entry.value > 0 && entry.key.runtime == runtime
        }?.key
    }

    mutating func beginBackgroundWarmup(
        for model: TranscriptionModelChoice
    ) -> TranscriptionModelWarmupLease? {
        guard !hasForegroundUse(on: model.runtime) else { return nil }

        if let backgroundLease, backgroundLease.model == model {
            return backgroundLease
        }

        nextGeneration &+= 1
        let lease = TranscriptionModelWarmupLease(
            model: model,
            generation: nextGeneration
        )
        backgroundLease = lease
        return lease
    }

    mutating func finishBackgroundWarmup(
        _ lease: TranscriptionModelWarmupLease,
        modelIsLoaded: Bool
    ) {
        guard backgroundLease == lease else { return }
        if !modelIsLoaded {
            backgroundLease = nil
        }
    }

    mutating func takeBackgroundWarmup(
        whenSwitchingFrom model: TranscriptionModelChoice
    ) -> TranscriptionModelChoice? {
        guard backgroundLease?.model == model else { return nil }
        backgroundLease = nil
        return model
    }

    /// Resolve a foreground request onto the model already active on the shared
    /// runtime. This prevents one Whisper variant from unloading another while
    /// a dictation or meeting still owns it.
    mutating func claimForegroundUse(
        of model: TranscriptionModelChoice
    ) -> TranscriptionModelForegroundClaim {
        let activeModel = foregroundModel(on: model.runtime)
        let resolvedModel = activeModel ?? model
        foregroundUseCounts[resolvedModel, default: 0] += 1

        guard
            activeModel == nil,
            let backgroundLease,
            backgroundLease.model.runtime == resolvedModel.runtime
        else {
            return TranscriptionModelForegroundClaim(
                model: resolvedModel,
                obsoleteBackgroundModel: nil
            )
        }

        self.backgroundLease = nil
        return TranscriptionModelForegroundClaim(
            model: resolvedModel,
            obsoleteBackgroundModel: backgroundLease.model == resolvedModel
                ? nil
                : backgroundLease.model
        )
    }

    /// Returns true when this release leaves the runtime with no foreground
    /// users, allowing a deferred warmup or obsolete-model teardown to proceed.
    mutating func releaseForegroundUse(
        of model: TranscriptionModelChoice
    ) -> Bool {
        let currentCount = foregroundUseCounts[model, default: 0]
        guard currentCount > 0 else { return false }
        if currentCount <= 1 {
            foregroundUseCounts[model] = nil
        } else {
            foregroundUseCounts[model] = currentCount - 1
        }
        return !hasForegroundUse(on: model.runtime)
    }

    mutating func reset() {
        backgroundLease = nil
        foregroundUseCounts.removeAll()
    }
}
