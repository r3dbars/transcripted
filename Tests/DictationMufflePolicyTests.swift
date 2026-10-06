import Foundation

func testDictationMufflePolicy() {
    runSuite("The muffle gate passes only when enabled with no meeting, shared mic, voice processing or automated launch") {
        assertNil(
            DictationMufflePolicy.gate(muffleContext()),
            "enabled, no meeting, own mic, no voice processing, not automated should pass"
        )
    }

    runSuite("Each reason the muffle gate refuses is reported on its own") {
        assertEqual(DictationMufflePolicy.gate(muffleContext(enabled: false)), .disabled, "setting off")
        assertEqual(DictationMufflePolicy.gate(muffleContext(meeting: true)), .meetingRecording, "meeting is recording")
        assertEqual(DictationMufflePolicy.gate(muffleContext(sharedMic: true)), .sharedMeetingMic, "dictating from the shared meeting mic")
        assertEqual(DictationMufflePolicy.gate(muffleContext(voiceProcessing: true)), .voiceProcessing, "voice processing already ducks other apps")
        assertEqual(DictationMufflePolicy.gate(muffleContext(automated: true)), .automatedLaunch, "automated launch")
    }

    runSuite("The muffle gate refuses every combination with a failing input, and automated launch always wins") {
        for enabled in [true, false] {
            for meeting in [true, false] {
                for shared in [true, false] {
                    for voice in [true, false] {
                        for automated in [true, false] {
                            let context = muffleContext(
                                enabled: enabled,
                                meeting: meeting,
                                sharedMic: shared,
                                voiceProcessing: voice,
                                automated: automated
                            )
                            let label = "enabled=\(enabled) meeting=\(meeting) shared=\(shared) voice=\(voice) automated=\(automated)"
                            let result = DictationMufflePolicy.gate(context)
                            let allClear = enabled && !meeting && !shared && !voice && !automated
                            if automated {
                                assertEqual(result, .automatedLaunch, "automated launch should win: \(label)")
                            } else if allClear {
                                assertNil(result, "all clear should pass: \(label)")
                            } else {
                                assertNotNil(result, "a failing input should refuse: \(label)")
                            }
                        }
                    }
                }
            }
        }
    }

    runSuite("Bluetooth output with no input streams and one or two channels may be muffled") {
        assertNil(DictationMuffleOutputRoute.ineligibility(transport: .bluetooth, inputStreamCount: 0, outputChannelCount: 2), "stereo Bluetooth output")
        assertNil(DictationMuffleOutputRoute.ineligibility(transport: .bluetooth, inputStreamCount: 0, outputChannelCount: 1), "mono Bluetooth output")
    }

    runSuite("Wired and built-in outputs with no input streams and one or two channels may be muffled") {
        for transport in muffleAllowedTransports {
            for channels in [1, 2] {
                assertNil(
                    DictationMuffleOutputRoute.ineligibility(transport: transport, inputStreamCount: 0, outputChannelCount: channels),
                    "\(transport) with \(channels) channel(s) should be allowed"
                )
            }
        }
    }

    runSuite("An output with input streams is refused, the AirPods call-mode rule") {
        for transport in muffleAllowedTransports {
            for inputs in [1, 2] {
                for channels in [1, 2] {
                    assertEqual(
                        DictationMuffleOutputRoute.ineligibility(transport: transport, inputStreamCount: inputs, outputChannelCount: channels),
                        .hasInputStreams,
                        "\(transport) with \(inputs) input stream(s), \(channels) channel(s)"
                    )
                }
            }
        }
        // Transports that are refused anyway keep their own reason; they must
        // still never be allowed.
        for transport in muffleAllTransports {
            assertNotNil(
                DictationMuffleOutputRoute.ineligibility(transport: transport, inputStreamCount: 1, outputChannelCount: 2),
                "\(transport) with an input stream must be refused"
            )
        }
    }

    runSuite("An unreadable input-stream or channel count refuses the output") {
        for transport in muffleAllowedTransports {
            assertEqual(
                DictationMuffleOutputRoute.ineligibility(transport: transport, inputStreamCount: nil, outputChannelCount: 2),
                .unreadable,
                "\(transport) with unreadable input streams"
            )
            assertEqual(
                DictationMuffleOutputRoute.ineligibility(transport: transport, inputStreamCount: 0, outputChannelCount: nil),
                .unreadable,
                "\(transport) with unreadable channel count"
            )
            assertEqual(
                DictationMuffleOutputRoute.ineligibility(transport: transport, inputStreamCount: nil, outputChannelCount: nil),
                .unreadable,
                "\(transport) with nothing readable"
            )
        }
    }

    runSuite("AirPlay, virtual, aggregate and unknown outputs are refused with their own reasons") {
        assertEqual(DictationMuffleOutputRoute.ineligibility(transport: .airPlay, inputStreamCount: 0, outputChannelCount: 2), .airPlay, "AirPlay")
        assertEqual(DictationMuffleOutputRoute.ineligibility(transport: .virtual, inputStreamCount: 0, outputChannelCount: 2), .virtualOrAggregate, "virtual")
        assertEqual(DictationMuffleOutputRoute.ineligibility(transport: .aggregate, inputStreamCount: 0, outputChannelCount: 2), .virtualOrAggregate, "aggregate")
        assertEqual(DictationMuffleOutputRoute.ineligibility(transport: .unknown, inputStreamCount: 0, outputChannelCount: 2), .unknownTransport, "unknown")
    }

    runSuite("An output with no channels or more than two channels is refused") {
        for transport in muffleAllowedTransports {
            assertEqual(
                DictationMuffleOutputRoute.ineligibility(transport: transport, inputStreamCount: 0, outputChannelCount: 0),
                .noOutputChannels,
                "\(transport) with 0 channels"
            )
            for channels in [3, 6, 8] {
                assertEqual(
                    DictationMuffleOutputRoute.ineligibility(transport: transport, inputStreamCount: 0, outputChannelCount: channels),
                    .multichannel,
                    "\(transport) with \(channels) channels"
                )
            }
        }
    }
}

private let muffleAllowedTransports: [DictationMuffleOutputTransport] = [
    .builtIn, .usb, .displayLink, .thunderbolt, .pci, .firewire, .bluetooth,
]

private let muffleAllTransports: [DictationMuffleOutputTransport] = muffleAllowedTransports + [
    .airPlay, .virtual, .aggregate, .unknown,
]

private func muffleContext(
    enabled: Bool = true,
    meeting: Bool = false,
    sharedMic: Bool = false,
    voiceProcessing: Bool = false,
    automated: Bool = false
) -> DictationMuffleContext {
    DictationMuffleContext(
        enabled: enabled,
        meetingRecording: meeting,
        dictatingFromSharedMeetingMic: sharedMic,
        voiceProcessingRequested: voiceProcessing,
        automatedLaunch: automated
    )
}
