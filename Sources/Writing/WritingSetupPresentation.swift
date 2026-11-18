#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// The reversible feature controls used when an existing setup is turned off.
@MainActor
protocol WritingSetupFeatureControl: AnyObject {
    var saveMyWritingEnabled: Bool { get }
    func setSaveMyWriting(_ enabled: Bool)
    func setAutocomplete(_ enabled: Bool)
    func applyRunState()
}

/// The Writing tab's words and small rules: the approved design's copy
/// (docs/writing-plan.md, "Product design (approved)"), which setup rows show,
/// badge text, validation messages, and the everyday view's summary and
/// status lines. Views read every string from here, so the fast tests pin
/// the approved copy word for word.
///
/// Foundation plus `TildeModelChoice` and `WritingKeyboardSetupState` only, so
/// the root fast tests compile it.
enum WritingSetupPresentation {
    // MARK: - Screen Recording

    /// What asking for Screen Recording does right now. Granting it can make
    /// macOS ask Transcripted to quit and reopen, so the ask never happens
    /// while a meeting or dictation records. After the one system prompt,
    /// System Settings is the only way to grant it.
    enum ScreenRecordingAsk: Equatable {
        case waitForCapture
        case request
        case openSettings
    }

    static func screenRecordingAsk(captureBusy: Bool, alreadyRequested: Bool) -> ScreenRecordingAsk {
        if captureBusy { return .waitForCapture }
        return alreadyRequested ? .openSettings : .request
    }

    /// Finishing setup with Autocomplete on asks for Screen Recording once,
    /// unless it's granted already or something is recording.
    static func asksForScreenRecordingAfterSetup(autocomplete: Bool, granted: Bool, captureBusy: Bool) -> Bool {
        autocomplete && !granted && !captureBusy
    }

    // MARK: - Setup, screen 1 of 2: Turn on Writing

    struct Point: Equatable {
        let symbolName: String
        let title: String
        let line: String
    }

    struct KeyHint: Equatable {
        /// The key cap, or `nil` for "keep typing", which has no single key.
        let key: String?
        let text: String
    }

    /// The pitch at the top of screen 1 (first setup only): what Writing is,
    /// the autocomplete demo, and where the writing lives. Owner-approved
    /// two-screen setup, 2026-11-18 (docs/writing-plan.md).
    enum Intro {
        static let smallTitle = "Writing"
        static let headline = "Your AI knows what you said. Not what you wrote."
        static let body = "A lot of your work happens in writing: Slack replies, emails, notes. Writing saves it next to your meetings and dictations, and helps you finish your sentences."
        /// The `~` key is named by its cap only: on ISO keyboards it isn't
        /// "the key above Tab" (a Tilde help-text bug the plan fixes).
        static let keyHints = [
            KeyHint(key: "Tab", text: "adds the next word"),
            KeyHint(key: "~", text: "takes the whole suggestion"),
            KeyHint(key: "Esc", text: "hides it"),
        ]
        /// True with Write for Me on too: it's the one thing that sends text,
        /// and only when its key is pressed.
        static let privacy = Point(
            symbolName: "lock",
            title: "Stays on your Mac.",
            line: "No account. It's saved as plain files you can point any AI agent at. Only Write for Me sends text, and only when you press its key."
        )
    }

    // MARK: - Setup

    static let setupStepCount = 2

    /// Screen 1's two questions: what Writing does, and in which apps.
    enum Step1 {
        static let title = "What should Writing do?"
        static let saveTitle = "Save my writing"
        static let saveLine = "Your AI can read what you wrote. Files stay on this Mac, only in apps you choose."
        static let autocompleteTitle = "Autocomplete"
        static let autocompleteLine = "Suggests the next words. Tab to accept."
        static let appsTitle = "Which apps?"
        static let allApps = "All apps"
        static let allAppsLine = "Password managers are always skipped."
        static let pickedApps = "Only apps I pick"
        static let sameApps = "Both use the same apps."
        static let needsOneApp = "Pick at least one app."
        static let moreApps = "More apps"
        static let fewerApps = "Fewer apps"
        static let continueTitle = "Continue"
        static let needsOne = "Turn on at least one to continue."
        static let turnOffTitle = "Turn off writing"
        static let turnOffMessage = "Both off turns writing off."
        /// Screen 1's heading while editing a finished setup (no pitch).
        static let editTitle = "Edit setup"
    }

    /// Screen 2: the keyboard, Screen Recording, and the model picked for
    /// you. The other model is a row in Settings on the Writing page.
    enum Step2 {
        static let title = "Allow and download"
        static let keyboardTitle = "Transcripted keyboard"
        /// Before the keyboard is installed. macOS 26 won't let an app turn a
        /// keyboard on, so the user adds it (`keyboardStep(_:)`).
        static let keyboardLine = "You add it in Keyboard settings. No privacy prompt."
        static let screenRecordingTitle = "Screen Recording"
        static let screenRecordingLine = "Reads the window you're replying in, on this Mac."
        static let modelTitle = "Model"
        static let autocompleteBadge = "Autocomplete"
        static let qwenIneligible = "Your Mac needs 16 GB of memory for this model."
        static let footnote = "Suggestion counts only, never text. Follows your analytics setting."
        static let turnOn = "Turn on writing"
    }

    /// The model row on screen 2: the pick, its size, and where to change it.
    static func modelLine(for choice: TildeModelChoice) -> String {
        let option = modelOptions.first { $0.choice == choice }
        let name = option?.name ?? choice.shortName
        let size = option.map { " (\($0.size))" } ?? ""
        return "\(name)\(size) downloads after you turn on writing. You can switch models later on this page."
    }

    static let back = "Back"
    /// Only while editing a finished setup: leaves the steps unchanged.
    static let cancel = "Cancel"
    /// Shown instead of the Screen Recording request while a meeting or
    /// dictation records: macOS may ask Transcripted to quit and reopen after
    /// the grant.
    /// The hold covers queued transcription too, so the line says so.
    static let finishRecordingFirst = "Finish recording and transcribing first"
    static let notNow = "Not now"

    /// The rows screen 2 shows: only what the screen 1 toggles need
    /// (docs/writing-plan.md, "Permissions").
    enum Step2Row: Equatable, CaseIterable {
        case keyboard
        case screenRecording
        case model
    }

    static func step2Rows(saveMyWriting: Bool, autocomplete: Bool) -> [Step2Row] {
        var rows: [Step2Row] = []
        if saveMyWriting || autocomplete { rows.append(.keyboard) }
        if autocomplete { rows += [.screenRecording, .model] }
        return rows
    }

    // MARK: - Keyboard guidance

    /// What to do about the keyboard, per `WritingKeyboardSetupState`
    /// (docs/writing-plan.md, "Permissions"). Nothing here logs the user out
    /// or opens System Settings; the button does, when the user asks.
    enum KeyboardGuidance {
        static let needsUserToAdd = "Add Transcripted in Keyboard settings: Input Sources › Edit… › +, then English › Transcripted."
        static let needsRelogin = "macOS lists new keyboards after you log out and back in. Log out, then add Transcripted in Keyboard settings."
        static let enabledNotSelected = "Choose Transcripted from the input menu in the menu bar."
        static let openKeyboardSettings = "Open Keyboard Settings"
    }

    /// The keyboard row on screen 2 and in the everyday view.
    struct KeyboardStep: Equatable {
        let line: String
        /// "Open Keyboard Settings", or `nil` when that wouldn't help.
        let buttonTitle: String?
        let isDone: Bool
    }

    /// `nil` means the keyboard isn't installed yet (screen 2 before "Turn on
    /// writing"): the plain line, no button.
    static func keyboardStep(_ state: WritingKeyboardSetupState?) -> KeyboardStep {
        switch state {
        case nil:
            KeyboardStep(line: Step2.keyboardLine, buttonTitle: nil, isDone: false)
        case .selected?:
            KeyboardStep(line: Step2.keyboardLine, buttonTitle: nil, isDone: true)
        case .enabledNotSelected?:
            KeyboardStep(line: KeyboardGuidance.enabledNotSelected, buttonTitle: nil, isDone: false)
        case .needsUserToAdd?:
            KeyboardStep(
                line: KeyboardGuidance.needsUserToAdd,
                buttonTitle: KeyboardGuidance.openKeyboardSettings,
                isDone: false
            )
        case .needsRelogin?:
            KeyboardStep(
                line: KeyboardGuidance.needsRelogin,
                buttonTitle: KeyboardGuidance.openKeyboardSettings,
                isDone: false
            )
        }
    }

    /// The everyday view's "Keyboard off" row. Setup is done there, so a
    /// keyboard that isn't installed (say the copy failed) gets the add
    /// steps too; the button tries the install again first.
    static func everydayKeyboardStep(_ state: WritingKeyboardSetupState?) -> KeyboardStep {
        keyboardStep(state ?? .needsUserToAdd)
    }

    /// Both features use the keyboard; with only one on it's simply needed.
    static func keyboardBadge(saveMyWriting: Bool, autocomplete: Bool) -> String {
        saveMyWriting && autocomplete ? "Both" : "Needed"
    }

    /// A blocking first-setup message or an explanation of an editing action.
    static func step1Message(saveMyWriting: Bool, autocomplete: Bool, isEditing: Bool = false) -> String? {
        guard !saveMyWriting && !autocomplete else { return nil }
        return isEditing ? Step1.turnOffMessage : Step1.needsOne
    }

    /// What screen 1's primary button does.
    enum Step1Primary: Equatable {
        case continueSetup
        case turnOffWriting
    }

    static func step1Primary(saveMyWriting: Bool, autocomplete: Bool, isEditing: Bool) -> Step1Primary {
        isEditing && !saveMyWriting && !autocomplete ? .turnOffWriting : .continueSetup
    }

    /// Persist the off choice before applying the runtime's reversible stop.
    @MainActor
    static func turnOffWriting(using controls: any WritingSetupFeatureControl) {
        // Save my writing rotates consent on a real change only.
        if controls.saveMyWritingEnabled { controls.setSaveMyWriting(false) }
        controls.setAutocomplete(false)
        controls.applyRunState()
    }

    /// `nil` when the apps question is answered.
    static func appsMessage(scope: ScopeMode, pickedCount: Int) -> String? {
        scope == .picked && pickedCount == 0 ? Step1.needsOneApp : nil
    }

    // MARK: - Setup choices

    enum ScopeMode: Equatable, Sendable {
        case all
        case picked
    }

    /// What the two screens collect before "Turn on writing" applies it.
    /// The model isn't asked: it starts on the smaller one (or what's saved)
    /// and the Settings card on the Writing page switches it.
    struct Draft: Equatable {
        var saveMyWriting = true
        var autocomplete = true
        var scope: ScopeMode = .all
        var pickedBundleIdentifiers: Set<String> = []
        var model: TildeModelChoice = .gemma4E2B

        /// At least one feature is on.
        var canContinueStep1: Bool {
            step1Message(saveMyWriting: saveMyWriting, autocomplete: autocomplete) == nil
        }

        /// "All apps", or at least one picked.
        var canContinueApps: Bool {
            appsMessage(scope: scope, pickedCount: pickedBundleIdentifiers.count) == nil
        }

        /// Whether screen 1's primary button is enabled. Editing with both
        /// features off is Turn off writing, which doesn't need apps.
        func canFinishStep1(isEditing: Bool) -> Bool {
            if isEditing, !saveMyWriting, !autocomplete { return true }
            return canContinueStep1 && canContinueApps
        }
    }

    // MARK: - Models

    struct ModelOption: Equatable {
        let choice: TildeModelChoice
        let name: String
        let size: String
        let detail: String
        let isDefault: Bool
    }

    static let modelOptions = [
        ModelOption(choice: .gemma4E2B, name: "Gemma 4 E2B", size: "3.4 GB", detail: "3.4 GB, faster", isDefault: true),
        ModelOption(choice: .qwen35B9B, name: "Qwen 3.5 9B", size: "5.6 GB", detail: "5.6 GB, better", isDefault: false),
    ]

    static let defaultTag = "(default)"

    static func modelName(_ choice: TildeModelChoice) -> String {
        modelOptions.first { $0.choice == choice }?.name ?? choice.shortName
    }

    /// The line under a model the Mac can't run, or `nil`.
    static func ineligibleLine(for choice: TildeModelChoice, isEligible: Bool) -> String? {
        isEligible ? nil : Step2.qwenIneligible
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
    /// Setup finished but both features are off now.
    static let writingOff = "Writing is off"

    /// The line under the title. Today owns the day's word count, so this
    /// only speaks up when Writing is off.
    static func summary(saveMyWriting: Bool, autocomplete: Bool) -> String? {
        saveMyWriting || autocomplete ? nil : writingOff
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
        case .all: Step1.allApps
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
    static let deleteConfirmMessage = "This deletes your saved writing files and what autocomplete learned from them, and turns off Save my writing. It can't be undone. The autocomplete model stays; Delete model removes it."
    static let deleteFailed = "Some writing couldn't be deleted. Try again."
    static let deleteModel = "Delete model"
    static let deleteModelConfirmTitle = "Delete the writing model?"
    static let deleteModelFailed = "Some model files couldn't be deleted. Try again."

    /// Delete model's confirmation. Autocomplete can't run without the
    /// model, so when it's on the delete turns it off, and the user hears
    /// that before anything goes.
    static func deleteModelConfirmMessage(autocompleteOn: Bool, modelBytes: Int64) -> String {
        let frees = modelBytes > 0 ? "This frees \(WritingStorageUsage.formatted(modelBytes)). " : ""
        let keeps = "Your saved writing and learning data stay."
        if autocompleteOn {
            return "\(frees)Autocomplete needs the model, so this turns Autocomplete off. Turning it back on downloads the model again. \(keeps)"
        }
        return "\(frees)\(keeps) Turning on Autocomplete later downloads the model again."
    }
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

extension WritingSetupPresentation {
    /// Write for Me's sound switch, on the Writing page while Write for Me is
    /// on. Same preference as Settings › Advanced (`NextSentenceSounds`).
    enum WriteForMeSounds {
        static let title = "Write for Me sounds"
        static let onLine = "Plays soft sounds as the card opens, listens and sends."
        static let offLine = "Write for Me is silent."
    }
}
