// DictationInputDeviceSelectionPolicy.swift
// Dictation uses the same Bluetooth-headset avoidance policy as meeting capture.

#if !TRANSCRIPTED_FAST_TESTS
import TranscriptedCore
#endif

typealias DictationAudioTransport = MeetingAudioTransport
typealias DictationAudioDevice = MeetingAudioDevice
typealias DictationInputDeviceSelectionReason = MeetingInputDeviceSelectionReason
typealias DictationInputDeviceSelection = MeetingInputDeviceSelection
typealias DictationInputDeviceSelectionPolicy = MeetingInputDeviceSelectionPolicy
