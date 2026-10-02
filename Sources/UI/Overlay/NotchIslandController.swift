// NotchIslandController.swift
// The one notch island shared by dictation, meetings and the call-detected
// prompt. Each controller keeps
// its own state machine, timers and actions and pushes a plain snapshot here
// (NotchIsland*Content). This composes them with NotchIslandPresentation,
// sizes the panel with NotchIslandGeometry for the display it picks (the one
// with the focused text field for a dictation, else the one under the pointer),
// grows it out of the notch (or down from the top edge of a display without
// one), and routes taps back to whichever controller owns them.

import AppKit

@MainActor
final class NotchIslandController: NotchIslandCallPromptPresenting {
    var dictationActionHandler: ((NotchIslandAction) -> Void)?
    var meetingActionHandler: ((NotchIslandAction) -> Void)?
    var callActionHandler: ((NotchIslandAction) -> Void)?
    var callHoverHandler: ((Bool) -> Void)?
    /// Right-click menu while a meeting records (Discard Recording…).
    var meetingMenuProvider: (() -> NSMenu?)?
    /// "Paste again" on the dictation that just landed.
    var onPasteLastDictation: (() -> Void)?
    /// The text of the dictation that just landed, for Copy and the preview.
    var lastDictationTextProvider: (() -> String?)?
    /// The pointer entered or left the island while "Who was on this call?"
    /// is up, so its Later ring and "Everyone's named" linger can pause.
    var speakerReviewHoverHandler: ((Bool) -> Void)?
    /// "Who was on this call?" went on or off screen (a dictation, a call
    /// prompt, or the next meeting hides it), so its Later ring only runs
    /// while someone can see it.
    var speakerReviewVisibilityHandler: ((Bool) -> Void)? {
        didSet { reportedSpeakerReviewVisible = nil }
    }
    /// The call prompt went on or off screen (it waits behind a dictation),
    /// so its timeout only runs while someone can see it.
    var callVisibilityHandler: ((Bool) -> Void)? {
        didSet { reportedCallPromptVisible = nil }
    }

    private static let hoverOpenDelay: UInt64 = 120_000_000
    private static let hoverCloseDelay: UInt64 = 380_000_000
    private static let recentInsertLinger: UInt64 = 2_600_000_000
    private static let meterInterval: CFTimeInterval = 0.05

    private var dictation: NotchIslandDictationContent?
    private var meeting: NotchIslandMeetingContent?
    private var callPrompt: NotchIslandCallPromptContent?
    private var speakerReview: NotchIslandSpeakerReviewContent?
    private var reportedSpeakerReviewVisible: Bool?
    private var reportedCallPromptVisible: Bool?
    /// The app that was in front when a name box took the keyboard. It gets
    /// the keyboard back once naming ends.
    private var keyboardReturnApp: NSRunningApplication?
    private var recentInsert: NotchIslandRecentInsert?
    private var targetApp: NSRunningApplication?
    private var listeningSince: Date?
    private var live = NotchIslandLiveValues()

    private var expanded = false
    private var collapsedStickyKey: String?
    private var isHovered = false
    private var lastLayout: NotchIslandLayout?
    private var lastWingWidths: (left: CGFloat, right: CGFloat) = (0, 0)
    private var lastMeterPush: CFTimeInterval = 0

    private var panel: NotchIslandPanel?
    private var islandView: NotchIslandView?
    /// The screen the island is on, kept while it is up so it never jumps.
    private var screen: NotchIslandScreenInfo?
    private var isShown = false
    /// Where the finished island sits on screen (the panel can be larger
    /// while the shape springs).
    private var targetFrame: NSRect?
    private var hideGeneration = 0
    private var hoverTask: Task<Void, Never>?
    private var recentInsertTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    /// Mouse monitors while the island is up: the window lets clicks through
    /// everywhere except over the island itself, and hover is judged from
    /// the pointer instead of tracking areas on a window that may ignore it.
    private var pointerMonitors: [Any] = []

    /// Always on: the Notch island is the only dictation, meeting and call
    /// prompt window. The old near-text, mini cursor and meeting pill panels
    /// are deleted; the call-prompt pill panel is still in the tree until it
    /// is, but nothing picks it.
    static var isSelected: Bool { true }

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.screen = nil
                self.targetFrame = nil
                if self.isShown { self.render(animated: false) }
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        hoverTask?.cancel()
        recentInsertTask?.cancel()
        tickTask?.cancel()
    }

    /// True while the pointer rests on the island (holds messages and the
    /// saved meeting, like hovering the old pills did).
    var isPointerOverIsland: Bool {
        guard isShown, let frame = targetFrame else { return false }
        return frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
    }

    /// Builds the panel and draws a sample island once at launch, so the
    /// first key press shows the island on the next frame instead of paying
    /// for window creation, fonts and symbols.
    func prewarm() {
        let (panel, islandView) = ensurePanel()
        guard !isShown, !panel.isVisible else { return }
        let screen = currentScreen()
        islandView.apply(
            NotchIslandPresentation.layout(
                dictation: NotchIslandDictationContent(phase: .listening),
                meeting: nil,
                callPrompt: nil,
                recentInsert: nil,
                expanded: false
            ),
            live: live
        )
        islandView.setGeometry(screen: screen, hasDrop: false, edgeProgress: nil)
        panel.alphaValue = 0
        panel.setFrame(
            NotchIslandGeometry.envelope(screen: screen, containing: [], margin: NotchIslandMotion.springMargin),
            display: true
        )
        panel.orderFrontRegardless()
        panel.display()
        panel.orderOut(nil)
        panel.alphaValue = 1
        self.screen = nil
    }

    // MARK: - Dictation

    func updateDictation(_ content: NotchIslandDictationContent?, targetApp: NSRunningApplication?) {
        if content?.phase == .starting || content == nil {
            listeningSince = nil
        }
        if content?.phase == .listening, listeningSince == nil {
            listeningSince = Date()
        }
        if content?.phase == .starting, recentInsert != nil {
            clearRecentInsert()
        }
        if case .loading(_, _, let progress?)? = content?.phase {
            live.loadingProgress = progress
        }
        let ended = content == nil && dictation != nil
        guard content != dictation || targetApp !== self.targetApp else { return }
        dictation = content
        self.targetApp = content == nil ? nil : targetApp
        if ended, recentInsert != nil {
            scheduleRecentInsertExpiry()
        }
        render()
        updateTicker()
    }

    func updateDictationLevel(_ level: Float) {
        guard isShown, dictation?.phase == .listening else { return }
        islandView?.pushDictationLevel(level)
    }

    /// The dictation landed. The island lingers on it after the "Pasted"
    /// beat so a hover can offer Copy and Paste again.
    func noteDictationInserted(title: String) {
        recentInsertTask?.cancel()
        recentInsertTask = nil
        recentInsert = NotchIslandRecentInsert(title: title, text: lastDictationTextProvider?())
        if dictation == nil {
            scheduleRecentInsertExpiry()
            render()
        }
    }

    // MARK: - Meetings

    func updateMeeting(_ content: NotchIslandMeetingContent?) {
        guard content != meeting else { return }
        meeting = content
        live.meetingElapsed = content?.duration ?? 0
        if case .transcribing(let progress, _)? = content?.phase {
            live.transcriptionProgress = progress ?? 0
        }
        render()
    }

    func updateMeetingLevels(mic: Float, system: Float) {
        guard isShown, meeting?.isRecording == true else { return }
        // Mic and call levels arrive as separate ticks; one push per beat
        // keeps the lanes scrolling at a steady pace.
        let now = CACurrentMediaTime()
        guard now - lastMeterPush >= Self.meterInterval else { return }
        lastMeterPush = now
        islandView?.pushMeetingLevels(mic: mic, system: system)
    }

    // MARK: - Call prompt

    func updateCallPrompt(_ content: NotchIslandCallPromptContent?) {
        if let content {
            live.callSecondsLeft = content.secondsLeft
        }
        guard content != callPrompt else {
            refreshLive()
            return
        }
        callPrompt = content
        render()
    }

    func updateCallPromptSeconds(_ secondsLeft: Int) {
        guard callPrompt != nil else { return }
        live.callSecondsLeft = secondsLeft
        refreshLive()
    }

    // MARK: - Speaker review

    /// Shows (or with nil, takes down) "Who was on this call?". The view is
    /// owned by the review's presenter and kept alive across drop-down
    /// rebuilds so typing and playback carry on.
    func showSpeakerReview(_ content: NotchIslandSpeakerReviewContent?, view: NSView?) {
        let (panel, islandView) = ensurePanel()
        speakerReview = content
        islandView.speakerReviewView = content == nil ? nil : view
        // Once naming ends (Done, Later, or a newer review), the name boxes
        // can't take the keyboard again; render() hands it back if they had it.
        panel.acceptsKeyForTyping = content?.stage == .naming
        render()
    }

    private func reportSpeakerReviewVisibility(_ visible: Bool) {
        guard reportedSpeakerReviewVisible != visible else { return }
        reportedSpeakerReviewVisible = visible
        speakerReviewVisibilityHandler?(visible)
    }

    private func reportCallPromptVisibility() {
        guard callPrompt != nil else {
            // The next prompt reports afresh.
            reportedCallPromptVisible = nil
            return
        }
        let visible = NotchIslandPresentation.callPromptIsOnScreen(dictation: dictation, callPrompt: callPrompt)
        guard reportedCallPromptVisible != visible else { return }
        reportedCallPromptVisible = visible
        callVisibilityHandler?(visible)
    }

    /// The review's rows grew or shrank.
    func speakerReviewLayoutChanged() {
        guard isShown, speakerReview != nil else { return }
        render()
    }

    /// A name box was clicked: take the keyboard, only while the review asks.
    func makeKeyForTyping() {
        guard let panel, panel.acceptsKeyForTyping else { return }
        if !panel.isKeyWindow {
            // The panel is non-activating, so the app the person was in is
            // still the frontmost app while they type a name here.
            keyboardReturnApp = Self.frontmostOtherApp()
        }
        panel.makeKey()
    }

    /// Gives the keyboard back to the app the person was in, without hiding
    /// the island and without activating Transcripted.
    ///
    /// The island is a non-activating panel: clicking a name box made it the
    /// key window but left the other app active (its menu bar stays up). So
    /// only key focus has to move back. AppKit has no public "stop being key"
    /// for a window that stays on screen (`resignKey()` is documented as
    /// never to be called directly and only updates AppKit's side), but
    /// ordering a key non-activating panel out hands key focus back to the
    /// active app, which is what `hide()` has always relied on. The panel can
    /// no longer become key at this point, so ordering it straight back in,
    /// in the same pass with its layers untouched, leaves the island where it
    /// was. Re-activating the app that was frontmost then asks it to take its
    /// key window back, in case the window server has not already; it never
    /// activates Transcripted.
    private func returnKeyboardIfHeld() {
        guard let panel, panel.isKeyWindow else {
            keyboardReturnApp = nil
            return
        }
        let returnTo = keyboardReturnApp ?? Self.frontmostOtherApp()
        keyboardReturnApp = nil
        panel.makeFirstResponder(nil)
        let couldTakeKey = panel.acceptsKeyForTyping
        panel.acceptsKeyForTyping = false
        if panel.isVisible {
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
        panel.acceptsKeyForTyping = couldTakeKey
        if let returnTo, !returnTo.isTerminated {
            returnTo.activate(options: [])
        }
    }

    private static func frontmostOtherApp() -> NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return nil }
        return app
    }

    // MARK: - Rendering

    private func render(animated: Bool = true) {
        if NotchIslandPresentation.stickyKey(dictation: dictation, meeting: meeting, callPrompt: callPrompt, speakerReview: speakerReview) == nil {
            collapsedStickyKey = nil
        }
        let layout = NotchIslandPresentation.layout(
            dictation: dictation,
            meeting: meeting,
            callPrompt: callPrompt,
            recentInsert: recentInsert,
            expanded: expanded,
            collapsedStickyKey: collapsedStickyKey,
            speakerReview: speakerReview
        )
        lastLayout = layout
        reportSpeakerReviewVisibility(layout.showsSpeakerReview)
        reportCallPromptVisibility()
        if !NotchIslandPresentation.speakerReviewKeepsKeyboard(speakerReview, onScreen: layout.showsSpeakerReview) {
            returnKeyboardIfHeld()
        }
        guard !layout.isEmpty else {
            hide(animated: animated)
            return
        }

        let (panel, islandView) = ensurePanel()
        // Hidden from screen sharing and screenshots unless the person
        // turned it on in Settings; read each time so the switch applies at once.
        panel.sharingType = NotchIslandPreferences.visibleInScreenSharing() ? .readOnly : .none
        let screen = currentScreen()
        live.dictationElapsed = listeningSince.map { Date().timeIntervalSince($0) } ?? 0
        islandView.targetAppIcon = targetApp?.icon
        islandView.apply(layout, live: live)
        var edgeProgress: Double?
        if layout.showsEdgeProgress, case .transcribing(let progress?, _)? = meeting?.phase {
            edgeProgress = progress
        }
        islandView.setGeometry(screen: screen, hasDrop: layout.drop != nil, edgeProgress: edgeProgress)

        let widths = islandView.wingContentWidths
        lastWingWidths = widths
        let size = NotchIslandGeometry.islandSize(
            screen: screen,
            leftContent: widths.left,
            rightContent: widths.right,
            dropHeight: islandView.dropHeight
        )
        let frame = NotchIslandGeometry.frame(screen: screen, size: size)

        let radius = islandView.currentCornerRadius
        if !isShown {
            islandView.resetBlur()
            isShown = true
            hideGeneration += 1
            let appearingFromHidden = !panel.isVisible
            let start = appearingFromHidden ? NotchIslandGeometry.collapsedFrame(screen: screen) : presentedShapeFrame(panel, islandView)
            let startRadius = appearingFromHidden ? NotchIslandGeometry.collapsedRadius(screen: screen) : islandView.shapeCornerRadius
            targetFrame = frame
            islandView.setContentVisible(false, animated: false)
            springShape(panel, islandView, from: start, fromRadius: startRadius, to: frame, radius: radius, spring: animated ? growSpring(screen) : nil)
            panel.orderFrontRegardless()
            startPointerWatch()
            islandView.setContentVisible(true, animated: animated)
            if animated {
                islandView.blurContent(in: true)
            }
            updateTicker()
            return
        }
        guard targetFrame != frame || islandView.shapeCornerRadius != radius else { return }
        targetFrame = frame
        springShape(
            panel,
            islandView,
            from: presentedShapeFrame(panel, islandView),
            fromRadius: islandView.shapeCornerRadius,
            to: frame,
            radius: radius,
            spring: animated ? growSpring(screen) : nil
        )
        pointerMoved()
    }

    private func growSpring(_ screen: NotchIslandScreenInfo) -> NotchIslandMotion.Spring {
        screen.hasNotch ? NotchIslandMotion.grow : NotchIslandMotion.growFromEdge
    }

    /// The shape's current on-screen rect, mid-spring included.
    private func presentedShapeFrame(_ panel: NSPanel, _ islandView: NotchIslandView) -> NSRect {
        let shape = islandView.presentedShapeRect
        let canvas = panel.frame
        return NSRect(x: canvas.minX + shape.minX, y: canvas.maxY - shape.maxY, width: shape.width, height: shape.height)
    }

    /// Springs the shape from one on-screen rect to another. The window
    /// stays put while the island is up (a fixed envelope with room for the
    /// overshoot); only Core Animation moves the shape, so the window can
    /// never resize out of step with it.
    private func springShape(
        _ panel: NotchIslandPanel,
        _ islandView: NotchIslandView,
        from start: NSRect,
        fromRadius: CGFloat,
        to end: NSRect,
        radius: CGFloat,
        spring: NotchIslandMotion.Spring?,
        completion: (() -> Void)? = nil
    ) {
        let screen = currentScreen()
        let needed = NotchIslandGeometry.envelope(screen: screen, containing: [start, end], margin: NotchIslandMotion.springMargin)
        let oldCanvas = panel.frame
        let canvas: NSRect
        if !panel.isVisible {
            canvas = needed
        } else if oldCanvas.contains(needed) {
            canvas = oldCanvas
        } else {
            canvas = oldCanvas.union(needed)
        }
        func local(_ rect: NSRect) -> CGRect {
            CGRect(x: rect.minX - canvas.minX, y: canvas.maxY - rect.maxY, width: rect.width, height: rect.height)
        }
        // Where the wings' content sits now, to slide it from there. Not on
        // the first grow, where the content starts in place.
        let slidesContent = spring != nil && completion == nil && panel.isVisible
        let previousAnchors = islandView.contentAnchors().map { $0 + oldCanvas.minX - canvas.minX }
        if canvas != oldCanvas || !panel.isVisible {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            panel.setFrame(canvas, display: false)
            islandView.frame = NSRect(origin: .zero, size: canvas.size)
            CATransaction.commit()
        }
        islandView.setIslandRect(local(end))
        if slidesContent, let spring {
            islandView.slideContent(from: previousAnchors, spring: spring)
        }
        islandView.morph(from: local(start), fromRadius: fromRadius, to: local(end), radius: radius, spring: spring) {
            completion?()
        }
    }

    // MARK: - Pointer

    private func startPointerWatch() {
        guard pointerMonitors.isEmpty else {
            pointerMoved()
            return
        }
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            Task { @MainActor [weak self] in self?.pointerMoved() }
        }) {
            pointerMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }) {
            pointerMonitors.append(local)
        }
        pointerMoved()
    }

    private func stopPointerWatch() {
        pointerMonitors.forEach { NSEvent.removeMonitor($0) }
        pointerMonitors = []
        panel?.ignoresMouseEvents = true
    }

    /// Clicks go to whatever is under the envelope unless the pointer is on
    /// the island itself.
    private func pointerMoved() {
        guard isShown, let panel, let frame = targetFrame else { return }
        let inside = frame.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
        }
        handleHover(inside)
    }

    /// Timers and countdowns tick without rebuilding the island, unless a
    /// digit is added (9:59 → 10:00) and a wing needs more room.
    private func refreshLive() {
        guard isShown, let islandView else { return }
        live.dictationElapsed = listeningSince.map { Date().timeIntervalSince($0) } ?? 0
        islandView.updateLive(live)
        let widths = islandView.wingContentWidths
        if widths.left != lastWingWidths.left || widths.right != lastWingWidths.right {
            render()
        }
    }

    private func hide(animated: Bool) {
        hoverTask?.cancel()
        hoverTask = nil
        tickTask?.cancel()
        tickTask = nil
        expanded = false
        isHovered = false
        guard isShown, let panel, let islandView else { return }
        isShown = false
        targetFrame = nil
        stopPointerWatch()
        hideGeneration += 1
        let generation = hideGeneration
        let finish = { [weak self] in
            guard let self, self.hideGeneration == generation, !self.isShown else { return }
            self.panel?.orderOut(nil)
            self.keyboardReturnApp = nil
            self.screen = nil
        }
        guard animated, !NotchIslandPalette.reduceMotion, let screen else {
            finish()
            return
        }
        // Content fades and softens while the shape pulls back into the
        // notch (or up into the top edge).
        islandView.setContentVisible(false, animated: true)
        islandView.blurContent(in: false)
        springShape(
            panel,
            islandView,
            from: presentedShapeFrame(panel, islandView),
            fromRadius: islandView.shapeCornerRadius,
            to: NotchIslandGeometry.collapsedFrame(screen: screen),
            radius: NotchIslandGeometry.collapsedRadius(screen: screen),
            spring: NotchIslandMotion.shrink,
            completion: finish
        )
        // Core Animation's "done" can be lost (the Mac sleeping mid-shrink);
        // take the window down anyway once the shrink must be over.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: NotchIslandMotion.hideFallbackNanoseconds)
            finish()
        }
    }

    private func ensurePanel() -> (NotchIslandPanel, NotchIslandView) {
        if let panel, let islandView { return (panel, islandView) }
        let initial = NSRect(x: 0, y: 0, width: NotchIslandGeometry.minimumTabWidth, height: NotchIslandGeometry.tabRowHeight)
        let panel = NotchIslandPanel(contentRect: initial, styleMask: [], backing: .buffered, defer: true)
        let view = NotchIslandView(frame: initial)
        view.autoresizingMask = [.width, .height]
        view.onAction = { [weak self] action in self?.handleAction(action) }
        view.onBackgroundClick = { [weak self] in self?.handleBackgroundClick() }
        view.menuProvider = { [weak self] in self?.meetingMenuProvider?() }
        panel.contentView = view
        self.panel = panel
        self.islandView = view
        return (panel, view)
    }

    /// The display the island is on, chosen once per show and kept while it
    /// is up (see `NotchIslandScreenChoice`).
    private func currentScreen() -> NotchIslandScreenInfo {
        if let screen { return screen }
        let screens = NSScreen.screens
        let focusedField = NotchIslandScreenChoice.looksUpFocusedField(
            dictationOpensIsland: dictation != nil,
            screenCount: screens.count
        ) ? focusedFieldRect() : nil
        let chosenFrame = NotchIslandScreenChoice.screenFrame(
            focusedFieldRect: focusedField,
            mouseLocation: NSEvent.mouseLocation,
            screenFrames: screens.map(\.frame),
            mainScreenFrame: NSScreen.main?.frame
        )
        let resolved: NotchIslandScreenInfo
        if let nsScreen = chosenFrame.flatMap({ frame in screens.first { $0.frame == frame } })
            ?? NSScreen.main
            ?? screens.first {
            resolved = NotchIslandGeometry.screenInfo(
                frame: nsScreen.frame,
                safeAreaTop: nsScreen.safeAreaInsets.top,
                leftAuxiliaryWidth: nsScreen.auxiliaryTopLeftArea?.width,
                rightAuxiliaryWidth: nsScreen.auxiliaryTopRightArea?.width
            )
        } else {
            resolved = NotchIslandScreenInfo(
                frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
                notchWidth: nil,
                rowHeight: NotchIslandGeometry.tabRowHeight
            )
        }
        screen = resolved
        return resolved
    }

    /// Where the focused text field of the app the words go to sits, in
    /// global Cocoa coordinates. One Accessibility round trip, bounded by
    /// `AccessibilityBridge`'s timeout; `currentScreen()` asks once per show.
    /// A "Not pasted" notice with no dictation app pastes into whatever is in
    /// front, so that app's field counts then.
    private func focusedFieldRect() -> CGRect? {
        guard let app = targetApp ?? Self.frontmostOtherApp(),
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let axRect = AccessibilityBridge.focusedTextFieldRect(for: app),
              let primaryFrame = NSScreen.screens.first?.frame else { return nil }
        return DictationOverlayPlacementPolicy.cocoaRect(fromAccessibilityRect: axRect, primaryScreenFrame: primaryFrame)
    }

    private func updateTicker() {
        guard isShown, dictation?.phase == .listening else {
            tickTask?.cancel()
            tickTask = nil
            return
        }
        guard tickTask == nil else { return }
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                self?.refreshLive()
            }
        }
    }

    // MARK: - The dictation that just landed

    private func scheduleRecentInsertExpiry() {
        recentInsertTask?.cancel()
        recentInsertTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.recentInsertLinger)
            // Reading it or reaching for Copy keeps it up.
            while let self, !Task.isCancelled, self.isHovered || self.expanded {
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
            guard !Task.isCancelled, let self else { return }
            self.recentInsertTask = nil
            self.recentInsert = nil
            self.render()
        }
    }

    private func clearRecentInsert() {
        recentInsertTask?.cancel()
        recentInsertTask = nil
        recentInsert = nil
    }

    // MARK: - Pointer and taps

    private func handleHover(_ hovered: Bool) {
        guard hovered != isHovered else { return }
        isHovered = hovered
        if callPrompt != nil { callHoverHandler?(hovered) }
        if speakerReview != nil { speakerReviewHoverHandler?(hovered) }
        islandView?.setCountdownPaused(hovered)
        hoverTask?.cancel()
        hoverTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: hovered ? Self.hoverOpenDelay : Self.hoverCloseDelay)
            guard !Task.isCancelled else { return }
            if !hovered {
                // An exit can arrive while the shape resizes under a still
                // pointer; only close once the pointer has really left.
                while self?.isPointerOverIsland == true {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                }
            }
            guard let self, self.isHovered == hovered, self.expanded != hovered else { return }
            self.expanded = hovered
            self.render()
        }
    }

    private func handleBackgroundClick() {
        if case .message? = dictation?.phase {
            dictationActionHandler?(.dictationDismissMessage)
            return
        }
        // Clicks between the review's rows mean nothing; Later and Done
        // are the ways out.
        if case .speakerReview? = lastLayout?.drop { return }
        let stickyKey = NotchIslandPresentation.stickyKey(dictation: dictation, meeting: meeting, callPrompt: callPrompt, speakerReview: speakerReview)
        if let stickyKey, lastLayout?.dropIsSticky == true {
            // Close the drop-down that opened by itself. It stays closed
            // until something new needs saying; a hover or click reopens it.
            collapsedStickyKey = stickyKey
            expanded = false
        } else {
            expanded.toggle()
        }
        hoverTask?.cancel()
        render()
    }

    private func handleAction(_ action: NotchIslandAction) {
        switch action.owner {
        case .dictation:
            dictationActionHandler?(action)
        case .meeting:
            meetingActionHandler?(action)
        case .callPrompt:
            callActionHandler?(action)
        case .island:
            handleOwnAction(action)
        }
    }

    private func handleOwnAction(_ action: NotchIslandAction) {
        switch action {
        case .copyLastDictation:
            guard let text = recentInsert?.text, !text.isEmpty else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            recentInsert?.title = "Copied"
            expanded = false
            render()
            scheduleRecentInsertExpiry()
        case .pasteLastDictation:
            clearRecentInsert()
            expanded = false
            render()
            onPasteLastDictation?()
        default:
            break
        }
    }
}
