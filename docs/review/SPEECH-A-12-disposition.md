# SPEECH-A-12: buffer cadence explains the level comment

The proposed correction from “about 25 readings a second” to 30 is rejected
for the existing 10 ms buffer case. This records a reviewed finding; it does
not propose an audio change.

`TranscriptedConstants.dictationLevelReadingInterval` is `1.0 / 30` seconds.
`DictationAudioLevelWindow.add` emits only after complete buffers reach that
threshold, then resets its accumulated duration to zero. It does not carry
overshoot into the next reading. Four 10 ms buffers therefore make one 40 ms
window, yielding 25 readings over 100 such buffers.

The existing `DictationAudioLevelWindowTests.swift` fixture asserts both 25
readings and indexes 3, 7, …, 99 for those 100 buffers. It separately checks
that 1024-frame buffers at 48 kHz emit every second buffer. The emission rate
depends on buffer size; neither 25 nor 30 is an unconditional timer rate.

This disposition is based on source and existing test assertions at audited
main `8a38235eef00816a79daa1324387a21ef880204d`. The test was inspected,
not executed for this documentation change. Native callback cadence and
waveform presentation are not measured here. The source comment, threshold,
accumulation algorithm and tests remain unchanged.
