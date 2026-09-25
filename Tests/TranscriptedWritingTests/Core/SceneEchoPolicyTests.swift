import Testing
@testable import TranscriptedWritingCore

@Suite("Scene echo policy")
struct SceneEchoPolicyTests {
    private let scene = ScreenScene.Scene(
        mode: .replying,
        conversationTurns: [
            .init(speaker: .other, text: "are you still coming or should I go without you?"),
            .init(speaker: .selfSpeaker, text: "still coming, just running a bit behind."),
        ],
        referenceSnippets: ["Invoice 4821 shows a $200 discrepancy versus our PO."]
    )

    @Test("A verbatim turn fragment is an echo")
    func turnFragmentIsEcho() {
        #expect(SceneEchoPolicy.isEcho("should I go without you", scene: scene))
        #expect(SceneEchoPolicy.isEcho("Are you still coming?", scene: scene))
        #expect(SceneEchoPolicy.isEcho("shows a $200 discrepancy versus", scene: scene))
    }

    @Test("Ordinary short reuse is not an echo")
    func shortReuseIsFine() {
        #expect(!SceneEchoPolicy.isEcho("still coming!", scene: scene))
        #expect(!SceneEchoPolicy.isEcho("ok", scene: scene))
        #expect(!SceneEchoPolicy.isEcho("running late, sorry — be there soon", scene: scene))
    }

    @Test("No scene, no echo")
    func nilScene() {
        #expect(!SceneEchoPolicy.isEcho("are you still coming or should I go", scene: nil))
    }

    @Test("Shipping profiles keep the 3-word / 10-character floor exactly")
    func shippingProfilesUnchanged() {
        for profile in [TildeProductProfile.production] {
            #expect(profile.sceneEchoMinimumWords == 3)
            #expect(profile.sceneEchoMinimumCharacters == 10)
            // The same three candidates the shipped floor has always judged.
            #expect(SceneEchoPolicy.isEcho("should I go without you", scene: scene, profile: profile))
            #expect(SceneEchoPolicy.isEcho("Are you still coming?", scene: scene, profile: profile))
            #expect(SceneEchoPolicy.isEcho(
                "shows a $200 discrepancy versus",
                scene: scene,
                profile: profile
            ))
            #expect(!SceneEchoPolicy.isEcho("still coming!", scene: scene, profile: profile))
            #expect(!SceneEchoPolicy.isEcho("ok", scene: scene, profile: profile))
        }
    }

    @Test("The 9B preview raises only the character floor, to 24")
    func preview9BUsesTheTunedCharacterFloor() {
        let profile = TildeProductProfile.preview9B
        #expect(profile.sceneEchoMinimumWords == 3)
        #expect(profile.sceneEchoMinimumCharacters == 24)

        // 22 normalized characters: an echo under the shipped floor, and
        // exactly the short fact-carrying shape Q12 measured as over-killed.
        let shortEcho = "still coming or should"
        #expect(SceneEchoPolicy.isEcho(shortEcho, scene: scene))
        #expect(!SceneEchoPolicy.isEcho(shortEcho, scene: scene, profile: profile))

        // A real long echo is still caught — the Q12 kill rule.
        #expect(SceneEchoPolicy.isEcho(
            "are you still coming or should I go without you",
            scene: scene,
            profile: profile
        ))
    }
}
