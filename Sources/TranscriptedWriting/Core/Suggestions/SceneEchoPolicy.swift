import Foundation

/// Rejects a suggestion that merely reads the screen back. The output
/// cleaner already refuses to replay the user's typed text; this is the
/// same idea for the injected scene context. Found 2026-08-23 while
/// evaluating prompt formats: a model reply can be a verbatim line from
/// the conversation block ("Them: are you still coming"), which reads as
/// nonsense ghost text.
public enum SceneEchoPolicy {
    /// The shipped floor. An echo needs at least three words and ten
    /// characters of contiguous overlap; short overlaps ("ok", "see you")
    /// are normal language reuse, not echoes.
    public static let defaultMinimumWords = 3
    public static let defaultMinimumCharacters = 10

    /// True when the suggestion is substantially a fragment of a scene
    /// turn or reference snippet.
    ///
    /// The floors are parameters rather than constants because Q12 measured
    /// the character floor offline: at 10 characters the detector coincides
    /// with a short visible-word cap, so correct short verbatim answers are
    /// indistinguishable from echo and get killed. Raising the floor is a
    /// nominated validation candidate, live only in the isolated 9B preview
    /// via `TildeProductProfile.sceneEchoMinimumCharacters`.
    public static func isEcho(
        _ suggestionText: String,
        scene: ScreenScene.Scene?,
        minimumWords: Int = defaultMinimumWords,
        minimumCharacters: Int = defaultMinimumCharacters
    ) -> Bool {
        isEcho(
            suggestionText,
            in: prepared(
                scene: scene,
                minimumWords: minimumWords,
                minimumCharacters: minimumCharacters
            )
        )
    }

    /// The profile-derived form the live completion path uses.
    public static func isEcho(
        _ suggestionText: String,
        scene: ScreenScene.Scene?,
        profile: TildeProductProfile
    ) -> Bool {
        isEcho(suggestionText, in: prepared(scene: scene, profile: profile))
    }

    /// One request's scene, normalized once.
    ///
    /// Every turn and snippet is lowercased and stripped of punctuation
    /// before the containment test; that result depends only on the scene, so
    /// a streaming request derives it once here instead of on every partial.
    public struct PreparedScene: Sendable {
        let normalizedSources: [String]
        let minimumWords: Int
        let minimumCharacters: Int

        /// No scene: nothing can be an echo, exactly as `scene == nil` meant
        /// before.
        public static let absent = PreparedScene(
            normalizedSources: [],
            minimumWords: defaultMinimumWords,
            minimumCharacters: defaultMinimumCharacters
        )
    }

    public static func prepared(
        scene: ScreenScene.Scene?,
        minimumWords: Int = defaultMinimumWords,
        minimumCharacters: Int = defaultMinimumCharacters
    ) -> PreparedScene {
        guard let scene else { return .absent }
        let sources = scene.conversationTurns.map(\.text) + scene.referenceSnippets
        return PreparedScene(
            normalizedSources: sources.map(normalized),
            minimumWords: minimumWords,
            minimumCharacters: minimumCharacters
        )
    }

    public static func prepared(
        scene: ScreenScene.Scene?,
        profile: TildeProductProfile
    ) -> PreparedScene {
        prepared(
            scene: scene,
            minimumWords: profile.sceneEchoMinimumWords,
            minimumCharacters: profile.sceneEchoMinimumCharacters
        )
    }

    public static func isEcho(_ suggestionText: String, in scene: PreparedScene) -> Bool {
        guard !scene.normalizedSources.isEmpty else { return false }
        let candidate = normalized(suggestionText)
        guard candidate.count >= scene.minimumCharacters,
              candidate.split(separator: " ").count >= scene.minimumWords else { return false }
        for source in scene.normalizedSources where source.contains(candidate) {
            return true
        }
        return false
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }
}
