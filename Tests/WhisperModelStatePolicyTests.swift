import Foundation

func testWhisperModelStatePolicy() {
    let turbo = TranscriptionModelChoice.whisperLargeV3Turbo
    let parakeet = TranscriptionModelChoice.parakeetTDTv3
    let states: [ParakeetModelState] = [
        .notLoaded, .downloading(progress: 0.37), .cached,
        .loading, .ready, .failed("Synthetic load failure")
    ]

    runSuite("Whisper Turbo preserves its own exact state and never leaks to non-Whisper models") {
        for state in states {
            assertEqual(
                WhisperModelStatePolicy.state(for: turbo, owner: turbo, storedState: state),
                state
            )
            assertEqual(
                WhisperModelStatePolicy.state(for: parakeet, owner: turbo, storedState: state),
                .notLoaded
            )
        }
    }

    runSuite("Unowned states and non-Whisper requests cannot claim Whisper readiness") {
        for model in TranscriptionModelChoice.allCases {
            for state in states {
                assertEqual(
                    WhisperModelStatePolicy.state(for: model, owner: nil, storedState: state),
                    .notLoaded
                )
                if !model.isWhisper {
                    assertEqual(
                        WhisperModelStatePolicy.state(for: model, owner: model, storedState: state),
                        .notLoaded
                    )
                }
            }
        }
    }

    runSuite("A supplied failure belongs only to its explicit Whisper owner") {
        let failure = ParakeetModelState.failed("Synthetic completed load failure")
        assertEqual(
            WhisperModelStatePolicy.state(for: turbo, owner: turbo, storedState: failure),
            failure
        )
        assertEqual(
            WhisperModelStatePolicy.state(for: turbo, owner: parakeet, storedState: failure),
            .notLoaded
        )
    }

    runSuite("An emitted payload overrides older storage only for its matching owner") {
        let olderStoredState = ParakeetModelState.downloading(progress: 0.21)
        assertEqual(
            WhisperModelStatePolicy.state(for: turbo, owner: turbo, storedState: olderStoredState, emittedState: nil),
            olderStoredState
        )
        assertEqual(
            WhisperModelStatePolicy.state(for: turbo, owner: nil, storedState: olderStoredState, emittedState: .ready),
            .notLoaded
        )
        for emitted in [ParakeetModelState.loading, .ready, .failed("Synthetic emitted failure")] {
            assertEqual(
                WhisperModelStatePolicy.state(for: turbo, owner: turbo, storedState: olderStoredState, emittedState: emitted),
                emitted
            )
            assertEqual(
                WhisperModelStatePolicy.state(for: parakeet, owner: turbo, storedState: olderStoredState, emittedState: emitted),
                .notLoaded
            )
        }
    }

    runSuite("Explicit owner and state snapshots distinguish old, unowned and new progress") {
        // Input snapshots only; this does not execute engine unload or initialization.
        assertEqual(
            WhisperModelStatePolicy.state(for: turbo, owner: parakeet, storedState: .ready),
            .notLoaded
        )
        assertEqual(
            WhisperModelStatePolicy.state(for: turbo, owner: nil, storedState: .notLoaded),
            .notLoaded
        )
        assertEqual(
            WhisperModelStatePolicy.state(for: turbo, owner: turbo, storedState: .downloading(progress: 0.12)),
            .downloading(progress: 0.12)
        )
        assertEqual(
            WhisperModelStatePolicy.state(for: parakeet, owner: turbo, storedState: .downloading(progress: 0.12)),
            .notLoaded
        )
    }
}
