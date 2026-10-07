// MeetingSystemAudioPermissionProbe.swift
// The Core Audio tap behind the system-audio permission probe. Support owns the
// probe logic (`SystemAudioPermissionRequester`) but may not name Core, so
// Meeting supplies the real capture backend and the entry points that use it.

import Foundation
import TranscriptedCore

@MainActor
enum MeetingSystemAudioPermissionProbe {
    /// A requester wired to a fresh `CoreAudioSystemAudioCapture` tap. Only
    /// signal presence is checked; no audio is saved or sent anywhere.
    static func makeRequester() -> SystemAudioPermissionRequester {
        let capture = CoreAudioSystemAudioCapture()
        return SystemAudioPermissionRequester(
            prepare: { try capture.prepare() },
            start: { receivedSignal in
                try capture.start { buffer in
                    receivedSignal(SystemAudioPermissionProbeClassifier.sampleEvidence(buffer))
                }
            },
            stop: { capture.stopSync() },
            backendErrors: capture.errorMessagePublisher
        )
    }

    static func accessDecision(forceRefresh: Bool = false) async -> TranscriptedPermissionAccess.SystemAudioPermissionAccessDecision {
        await TranscriptedPermissionAccess.systemAudioRecordingAccessDecision(
            forceRefresh: forceRefresh,
            makeRequester: makeRequester
        )
    }

    static func revalidateStatus() async -> Bool {
        await TranscriptedPermissionAccess.revalidateSystemAudioRecordingStatus(makeRequester: makeRequester)
    }

    /// The Settings / onboarding "Grant" action: same as
    /// `TranscriptedPermissionAccess.requestAccessOrOpenSettings`, with the
    /// system-audio probe wired to the Core Audio tap.
    @discardableResult
    static func requestAccessOrOpenSettings(
        for kind: TranscriptedPermissionKind,
        firstAccessibilityAskShowsPromptOnly: Bool = false
    ) async -> Bool {
        await TranscriptedPermissionAccess.requestAccessOrOpenSettings(
            for: kind,
            firstAccessibilityAskShowsPromptOnly: firstAccessibilityAskShowsPromptOnly,
            requestSystemAudio: {
                await TranscriptedPermissionAccess.requestSystemAudioRecordingAccessIfNeeded(
                    forceRefresh: true,
                    makeRequester: makeRequester
                )
            }
        )
    }
}
