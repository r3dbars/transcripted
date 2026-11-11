import AppKit
import Combine
import CryptoKit
import Foundation
import SwiftUI
import TranscriptedCore

/// Settings › Dictations and Settings › Meetings, used like a person with a
/// long library would: the real day-grouped list (`HomeDayGroupedList` inside
/// the Settings detail-column `ScrollView`) over `HomeViewModel`, a fresh
/// temporary capture library, and successive Load More clicks from the
/// bottom. A user report on 1.1.76: after scrolling to the bottom and
/// clicking Load More several times, both lists froze and the app had to be
/// force quit. Speakers had the same hang class (PR #2311); this smoke does
/// not touch that page.
///
/// Promises, for both lists at more than one library size:
/// - each Load More from the bottom adds one page of rows;
/// - a forward scroll still reaches the bottom after those pages land;
/// - the scroll offset never jumps back while scrolling forward or while
///   Load More grows the document;
/// - each step costs a few layout passes, and the page goes quiet once
///   scrolling stops.
///
/// The lazy-stack layout is a hypothesis based on the Speakers regression.
/// This harness must reproduce and then clear the capture-list failure on
/// macOS before it can establish that the reported freeze is fixed.
///
/// A hang guard turns a frozen main thread into a failure that names the
/// step; it never checks how long a step took.
@main struct CaptureListLoadMoreScrollSmoke {
    enum Kind: String {
        case dictations = "Dictations"
        case meetings = "Meetings"
    }

    struct Scenario {
        let kind: Kind
        let itemCount: Int
        var label: String { "\(kind.rawValue), \(itemCount) saved" }
    }

    /// Several sizes: whether a broken layout stalls depends on the list's
    /// geometry, so one size alone can pass by luck. Each capture sits on its
    /// own day so Load More grows the lazy stack of sections, not one inner
    /// column.
    static let scenarios = [
        Scenario(kind: .dictations, itemCount: 80),
        Scenario(kind: .meetings, itemCount: 80),
        Scenario(kind: .dictations, itemCount: 150),
        Scenario(kind: .meetings, itemCount: 150),
    ]
    static let pageSize = 10
    static let stepPoints: CGFloat = 40
    /// Further than any real list here, so a stuck scroll fails instead of looping.
    static let maximumSteps = 800
    /// A backward move bigger than this while scrolling forward is a jump.
    static let allowedBackwardPoints: CGFloat = 100
    /// One 40 pt step lays the page out a handful of times; a loop does far more.
    static let maximumLayoutsPerStep = 20
    /// Load More publishes a new page of day sections; that is allowed to
    /// cost more passes than a 40 pt nudge, but not an update loop.
    static let maximumLayoutsPerLoadMore = 80
    /// Layout passes allowed in a quiet second once scrolling stops (seen: 0).
    static let maximumIdleLayouts = 3

    private static var scenarioManifest: String {
        scenarios.map(\.label).joined(separator: "\n") + "\n"
    }

    static func main() {
        precondition(ProcessInfo.processInfo.environment["TRANSCRIPTED_AUTOMATED_HARNESS"] == "1")
        if CommandLine.arguments.dropFirst() == ["--list-scenarios"] {
            print(scenarioManifest, terminator: "")
            return
        }
        guard CommandLine.arguments.count == 1 else { exit(2) }
        setvbuf(stdout, nil, _IOLBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let guardian = CaptureListHangGuard()
        guardian.start()
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {
            MainActor.assumeIsolated {
                var completed = 0
                let failures = scenarios.compactMap { scenario in
                    let failure = run(scenario, guardian: guardian)
                    completed += 1
                    return failure
                }
                recordCompletion(completed: completed, failed: failures.count)
                for failure in failures { print("FAIL: \(failure)") }
                guard failures.isEmpty else { exit(1) }
                print("PASS: Capture list Load More scroll smoke (\(scenarios.count) lists)")
                exit(0)
            }
        }
        app.run()
        print("FAIL: AppKit returned before the scroll scenarios completed")
        exit(1)
    }

    private static func recordCompletion(completed: Int, failed: Int) {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["TRANSCRIPTED_FAST_TEST_COMPLETION_PATH"],
              let runID = environment["TRANSCRIPTED_FAST_TEST_COMPLETION_RUN_ID"] else {
            print("FAIL: scroll completion contract is missing")
            exit(1)
        }
        let digest = SHA256.hash(data: Data(scenarioManifest.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let receipt: [String: Any] = [
            "version": 1, "run_id": runID, "selection_digest": digest,
            "selected_functions": scenarios.count, "executed_functions": completed,
            "assertions": completed, "passed_assertions": completed - failed,
            "failed_assertions": failed, "quarantined_suites": 0,
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            print("FAIL: scroll completion receipt could not be written")
            exit(1)
        }
    }

    @MainActor static func setupFailed(_ message: String) -> Never {
        print("FAIL: setup: \(message)")
        exit(1)
    }

    @MainActor static func run(_ scenario: Scenario, guardian: CaptureListHangGuard) -> String? {
        guardian.note("building \(scenario.label)")
        let fixture: Fixture
        do {
            fixture = try Fixture.shared()
            try fixture.reset()
            try fixture.populate(scenario)
        } catch {
            setupFailed("fixture for \(scenario.label) could not be written: \(error)")
        }
        defer { fixture.resetSafely() }

        let viewModel = HomeViewModel()
        viewModel.setShown(true)
        viewModel.refresh()
        guardian.note("loading \(scenario.label)")
        var pumps = 0
        while (viewModel.isLoading || visibleCount(viewModel, kind: scenario.kind) == 0) && pumps < 400 {
            pump(0.02)
            pumps += 1
        }
        let firstPage = min(pageSize, scenario.itemCount)
        guard visibleCount(viewModel, kind: scenario.kind) == firstPage else {
            setupFailed("\(scenario.label) should open on \(firstPage) rows, got \(visibleCount(viewModel, kind: scenario.kind))")
        }
        guard scenario.itemCount <= pageSize || canLoadMore(viewModel, kind: scenario.kind) else {
            setupFailed("\(scenario.label) should offer Load More after the first page")
        }

        let diagnostics = CaptureListScrollDiagnosticCapture(viewModel: viewModel, kind: scenario.kind)
        let publications = viewModel.objectWillChange.sink {
            MainActor.assumeIsolated { diagnostics.notePublication() }
        }
        defer { publications.cancel() }

        let window = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 900, height: 700),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        let hosting = CaptureListLayoutCountingHostingView(
            rootView: CaptureListPageShell {
                page(for: scenario.kind, viewModel: viewModel)
            }
        )
        window.contentView = hosting
        window.orderFrontRegardless()
        defer {
            viewModel.cancel()
            window.close()
        }
        pump(0.5)

        guard let scroll = firstScrollView(in: hosting) else {
            setupFailed("\(scenario.label): no scroll view under the page")
        }
        let clip = scroll.contentView
        var lastY = clip.bounds.origin.y
        var step = 0
        var worstLayouts = 0
        var loadMoreCount = 0
        weak var initialDocument = scroll.documentView
        func record(_ phase: Int, step: Int, requestedY: CGFloat, maximumY: CGFloat,
                    beforeDocument: CGFloat, beforeViewport: CGFloat, layouts: Int) {
            diagnostics.record(
                phase: phase, step: step, viewModel: viewModel, kind: scenario.kind,
                loadMoreCount: loadMoreCount, scroll: scroll, clip: clip,
                initialDocument: initialDocument, hosting: hosting, window: window,
                requestedY: requestedY, maximumY: maximumY,
                beforeDocument: beforeDocument, beforeViewport: beforeViewport, layouts: layouts
            )
        }
        record(0, step: step, requestedY: lastY, maximumY: (scroll.documentView?.frame.height ?? 0) - clip.bounds.height,
            beforeDocument: scroll.documentView?.frame.height ?? 0, beforeViewport: clip.bounds.height, layouts: 0)

        while visibleCount(viewModel, kind: scenario.kind) < scenario.itemCount {
        if let failure = scrollTowardBottom(
            scenario: scenario, scroll: scroll, clip: clip,
            layoutPasses: { hosting.layoutPasses },
            guardian: guardian, lastY: &lastY, step: &step, worstLayouts: &worstLayouts,
            record: record
        ) {
            return diagnostics.failure(failure)
        }
            guard canLoadMore(viewModel, kind: scenario.kind) else {
                return diagnostics.failure("\(scenario.label): Load More disappeared with \(visibleCount(viewModel, kind: scenario.kind)) of \(scenario.itemCount) rows on screen")
            }
            guardian.note("\(scenario.label): Load More \(loadMoreCount) at y=\(Int(lastY))")
            let layoutsBefore = hosting.layoutPasses
            let documentHeightBefore = scroll.documentView?.frame.height ?? 0
            let viewportHeightBefore = clip.bounds.height
            let expected = min(visibleCount(viewModel, kind: scenario.kind) + pageSize, scenario.itemCount)
            loadMore(viewModel, kind: scenario.kind)
            loadMore(viewModel, kind: scenario.kind)
            pumps = 0
            while (viewModel.isLoadingMore || visibleCount(viewModel, kind: scenario.kind) < expected) && pumps < 400 {
                pump(0.02)
                pumps += 1
            }
            let y = clip.bounds.origin.y
            let layouts = hosting.layoutPasses - layoutsBefore
            worstLayouts = max(worstLayouts, layouts)
            record(1, step: step, requestedY: lastY, maximumY: (scroll.documentView?.frame.height ?? 0) - clip.bounds.height,
                beforeDocument: documentHeightBefore, beforeViewport: viewportHeightBefore, layouts: layouts)
            if visibleCount(viewModel, kind: scenario.kind) != expected {
                return diagnostics.failure("\(scenario.label): Load More \(loadMoreCount) left \(visibleCount(viewModel, kind: scenario.kind)) rows on screen, expected \(expected)")
            }
            if y < lastY - allowedBackwardPoints {
                return diagnostics.failure("\(scenario.label): Load More \(loadMoreCount) jumped the scroll from y=\(Int(lastY)) to y=\(Int(y))")
            }
            if layouts > maximumLayoutsPerLoadMore {
                return diagnostics.failure("\(scenario.label): Load More \(loadMoreCount) laid the page out \(layouts) times")
            }
            lastY = y
            loadMoreCount += 1
            step += 1
        }

        if let failure = scrollTowardBottom(
            scenario: scenario, scroll: scroll, clip: clip,
            layoutPasses: { hosting.layoutPasses },
            guardian: guardian, lastY: &lastY, step: &step, worstLayouts: &worstLayouts,
            record: record, untilBottom: true
        ) {
            return diagnostics.failure(failure)
        }

        guardian.note("\(scenario.label): settling at the bottom")
        pump(1.0)
        let settled = hosting.layoutPasses
        pump(1.0)
        let idleLayouts = hosting.layoutPasses - settled
        record(2, step: step, requestedY: lastY, maximumY: (scroll.documentView?.frame.height ?? 0) - clip.bounds.height,
            beforeDocument: scroll.documentView?.frame.height ?? 0, beforeViewport: clip.bounds.height, layouts: idleLayouts)
        if idleLayouts > maximumIdleLayouts {
            return diagnostics.failure("\(scenario.label): the page kept laying out after scrolling stopped (\(idleLayouts) passes)")
        }
        print("ok: \(scenario.label): \(loadMoreCount) Load More clicks, reached the bottom (y=\(Int(lastY))) in \(step) steps, at most \(worstLayouts) layouts per step")
        return nil
    }

    @MainActor private static func scrollTowardBottom(
        scenario: Scenario,
        scroll: NSScrollView,
        clip: NSClipView,
        layoutPasses: () -> Int,
        guardian: CaptureListHangGuard,
        lastY: inout CGFloat,
        step: inout Int,
        worstLayouts: inout Int,
        record: (Int, Int, CGFloat, CGFloat, CGFloat, CGFloat, Int) -> Void,
        untilBottom: Bool = false
    ) -> String? {
        while true {
            let maxY = (scroll.documentView?.frame.height ?? 0) - clip.bounds.height
            if lastY >= maxY - 1 { return nil }
            if !untilBottom, maxY - lastY <= stepPoints * 2 { return nil }
            if step >= maximumSteps {
                return "\(scenario.label): after \(step) steps the scroll is at y=\(Int(lastY)) of \(Int(maxY)), never reaching the bottom"
            }
            guardian.note("\(scenario.label): step \(step) from y=\(Int(lastY))")
            let layoutsBefore = layoutPasses()
            let documentHeightBefore = scroll.documentView?.frame.height ?? 0
            let viewportHeightBefore = clip.bounds.height
            let requestedY = min(lastY + stepPoints, maxY)
            clip.scroll(to: NSPoint(x: 0, y: requestedY))
            scroll.reflectScrolledClipView(clip)
            pump(0.03)
            let y = clip.bounds.origin.y
            // Pass the current step by value: the caller's step is exclusively
            // borrowed for this function and must not be read by the callback.
            record(1, step, requestedY, maxY, documentHeightBefore, viewportHeightBefore,
                   layoutPasses() - layoutsBefore)
            if y < lastY - allowedBackwardPoints {
                return "\(scenario.label): at step \(step) the scroll jumped back from y=\(Int(lastY)) to y=\(Int(y))"
            }
            let layouts = layoutPasses() - layoutsBefore
            worstLayouts = max(worstLayouts, layouts)
            if layouts > maximumLayoutsPerStep {
                return "\(scenario.label): step \(step) at y=\(Int(y)) laid the page out \(layouts) times"
            }
            lastY = y
            step += 1
        }
    }

    @MainActor private static func visibleCount(_ viewModel: HomeViewModel, kind: Kind) -> Int {
        switch kind {
        case .dictations:
            return viewModel.dictationDaySections.reduce(0) { $0 + $1.items.count }
        case .meetings:
            return viewModel.meetingDaySections.reduce(0) { $0 + $1.items.count }
        }
    }

    @MainActor private static func canLoadMore(_ viewModel: HomeViewModel, kind: Kind) -> Bool {
        switch kind {
        case .dictations: return viewModel.canLoadMoreDictations
        case .meetings: return viewModel.canLoadMoreMeetings
        }
    }

    @MainActor private static func loadMore(_ viewModel: HomeViewModel, kind: Kind) {
        switch kind {
        case .dictations: viewModel.loadMoreDictations()
        case .meetings: viewModel.loadMoreMeetings()
        }
    }

    @ViewBuilder
    @MainActor private static func page(for kind: Kind, viewModel: HomeViewModel) -> some View {
        switch kind {
        case .dictations:
            DictationsSettingsPage(
                homeViewModel: viewModel,
                homeCopiedRowID: nil,
                onStartDictation: {},
                onLoadMoreDictations: { viewModel.loadMoreDictations() },
                onCopyDictation: { _ in },
                dictationRowMenuItems: { _ in [] }
            )
        case .meetings:
            HomeCaptureListSection(
                sections: viewModel.meetingDaySections,
                emptyMessage: HomeCaptureListCopy.emptyMeetings,
                isLoading: viewModel.isLoading,
                isLoadingMore: viewModel.isLoadingMore,
                canLoadMore: viewModel.canLoadMoreMeetings,
                getID: { AnyHashable($0.id) },
                onLoadMore: { viewModel.loadMoreMeetings() }
            ) { item in
                QuietMeetingRow(
                    item: item,
                    isCopied: false,
                    onOpen: {},
                    onCopy: {},
                    menuItems: []
                )
            }
        }
    }

    @MainActor static func pump(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until {
            RunLoop.current.run(mode: .default, before: min(until, Date().addingTimeInterval(0.005)))
        }
    }

    @MainActor static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }
}

@MainActor private final class CaptureListScrollDiagnosticCapture {
    private let initialIDs: [String]
    private var publications = 0
    private var history = CaptureListScrollDiagnosticHistory()
    private let kind: CaptureListLoadMoreScrollSmoke.Kind

    init(viewModel: HomeViewModel, kind: CaptureListLoadMoreScrollSmoke.Kind) {
        self.kind = kind
        initialIDs = Self.ids(viewModel, kind: kind)
    }

    func notePublication() { publications += 1 }

    func record(
        phase: Int, step: Int, viewModel: HomeViewModel,
        kind: CaptureListLoadMoreScrollSmoke.Kind, loadMoreCount: Int,
        scroll: NSScrollView, clip: NSClipView, initialDocument: NSView?,
        hosting: NSView, window: NSWindow, requestedY: CGFloat,
        maximumY: CGFloat, beforeDocument: CGFloat, beforeViewport: CGFloat, layouts: Int
    ) {
        let current = Self.ids(viewModel, kind: kind)
        history.append(.init(
            phase: phase, step: step, modelPublications: publications,
            visibleCount: current.count, loadMoreCount: loadMoreCount,
            canLoadMore: kind == .dictations ? viewModel.canLoadMoreDictations : viewModel.canLoadMoreMeetings,
            isLoadingMore: viewModel.isLoadingMore,
            scrollAttached: scroll.window === window && scroll.isDescendant(of: hosting),
            scrollStillFirst: CaptureListLoadMoreScrollSmoke.firstScrollView(in: hosting) === scroll,
            clipUnchanged: scroll.contentView === clip,
            documentUnchanged: initialDocument != nil && scroll.documentView === initialDocument,
            documentHeightBefore: Double(beforeDocument), viewportHeightBefore: Double(beforeViewport),
            maximumY: Double(maximumY), requestedY: Double(requestedY),
            actualY: Double(clip.bounds.origin.y),
            documentHeightAfter: Double(scroll.documentView?.frame.height ?? 0),
            viewportHeightAfter: Double(clip.bounds.height), layoutDelta: layouts
        ))
        _ = initialIDs
        _ = current
    }

    func failure(_ message: String) -> String {
        if let json = history.json() {
            print("SCROLL_DIAGNOSTICS " + json)
        } else {
            print("SCROLL_DIAGNOSTICS_ENCODING_FAILED")
        }
        return message
    }

    private static func ids(_ viewModel: HomeViewModel, kind: CaptureListLoadMoreScrollSmoke.Kind) -> [String] {
        switch kind {
        case .dictations:
            return viewModel.dictationDaySections.flatMap { $0.items.map(\.id) }
        case .meetings:
            return viewModel.meetingDaySections.flatMap { $0.items.map(\.id) }
        }
    }
}

/// The real Settings detail column around one capture list.
private struct CaptureListPageShell<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            LibraryTokens.contentBackground.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    content()
                }
                .padding(.horizontal, 28)
                .padding(.top, 4)
                .padding(.bottom, 28)
                .frame(maxWidth: 860, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

private final class CaptureListLayoutCountingHostingView<Content: View>: NSHostingView<Content> {
    private(set) var layoutPasses = 0

    override func layout() {
        layoutPasses += 1
        super.layout()
    }
}

final class CaptureListHangGuard: @unchecked Sendable {
    private let quietLimit: TimeInterval = 60
    private let lock = NSLock()
    private var lastNote = "starting"
    private var lastProgress = Date()

    func note(_ text: String) {
        lock.lock()
        lastNote = text
        lastProgress = Date()
        lock.unlock()
    }

    func start() {
        Thread.detachNewThread { [self] in
            while true {
                Thread.sleep(forTimeInterval: 1)
                lock.lock()
                let quiet = Date().timeIntervalSince(lastProgress)
                let note = lastNote
                lock.unlock()
                if quiet > quietLimit {
                    print("FAIL: the main thread stopped answering (\(note))")
                    exit(1)
                }
            }
        }
    }
}

@MainActor private final class Fixture {
    let container: URL
    let meetings: URL
    let dictations: URL
    private let fixtureHome: URL
    private let fixtureParent: URL
    private let captures: URL
    private static var instance: Fixture?

    static func shared() throws -> Fixture {
        if let instance { return instance }
        let created = try Fixture()
        instance = created
        return created
    }

    private init() throws {
        let environment = ProcessInfo.processInfo.environment
        guard AutomatedLaunchEnvironment.isActive(environment: environment),
              environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1" else {
            throw IsolationError.unowned
        }
        let paths = try CaptureListFixturePaths(environment: environment)
        let home = paths.home
        let parent = paths.parent
        let actualContainer = paths.container
        let expectedCaptures = paths.captures
        let expectedMeetings = paths.meetings
        let expectedDictations = paths.dictations
        // Prepare only exact owned leaves before consulting app storage helpers.
        for directory in [expectedCaptures, expectedMeetings, expectedDictations] {
            guard directory.resolvingSymlinksInPath().standardizedFileURL == directory else {
                throw IsolationError.unowned
            }
            try FileManager.default.createPrivateDirectory(at: directory)
            try CaptureListFixturePaths.requirePrivateDirectory(directory)
        }
        // Pin the volatile capture location before app helpers can consult a
        // stale preference belonging to this executable in the test account.
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[TranscriptedStoragePreferences.captureLibraryLocationKey] = expectedCaptures.path
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        let meetingsURL = FileManager.default.meetingSupportDir.resolvingSymlinksInPath().standardizedFileURL
        let dictationsURL = FileManager.default.dictationSupportDir.resolvingSymlinksInPath().standardizedFileURL
        guard meetingsURL == expectedMeetings, dictationsURL == expectedDictations else {
            throw IsolationError.unowned
        }
        fixtureHome = home
        fixtureParent = parent
        container = actualContainer
        captures = expectedCaptures
        meetings = meetingsURL
        dictations = dictationsURL
    }

    func reset() throws {
        try emptyDirectory(meetings)
        try emptyDirectory(dictations)
    }

    func resetSafely() {
        do {
            try reset()
        } catch {
            CaptureListLoadMoreScrollSmoke.setupFailed("fixture cleanup failed")
        }
    }

    func populate(_ scenario: CaptureListLoadMoreScrollSmoke.Scenario) throws {
        switch scenario.kind {
        case .dictations:
            for index in 0..<scenario.itemCount {
                try writeDictation(index: index)
            }
        case .meetings:
            for index in 0..<scenario.itemCount {
                try writeMeeting(index: index)
            }
        }
    }

    private func emptyDirectory(_ url: URL) throws {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard fixtureHome.resolvingSymlinksInPath().standardizedFileURL == fixtureHome,
              fixtureHome.deletingLastPathComponent() == fixtureParent,
              fixtureHome.lastPathComponent.hasPrefix("transcripted-capture-list-scroll."),
              container.resolvingSymlinksInPath().standardizedFileURL == container,
              container == fixtureHome.appendingPathComponent("container", isDirectory: true),
              captures.resolvingSymlinksInPath().standardizedFileURL == captures,
              captures == container.appendingPathComponent("captures", isDirectory: true),
              resolved == url.standardizedFileURL,
              resolved.deletingLastPathComponent() == captures,
              (resolved == meetings && resolved.lastPathComponent == "meetings") ||
                (resolved == dictations && resolved.lastPathComponent == "dictations") else {
            throw IsolationError.unowned
        }
        let items = try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for item in items {
            guard item.standardizedFileURL.deletingLastPathComponent() == resolved else {
                throw IsolationError.unowned
            }
            try FileManager.default.removeItem(at: item)
        }
    }

    private func writeDictation(index: Int) throws {
        let date = day(offset: -index)
        _ = try DictationTranscriptStore.save(
            text: "Synthetic dictation body number \(index)",
            sourceApp: nil,
            delivery: .copied,
            createdAt: date,
            directory: dictations
        )
    }

    private func writeMeeting(index: Int) throws {
        let date = day(offset: -index)
        let url = meetings.appendingPathComponent("meeting-\(index).md", isDirectory: false)
        let dayStamp = format(date, "yyyy-MM-dd")
        let timeStamp = format(date, "HH:mm:ss")
        let markdown = """
        ---
        title: "Synthetic Meeting \(index)"
        capture_type: meeting
        date: "\(dayStamp)"
        time: "\(timeStamp)"
        duration: "10:00"
        total_word_count: 5
        mic_utterances: 1
        system_utterances: 1
        transcript_id: "\(UUID().uuidString)"
        ---

        # Synthetic Meeting \(index)

        ## Transcript

        **00:01** [Mic/You]
        Synthetic test meeting.

        **00:04** [System/Remote Participant]
        Synthetic response.
        """
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.creationDate: date, .modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    private func day(offset: Int) -> Date {
        Calendar(identifier: .gregorian).date(byAdding: .day, value: offset, to: Date()) ?? Date()
    }

    private func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    private enum IsolationError: Error { case unowned }
}
