import Foundation

/// Promises of the voice print's identity:
///   - the same ID always gets the same color and ring gaps (pinned to the
///     approved mockup generator's output, so the app draws what the design showed);
///   - every print is the same five rings, only gap angles differ, in 15-degree
///     steps with neighbouring gaps at least 45 degrees apart;
///   - people on one call never share a color while colors remain.
func testVoicePrintStyle() {
    runSuite("Voice prints match the approved mockup generator") {
        let priya = VoicePrintStyle(seedString: "priya-13")
        assertEqual(VoicePrintStyle.palette[priya.preferredColorIndex].name, "Lavender", "priya color")
        assertEqual(priya.gapAngles, [30, 120, 45, 135, 210], "priya gaps")
        let marcus = VoicePrintStyle(seedString: "marcus-264")
        assertEqual(VoicePrintStyle.palette[marcus.preferredColorIndex].name, "Sky", "marcus color")
        assertEqual(marcus.gapAngles, [270, 195, 270, 135, 345], "marcus gaps")
        let dana = VoicePrintStyle(seedString: "dana-1")
        assertEqual(VoicePrintStyle.palette[dana.preferredColorIndex].name, "Rose", "dana color")
        assertEqual(dana.gapAngles, [180, 255, 135, 195, 135], "dana gaps")
        let uuid = VoicePrintStyle(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
        assertEqual(VoicePrintStyle.palette[uuid.preferredColorIndex].name, "Periwinkle", "uuid color")
        assertEqual(uuid.gapAngles, [75, 270, 210, 285, 135], "uuid gaps")
    }

    runSuite("Every print is tidy: 5 rings, 15-degree gaps, neighbours 45+ apart, stable per ID") {
        for _ in 0..<200 {
            let id = UUID()
            let style = VoicePrintStyle(id: id)
            assertEqual(style, VoicePrintStyle(id: id), "stable")
            assertEqual(style.gapAngles.count, VoicePrintStyle.ringRadii.count, "one gap per ring")
            assertTrue(style.gapAngles.allSatisfy { $0 >= 0 && $0 < 360 && $0.truncatingRemainder(dividingBy: 15) == 0 }, "15-degree steps")
            for i in 1..<style.gapAngles.count {
                assertTrue(VoicePrintStyle.angularDistance(style.gapAngles[i], style.gapAngles[i - 1]) >= 45, "neighbours apart")
            }
            assertTrue((0..<VoicePrintStyle.palette.count).contains(style.preferredColorIndex), "palette index")
        }
    }

    runSuite("People on one call get different colors while colors remain") {
        let ids = (0..<8).map { _ in UUID() }
        let colors = VoicePrintStyle.colorIndices(for: ids)
        assertEqual(Set(colors.values).count, 8, "eight people, eight colors")
        let first = ids[0]
        assertEqual(colors[first], VoicePrintStyle(id: first).preferredColorIndex, "first keeps preferred")
        let crowd = (0..<11).map { _ in UUID() }
        assertEqual(VoicePrintStyle.colorIndices(for: crowd).count, 11, "more people than colors still all colored")
    }
}
