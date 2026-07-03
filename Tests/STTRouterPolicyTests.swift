// STTRouterPolicyTests.swift
// Tests the pure routing-classification policy that STTRouter relies on to
// dispatch between the Parakeet, Whisper, and Nemotron engines. STTRouter
// itself is a MainActor wrapper over live AVAudioEngine / FluidAudio / WhisperKit engines
// with no pure-function seams; its routing decisions are driven entirely by
// switching on TranscriptionModelChoice cases. These tests pin the
// classification surface (engineName, isWhisper, whisperKitModelName,
// transcriptionEngineIdentifier) so changes to that surface cannot silently
// reroute dictation/meeting audio to the wrong backend.

import Foundation

func testSTTRouterPolicy() {
    runSuite("STTRouter policy — Parakeet routes to the parakeet engine") {
        let model: TranscriptionModelChoice = .parakeetTDTv3

        assertEqual(model.engineName, "parakeet", "Parakeet must dispatch to the parakeet engine path")
        assertFalse(model.isWhisper, "Parakeet must not be classified as a Whisper model")
        assertNil(model.whisperKitModelName, "Parakeet must not request a WhisperKit model name")
    }

    runSuite("STTRouter policy — Whisper Large V3 Turbo routes to the whisper engine") {
        let model: TranscriptionModelChoice = .whisperLargeV3Turbo

        assertEqual(model.engineName, "whisper", "Whisper Turbo must dispatch to the whisper engine path")
        assertTrue(model.isWhisper, "Whisper Turbo must be classified as a Whisper model")
        assertEqual(
            model.whisperKitModelName,
            "large-v3-v20240930_turbo_632MB",
            "Whisper Turbo must resolve to the turbo WhisperKit bundle"
        )
    }

    runSuite("STTRouter policy — Whisper Large V3 routes to the whisper engine") {
        let model: TranscriptionModelChoice = .whisperLargeV3

        assertEqual(model.engineName, "whisper", "Whisper must dispatch to the whisper engine path")
        assertTrue(model.isWhisper, "Whisper must be classified as a Whisper model")
        assertEqual(
            model.whisperKitModelName,
            "large-v3-v20240930_626MB",
            "Whisper must resolve to the non-turbo WhisperKit bundle"
        )
    }

    runSuite("STTRouter policy — Nemotron streaming routes to the nemotron engine") {
        let model: TranscriptionModelChoice = .nemotronStreaming

        assertEqual(model.engineName, "nemotron", "Nemotron must dispatch to the nemotron engine path")
        assertFalse(model.isWhisper, "Nemotron must not be classified as a Whisper model")
        assertNil(model.whisperKitModelName, "Nemotron must not request a WhisperKit model name")
    }

    runSuite("STTRouter policy — every model classifies to exactly one engine") {
        // Mirror STTRouter's switch: every case must map to exactly one of the
        // parakeet, whisper, or nemotron engine paths.
        for model in TranscriptionModelChoice.allCases {
            let enginePaths = ["parakeet", "whisper", "nemotron"].filter { $0 == model.engineName }
            assertEqual(
                enginePaths.count,
                1,
                "model \(model.rawValue) must route to exactly one known engine path"
            )
            assertEqual(
                model.isWhisper,
                model.engineName == "whisper",
                "isWhisper flag must agree with engineName for \(model.rawValue)"
            )
        }
    }

    runSuite("STTRouter policy — Whisper models carry a WhisperKit bundle name; Parakeet does not") {
        for model in TranscriptionModelChoice.allCases {
            if model.isWhisper {
                assertNotNil(
                    model.whisperKitModelName,
                    "Whisper model \(model.rawValue) must resolve to a WhisperKit bundle"
                )
            } else {
                assertNil(
                    model.whisperKitModelName,
                    "non-Whisper model \(model.rawValue) must not request a WhisperKit bundle"
                )
            }
        }
    }

    runSuite("STTRouter policy — every model exposes a stable analytics engine identifier") {
        // STTRouter / EventReporter rely on these strings for dictation_model_unavailable
        // and transcription engine analytics; pin them so renames are intentional.
        assertEqual(
            TranscriptionModelChoice.parakeetTDTv3.transcriptionEngineIdentifier,
            "parakeet_local"
        )
        assertEqual(
            TranscriptionModelChoice.whisperLargeV3Turbo.transcriptionEngineIdentifier,
            "whisper_large_v3_turbo_local"
        )
        assertEqual(
            TranscriptionModelChoice.whisperLargeV3.transcriptionEngineIdentifier,
            "whisper_large_v3_local"
        )
        assertEqual(
            TranscriptionModelChoice.nemotronStreaming.transcriptionEngineIdentifier,
            "nemotron_streaming_local"
        )

        // Identifiers must be unique across all cases.
        let ids = TranscriptionModelChoice.allCases.map { $0.transcriptionEngineIdentifier }
        assertEqual(
            Set(ids).count,
            ids.count,
            "transcriptionEngineIdentifier must be unique across all models"
        )
    }

    runSuite("STTRouter policy — display strings used in unavailable-model error context are non-empty") {
        // STTRouter logs `model.title` and `model.rawValue` when Whisper init fails;
        // empty values would produce useless diagnostics.
        for model in TranscriptionModelChoice.allCases {
            assertFalse(model.title.isEmpty, "title must be non-empty for \(model.rawValue)")
            assertFalse(model.shortTitle.isEmpty, "shortTitle must be non-empty for \(model.rawValue)")
            assertFalse(model.rawValue.isEmpty, "rawValue must be non-empty for \(model)")
            assertFalse(
                model.transcriptionEngineDisplayName.isEmpty,
                "transcriptionEngineDisplayName must be non-empty for \(model.rawValue)"
            )
        }
    }

    runSuite("STTRouter policy — rawValues are stable and round-trip through TranscriptionModelChoice") {
        // STTRouter and TranscriptionModelPreferences persist these raw values.
        // Renaming them silently would orphan existing user preferences and
        // reroute their audio to the default model after upgrade.
        assertEqual(TranscriptionModelChoice.parakeetTDTv3.rawValue, "parakeet-tdt-v3")
        assertEqual(TranscriptionModelChoice.whisperLargeV3Turbo.rawValue, "whisper-large-v3-turbo")
        assertEqual(TranscriptionModelChoice.whisperLargeV3.rawValue, "whisper-large-v3")
        assertEqual(TranscriptionModelChoice.nemotronStreaming.rawValue, "nemotron-streaming-0.6b")

        for model in TranscriptionModelChoice.allCases {
            assertEqual(
                TranscriptionModelChoice(rawValue: model.rawValue),
                model,
                "rawValue must round-trip for \(model.rawValue)"
            )
        }
    }

    runSuite("STTRouter policy — unknown rawValues do not resolve to any model") {
        // Guards against accidental fallbacks routing unknown saved models
        // into Parakeet at the enum layer (TranscriptionModelPreferences
        // handles the default-substitution separately).
        assertNil(TranscriptionModelChoice(rawValue: "not-a-real-model"))
        assertNil(TranscriptionModelChoice(rawValue: ""))
        assertNil(TranscriptionModelChoice(rawValue: "parakeet"))
        assertNil(TranscriptionModelChoice(rawValue: "whisper-large-v3-turbo "))  // trailing space
    }

    runSuite("STTRouter policy — runtime availability is true for every non-gated model; Nemotron follows its beta gate") {
        // STTRouter.refreshModelDownloadState and TranscriptionModelPreferences
        // .effectiveModel both fan out on isRuntimeAvailable. Pin the current
        // contract so flipping a model to unavailable is an intentional change.
        for model in TranscriptionModelChoice.allCases where model != .nemotronStreaming {
            assertTrue(
                model.isRuntimeAvailable,
                "model \(model.rawValue) must currently be runtime-available so STTRouter does not fall back unexpectedly"
            )
        }

        // Nemotron is the one beta-gated model: its availability must track
        // the opt-in flag so effectiveModel() self-heals to Parakeet when off.
        let suiteName = "STTRouterPolicyTests.nemotron-gate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(
            TranscriptionModelChoice.nemotronStreaming.isRuntimeAvailable(userDefaults: defaults),
            "Nemotron must be runtime-unavailable while the beta flag is off"
        )
        SpeechModelBetaPreferences.setNemotronBetaEnabled(true, userDefaults: defaults)
        assertTrue(
            TranscriptionModelChoice.nemotronStreaming.isRuntimeAvailable(userDefaults: defaults),
            "Nemotron must become runtime-available once the beta flag is on"
        )
    }

    runSuite("STTRouter policy — Whisper bundle names are unique per Whisper case") {
        // If two Whisper cases collided to the same bundle name STTRouter would
        // load the wrong model when a user switched between them.
        let whisperBundles = TranscriptionModelChoice.allCases
            .compactMap { $0.whisperKitModelName }
        assertEqual(
            Set(whisperBundles).count,
            whisperBundles.count,
            "Whisper bundle names must be unique across Whisper cases"
        )
    }

    runSuite("STTRouter policy — notification name STTRouter subscribes to is stable") {
        // STTRouter listens on .transcriptionModelPreferenceDidChange to refetch
        // the effective model and re-initialize. The raw string is the contract
        // between the preference writer and the router observer.
        assertEqual(
            Notification.Name.transcriptionModelPreferenceDidChange.rawValue,
            "transcriptionModelPreferenceDidChange",
            "preference-change notification name must stay stable so STTRouter keeps observing"
        )
    }
}
