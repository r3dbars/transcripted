import Foundation

func testMeetingMicOnlyNotice() {
    runSuite("MeetingMicOnlyNoticePolicy.initialNotice — only a recording without the system tap is mic only") {
        assertEqual(
            MeetingMicOnlyNoticePolicy.initialNotice(capturesSystemAudio: false),
            .callAudioOff,
            "Record Just My Mic (chosen now or remembered after Don't Allow) must say so on the pill"
        )
        assertNil(
            MeetingMicOnlyNoticePolicy.initialNotice(capturesSystemAudio: true),
            "a recording that builds the system tap, including Turn It On with no macOS answer, is not mic only"
        )
        assertNil(
            MeetingMicOnlyNoticePolicy.initialNotice(
                capturesSystemAudio: MeetingRecordingStartGate.turnOnWithoutMacOSAnswer.capturesSystemAudio
            ),
            "Turn It On without a macOS answer keeps the tap, so no mic-only note"
        )
        assertEqual(
            MeetingMicOnlyNoticePolicy.initialNotice(
                capturesSystemAudio: MeetingSystemAudioAccessFlow.Outcome.recordMicOnlyRemembered.startDecision.capturesSystemAudio
            ),
            .callAudioOff,
            "the remembered choice after Don't Allow is exactly the meeting that used to record one side silently"
        )
        assertNil(
            MeetingMicOnlyNoticePolicy.initialNotice(
                capturesSystemAudio: MeetingSystemAudioAccessFlow.Outcome.recordBothSides.startDecision.capturesSystemAudio
            ),
            "a normal both-sides meeting shows no note"
        )
    }

    runSuite("MeetingMicOnlyNoticePolicy.tapAction — the fix follows macOS's current answer") {
        assertEqual(
            MeetingMicOnlyNoticePolicy.tapAction(for: .notDetermined),
            .showMacOSBox,
            "macOS hasn't asked yet, so its own allow box can still appear"
        )
        assertEqual(
            MeetingMicOnlyNoticePolicy.tapAction(for: .denied),
            .openSettings,
            "macOS won't ask twice after Don't Allow; only System Settings can turn it on"
        )
        assertEqual(
            MeetingMicOnlyNoticePolicy.tapAction(for: .unavailable),
            .openSettings,
            "when macOS's answer can't be read, Settings is the safe place to send the user"
        )
        assertEqual(
            MeetingMicOnlyNoticePolicy.tapAction(for: .authorized),
            .alreadyOn,
            "turned on in Settings before the click: nothing to open, just show it worked"
        )
    }

    runSuite("MeetingMicOnlyNoticePolicy.notice — flips once call audio is on, and never flips back") {
        assertEqual(
            MeetingMicOnlyNoticePolicy.notice(current: .callAudioOff, afterStatus: .authorized),
            .callAudioOnForNextMeeting,
            "access turned on mid-meeting should read as on for the next meeting"
        )
        for status in [SystemAudioCaptureTCCStatus.denied, .notDetermined, .unavailable] {
            assertEqual(
                MeetingMicOnlyNoticePolicy.notice(current: .callAudioOff, afterStatus: status),
                .callAudioOff,
                "\(status.rawValue) must leave the mic-only note as is"
            )
        }
        assertEqual(
            MeetingMicOnlyNoticePolicy.notice(current: .callAudioOnForNextMeeting, afterStatus: .denied),
            .callAudioOnForNextMeeting,
            "a later read can't take back what the user already saw work"
        )
        assertNil(
            MeetingMicOnlyNoticePolicy.notice(current: nil, afterStatus: .authorized),
            "a both-sides recording never grows a note"
        )
    }

    runSuite("MeetingMicOnlyNoticePolicy.shouldKeepCheckingAccess — stops when on or when the recording ends") {
        assertTrue(
            MeetingMicOnlyNoticePolicy.shouldKeepCheckingAccess(notice: .callAudioOff, isRecording: true),
            "keep re-reading while the user may still be in System Settings"
        )
        assertFalse(
            MeetingMicOnlyNoticePolicy.shouldKeepCheckingAccess(notice: .callAudioOnForNextMeeting, isRecording: true),
            "stop once access is on"
        )
        assertFalse(
            MeetingMicOnlyNoticePolicy.shouldKeepCheckingAccess(notice: .callAudioOff, isRecording: false),
            "stop when the recording ends"
        )
        assertFalse(
            MeetingMicOnlyNoticePolicy.shouldKeepCheckingAccess(notice: nil, isRecording: true),
            "never poll for a both-sides recording"
        )
    }

    runSuite("MeetingMicOnlyNoticeCopy — plain, short, and honest about what is recorded") {
        assertEqual(MeetingMicOnlyNoticeCopy.title(for: .callAudioOff), "Mic only", "the pill note")
        assertEqual(MeetingMicOnlyNoticeCopy.title(for: .callAudioOnForNextMeeting), "Call audio on", "the note after the fix")
        let allCopy = [
            MeetingMicOnlyNoticeCopy.title(for: .callAudioOff),
            MeetingMicOnlyNoticeCopy.title(for: .callAudioOnForNextMeeting),
            MeetingMicOnlyNoticeCopy.tooltip(for: .callAudioOff),
            MeetingMicOnlyNoticeCopy.tooltip(for: .callAudioOnForNextMeeting),
            MeetingMicOnlyNoticeCopy.accessibilityLabel(for: .callAudioOff),
            MeetingMicOnlyNoticeCopy.accessibilityLabel(for: .callAudioOnForNextMeeting),
            MeetingMicOnlyNoticeCopy.accessibilityHelp(for: .callAudioOff),
            MeetingMicOnlyNoticeCopy.accessibilityHelp(for: .callAudioOnForNextMeeting),
            MeetingMicOnlyNoticeCopy.detectedCallPromptDetail,
            MeetingMicOnlyNoticeCopy.checkAccessTitle,
            MeetingMicOnlyNoticeCopy.checkAccessAccessibilityLabel,
            MeetingMicOnlyNoticeCopy.checkAccessTooltip,
        ]
        for copy in allCopy {
            assertFalse(copy.contains("\u{2014}"), "no em dashes: \(copy)")
            assertFalse(copy.lowercased().contains("voice note"), "never say voice notes: \(copy)")
        }
        assertTrue(
            MeetingMicOnlyNoticeCopy.accessibilityLabel(for: .callAudioOnForNextMeeting).contains("stays mic only"),
            "turning access on mid-meeting must not claim this recording now has the other side"
        )
        // The recording pill note sits beside the waveform in a 356pt strip.
        assertTrue(MeetingMicOnlyNoticeCopy.title(for: .callAudioOff).count <= 14, "note title stays short")
        assertTrue(MeetingMicOnlyNoticeCopy.title(for: .callAudioOnForNextMeeting).count <= 14, "note title stays short")
    }

    runSuite("MeetingSystemAudioCheckAccessPolicy — Check Access only where access could be the cause") {
        func warning(
            _ cause: MeetingSystemAudioDegradationWarning.Cause,
            _ phase: MeetingSystemAudioDegradationWarning.Phase
        ) -> MeetingSystemAudioDegradationWarning {
            MeetingSystemAudioDegradationWarning(cause: cause, phase: phase, isPromptDismissed: false)
        }
        assertTrue(
            MeetingSystemAudioCheckAccessPolicy.offersCheckAccess(for: warning(.unverified, .degraded), status: .unavailable),
            "unverified system audio may be access; offer the one-tap check"
        )
        assertTrue(
            MeetingSystemAudioCheckAccessPolicy.offersCheckAccess(for: warning(.failure, .degraded), status: .denied),
            "a failed stream may be access; offer the check"
        )
        assertTrue(
            MeetingSystemAudioCheckAccessPolicy.offersCheckAccess(for: warning(.failure, .recovering), status: .denied),
            "a failing stream may be access; offer the check"
        )
        assertFalse(
            MeetingSystemAudioCheckAccessPolicy.offersCheckAccess(for: warning(.failure, .recovered), status: .denied),
            "a recovered stream needs nothing"
        )
        assertFalse(
            MeetingSystemAudioCheckAccessPolicy.offersCheckAccess(for: warning(.silence, .degraded), status: .denied),
            "silence is normal on a quiet call; don't send the user to Settings for it"
        )
        assertFalse(
            MeetingSystemAudioCheckAccessPolicy.offersCheckAccess(for: warning(.interruption, .recovering), status: .denied),
            "an interruption is a device/route blip, not access"
        )

        assertFalse(
            MeetingSystemAudioCheckAccessPolicy.offersCheckAccess(for: warning(.failure, .degraded), status: .authorized),
            "access already on: Settings would only show a switch that's on"
        )
    }

    runSuite("MeetingMicOnlyNoticePolicy.noticeAfterStart — Turn It On then Don't Allow still says mic only") {
        assertEqual(
            MeetingMicOnlyNoticePolicy.noticeAfterStart(current: nil, mayHaveRaisedMacOSBox: true, status: .denied),
            .callAudioOff,
            "the tap is built but macOS said no, so only the mic is heard"
        )
        assertNil(
            MeetingMicOnlyNoticePolicy.noticeAfterStart(current: nil, mayHaveRaisedMacOSBox: true, status: .authorized),
            "Allow in the box records both sides"
        )
        assertNil(
            MeetingMicOnlyNoticePolicy.noticeAfterStart(current: nil, mayHaveRaisedMacOSBox: true, status: .notDetermined),
            "no answer yet: don't claim mic only"
        )
        assertNil(
            MeetingMicOnlyNoticePolicy.noticeAfterStart(current: nil, mayHaveRaisedMacOSBox: false, status: .denied),
            "an ordinary start was already decided before capture"
        )
    }

    runSuite("MeetingMicOnlyNoticePolicy.detectedCallPromptSaysMicOnly — only when Record won't ask") {
        assertTrue(
            MeetingMicOnlyNoticePolicy.detectedCallPromptSaysMicOnly(status: .denied, micOnlyRemembered: true),
            "remembered mic only after Don't Allow: Record starts one-sided without asking"
        )
        assertFalse(
            MeetingMicOnlyNoticePolicy.detectedCallPromptSaysMicOnly(status: .denied, micOnlyRemembered: false),
            "denied without a choice still gets the question, so don't promise the outcome"
        )
        assertFalse(
            MeetingMicOnlyNoticePolicy.detectedCallPromptSaysMicOnly(status: .authorized, micOnlyRemembered: true),
            "access on: both sides"
        )
    }

    runSuite("Mid-meeting unverified warning points at the Check Access button, briefly") {
        let detail = MeetingSystemAudioDegradationCopy.detail(
            for: MeetingSystemAudioDegradationWarning(cause: .unverified, phase: .degraded, isPromptDismissed: false)
        )
        assertEqual(detail, "Mic is recording. Check System Audio access.", "short enough for the one-line prompt detail")
    }
}
