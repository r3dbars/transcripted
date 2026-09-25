import Foundation

/// The Writing tab's words and small rules: the approved design's copy
/// (docs/writing-plan.md, "Product design (approved)"), which setup rows show,
/// badge text, validation messages, and the everyday view's summary and
/// status lines. Views read every string from here, so the fast tests pin
/// the approved copy word for word.
///
/// Foundation plus `TildeModelChoice` only, so the root fast tests compile it.
enum WritingSetupPresentation {
    // MARK: - Intro, page 1 of 2

    struct ContextItem: Equatable {
        let title: String
        /// Meetings and Dictations are already saved; Writing is the one to add.
        let isAdded: Bool
    }

    struct Point: Equatable {
        let symbolName: String
        let title: String
        let line: String
    }

    enum IntroPage1 {
        static let smallTitle = "Writing"
        static let headline = "Your AI knows what you said. Not what you wrote."
        static let body = "Transcripted already saves your meetings and dictations. But a lot of your work happens in writing: Slack replies, emails, notes. Writing in Transcripted adds that context, and helps you write faster."
        static let contextLabel = "Your context"
        static let contextItems = [
            ContextItem(title: "Meetings", isAdded: false),
            ContextItem(title: "Dictations", isAdded: false),
            ContextItem(title: "Writing", isAdded: true),
        ]
        static let points = [
            Point(
                symbolName: "sparkles",
                title: "Fuller context for your AI.",
                line: "Your notes and replies sit next to your meetings, so your AI can pick up where you left off."
            ),
            Point(
                symbolName: "hand.raised",
                title: "You're in control.",
                line: "Pick the apps. Pause or delete anytime."
            ),
            Point(
                symbolName: "lock",
                title: "100% local.",
                line: "No account. Your writing never leaves your Mac. It's saved as plain files you can point any AI agent at."
            ),
        ]
        static let next = "Next"
    }

    // MARK: - Intro, page 2 of 2

    struct KeyHint: Equatable {
        /// The key cap, or `nil` for "keep typing", which has no single key.
        let key: String?
        let text: String
    }

    enum IntroPage2 {
        static let headline = "Autocomplete finishes your sentences."
        static let body = "As you type, Transcripted suggests the next few words right where you're typing. Take them or leave them."
        /// The `~` key is named by its cap only: on ISO keyboards it isn't
        /// "the key above Tab" (a Tilde help-text bug the plan fixes).
        static let keyHints = [
            KeyHint(key: "Tab", text: "adds the next word"),
            KeyHint(key: "~", text: "takes the whole suggestion"),
            KeyHint(key: nil, text: "Keep typing to ignore it"),
            KeyHint(key: "Esc", text: "hides it"),
        ]
        static let back = "Back"
        static let setUp = "Set up writing"
    }

    static let introPageCount = 2

    // MARK: - Setup

    static let setupStepCount = 3

    static func stepLabel(_ step: Int) -> String {
        "Step \(step) of \(setupStepCount)"
    }

    enum Step1 {
        static let title = "What should writing do?"
        static let saveTitle = "Save my writing"
        static let saveLine = "Your AI can read what you wrote. Files stay on this Mac, only in apps you choose."
        static let autocompleteTitle = "Autocomplete"
        static let autocompleteLine = "Suggests the next words. Hit Tab to accept."
        static let continueTitle = "Continue"
        static let needsOne = "Turn on at least one to continue."
    }

    enum Step2 {
        static let title = "Which apps?"
        static let allApps = "All apps"
        static let allAppsLine = "Password managers are always skipped."
        static let pickedApps = "Only apps I pick"
        static let sameApps = "Autocomplete uses the same apps."
        static let needsOne = "Pick at least one app."
        static let moreApps = "More apps"
        static let fewerApps = "Fewer apps"
    }

    enum Step3 {
        static let title = "Allow and download"
        static let keyboardTitle = "Transcripted keyboard"
        static let keyboardLine = "Turns on in Input Sources. No privacy prompt."
        static let screenRecordingTitle = "Screen Recording"
        static let screenRecordingLine = "Reads the window you're replying in, on this Mac."
        static let modelTitle = "Model"
        static let autocompleteBadge = "Autocomplete"
        static let qwenIneligible = "Your Mac needs 16 GB of memory for this model."
        static let footnote = "Suggestion counts only, never text. Follows your analytics setting."
        static let turnOn = "Turn on writing"
    }

    static let back = "Back"
    /// Only while editing a finished setup: leaves the steps unchanged.
    static let cancel = "Cancel"
    /// Shown instead of the Screen Recording request while a meeting or
    /// dictation records: macOS may ask Transcripted to quit and reopen after
    /// the grant.
    static let finishRecordingFirst = "Finish your recording first"

    /// The rows step 3 shows: only what the step 1 toggles need
    /// (docs/writing-plan.md, "Permissions").
    enum Step3Row: Equatable, CaseIterable {
        case keyboard
        case screenRecording
        case model
    }

    static func step3Rows(saveMyWriting: Bool, autocomplete: Bool) -> [Step3Row] {
        var rows: [Step3Row] = []
        if saveMyWriting || autocomplete { rows.append(.keyboard) }
        if autocomplete { rows += [.screenRecording, .model] }
        return rows
    }

    /// Both features use the keyboard; with only one on it's simply needed.
    static func keyboardBadge(saveMyWriting: Bool, autocomplete: Bool) -> String {
        saveMyWriting && autocomplete ? "Both" : "Needed"
    }

    /// `nil` when step 1 can continue.
    static func step1Message(saveMyWriting: Bool, autocomplete: Bool) -> String? {
        saveMyWriting || autocomplete ? nil : Step1.needsOne
    }

    /// `nil` when step 2 can continue.
    static func step2Message(scope: ScopeMode, pickedCount: Int) -> String? {
        scope == .picked && pickedCount == 0 ? Step2.needsOne : nil
    }

    // MARK: - Setup choices

    enum ScopeMode: Equatable, Sendable {
        case all
        case picked
    }

    /// What the three steps collect before "Turn on writing" applies it.
    struct Draft: Equatable {
        var saveMyWriting = true
        var autocomplete = true
        var scope: ScopeMode = .all
        var pickedBundleIdentifiers: Set<String> = []
        var model: TildeModelChoice = .gemma4E2B

        var canContinueStep1: Bool {
            step1Message(saveMyWriting: saveMyWriting, autocomplete: autocomplete) == nil
        }

        var canContinueStep2: Bool {
            step2Message(scope: scope, pickedCount: pickedBundleIdentifiers.count) == nil
        }
    }

    // MARK: - Models

    struct ModelOption: Equatable {
        let choice: TildeModelChoice
        let name: String
        let detail: String
        let isDefault: Bool
    }

    static let modelOptions = [
        ModelOption(choice: .gemma4E2B, name: "Gemma 4 E2B", detail: "3.4 GB, faster", isDefault: true),
        ModelOption(choice: .qwen35B9B, name: "Qwen 3.5 9B", detail: "5.6 GB, better", isDefault: false),
    ]

    static let defaultTag = "(default)"

    static func modelName(_ choice: TildeModelChoice) -> String {
        modelOptions.first { $0.choice == choice }?.name ?? choice.shortName
    }

    /// The line under a model the Mac can't run, or `nil`.
    static func ineligibleLine(for choice: TildeModelChoice, isEligible: Bool) -> String? {
        isEligible ? nil : Step3.qwenIneligible
    }

    // MARK: - App chips

    struct AppChoice: Equatable, Hashable, Sendable {
        let bundleIdentifier: String
        let name: String
    }

    /// Chips lead with these when installed, in this order.
    static let preferredBundleIdentifiers = [
        "com.tinyspeck.slackmacgap", // Slack
        "com.apple.Notes",
        "com.apple.mail",
        "com.apple.MobileSMS", // Messages
        "com.google.Chrome",
        "notion.id",
        "com.linear",
    ]

    /// How many chips show before "More apps".
    static let collapsedAppCount = 12

    /// The preferred apps first, in `preferredBundleIdentifiers` order, then
    /// the rest by name. Duplicate bundle identifiers keep their first entry.
    static func orderedApps(_ apps: [AppChoice]) -> [AppChoice] {
        var seen = Set<String>()
        let unique = apps.filter { seen.insert($0.bundleIdentifier.lowercased()).inserted }
        let preferredRank = Dictionary(
            uniqueKeysWithValues: preferredBundleIdentifiers.enumerated().map { ($1.lowercased(), $0) }
        )
        let preferred = unique
            .filter { preferredRank[$0.bundleIdentifier.lowercased()] != nil }
            .sorted { preferredRank[$0.bundleIdentifier.lowercased()]! < preferredRank[$1.bundleIdentifier.lowercased()]! }
        let rest = unique
            .filter { preferredRank[$0.bundleIdentifier.lowercased()] == nil }
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.bundleIdentifier < $1.bundleIdentifier : order == .orderedAscending
            }
        return preferred + rest
    }

    /// The chips to show. Collapsed, the first `collapsedAppCount` plus any
    /// picked app further down, so a pick never hides.
    static func visibleApps(ordered: [AppChoice], picked: Set<String>, showAll: Bool) -> [AppChoice] {
        guard !showAll, ordered.count > collapsedAppCount else { return ordered }
        return ordered.enumerated()
            .filter { $0.offset < collapsedAppCount || picked.contains($0.element.bundleIdentifier) }
            .map(\.element)
    }

    // MARK: - Everyday view

    static let everydayTitle = "Writing"
    static let autocompleteOnly = "Autocomplete only"
    /// Setup finished but both features are off now.
    static let writingOff = "Writing is off"

    static func summary(saveMyWriting: Bool, autocomplete: Bool, wordsToday: Int) -> String {
        if saveMyWriting { return wordsToday == 1 ? "1 word today" : "\(wordsToday.formatted()) words today" }
        return autocomplete ? autocompleteOnly : writingOff
    }

    static func suggestionsAcceptedLine(_ count: Int) -> String {
        count == 1 ? "1 suggestion accepted today" : "\(count.formatted()) suggestions accepted today"
    }

    static func keystrokesSavedLine(today: Int, last7Days: Int, partial: Bool) -> String {
        let suffix = partial ? " (partial)" : ""
        let todayText = today == 1 ? "1 keystroke saved today" : "\(today.formatted()) keystrokes saved today"
        return "\(todayText) · \(last7Days.formatted()) in the last 7 days\(suffix)"
    }

    /// The Autocomplete section's accepted count: the text-free ledger once it
    /// has today's evidence, else the keyboard's daily counter.
    static func suggestionsAcceptedToday(ledgerAccepted: Int, ledgerHasTodayEvidence: Bool, keyboardCounter: Int) -> Int {
        ledgerHasTodayEvidence ? ledgerAccepted : keyboardCounter
    }

    /// Where the model is, in a few words for the status line.
    enum ModelStatus: Equatable {
        /// Writing isn't running, so nothing is known yet.
        case waiting
        case checking
        case notDownloaded
        case downloading(fraction: Double?)
        case verifying
        case starting
        case ready
        case restarting
        case stopped
        case failed(ModelFailureKind)
    }

    enum ModelFailureKind: Equatable {
        case offline
        case diskSpace
        case rejected
        case verification
        case install
    }

    static func modelStatusText(_ status: ModelStatus) -> String {
        switch status {
        case .waiting: "waiting"
        case .checking: "checking"
        case .notDownloaded: "not downloaded"
        case let .downloading(fraction):
            fraction.map { "downloading \(Int(($0 * 100).rounded(.down)))%" } ?? "downloading"
        case .verifying: "checking the download"
        case .starting: "starting"
        case .ready: "ready"
        case .restarting: "restarting"
        case .stopped: "stopped"
        case let .failed(kind):
            switch kind {
            case .offline: "download paused, no connection"
            case .diskSpace: "needs more disk space"
            case .rejected: "download failed"
            case .verification: "download didn't verify"
            case .install: "couldn't install"
            }
        }
    }

    static func isProblem(_ status: ModelStatus) -> Bool {
        switch status {
        case .failed, .stopped: true
        default: false
        }
    }

    static func scopeText(scope: ScopeMode, pickedCount: Int) -> String {
        switch scope {
        case .all: Step2.allApps
        case .picked: pickedCount == 1 ? "1 app" : "\(pickedCount) apps"
        }
    }

    /// "Keyboard on · Gemma 4 E2B ready · All apps". The keyboard part is
    /// left out until it's known; the model part only with Autocomplete on.
    static func statusLine(
        keyboardOn: Bool?,
        autocomplete: Bool,
        model: TildeModelChoice,
        modelStatus: ModelStatus,
        scope: ScopeMode,
        pickedCount: Int
    ) -> String {
        var parts: [String] = []
        if let keyboardOn { parts.append(keyboardOn ? "Keyboard on" : "Keyboard off") }
        if autocomplete { parts.append("\(modelName(model)) \(modelStatusText(modelStatus))") }
        parts.append(scopeText(scope: scope, pickedCount: pickedCount))
        return parts.joined(separator: " · ")
    }

    static let editSetup = "Edit setup"
    static let pauseForHour = "Pause for 1 hour"
    static let resume = "Resume"
    static let deleteAll = "Delete all writing"
    static let deleteConfirmTitle = "Delete all writing?"
    static let deleteConfirmMessage = "This deletes your saved writing files and what autocomplete learned from them, and turns off Save my writing. It can't be undone."
    static let deleteFailed = "Some writing couldn't be deleted. Try again."
    static let turnOnKeyboard = "Turn on keyboard"
    static let allowScreenRecording = "Allow Screen Recording"
    static let openScreenRecordingSettings = "Open Screen Recording settings"
    static let screenRecordingReopenLine = "After you allow it, macOS may ask to reopen Transcripted."
    static let savedWritingLabel = "Today"
    static let nothingSavedYet = "Nothing saved yet today. What you write in your apps shows up here."
    static let autocompleteLabel = "Autocomplete"
    static let settingsLabel = "Settings"
    static let personalizedTitle = "Personalized suggestions"
    static let personalizedLine = "Learns from your saved writing on this Mac to tune suggestions to you."
    static let personalizedNeedsSave = "Needs Save my writing."
    static let storageTitle = "Storage"

    static let saveProblemLine = "Writing couldn't be saved to this folder. Check that the capture folder is on this Mac and writable."

    static func pausedLine(until: Date, timeFormatter: DateFormatter) -> String {
        "Paused until \(timeFormatter.string(from: until))"
    }

    /// "Slack · 42 words · 3 accepted"
    static func entryMetaLine(sourceApp: String, words: Int, acceptedWords: Int) -> String {
        var parts = [sourceApp, words == 1 ? "1 word" : "\(words.formatted()) words"]
        if acceptedWords > 0 { parts.append("\(acceptedWords.formatted()) accepted") }
        return parts.joined(separator: " · ")
    }
}
