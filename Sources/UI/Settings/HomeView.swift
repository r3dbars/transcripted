import AppKit
import SwiftUI
import TranscriptedCore

// MARK: - View model

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var dictationDaySections: [HomeDaySection<SavedDictationEntry>] = []
    @Published private(set) var meetingDaySections: [HomeDaySection<RecentMeetingItem>] = []
    @Published private(set) var todayDictationCount: Int = 0
    @Published private(set) var todayMeetingCount: Int = 0
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isLoadingMore: Bool = false
    @Published private(set) var canLoadMoreDictations: Bool = false
    @Published private(set) var canLoadMoreMeetings: Bool = false
    /// Set when the meetings-folder scan hits a damaged/broken path. Drives the
    /// Home warning card. `nil` for the normal empty/loaded state.
    @Published private(set) var scanWarning: HomeScanWarningCardModel?

    // Once the user dismisses the warning we stay quiet until they explicitly
    // retry or re-enter Home (`refresh()`), so a silent background reload does
    // not keep re-raising the same card they just cleared.
    private var scanWarningDismissed = false

    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = SupersessionEpoch()
    private var dictationLimit = 10
    private var meetingLimit = 10
    private var didTrackActivationReturnProxy = false
    private var captureRefreshObserver: HomeCaptureRefreshObserver?

    init() {
        // Background post-save work (WAV->M4A recompression, transcript rename)
        // rewrites the files whose URLs this cache resolved at scan time. Re-resolve
        // from disk whenever that happens so cached transcript/audio URLs never
        // outlive the real files. The broadcaster is already debounced.
        captureRefreshObserver = HomeCaptureRefreshObserver { _ in
            Task { @MainActor [weak self] in
                self?.refreshAfterCaptureArtifactsChanged()
            }
        }
    }

    /// Silent re-resolution of the currently visible captures after the on-disk
    /// artifacts changed underneath the cache. Keeps the current paging window and
    /// avoids flipping the loading spinners so a passive background refresh does
    /// not flash the UI.
    func refreshAfterCaptureArtifactsChanged() {
        loadCurrentLimits(isInitialLoad: false, isSilent: true)
    }

    // Settings Home must open instantly, even for users with thousands of dictations.
    // Keep the dashboard to a small recent slice and leave deep history to the dedicated pages/files.
    private let initialDictationLimit = 10
    private let initialMeetingLimit = 10

    func refresh() {
        refreshTask?.cancel()
        dictationLimit = initialDictationLimit
        meetingLimit = initialMeetingLimit
        scanWarningDismissed = false
        isLoading = true
        loadCurrentLimits(isInitialLoad: true)
    }

    /// Retry from the scan warning card: clear the dismissed latch and reload
    /// from disk so a fixed path clears the card on its own.
    func retryScan() {
        refresh()
    }

    func dismissScanWarning() {
        scanWarning = nil
        scanWarningDismissed = true
    }

    func removeVisibleMeeting(id: String) {
        var didRemove = false
        meetingDaySections = meetingDaySections.compactMap { section in
            let remainingItems = section.items.filter { item in
                let shouldKeep = item.id != id
                if !shouldKeep {
                    didRemove = true
                }
                return shouldKeep
            }
            guard !remainingItems.isEmpty else { return nil }
            return HomeDaySection(day: section.day, label: section.label, items: remainingItems)
        }

        guard didRemove else { return }
        todayMeetingCount = meetingDaySections
            .flatMap(\.items)
            .filter { Calendar.current.isDateInToday($0.date) }
            .count
    }

    func loadMoreDictations() {
        guard !isLoading, !isLoadingMore, canLoadMoreDictations else { return }
        dictationLimit += initialDictationLimit
        loadCurrentLimits(isInitialLoad: false)
    }

    func loadMoreMeetings() {
        guard !isLoading, !isLoadingMore, canLoadMoreMeetings else { return }
        meetingLimit += initialMeetingLimit
        loadCurrentLimits(isInitialLoad: false)
    }

    private func loadCurrentLimits(isInitialLoad: Bool, isSilent: Bool = false) {
        refreshTask?.cancel()
        let generation = refreshGeneration.begin()
        isLoading = isInitialLoad && !isSilent
        isLoadingMore = !isInitialLoad && !isSilent
        let requestedDictationLimit = dictationLimit
        let requestedMeetingLimit = meetingLimit
        refreshTask = Task { @MainActor in
            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: requestedDictationLimit + 1,
                meetingLimit: requestedMeetingLimit + 1,
                includeDictationCounts: true
            )
            let diagnosis = await Task.detached(priority: .utility) {
                RecentMeetingsScanner.diagnose()
            }.value
            guard !Task.isCancelled, self.refreshGeneration.finishIfCurrent(generation) else {
                return
            }
            self.scanWarning = self.scanWarningDismissed
                ? nil
                : HomeScanWarningPolicy.card(for: diagnosis)
            let visibleDictations = Array(snapshot.dictations.prefix(requestedDictationLimit))
            let visibleMeetings = Array(snapshot.meetings.prefix(requestedMeetingLimit))
            let calendar = Calendar.current
            self.todayDictationCount = snapshot.dictationCounts.today
            self.todayMeetingCount = visibleMeetings.lazy.filter { calendar.isDateInToday($0.date) }.count
            self.dictationDaySections = Self.groupByDay(visibleDictations, dateForItem: \.createdAt)
            self.meetingDaySections = Self.groupByDay(visibleMeetings, dateForItem: \.date)
            self.canLoadMoreDictations = snapshot.dictations.count > requestedDictationLimit
            self.canLoadMoreMeetings = snapshot.meetings.count > requestedMeetingLimit
            self.trackActivationReturnProxyIfNeeded(
                dictations: visibleDictations,
                meetings: visibleMeetings
            )
            self.isLoading = false
            self.isLoadingMore = false
        }
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration.invalidate()
        isLoading = false
        isLoadingMore = false
    }

    // MARK: - Helpers

    static func groupByDay<Item>(
        _ items: [Item],
        dateForItem: (Item) -> Date
    ) -> [HomeDaySection<Item>] {
        let calendar = Calendar.current
        var buckets: [(day: Date, items: [Item])] = []

        for item in items {
            let day = calendar.startOfDay(for: dateForItem(item))
            if let lastIndex = buckets.indices.last, buckets[lastIndex].day == day {
                buckets[lastIndex].items.append(item)
            } else if let existing = buckets.firstIndex(where: { $0.day == day }) {
                buckets[existing].items.append(item)
            } else {
                buckets.append((day: day, items: [item]))
            }
        }

        return buckets.map { bucket in
            HomeDaySection(day: bucket.day, label: dayLabel(for: bucket.day), items: bucket.items)
        }
    }

    private static func dayLabel(for day: Date) -> String {
        HomeDaySectionLabel.label(for: day)
    }

    private func trackActivationReturnProxyIfNeeded(
        dictations: [SavedDictationEntry],
        meetings: [RecentMeetingItem]
    ) {
        guard !didTrackActivationReturnProxy else { return }

        let dictationCandidates = dictations.map { entry in
            (kind: ActivationTelemetry.ArtifactKind.dictation, date: entry.createdAt)
        }
        let meetingCandidates = meetings.map { item in
            (kind: ActivationTelemetry.ArtifactKind.meeting, date: item.date)
        }
        guard let latest = (dictationCandidates + meetingCandidates).max(by: { $0.date < $1.date }) else {
            return
        }

        didTrackActivationReturnProxy = ActivationTelemetry.trackReturnProxyIfEligible(
            priorArtifactKind: latest.kind,
            priorArtifactDate: latest.date,
            surface: .home
        )
        if didTrackActivationReturnProxy {
            let artifactCount = dictations.count + meetings.count
            ActivationTelemetry.trackHabitLoopAction(
                actionKind: artifactCount >= 2 ? .returnAfterSecondArtifact : .returnAfterFirstArtifact,
                surface: .home,
                artifactKind: latest.kind,
                artifactDate: latest.date,
                artifactCount: artifactCount
            )
        }
    }

}

struct HomeDaySection<Item>: Identifiable {
    let day: Date
    let label: String
    let items: [Item]

    var id: TimeInterval { day.timeIntervalSinceReferenceDate }
}

enum HomeMeetingListItem: Identifiable {
    case saved(RecentMeetingItem)
    case failed(MeetingSessionController.FailedMeetingItem)

    var id: String {
        switch self {
        case .saved(let item):
            return "saved-\(item.id)"
        case .failed(let item):
            return "failed-\(item.id.uuidString)"
        }
    }

    var date: Date {
        switch self {
        case .saved(let item):
            return item.date
        case .failed(let item):
            return item.timestamp
        }
    }
}

struct HomeDeleteConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let perform: () -> Void

    init(
        title: String,
        message: String,
        confirmTitle: String = "Delete",
        perform: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.perform = perform
    }
}

struct HomeDeleteFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let retryTitle: String
    let details: String?
    let retry: () -> Void

    init(
        title: String,
        message: String,
        retryTitle: String = HomeActionFailureCopy.retryTitle,
        details: String? = nil,
        retry: @escaping () -> Void = {}
    ) {
        self.title = title
        self.message = message
        self.retryTitle = retryTitle
        self.details = details
        self.retry = retry
    }
}

// MARK: - Stats summary

enum HomeFeedbackIssueKind: String, CaseIterable, Identifiable {
    case wrongWords
    case missingText
    case badFormatting
    case wrongSpeakers
    case audioProblem
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wrongWords: return "Wrong words"
        case .missingText: return "Missing text"
        case .badFormatting: return "Bad formatting"
        case .wrongSpeakers: return "Speaker issue"
        case .audioProblem: return "Audio issue"
        case .other: return "Other"
        }
    }
}

struct HomeFeedbackTarget: Identifiable {
    let id: String
    let sourceKind: String
    let title: String
    let createdAt: Date
    let referenceID: String
    let suggestedIssue: HomeFeedbackIssueKind

    static func dictation(_ entry: SavedDictationEntry) -> HomeFeedbackTarget {
        HomeFeedbackTarget(
            id: "dictation-\(stableReferenceID(for: entry.id))",
            sourceKind: "dictation",
            title: "Dictation at \(HomeActivityRowFormatting.timeFormatter.string(from: entry.createdAt))",
            createdAt: entry.createdAt,
            referenceID: stableReferenceID(for: entry.id),
            suggestedIssue: .wrongWords
        )
    }

    static func meeting(_ item: RecentMeetingItem) -> HomeFeedbackTarget {
        HomeFeedbackTarget(
            id: "meeting-\(stableReferenceID(for: item.id))",
            sourceKind: "meeting",
            title: "Meeting at \(HomeActivityRowFormatting.timeFormatter.string(from: item.date))",
            createdAt: item.date,
            referenceID: stableReferenceID(for: item.id),
            suggestedIssue: .wrongSpeakers
        )
    }

    private static func stableReferenceID(for value: String) -> String {
        HomeStableReferenceID.id(for: value)
    }
}

struct HomeFeedbackSubmission {
    let target: HomeFeedbackTarget
    let issueKind: HomeFeedbackIssueKind
    let notes: String
    let includeDiagnostics: Bool
}

struct HomeMeetingPreview: Identifiable {
    let id: String
    let title: String
    let date: Date
    let transcriptURL: URL
    let audio: MeetingAudioAttachment?
    let markdown: String
    let content: HomeMeetingPreviewContent
    let readError: String?
    let feedbackTarget: HomeFeedbackTarget

    init(
        item: RecentMeetingItem,
        markdown: String,
        readError: String? = nil
    ) {
        id = item.id
        title = item.title
        date = item.date
        transcriptURL = item.transcriptURL
        audio = item.audio
        self.markdown = markdown
        content = HomeMeetingPreviewContent.make(from: markdown)
        self.readError = readError
        feedbackTarget = HomeFeedbackTarget.meeting(item)
    }

    private init(
        id: String,
        title: String,
        date: Date,
        transcriptURL: URL,
        audio: MeetingAudioAttachment?,
        markdown: String,
        content: HomeMeetingPreviewContent,
        readError: String?,
        feedbackTarget: HomeFeedbackTarget
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.transcriptURL = transcriptURL
        self.audio = audio
        self.markdown = markdown
        self.content = content
        self.readError = readError
        self.feedbackTarget = feedbackTarget
    }

    /// Returns a copy reflecting a renamed transcript while keeping the stable `id`
    /// so the open preview sheet updates in place instead of dismissing and re-presenting.
    func updatingAfterRename(
        transcriptURL: URL,
        title: String,
        audio: MeetingAudioAttachment?
    ) -> HomeMeetingPreview {
        HomeMeetingPreview(
            id: id,
            title: title,
            date: date,
            transcriptURL: transcriptURL,
            audio: audio,
            markdown: markdown,
            content: content,
            readError: readError,
            feedbackTarget: feedbackTarget
        )
    }

    /// Returns a copy with freshly-read transcript text after an inline speaker edit.
    func updatingMarkdown(_ markdown: String, readError: String? = nil) -> HomeMeetingPreview {
        HomeMeetingPreview(
            id: id,
            title: title,
            date: date,
            transcriptURL: transcriptURL,
            audio: audio,
            markdown: markdown,
            content: HomeMeetingPreviewContent.make(from: markdown),
            readError: readError,
            feedbackTarget: feedbackTarget
        )
    }
}

enum HomeMeetingMarkdownReadResult {
    case success(String)
    case failure(String)
}

// MARK: - Canvas header

struct HomeAttentionIssue: Identifiable {
    enum Destination {
        case failedMeetings
        case speakers
        case privacy
        case models
    }

    enum Tone {
        case warning
        case failure

        var color: Color {
            switch self {
            case .warning: return .orange
            case .failure: return .red
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let tone: Tone
    let destination: Destination
}

struct HomeScanWarningCard: View {
    let model: HomeScanWarningCardModel
    let onRetry: () -> Void
    let onReveal: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 34, height: 34)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title)
                        .font(.headline)
                    Text(model.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("transcripted.home.scan-warning.dismiss")
            }

            HStack(spacing: 8) {
                Button(action: onRetry) {
                    Text(model.retryTitle)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .accessibilityIdentifier("transcripted.home.scan-warning.retry")

                Button(action: onReveal) {
                    Text(model.revealTitle)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("transcripted.home.scan-warning.reveal")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.orange.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.home.scan-warning")
    }
}

// MARK: - Stats detail

struct HomeRowMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let symbolName: String
    let isEnabled: Bool
    let isDestructive: Bool
    /// Optional AX/automation hook for a single item inside the ⋯ menu. The
    /// menu button itself only carries one identifier for the whole menu, so
    /// actions that automation needs to target by name (Rename) set this.
    let automationIdentifier: String?
    let action: () -> Void

    init(
        title: String,
        symbolName: String,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        automationIdentifier: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbolName = symbolName
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.automationIdentifier = automationIdentifier
        self.action = action
    }
}

struct HomeRowActionButtons: View {
    let isCopied: Bool
    let onCopy: () -> Void
    let menuItems: [HomeRowMenuItem]
    var leadingAccessory: AnyView? = nil
    /// Page-scoped so AX/automation can tell the Home meeting row's Copy
    /// apart from the Dictations row's Copy.
    var copyAutomationIdentifier = "transcripted.home.row.copy"

    var body: some View {
        HStack(spacing: 4) {
            if let leadingAccessory {
                leadingAccessory
            }

            iconButton(
                systemName: isCopied ? "checkmark" : "square.on.square",
                help: isCopied ? "Copied" : "Copy",
                action: onCopy
            )

            if !menuItems.isEmpty {
                HomeRowMoreMenuButton(items: menuItems)
                    .frame(width: HomeHitTarget.minimum, height: HomeHitTarget.minimum)
                    .help("More options")
            }
        }
    }

    private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(HomeCompactIconButtonStyle())
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityIdentifier(copyAutomationIdentifier)
    }
}

struct HomeRowMoreMenuButton: NSViewRepresentable {
    let items: [HomeRowMenuItem]
    var automationIdentifier = "transcripted.home.row.more"

    func makeCoordinator() -> Coordinator {
        Coordinator(items: items)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = HoverMenuButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: "More options"
        )
        button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator
        button.retainedActionTarget = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.setButtonType(.momentaryChange)
        button.setAccessibilityLabel("More options")
        button.identifier = NSUserInterfaceItemIdentifier(automationIdentifier)
        button.setAccessibilityIdentifier(automationIdentifier)
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.items = items
        if let hoverButton = button as? HoverMenuButton {
            hoverButton.retainedActionTarget = context.coordinator
        }
        button.target = context.coordinator
        button.isEnabled = !items.isEmpty
        button.identifier = NSUserInterfaceItemIdentifier(automationIdentifier)
        button.setAccessibilityIdentifier(automationIdentifier)
    }

    final class Coordinator: NSObject {
        var items: [HomeRowMenuItem]

        init(items: [HomeRowMenuItem]) {
            self.items = items
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            // Without this, AppKit auto-enables every item whose target responds
            // to the action, overriding the per-item isEnabled set below.
            menu.autoenablesItems = false
            for item in items {
                let menuItem = ClosureMenuItem(menuItem: item)
                if let image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: item.title) {
                    image.isTemplate = true
                    menuItem.image = image.withSymbolConfiguration(
                        NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                    )
                }
                if item.isDestructive {
                    menuItem.attributedTitle = NSAttributedString(
                        string: item.title,
                        attributes: [.foregroundColor: NSColor.systemRed]
                    )
                }
                if let automationIdentifier = item.automationIdentifier {
                    menuItem.identifier = NSUserInterfaceItemIdentifier(automationIdentifier)
                    menuItem.setAccessibilityIdentifier(automationIdentifier)
                }
                menu.addItem(menuItem)
            }

            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 2),
                in: sender
            )
        }
    }

    /// A menu item that owns its action closure and acts as its own target.
    ///
    /// Two things have to hold for a handler to both fire *and* be able to drive
    /// SwiftUI presentation:
    ///   1. The item owns its handler instead of pointing `NSMenuItem.target` at
    ///      a separately, weakly-retained object. The `NSMenu` retains its items
    ///      for the whole `popUp` tracking loop, so the handler can't be torn
    ///      down with the SwiftUI coordinator while the menu is open. (The old
    ///      design's weak target could deallocate first, so closures silently
    ///      never fired — delete, reveal, and report all no-op'd.)
    ///   2. The handler runs on the next main-runloop turn, *after* `popUp`'s
    ///      modal tracking loop exits. A handler that mutates SwiftUI state to
    ///      present an `.alert(item:)`/`.sheet(item:)` (e.g. the Home delete
    ///      confirmation) won't present if it runs synchronously inside that
    ///      loop. The async block captures `handler` strongly, so deferring is
    ///      safe here — the dealloc trap from (1) does not reappear.
    final class ClosureMenuItem: NSMenuItem {
        private let handler: () -> Void

        init(menuItem: HomeRowMenuItem) {
            self.handler = menuItem.action
            super.init(title: menuItem.title, action: #selector(invoke), keyEquivalent: "")
            target = self
            isEnabled = menuItem.isEnabled
        }

        @available(*, unavailable)
        required init(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func invoke() {
            guard isEnabled else { return }
            DispatchQueue.main.async { [handler] in handler() }
        }
    }

    final class HoverMenuButton: NSButton {
        var retainedActionTarget: AnyObject?
        private var trackingAreaRef: NSTrackingArea?
        private var hoverBackgroundLayer: CALayer?
        private var isHovering = false {
            didSet { updateAppearance() }
        }

        override var isHighlighted: Bool {
            didSet { updateAppearance() }
        }

        override var isEnabled: Bool {
            didSet { updateAppearance() }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingAreaRef {
                removeTrackingArea(trackingAreaRef)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingAreaRef = area
        }

        override func layout() {
            super.layout()
            layoutHoverBackgroundLayer()
        }

        override func mouseEntered(with event: NSEvent) {
            guard isEnabled else { return }
            isHovering = true
        }

        override func mouseExited(with event: NSEvent) {
            isHovering = false
        }

        private func updateAppearance() {
            layoutHoverBackgroundLayer()
            guard isEnabled else {
                layer?.backgroundColor = NSColor.clear.cgColor
                hoverBackgroundLayer?.backgroundColor = NSColor.clear.cgColor
                alphaValue = 0.55
                return
            }

            alphaValue = 1
            let color: NSColor
            if isHighlighted {
                color = NSColor.labelColor.withAlphaComponent(0.07)
            } else if isHovering {
                color = NSColor.labelColor.withAlphaComponent(0.04)
            } else {
                color = .clear
            }
            layer?.backgroundColor = NSColor.clear.cgColor
            hoverBackgroundLayer?.backgroundColor = color.cgColor
        }

        private func layoutHoverBackgroundLayer() {
            guard wantsLayer, let layer else { return }
            let backgroundLayer: CALayer
            if let hoverBackgroundLayer {
                backgroundLayer = hoverBackgroundLayer
            } else {
                let createdLayer = CALayer()
                createdLayer.cornerRadius = 7
                layer.insertSublayer(createdLayer, at: 0)
                hoverBackgroundLayer = createdLayer
                backgroundLayer = createdLayer
            }

            let size = HomeHitTarget.compactVisibleSize
            backgroundLayer.frame = CGRect(
                x: floor((bounds.width - size) / 2),
                y: floor((bounds.height - size) / 2),
                width: size,
                height: size
            )
        }
    }
}

// MARK: - Activity rows

enum HomeActivityRowFormatting {
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "h:mm a"
        return f
    }()
}


struct HomeFailedMeetingInlineRow: View {
    let item: MeetingSessionController.FailedMeetingItem
    let canRetry: Bool
    let retryUnavailableReason: String?
    let onRetry: () -> Void
    let onRevealAudio: () -> Void
    let onClear: () -> Void
    /// Kept audio playback for the failed capture (the row is the only
    /// surface for it since the failed-meetings card was retired). `nil`
    /// hides the control.
    var audioAttachment: MeetingAudioAttachment? = nil

    @ObservedObject private var playback = MeetingAudioPlayback.shared

    @State private var isHovering = false

    var body: some View {
        let presentation = inlinePresentation
        HStack(alignment: .top, spacing: 14) {
            Text(HomeActivityRowFormatting.timeFormatter.string(from: item.timestamp))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                statusLine(presentation: presentation)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(item.detail)

            actions
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.035) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if let audioAttachment {
                Button {
                    playback.toggle(audioAttachment)
                } label: {
                    Label(
                        playback.isActive(audioAttachment) ? "Pause audio" : "Play audio",
                        systemImage: playback.isActive(audioAttachment) ? "pause.fill" : "play.fill"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Play the kept audio for this meeting")
                .accessibilityIdentifier("transcripted.home.failed-meeting.play-audio")
            }

            if hasRetainedAudioFiles {
                Button {
                    onRevealAudio()
                } label: {
                    Label("Show Audio", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show saved audio in Finder")
                .accessibilityIdentifier("transcripted.home.failed-meeting.show-audio")
            }

            if inlinePresentation.canShowRetryAction {
                HomeAttentionActionButton(
                    title: item.isRetrying ? "Retrying" : "Try again",
                    isDisabled: retryDisabled,
                    automationIdentifier: "transcripted.home.failed-meeting.retry",
                    action: onRetry
                )
                .help(retryHelp)
            }

            HomeRowMoreMenuButton(items: [
                HomeRowMenuItem(
                    title: "Delete failed meeting",
                    symbolName: "trash",
                    isDestructive: true,
                    action: onClear
                )
            ], automationIdentifier: "transcripted.home.failed-meeting.more")
            .frame(width: HomeHitTarget.minimum, height: HomeHitTarget.minimum)
            .help("More options")
        }
    }

    private var inlinePresentation: HomeFailedMeetingInlinePresentation {
        HomeFailedMeetingInlinePresentation.make(
            isRetryable: item.isRetryable,
            isRetrying: item.isRetrying,
            hasAudioFiles: item.hasAudioFiles,
            detail: item.detail,
            usableAudio: item.usableAudio
        )
    }

    private func statusLine(presentation: HomeFailedMeetingInlinePresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(presentation.statusText)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.red)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.red.opacity(0.12))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.red.opacity(0.18), lineWidth: 1)
                )
                .accessibilityLabel(presentation.statusText)

            if let detail = presentation.inlineDetail {
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var retryDisabled: Bool {
        FailedMeetingRecoveryPresentation.retryDisabled(
            canRetry: canRetry,
            isRetryable: item.isRetryable,
            isRetrying: item.isRetrying,
            hasAudioFiles: item.hasAudioFiles,
            usableAudio: item.usableAudio
        )
    }

    private var retryHelp: String {
        FailedMeetingRecoveryPresentation.retryHelp(
            canRetry: canRetry,
            retryUnavailableReason: retryUnavailableReason,
            isRetryable: item.isRetryable,
            isRetrying: item.isRetrying,
            hasAudioFiles: item.hasAudioFiles,
            usableAudio: item.usableAudio
        )
    }

    private var hasRetainedAudioFiles: Bool {
        !item.audioURLs.isEmpty
    }
}

private struct HomeAttentionActionButton: View {
    let title: String
    let isDisabled: Bool
    var tint: Color = .red
    var automationIdentifier: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: isHovering && !isDisabled ? 5 : 2, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .homeAutomationIdentifier(automationIdentifier)
    }

    private var foregroundColor: Color {
        isDisabled ? tint.opacity(0.55) : Color.white
    }

    private var backgroundColor: Color {
        if isDisabled {
            return tint.opacity(0.12)
        }
        return tint.opacity(isHovering ? 0.9 : 0.78)
    }

    private var borderColor: Color {
        isDisabled ? tint.opacity(0.16) : Color.white.opacity(0.14)
    }

    private var shadowColor: Color {
        isDisabled ? Color.clear : tint.opacity(0.16)
    }
}

enum HomeHitTarget {
    static let minimum: CGFloat = 40
    static let compactVisibleSize: CGFloat = 26
}

private struct HomeCompactIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .frame(width: HomeHitTarget.compactVisibleSize, height: HomeHitTarget.compactVisibleSize)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(strokeColor, lineWidth: 1)
                )
                .frame(width: HomeHitTarget.minimum, height: HomeHitTarget.minimum)
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.55)
                .onHover { isHovering = $0 }
        }

        private var backgroundColor: Color {
            if configuration.isPressed {
                return Color.primary.opacity(0.10)
            }
            if isHovering {
                return Color.primary.opacity(0.06)
            }
            return Color.clear
        }

        private var strokeColor: Color {
            configuration.isPressed || isHovering ? Color.primary.opacity(0.08) : Color.clear
        }
    }
}

private extension View {
    @ViewBuilder
    func homeAutomationIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

struct HomeListEmptyState {
    let symbolName: String
    let title: String
    let message: String
    let actionTitle: String
    let automationIdentifier: String
    let action: () -> Void
    var secondaryActionTitle: String? = nil
    var secondaryAutomationIdentifier: String? = nil
    var secondaryAction: (() -> Void)? = nil
}

private struct HomeEmptyStateView: View {
    let state: HomeListEmptyState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: state.symbolName)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 5) {
                Text(state.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primary)

                Text(state.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }

            HStack(spacing: 8) {
                Button(action: state.action) {
                    Text(state.actionTitle)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier(state.automationIdentifier)

                if let secondaryTitle = state.secondaryActionTitle,
                   let secondaryAutomationIdentifier = state.secondaryAutomationIdentifier,
                   let secondaryAction = state.secondaryAction {
                    Button(action: secondaryAction) {
                        Text(secondaryTitle)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier(secondaryAutomationIdentifier)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 16)
    }
}

// MARK: - Day-grouped list

struct HomeDayGroupedList<Item, Row: View>: View {
    let sections: [HomeDaySection<Item>]
    let emptyMessage: String
    var emptyState: HomeListEmptyState? = nil
    let getID: (Item) -> AnyHashable
    var sectionSpacing: CGFloat = 12
    var headerSpacing: CGFloat = 2
    @ViewBuilder let row: (Item) -> Row

    /// Plain-words day header: "Today", "Yesterday", or "Monday, August 3" —
    /// nothing the reader has to decode.
    static func headerTitle(for section: HomeDaySection<Item>) -> String {
        if section.label == "Today" || section.label == "Yesterday" {
            return section.label
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter.string(from: section.day)
    }

    var body: some View {
        if sections.isEmpty {
            if let emptyState {
                HomeEmptyStateView(state: emptyState)
            } else {
                HStack {
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 28)
                .padding(.horizontal, 4)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: sectionSpacing) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: headerSpacing) {
                        Text(Self.headerTitle(for: section))
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.88)
                            .textCase(.uppercase)
                            .foregroundStyle(LibraryTokens.ink2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 6)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(LibraryTokens.hairline)
                                    .frame(height: 1)
                            }

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                                row(item)
                                    .id(getID(item))
                                if index < section.items.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Capture list

/// Filter box over the Home meetings list. Matches the user's query against
/// already-loaded meeting metadata (title and date) via
/// `HomeMeetingListFilter`; it never reads transcript bodies, so it stays cheap
/// even for large libraries. Filtering applies to the meetings currently loaded
/// into the dashboard slice — "Show more" pages in older meetings to search.
struct HomeMeetingSearchField: View {
    @Binding var query: String
    /// Bump to move keyboard focus into the field (⌘F, or the header
    /// magnifier revealing the bar). Also focuses on first appearance when
    /// the token is already non-zero, so a request made while the bar was
    /// hidden lands once it mounts.
    var focusRequestToken: Int = 0

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Find captures", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .task(id: focusRequestToken) {
                    guard focusRequestToken > 0 else { return }
                    isFocused = true
                }
                .accessibilityIdentifier("transcripted.home.meeting-search.field")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
                .accessibilityLabel("Clear meeting filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct HomeCaptureListSection<Item, Row: View>: View {
    let sections: [HomeDaySection<Item>]
    let emptyMessage: String
    var emptyState: HomeListEmptyState? = nil
    let isLoading: Bool
    let isLoadingMore: Bool
    let canLoadMore: Bool
    let getID: (Item) -> AnyHashable
    let onLoadMore: () -> Void
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 28)
            } else {
                HomeDayGroupedList(
                    sections: sections,
                    emptyMessage: emptyMessage,
                    emptyState: emptyState,
                    getID: getID,
                    sectionSpacing: 14,
                    headerSpacing: 2,
                    row: row
                )

                if canLoadMore || isLoadingMore {
                    HomeLoadMoreButton(
                        title: "Load more",
                        isLoading: isLoadingMore,
                        action: onLoadMore
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Row feedback

struct HomeFeedbackSheet: View {
    let target: HomeFeedbackTarget
    let onCancel: () -> Void
    let onSubmit: (HomeFeedbackSubmission) -> Void

    @State private var issueKind: HomeFeedbackIssueKind
    @State private var notes = ""
    @State private var includeDiagnostics = true

    init(
        target: HomeFeedbackTarget,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (HomeFeedbackSubmission) -> Void
    ) {
        self.target = target
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        _issueKind = State(initialValue: target.suggestedIssue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Report an issue")
                    .font(.system(size: 22, weight: .semibold))
                Text(target.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Issue")
                    .font(.subheadline.weight(.semibold))
                HomeIssueKindSelector(selection: $issueKind)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What happened?")
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            }

            Toggle("Include safe diagnostics", isOn: $includeDiagnostics)

            Text("Transcripted attaches the capture type, time, app version, a private reference ID, and recent scrubbed logs. It does not attach transcript text, audio, file paths, meeting titles, emails, or raw URLs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                SettingsInlineActionButton(title: "Cancel", action: onCancel)
                Spacer()
                SettingsInlineActionButton(title: "Review report", tone: .accent) {
                    onSubmit(HomeFeedbackSubmission(
                        target: target,
                        issueKind: issueKind,
                        notes: notes,
                        includeDiagnostics: includeDiagnostics
                    ))
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct HomeIssueKindSelector: View {
    @Binding var selection: HomeFeedbackIssueKind

    private let columns = [
        GridItem(.flexible(minimum: 140), spacing: 8),
        GridItem(.flexible(minimum: 140), spacing: 8),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(HomeFeedbackIssueKind.allCases) { kind in
                HomeIssueKindButton(
                    kind: kind,
                    isSelected: selection == kind
                ) {
                    selection = kind
                }
            }
        }
    }
}

private struct HomeIssueKindButton: View {
    let kind: HomeFeedbackIssueKind
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(kind.label)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(SettingsHoverButtonStyle(
            tone: isSelected ? .accent : .neutral,
            cornerRadius: 8,
            normalFill: background,
            normalStroke: stroke
        ))
    }

    private var background: Color {
        isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035)
    }

    private var stroke: Color {
        isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08)
    }
}

// MARK: - Load more / failed meetings

struct HomeLoadMoreButton: View {
    let title: String
    let isLoading: Bool
    var automationIdentifier = "transcripted.home.load-more"
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack {
            Spacer(minLength: 0)

            Button(action: action) {
                Text(isLoading ? "Loading..." : title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isLoading ? Color.secondary : Color.secondary.opacity(isHovering ? 1 : 0.82))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
                    )
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .accessibilityIdentifier(automationIdentifier)

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}
