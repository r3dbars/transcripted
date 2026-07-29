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
        let lease = ownership.beginBackgroundWarmup(for: .nemotronStreaming)!

        ownership.finishBackgroundWarmup(lease, modelIsLoaded: false)

        assertNil(ownership.backgroundLease)
        assertNotNil(ownership.beginBackgroundWarmup(for: .nemotronStreaming))
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
}
