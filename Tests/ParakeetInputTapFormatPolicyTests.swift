import AVFoundation
import Foundation

func testParakeetInputTapFormatPolicy() {
    runSuite("Raw input tap matches hardware instead of a stale output bus") {
        for rate: Double in [8_000, 16_000, 24_000, 44_100, 48_000, 96_000] {
            let hardware = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            let staleOutput = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            do {
                let tap = try ParakeetInputTapFormatPolicy.format(
                    inputFormat: hardware, outputFormat: staleOutput, voiceProcessingEnabled: false
                )
                assertTrue(tap === hardware, "raw capture must preserve the entire hardware format at \(rate)Hz")
                assertEqual(tap.sampleRate, rate, "AirPods/USB input must not inherit the playback rate")
                assertEqual(tap.channelCount, 1, "input channels must not inherit the output channel layout")
            } catch {
                assertTrue(false, "valid hardware format should be accepted: \(error)")
            }
        }
    }

    runSuite("Voice processing uses its actual processed format") {
        let hardware = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)!
        let processed = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        do {
            let enabled = try ParakeetInputTapFormatPolicy.format(
                inputFormat: hardware, outputFormat: processed, voiceProcessingEnabled: true
            )
            assertTrue(enabled === processed, "active VPIO retains its processed output format")
            let disabled = try ParakeetInputTapFormatPolicy.format(
                inputFormat: hardware, outputFormat: processed, voiceProcessingEnabled: false
            )
            assertTrue(disabled === hardware, "failed enable or Zoom downgrade must use actual raw hardware")
        } catch {
            assertTrue(false, "valid processing formats should be accepted: \(error)")
        }
    }

    runSuite("Invalid route formats fail before entering native tap installation") {
        let valid = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        // A zeroed ASBD models the unavailable format returned during a route change.
        var description = AudioStreamBasicDescription()
        let unavailable = AVAudioFormat(streamDescription: &description)!
        let unsupported = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: false)!
        for (input, output, processing) in [
            (unavailable, valid, false),
            (unavailable, valid, true),
            (valid, unavailable, true),
            (unsupported, valid, false),
            (valid, unsupported, true),
        ] {
            do {
                _ = try ParakeetInputTapFormatPolicy.format(
                    inputFormat: input, outputFormat: output, voiceProcessingEnabled: processing
                )
                assertTrue(false, "unavailable hardware/processed format must fail closed")
            } catch {
                assertEqual(
                    ParakeetAudioFormatReadinessPolicy.startFailureReason(for: error as NSError),
                    .audioRouteNotSettled,
                    "format loss must enter the existing bounded recovery path"
                )
            }
        }
    }
}
