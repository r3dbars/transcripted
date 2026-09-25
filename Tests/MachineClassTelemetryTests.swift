import Foundation

func testMachineClassTelemetry() {
    runSuite("Chip family comes from the brand string, nothing else") {
        assertEqual(MachineClassTelemetry.chip(fromBrandString: "Apple M1"), "m1", "base chip")
        assertEqual(MachineClassTelemetry.chip(fromBrandString: "Apple M2 Pro"), "m2_pro", "pro tier")
        assertEqual(MachineClassTelemetry.chip(fromBrandString: "Apple M3 Max"), "m3_max", "max tier")
        assertEqual(MachineClassTelemetry.chip(fromBrandString: "Apple M1 Ultra"), "m1_ultra", "ultra tier")
        assertEqual(MachineClassTelemetry.chip(fromBrandString: "Apple M10"), "m10", "two-digit family")
        assertEqual(MachineClassTelemetry.chip(fromBrandString: "Apple M4 (Virtual)"), "m4", "unknown suffix is ignored")
        assertEqual(MachineClassTelemetry.chip(fromBrandString: "Intel(R) Core(TM) i9"), "unknown", "non-Apple chips are unknown")
        assertEqual(MachineClassTelemetry.chip(fromBrandString: "Apple Max"), "unknown", "no family number")
        assertEqual(MachineClassTelemetry.chip(fromBrandString: nil), "unknown", "sysctl failure")
    }

    runSuite("Memory is a coarse bucket") {
        let gigabyte: UInt64 = 1_073_741_824
        assertEqual(MachineClassTelemetry.memoryBucket(bytes: 8 * gigabyte), "8gb", "8 GB")
        assertEqual(MachineClassTelemetry.memoryBucket(bytes: 16 * gigabyte), "16gb", "16 GB")
        assertEqual(MachineClassTelemetry.memoryBucket(bytes: 18 * gigabyte), "16gb", "18 GB rounds into 16")
        assertEqual(MachineClassTelemetry.memoryBucket(bytes: 24 * gigabyte), "24gb", "24 GB")
        assertEqual(MachineClassTelemetry.memoryBucket(bytes: 36 * gigabyte), "32gb", "36 GB rounds into 32")
        assertEqual(MachineClassTelemetry.memoryBucket(bytes: 48 * gigabyte), "48gb", "48 GB")
        assertEqual(MachineClassTelemetry.memoryBucket(bytes: 64 * gigabyte), "64gb", "64 GB")
        assertEqual(MachineClassTelemetry.memoryBucket(bytes: 128 * gigabyte), "96gb_plus", "large memory")
    }

    runSuite("Exact timings are rounded to 10 ms") {
        assertEqual(MachineClassTelemetry.roundedMilliseconds(0), "0", "zero")
        assertEqual(MachineClassTelemetry.roundedMilliseconds(194), "190", "rounds down")
        assertEqual(MachineClassTelemetry.roundedMilliseconds(195), "200", "rounds half up")
        assertEqual(MachineClassTelemetry.roundedMilliseconds(5_016), "5020", "seconds")
        assertEqual(MachineClassTelemetry.roundedMilliseconds(-5), "0", "negative clamps to zero")
    }

    runSuite("Speed fields survive the analytics sanitizer") {
        let properties = MachineClassTelemetry.current.merging([
            "stt_model": "parakeet-tdt-v3",
            "start_latency_ms": "190",
            "first_sound_latency_ms": "200",
            "first_sound_latency_bucket": "100_249ms",
            "decode_latency_ms": "420",
            "stop_to_paste_latency_ms": "610",
        ]) { current, _ in current }
        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(properties, allowedKeys: Set(properties.keys))
        for key in properties.keys {
            assertEqual(sanitized[key], properties[key], "\(key) reaches PostHog unchanged")
        }
    }
}
