import Foundation

/// The intro's looping autocomplete demo, as data: a sentence types itself,
/// an underlined suggestion fades in, `Tab` takes it one word at a time, then
/// "N keystrokes saved". It cycles a Slack reply, an email and a note
/// (docs/writing-plan.md, "Intro, page 2 of 2"). `WritingDemoView` only plays
/// these frames; with Reduce Motion on it shows `stillFrame` and never moves.
///
/// Foundation only, so the root fast tests compile it.
enum WritingDemoScript {
    struct Scene: Equatable {
        let app: String
        let symbolName: String
        /// What the person types, ending where the suggestion starts.
        let typed: String
        let suggestion: String
    }

    enum Phase: Equatable {
        case typing
        case waiting
        case suggesting
        case accepting
        case saved
    }

    struct Frame: Equatable {
        let sceneIndex: Int
        let phase: Phase
        /// Text in the field: typed, plus any accepted words.
        let fieldText: String
        /// The rest of the suggestion, shown underlined after the field text.
        let ghostText: String
        /// `Tab` is down in this frame.
        let tabPressed: Bool
        /// Shown in the `.saved` frame only.
        let keystrokesSaved: Int?
        /// How long this frame holds before the next one.
        let duration: TimeInterval
    }

    static let scenes = [
        Scene(
            app: "Slack",
            symbolName: "number",
            typed: "Sounds good, I can ",
            suggestion: "take a look after lunch"
        ),
        Scene(
            app: "Mail",
            symbolName: "envelope",
            typed: "Thanks for sending this over. I'll ",
            suggestion: "review it and reply tomorrow"
        ),
        Scene(
            app: "Notes",
            symbolName: "note.text",
            typed: "Next step: follow up with ",
            suggestion: "the design team on Monday"
        ),
    ]

    static let typingInterval: TimeInterval = 0.05
    static let revealDelay: TimeInterval = 0.4
    static let suggestionHold: TimeInterval = 1.0
    static let tabInterval: TimeInterval = 0.45
    static let savedHold: TimeInterval = 1.8

    /// `Tab` adds the next word and its trailing space, so each step is a
    /// word plus the space after it; the last word has none.
    static func wordSteps(in suggestion: String) -> [String] {
        var steps: [String] = []
        var current = ""
        for character in suggestion {
            current.append(character)
            if character == " " {
                steps.append(current)
                current = ""
            }
        }
        if !current.isEmpty { steps.append(current) }
        return steps
    }

    /// Accepted characters, the same measure as "keystrokes saved" in the
    /// everyday view (the outcome ledger counts accepted characters).
    static func keystrokesSaved(for scene: Scene) -> Int {
        scene.suggestion.count
    }

    static func frames(for sceneIndex: Int) -> [Frame] {
        let scene = scenes[sceneIndex]
        var frames: [Frame] = []
        var field = ""
        for character in scene.typed {
            field.append(character)
            frames.append(Frame(
                sceneIndex: sceneIndex,
                phase: .typing,
                fieldText: field,
                ghostText: "",
                tabPressed: false,
                keystrokesSaved: nil,
                duration: typingInterval
            ))
        }
        frames.append(Frame(
            sceneIndex: sceneIndex,
            phase: .waiting,
            fieldText: field,
            ghostText: "",
            tabPressed: false,
            keystrokesSaved: nil,
            duration: revealDelay
        ))
        frames.append(Frame(
            sceneIndex: sceneIndex,
            phase: .suggesting,
            fieldText: field,
            ghostText: scene.suggestion,
            tabPressed: false,
            keystrokesSaved: nil,
            duration: suggestionHold
        ))
        var remaining = scene.suggestion
        for word in wordSteps(in: scene.suggestion) {
            field += word
            remaining = String(remaining.dropFirst(word.count))
            frames.append(Frame(
                sceneIndex: sceneIndex,
                phase: .accepting,
                fieldText: field,
                ghostText: remaining,
                tabPressed: true,
                keystrokesSaved: nil,
                duration: tabInterval
            ))
        }
        frames.append(Frame(
            sceneIndex: sceneIndex,
            phase: .saved,
            fieldText: field,
            ghostText: "",
            tabPressed: false,
            keystrokesSaved: keystrokesSaved(for: scene),
            duration: savedHold
        ))
        return frames
    }

    /// One full cycle: every scene, in order. The view loops it.
    static let allFrames: [Frame] = scenes.indices.flatMap { frames(for: $0) }

    /// Reduce Motion: the first scene with its whole suggestion showing.
    static var stillFrame: Frame {
        frames(for: 0).first { $0.phase == .suggesting }!
    }

    static func keystrokesSavedText(_ count: Int) -> String {
        count == 1 ? "1 keystroke saved" : "\(count) keystrokes saved"
    }
}
