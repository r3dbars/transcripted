import Foundation

/// Renders Intent Futures into a tiny, fixed-vocabulary prompt block. The
/// planner never copies raw conversation content here; ScreenScene already
/// owns that separately. This block only tells the completion model which
/// semantic directions are currently plausible.
public enum IntentPromptHint {
    public static func block(
        scene: ScreenScene.Scene?,
        textBeforeCursor: String
    ) -> String {
        let futures = IntentFuturesPlanner.futures(
            scene: scene,
            textBeforeCursor: textBeforeCursor
        )
        let hint = IntentFuturesPlanner.promptHint(for: futures)
        guard !hint.isEmpty else { return "" }
        return "Likely response directions: \(hint)\n"
    }
}
