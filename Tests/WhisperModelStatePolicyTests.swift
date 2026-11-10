import Foundation

func testWhisperModelStatePolicy() {
    let turbo = TranscriptionModelChoice.whisperLargeV3Turbo
    let large = TranscriptionModelChoice.whisperLargeV3
    let states: [ParakeetModelState] = [
        .notLoaded, .downloading(progress: 0.37), .cached,
        .loading, .ready, .failed("Synthetic load failure")
    ]

    runSuite("A Whisper variant preserves its own exact state and never borrows another's") {
        for (owner, other) in [(turbo, large), (large, turbo)] {
            for state in states {
                assertEqual(
                    WhisperModelStatePolicy.state(for: owner, owner: owner, storedState: state),
                    state
                )
                assertEqual(
                    WhisperModelStatePolicy.state(for: other, owner: owner, storedState: state),
                    .notLoaded
                )
            }
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

    runSuite("A supplied failure belongs only to its explicit model owner") {
        let failure = ParakeetModelState.failed("Synthetic completed load failure")
        assertEqual(
            WhisperModelStatePolicy.state(for: large, owner: large, storedState: failure),
            failure
        )
        assertEqual(
            WhisperModelStatePolicy.state(for: turbo, owner: large, storedState: failure),
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
                WhisperModelStatePolicy.state(for: large, owner: turbo, storedState: olderStoredState, emittedState: emitted),
                .notLoaded
            )
        }
    }

    runSuite("Explicit owner and state snapshots distinguish old, unowned and new progress") {
        // Input snapshots only; this does not execute engine unload or initialization.
        assertEqual(
            WhisperModelStatePolicy.state(for: turbo, owner: large, storedState: .ready),
            .notLoaded
        )
        assertEqual(
            WhisperModelStatePolicy.state(for: large, owner: large, storedState: .ready),
            .ready
        )
        for model in [large, turbo] {
            assertEqual(
                WhisperModelStatePolicy.state(for: model, owner: nil, storedState: .notLoaded),
                .notLoaded
            )
        }
        assertEqual(
            WhisperModelStatePolicy.state(for: turbo, owner: turbo, storedState: .downloading(progress: 0.12)),
            .downloading(progress: 0.12)
        )
        assertEqual(
            WhisperModelStatePolicy.state(for: large, owner: turbo, storedState: .downloading(progress: 0.12)),
            .notLoaded
        )
    }
}
