import Foundation

func testTranscriptionModelWarmupOwnership() {
    runSuite("Model warmup ownership - background work is promoted by foreground use") {
        var ownership = TranscriptionModelWarmupOwnership()
        let lease = ownership.beginBackgroundWarmup(for: .parakeetTDTv3)

        assertNotNil(lease)
        let claim = ownership.claimForegroundUse(of: .parakeetTDTv3)
        assertEqual(claim.model, .parakeetTDTv3)
        assertNil(
            claim.obsoleteBackgroundModel,
            "claiming the same model should promote, not tear down, its warmup"
        )
        assertNil(
            ownership.backgroundLease,
            "foreground promotion should make the warmup non-disposable"
        )
        assertTrue(ownership.hasForegroundUse(of: .parakeetTDTv3))
        assertTrue(ownership.releaseForegroundUse(of: .parakeetTDTv3))
        assertFalse(ownership.hasForegroundUse(of: .parakeetTDTv3))
    }

    runSuite("Model warmup ownership - failed starts release their foreground claim") {
        var ownership = TranscriptionModelWarmupOwnership()
        _ = ownership.claimForegroundUse(of: .parakeetTDTv3)

        assertTrue(
            ownership.releaseForegroundUse(of: .parakeetTDTv3),
            "a failed recording start should leave the runtime available for cleanup"
        )
        assertNotNil(
            ownership.beginBackgroundWarmup(for: .parakeetTDTv3),
            "a released model must not stay foreground-owned for the app lifetime"
        )
    }

    runSuite("Model warmup ownership - overlapping users release only at zero") {
        var ownership = TranscriptionModelWarmupOwnership()
        _ = ownership.claimForegroundUse(of: .whisperLargeV3Turbo)
        _ = ownership.claimForegroundUse(of: .whisperLargeV3Turbo)

        assertFalse(
            ownership.releaseForegroundUse(of: .whisperLargeV3Turbo),
            "the runtime must stay protected while another user remains"
        )
        assertTrue(ownership.hasForegroundUse(on: .whisper))
        assertTrue(
            ownership.releaseForegroundUse(of: .whisperLargeV3Turbo),
            "the final release should make the runtime available"
        )
        assertFalse(ownership.hasForegroundUse(on: .whisper))
    }

    runSuite("Model warmup ownership - Whisper variants share one runtime") {
        var ownership = TranscriptionModelWarmupOwnership()
        let lease = ownership.beginBackgroundWarmup(for: .whisperLargeV3Turbo)
        assertNotNil(lease)

        let claim = ownership.claimForegroundUse(of: .whisperLargeV3)
        assertEqual(claim.model, .whisperLargeV3)
        assertEqual(
            claim.obsoleteBackgroundModel,
            .whisperLargeV3Turbo,
            "foreground use of one Whisper variant must displace background work for the other"
        )
        assertNil(ownership.backgroundLease)
        assertNil(
            ownership.beginBackgroundWarmup(for: .whisperLargeV3Turbo),
            "background replacement must wait while the shared Whisper runtime is active"
        )
    }

    runSuite("Model warmup ownership - foreground Whisper variants share one concrete model") {
        var ownership = TranscriptionModelWarmupOwnership()
        let firstClaim = ownership.claimForegroundUse(of: .whisperLargeV3Turbo)
        let secondClaim = ownership.claimForegroundUse(of: .whisperLargeV3)

        assertEqual(firstClaim.model, .whisperLargeV3Turbo)
        assertEqual(
            secondClaim.model,
            .whisperLargeV3Turbo,
            "a second foreground request must reuse the model already active on the runtime"
        )
        assertEqual(
            ownership.foregroundModel(on: .whisper),
            .whisperLargeV3Turbo
        )
        assertNil(secondClaim.obsoleteBackgroundModel)
        assertTrue(ownership.hasForegroundUse(of: .whisperLargeV3Turbo))
        assertFalse(
            ownership.releaseForegroundUse(of: secondClaim.model),
            "the first foreground owner must keep the shared runtime protected"
        )
        assertTrue(ownership.releaseForegroundUse(of: firstClaim.model))
    }

    runSuite("Model warmup ownership - stale completion cannot clear a newer lease") {
        var ownership = TranscriptionModelWarmupOwnership()
        let firstLease = ownership.beginBackgroundWarmup(for: .parakeetTDTv3)!
        assertEqual(
            ownership.takeBackgroundWarmup(whenSwitchingFrom: .parakeetTDTv3),
            .parakeetTDTv3
        )

        let secondLease = ownership.beginBackgroundWarmup(for: .parakeetTDTv3)!
        assertFalse(firstLease == secondLease, "a restarted warmup needs a new generation")

        ownership.finishBackgroundWarmup(firstLease, modelIsLoaded: false)
        assertEqual(
            ownership.backgroundLease,
            secondLease,
            "an old canceled warmup must not clear a newer warmup for the same model"
        )
    }

    runSuite("Model warmup ownership - failed current warmup releases its lease") {
        var ownership = TranscriptionModelWarmupOwnership()
        let lease = ownership.beginBackgroundWarmup(for: .whisperLargeV3Turbo)!

        ownership.finishBackgroundWarmup(lease, modelIsLoaded: false)

        assertNil(ownership.backgroundLease)
        assertNotNil(ownership.beginBackgroundWarmup(for: .whisperLargeV3Turbo))
    }

    runSuite("Model warmup ownership - duplicate releases do not trigger cleanup") {
        var ownership = TranscriptionModelWarmupOwnership()
        let claim = ownership.claimForegroundUse(of: .parakeetTDTv3)

        assertTrue(ownership.releaseForegroundUse(of: claim.model))
        assertFalse(
            ownership.releaseForegroundUse(of: claim.model),
            "an already released claim must remain a no-op"
        )
    }

    runSuite("Recording model ownership - stale sessions cannot release a successor") {
        var ownership = TranscriptionRecordingModelOwnership()
        let first = ownership.replace(with: .parakeetTDTv3)
        let second = ownership.replace(with: .parakeetTDTv3)

        assertEqual(first.replacedModel, nil)
        assertEqual(second.replacedModel, .parakeetTDTv3)
        assertNil(
            ownership.release(ifMatching: first.lease),
            "an older async stop task must not release the newer recording's model"
        )
        assertEqual(ownership.activeLease, second.lease)
        assertEqual(ownership.release(ifMatching: second.lease), .parakeetTDTv3)
        assertNil(ownership.activeLease)
    }

    runSuite("Recording model ownership - unconditional teardown takes only the active lease") {
        var ownership = TranscriptionRecordingModelOwnership()
        _ = ownership.replace(with: .whisperLargeV3Turbo)

        assertEqual(ownership.takeActiveModel(), .whisperLargeV3Turbo)
        assertNil(ownership.takeActiveModel())
    }

    runSuite("Model preparation generation - stale completion cannot publish") {
        var generation = TranscriptionModelPreparationGeneration()
        let first = generation.begin()
        let second = generation.begin()

        assertFalse(generation.isCurrent(first))
        assertTrue(generation.isCurrent(second))
        generation.invalidate()
        assertFalse(
            generation.isCurrent(second),
            "cleanup or job start must invalidate an in-flight model preparation"
        )
    }

    runSuite("Pending model ownership - timeout releases immediately and stale completion is harmless") {
        var warmup = TranscriptionModelWarmupOwnership()
        var pending = TranscriptionPendingModelOwnership()
        var generation = TranscriptionModelPreparationGeneration()

        let firstGeneration = generation.begin()
        let firstClaim = warmup.claimForegroundUse(of: .whisperLargeV3Turbo)
        let firstPending = pending.replace(
            with: firstClaim.model,
            generation: firstGeneration
        )

        generation.invalidate()
        let timedOutModel = pending.takeActiveModel()
        assertEqual(timedOutModel, .whisperLargeV3Turbo)
        assertTrue(
            timedOutModel.map { warmup.releaseForegroundUse(of: $0) } == true,
            "timeout should release the suspended foreground claim immediately"
        )

        let replacementClaim = warmup.claimForegroundUse(of: .whisperLargeV3)
        assertEqual(
            replacementClaim.model,
            .whisperLargeV3,
            "the released runtime must not force a later Whisper request onto the stale variant"
        )
        assertNil(
            pending.take(ifMatching: firstPending.lease),
            "the eventual stale completion must not release the claim a second time"
        )
        assertTrue(warmup.releaseForegroundUse(of: replacementClaim.model))
    }
}
