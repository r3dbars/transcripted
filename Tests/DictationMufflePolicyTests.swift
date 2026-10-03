import Foundation

func testDictationMufflePolicy() {
    runSuite("Dictation muffles other audio only when every condition is met") {
        assertEqual(
            muffleDecision(),
            .muffle,
            "enabled + authorized + no meeting + own mic + not automated should muffle"
        )
    }

    runSuite("Each reason not to muffle is reported on its own") {
        assertEqual(muffleDecision(enabled: false), .skip(.disabled), "setting off")
        assertEqual(muffleDecision(systemAudioAuthorized: false), .skip(.permissionMissing), "no system audio permission")
        assertEqual(muffleDecision(meetingRecording: true), .skip(.meetingRecording), "meeting is recording")
        assertEqual(muffleDecision(sharedMeetingMic: true), .skip(.sharedMeetingMic), "dictating from the shared meeting mic")
        assertEqual(muffleDecision(voiceProcessing: true), .skip(.voiceProcessing), "Apple voice processing already ducks other apps")
        assertEqual(muffleDecision(automatedLaunch: true), .skip(.automatedLaunch), "automated launch")
    }

    runSuite("Automated launches never muffle, whatever else is true") {
        for enabled in [true, false] {
            for authorized in [true, false] {
                for meeting in [true, false] {
                    for shared in [true, false] {
                        assertEqual(
                            muffleDecision(
                                enabled: enabled,
                                systemAudioAuthorized: authorized,
                                meetingRecording: meeting,
                                sharedMeetingMic: shared,
                                automatedLaunch: true
                            ),
                            .skip(.automatedLaunch),
                            "automated launch must win (enabled=\(enabled) authorized=\(authorized) meeting=\(meeting) shared=\(shared))"
                        )
                    }
                }
            }
        }
    }

    runSuite("Muffling never happens unless all conditions pass") {
        var muffleCount = 0
        for enabled in [true, false] {
            for authorized in [true, false] {
                for meeting in [true, false] {
                    for shared in [true, false] {
                        for automated in [true, false] {
                            for voiceProcessing in [true, false] {
                                let decision = muffleDecision(
                                    enabled: enabled,
                                    systemAudioAuthorized: authorized,
                                    meetingRecording: meeting,
                                    sharedMeetingMic: shared,
                                    voiceProcessing: voiceProcessing,
                                    automatedLaunch: automated
                                )
                                if decision == .muffle { muffleCount += 1 }
                            }
                        }
                    }
                }
            }
        }
        assertEqual(muffleCount, 1, "exactly one of 64 combinations should muffle")
    }

    runSuite("Bluetooth output (AirPods) is never muffled, even with no input streams") {
        for inputs in [0, 1, 2] {
            for outputs in [0, 1, 2, 8] {
                assertEqual(
                    DictationMuffleOutputRoute.ineligibility(transport: .bluetooth, inputStreamCount: inputs, outputChannelCount: outputs),
                    .bluetooth,
                    "bluetooth inputs=\(inputs) outputs=\(outputs)"
                )
            }
        }
    }

    runSuite("AirPlay, virtual, aggregate and unknown outputs are refused") {
        assertEqual(
            DictationMuffleOutputRoute.ineligibility(transport: .airPlay, inputStreamCount: 0, outputChannelCount: 2),
            .airPlay,
            "airplay"
        )
        assertEqual(
            DictationMuffleOutputRoute.ineligibility(transport: .virtual, inputStreamCount: 0, outputChannelCount: 2),
            .virtualOrAggregate,
            "virtual"
        )
        assertEqual(
            DictationMuffleOutputRoute.ineligibility(transport: .aggregate, inputStreamCount: 0, outputChannelCount: 2),
            .virtualOrAggregate,
            "aggregate"
        )
        assertEqual(
            DictationMuffleOutputRoute.ineligibility(transport: .unknown, inputStreamCount: 0, outputChannelCount: 2),
            .unknownTransport,
            "unknown"
        )
    }

    runSuite("Wired and built-in outputs with no input streams can be muffled") {
        for transport in allowedMuffleTransports {
            for outputs in [1, 2, 6] {
                assertNil(
                    DictationMuffleOutputRoute.ineligibility(transport: transport, inputStreamCount: 0, outputChannelCount: outputs),
                    "\(transport) with 0 inputs and \(outputs) outputs should be allowed"
                )
            }
        }
    }

    runSuite("An output device that also has an input stream is refused") {
        for transport in allowedMuffleTransports {
            for inputs in [1, 2] {
                assertEqual(
                    DictationMuffleOutputRoute.ineligibility(transport: transport, inputStreamCount: inputs, outputChannelCount: 2),
                    .hasInputStreams,
                    "\(transport) with \(inputs) input streams"
                )
            }
        }
    }

    runSuite("An output device with no output channels is refused") {
        for transport in allowedMuffleTransports {
            assertEqual(
                DictationMuffleOutputRoute.ineligibility(transport: transport, inputStreamCount: 0, outputChannelCount: 0),
                .noOutputChannels,
                "\(transport) with 0 output channels"
            )
            assertNotNil(
                DictationMuffleOutputRoute.ineligibility(transport: transport, inputStreamCount: 1, outputChannelCount: 0),
                "\(transport) with inputs and 0 output channels"
            )
        }
    }
}

private let allowedMuffleTransports: [DictationMuffleOutputTransport] = [
    .builtIn, .usb, .displayLink, .thunderbolt, .pci, .firewire,
]

private func muffleDecision(
    enabled: Bool = true,
    systemAudioAuthorized: Bool = true,
    meetingRecording: Bool = false,
    sharedMeetingMic: Bool = false,
    voiceProcessing: Bool = false,
    automatedLaunch: Bool = false
) -> DictationMuffleDecision {
    DictationMufflePolicy.decision(
        enabled: enabled,
        systemAudioAuthorized: systemAudioAuthorized,
        meetingRecording: meetingRecording,
        dictatingFromSharedMeetingMic: sharedMeetingMic,
        voiceProcessingRequested: voiceProcessing,
        automatedLaunch: automatedLaunch
    )
}
